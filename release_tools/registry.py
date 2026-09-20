"""VulnerabilityRegistry — 脆弱性/waiverのYAML永続化とCRUD、BR1.x/BR2.xの実装。

対応ビジネスルール: BR1.1, BR1.2, BR2.2, BR2.3, BR2.4(棚卸し・waiverの
発行/失効ライフサイクル)。
"""
from __future__ import annotations

from datetime import date
from pathlib import Path
from typing import Dict, List, Optional

import yaml

from .models import Vulnerability, VULNERABILITY_STATUSES, Waiver

# severity(棚卸し時の初期値)から priority を導出するマッピング。
# 1=最優先、4=最低優先。棚卸し時にseverityを初期値として設定する。
SEVERITY_TO_INITIAL_PRIORITY = {"Critical": 1, "High": 2, "Medium": 3, "Low": 4}

REGISTRY_SCHEMA_VERSION = 1


def compute_finding_status(vulnerability_status: Optional[str]) -> str:
    """BR2.4: FindingのstatusをVulnerability.statusに従属して計算する。

    Vulnerability.status=Waived の間はWaived、Fixedになった時点でResolved、
    それ以外(対応するVulnerabilityが存在しない場合を含む)はOpen。
    """
    if vulnerability_status == "Waived":
        return "Waived"
    if vulnerability_status == "Fixed":
        return "Resolved"
    return "Open"


class VulnerabilityRegistryError(Exception):
    """VulnerabilityRegistry操作に伴うドメインエラー(BR違反・不正な参照など)。"""


class VulnerabilityRegistry:
    """`data/vulnerability-registry.yaml` を単一のソース・オブ・トゥルースとする
    Vulnerability/WaiverのCRUD層。"""

    def __init__(self, path: Path | str, load_if_exists: bool = True) -> None:
        self.path = Path(path)
        self.vulnerabilities: Dict[str, Vulnerability] = {}
        self.waivers: Dict[str, Waiver] = {}
        if load_if_exists and self.path.exists():
            self.load()

    # --- 永続化 -----------------------------------------------------------

    def load(self) -> None:
        raw = self.path.read_text(encoding="utf-8")
        data = yaml.safe_load(raw) or {}
        self.vulnerabilities = {
            cve_id: Vulnerability.from_dict(v) for cve_id, v in (data.get("vulnerabilities") or {}).items()
        }
        self.waivers = {
            waiver_id: Waiver.from_dict(w) for waiver_id, w in (data.get("waivers") or {}).items()
        }

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        data = {
            "version": REGISTRY_SCHEMA_VERSION,
            "vulnerabilities": {cve_id: v.to_dict() for cve_id, v in sorted(self.vulnerabilities.items())},
            "waivers": {waiver_id: w.to_dict() for waiver_id, w in sorted(self.waivers.items())},
        }
        self.path.write_text(
            yaml.safe_dump(data, sort_keys=True, allow_unicode=True),
            encoding="utf-8",
        )

    # --- Vulnerability CRUD -------------------------------------------------

    def register_cve(
        self,
        cve_id: str,
        component_name: str,
        severity: str,
        fix_reference: Optional[str] = None,
    ) -> Vulnerability:
        """新規CVE/GHSAをVulnerability台帳に反映する(棚卸しワークフロー手順2)。

        priorityはseverityから初期導出する。
        """
        if cve_id in self.vulnerabilities:
            raise VulnerabilityRegistryError(f"{cve_id} は既に棚卸し済みです")
        priority = SEVERITY_TO_INITIAL_PRIORITY.get(severity)
        if priority is None:
            raise VulnerabilityRegistryError(f"severity が不正なため priority を導出できません: {severity!r}")
        vuln = Vulnerability(
            cve_id=cve_id,
            component_name=component_name,
            severity=severity,
            priority=priority,
            status="Open",
            fix_reference=fix_reference,
        )
        self.vulnerabilities[cve_id] = vuln
        return vuln

    def get_vulnerability(self, cve_id: str) -> Vulnerability:
        try:
            return self.vulnerabilities[cve_id]
        except KeyError as exc:
            raise VulnerabilityRegistryError(f"未棚卸しのCVE/GHSAです: {cve_id}") from exc

    def list_vulnerabilities(
        self, status: Optional[str] = None, component_name: Optional[str] = None
    ) -> List[Vulnerability]:
        values = list(self.vulnerabilities.values())
        if status is not None:
            values = [v for v in values if v.status == status]
        if component_name is not None:
            values = [v for v in values if v.component_name == component_name]
        return sorted(values, key=lambda v: (v.priority, v.cve_id))

    def update_status(self, cve_id: str, new_status: str, today: Optional[date] = None) -> Vulnerability:
        """汎用ステータス更新。BR1.2(Waivedへの遷移にはActiveなwaiverが必須)を強制する。"""
        vuln = self.get_vulnerability(cve_id)
        if new_status not in VULNERABILITY_STATUSES:
            raise VulnerabilityRegistryError(
                f"status は {VULNERABILITY_STATUSES} のいずれかでなければなりません: {new_status!r}"
            )
        if new_status == "Waived" and not self._has_active_waiver(cve_id, today or date.today()):
            raise VulnerabilityRegistryError(
                f"BR1.2違反: {cve_id} をWaivedにするにはstatus=ActiveなWaiverが最低1件必要です"
            )
        vuln.status = new_status
        return vuln

    def update_fix_reference(self, cve_id: str, fix_reference: str) -> Vulnerability:
        """修正コミット/パッチのトレーサビリティ(BR4.2)を記録する(棚卸しワークフロー手順4)。"""
        vuln = self.get_vulnerability(cve_id)
        vuln.fix_reference = fix_reference
        return vuln

    # --- Waiver CRUD ---------------------------------------------------------

    def issue_waiver(
        self,
        waiver_id: str,
        cve_id: str,
        reason: str,
        issued_at: date,
        expires_at: date,
    ) -> Waiver:
        """Waiverを発行し、Vulnerability.statusをWaivedへ更新する(棚卸しワークフロー手順5)。

        BR1.1(expires_at > issued_at)は `Waiver.__post_init__` が検証する。
        Waiver作成直後は必ずstatus=Activeであるため、BR1.2の前提はここで自動的に満たされる。
        """
        self.get_vulnerability(cve_id)  # 存在確認(未棚卸しのCVEへのwaiver発行を拒否)
        if waiver_id in self.waivers:
            raise VulnerabilityRegistryError(f"waiver_id が重複しています: {waiver_id}")
        waiver = Waiver(
            waiver_id=waiver_id,
            cve_id=cve_id,
            reason=reason,
            issued_at=issued_at,
            expires_at=expires_at,
            status="Active",
        )
        self.waivers[waiver_id] = waiver
        vuln = self.vulnerabilities[cve_id]
        vuln.status = "Waived"
        return waiver

    def get_waiver(self, waiver_id: str) -> Waiver:
        try:
            return self.waivers[waiver_id]
        except KeyError as exc:
            raise VulnerabilityRegistryError(f"未発行のwaiverです: {waiver_id}") from exc

    def list_waivers(self, cve_id: Optional[str] = None, status: Optional[str] = None) -> List[Waiver]:
        values = list(self.waivers.values())
        if cve_id is not None:
            values = [w for w in values if w.cve_id == cve_id]
        if status is not None:
            values = [w for w in values if w.status == status]
        return sorted(values, key=lambda w: w.waiver_id)

    # --- BR2.2 / BR2.3: 期限切れ評価 -------------------------------------------

    def evaluate_waiver_expiry(self, today: Optional[date] = None) -> dict:
        """BR2.2: 期限切れwaiverをExpiredへ、BR2.3: 紐づくActiveなwaiverが0件に
        なったVulnerability(Fixedを除く)をWaivedからOpenへ戻す。

        次回以降のScanRunゲート判定(BR2.1)の直前に必ず呼び出すことを想定する。
        既に公開済みのPublishedImageは遡って無効化しない(BR2.2の但し書き) —
        本メソッドはレジストリの状態のみを更新し、過去のPublishedImageレコードには
        一切触れないため、この制約は自然に満たされる。
        """
        today = today or date.today()
        changed = {"expired_waivers": [], "reverted_vulnerabilities": []}
        for waiver in self.waivers.values():
            if waiver.status == "Active" and waiver.expires_at < today:
                waiver.status = "Expired"
                changed["expired_waivers"].append(waiver.waiver_id)
        for vuln in self.vulnerabilities.values():
            # statusは単一フィールドのため「Waived」と「Fixed」は排他的に成立する。
            # BR2.3の「Fixedでない限り」は、Waived状態からの復帰判定にのみ関わる文言であり、
            # ここでのstatus=="Waived"チェック自体がその条件を包含している。
            if vuln.status == "Waived" and not self._has_active_waiver(vuln.cve_id, today):
                vuln.status = "Open"
                changed["reverted_vulnerabilities"].append(vuln.cve_id)
        return changed

    def is_waiver_active_for_gate(self, cve_id: str, today: Optional[date] = None) -> bool:
        """ScanRunnerゲート(BR2.1)向け: 期限切れ評価(BR2.2/BR2.3)を先に適用してから判定する。"""
        today = today or date.today()
        self.evaluate_waiver_expiry(today)
        return self._has_active_waiver(cve_id, today)

    def _has_active_waiver(self, cve_id: str, today: date) -> bool:
        return any(
            w.cve_id == cve_id and w.status == "Active" and w.expires_at >= today
            for w in self.waivers.values()
        )
