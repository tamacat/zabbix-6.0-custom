"""エンティティモデル定義。

VulnerabilityRegistry・ScanRunner・ImagePublisher等が扱う各エンティティの
型・必須・allowed_values・pattern制約の機械可読ソース・オブ・トゥルース。
各クラスは `__post_init__` でこれらの制約を検証し、違反時は
`ValueError`/`TypeError` を送出する(fail fast)。

## Key Decision: Finding.cve_id / Vulnerability相関キーの追加

Findingは元々のエンティティ定義に `cve_id` 属性を持たないが、
「Finding may correspond to one known Vulnerability」(0..* to 0..1)という
関係性が定義されており、BR2.1(未waiver findingの判定)・BR2.4
(FindingステータスのVulnerability従属)はいずれもこの相関が実装上
必須である。属性一覧の漏れと判断し、既存の `Vulnerability.cve_id` と
同じフォーマットの任意項目として追加した。これは新しい業務要件の追加では
なく、既に確定した関係性を実装可能にするための最小限の補完である。
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import date, datetime
from typing import List, Optional

# --- 許可値・パターン ----------------------------------------------------------

COMPONENT_NAMES = ("zabbix-server", "zabbix-web", "zabbix-agent2", "zabbix-proxy")
SEVERITIES = ("Critical", "High", "Medium", "Low")
VULNERABILITY_STATUSES = ("Open", "InProgress", "Fixed", "Waived")
WAIVER_STATUSES = ("Active", "Expired", "Superseded")
SCAN_TYPES = ("SCA", "SAST")
SCAN_VERDICTS = ("Pass", "Fail")
FINDING_STATUSES = ("Open", "Waived", "Resolved")
SECRET_SCAN_TRIGGERS = ("pre-commit", "ci")
SECRET_SCAN_RESULTS = ("Clean", "Blocked")
COMPAT_RESULTS = ("Pass", "Fail")
ARCHITECTURES = ("amd64",)  # BR5.2: 初回リリースはamd64のみ

CVE_ID_PATTERN = re.compile(r"^(CVE-\d{4}-\d{4,}|GHSA-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4})$")
WAIVER_ID_PATTERN = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")  # kebab-case


def _require(condition: bool, message: str) -> None:
    """検証条件を満たさない場合に ValueError を送出するガード節ヘルパー。"""
    if not condition:
        raise ValueError(message)


# --- VulnerabilityRegistry が所有するエンティティ ------------------------------

@dataclass
class Vulnerability:
    """対象コンポーネントに存在する既知の脆弱性(CVE/GHSA)の棚卸し記録。"""

    cve_id: str
    component_name: str
    severity: str
    priority: int
    status: str = "Open"
    fix_reference: Optional[str] = None

    def __post_init__(self) -> None:
        _require(
            bool(CVE_ID_PATTERN.match(self.cve_id)),
            f"cve_id はCVE-YYYY-NNNN(N...)またはGHSA-xxxx-xxxx-xxxx形式でなければなりません: {self.cve_id!r}",
        )
        _require(
            self.component_name in COMPONENT_NAMES,
            f"component_name は {COMPONENT_NAMES} のいずれかでなければなりません: {self.component_name!r}",
        )
        _require(
            self.severity in SEVERITIES,
            f"severity は {SEVERITIES} のいずれかでなければなりません: {self.severity!r}",
        )
        _require(
            self.status in VULNERABILITY_STATUSES,
            f"status は {VULNERABILITY_STATUSES} のいずれかでなければなりません: {self.status!r}",
        )
        _require(
            isinstance(self.priority, int) and 1 <= self.priority <= 4,
            f"priority は1〜4の整数でなければなりません: {self.priority!r}",
        )

    def to_dict(self) -> dict:
        return {
            "cve_id": self.cve_id,
            "component_name": self.component_name,
            "severity": self.severity,
            "priority": self.priority,
            "status": self.status,
            "fix_reference": self.fix_reference,
        }

    @classmethod
    def from_dict(cls, data: dict) -> "Vulnerability":
        return cls(**data)


@dataclass
class Waiver:
    """修正版が未公開の脆弱性に対して発行される期限付き例外。"""

    waiver_id: str
    cve_id: str
    reason: str
    issued_at: date
    expires_at: date
    status: str = "Active"

    def __post_init__(self) -> None:
        _require(
            bool(WAIVER_ID_PATTERN.match(self.waiver_id)),
            f"waiver_id はkebab-caseでなければなりません(例: waiver-cve-2026-00001): {self.waiver_id!r}",
        )
        _require(bool(self.reason and self.reason.strip()), "reason は空文字であってはなりません(BR1.1関連)")
        _require(isinstance(self.issued_at, date), f"issued_at はdate型でなければなりません: {self.issued_at!r}")
        _require(isinstance(self.expires_at, date), f"expires_at はdate型でなければなりません: {self.expires_at!r}")
        _require(
            self.expires_at > self.issued_at,
            f"BR1.1違反: expires_at({self.expires_at})はissued_at({self.issued_at})より後でなければなりません",
        )
        _require(
            self.status in WAIVER_STATUSES,
            f"status は {WAIVER_STATUSES} のいずれかでなければなりません: {self.status!r}",
        )

    def to_dict(self) -> dict:
        return {
            "waiver_id": self.waiver_id,
            "cve_id": self.cve_id,
            "reason": self.reason,
            "issued_at": self.issued_at.isoformat(),
            "expires_at": self.expires_at.isoformat(),
            "status": self.status,
        }

    @classmethod
    def from_dict(cls, data: dict) -> "Waiver":
        d = dict(data)
        if isinstance(d.get("issued_at"), str):
            d["issued_at"] = date.fromisoformat(d["issued_at"])
        if isinstance(d.get("expires_at"), str):
            d["expires_at"] = date.fromisoformat(d["expires_at"])
        return cls(**d)


# --- BuildPipeline が所有するエンティティ --------------------------------------

@dataclass
class ImageBuildTarget:
    """ビルド対象コンポーネントごとのビルド構成。"""

    component_name: str
    base_image_version: str
    tag_template: str
    dockerfile_path: str
    database_engines: str
    architecture: str = "amd64"

    def __post_init__(self) -> None:
        _require(
            self.component_name in COMPONENT_NAMES,
            f"component_name は {COMPONENT_NAMES} のいずれかでなければなりません(FR1.5: zabbix-java-gatewayは対象外): {self.component_name!r}",
        )
        _require(
            self.architecture in ARCHITECTURES,
            f"BR5.2違反: 初回リリースはamd64のみ対応です: {self.architecture!r}",
        )
        _require(bool(self.base_image_version), "base_image_version は必須です")
        _require(bool(self.tag_template), "tag_template は必須です")
        _require(bool(self.dockerfile_path), "dockerfile_path は必須です")
        allowed_engines = {"MySQL", "SQLite3"} if self.component_name == "zabbix-proxy" else {"MySQL"}
        _require(
            self.database_engines in allowed_engines,
            f"BR5.1違反: {self.component_name} が使用可能なdatabase_enginesは {sorted(allowed_engines)} です: {self.database_engines!r}",
        )


# --- ScanRunner が所有するエンティティ ------------------------------------------

@dataclass
class ScanRun:
    """SCA(依存関係・イメージ)またはSAST(ソース)の1回のスキャン実行記録。"""

    scan_run_id: str
    scan_type: str
    target_image: str
    tool: str
    executed_at: datetime
    verdict: str

    def __post_init__(self) -> None:
        _require(self.scan_type in SCAN_TYPES, f"scan_type は {SCAN_TYPES} のいずれかでなければなりません: {self.scan_type!r}")
        _require(
            self.target_image in COMPONENT_NAMES,
            f"target_image は {COMPONENT_NAMES} のいずれかでなければなりません: {self.target_image!r}",
        )
        _require(bool(self.tool), "tool は必須です")
        _require(self.verdict in SCAN_VERDICTS, f"verdict は {SCAN_VERDICTS} のいずれかでなければなりません: {self.verdict!r}")


@dataclass
class Finding:
    """1回のスキャンで検出された個別の指摘。"""

    finding_id: str
    scan_run_id: str
    severity: str
    status: str = "Open"
    # 補足: モジュールdocstring「Key Decision」参照。元々のattributes一覧には
    # 明記されていないが、relationshipsで定義された「Finding may correspond to one
    # known Vulnerability」を実装するための相関キーとして追加した。
    cve_id: Optional[str] = None
    # SASTのbaseline照合用の、行番号に依存しない安定キー(gate.pyが設定する)。
    baseline_key: Optional[str] = None

    def __post_init__(self) -> None:
        _require(self.severity in SEVERITIES, f"severity は {SEVERITIES} のいずれかでなければなりません: {self.severity!r}")
        _require(self.status in FINDING_STATUSES, f"status は {FINDING_STATUSES} のいずれかでなければなりません: {self.status!r}")
        if self.cve_id is not None:
            _require(
                bool(CVE_ID_PATTERN.match(self.cve_id)),
                f"cve_id はCVE-YYYY-NNNN(N...)またはGHSA-xxxx-xxxx-xxxx形式でなければなりません: {self.cve_id!r}",
            )


# --- SecretScanner が所有するエンティティ ---------------------------------------

@dataclass
class SecretScanRun:
    """pre-commitまたはCIでの機密情報スキャン1回の実行記録。"""

    run_id: str
    trigger: str
    executed_at: datetime
    result: str
    findings_count: int = 0

    def __post_init__(self) -> None:
        _require(
            self.trigger in SECRET_SCAN_TRIGGERS,
            f"trigger は {SECRET_SCAN_TRIGGERS} のいずれかでなければなりません: {self.trigger!r}",
        )
        _require(
            self.result in SECRET_SCAN_RESULTS,
            f"result は {SECRET_SCAN_RESULTS} のいずれかでなければなりません: {self.result!r}",
        )
        _require(self.findings_count >= 0, f"findings_count は0以上でなければなりません: {self.findings_count!r}")


# --- CompatibilityTestRunner が所有するエンティティ ------------------------------

@dataclass
class CompatibilityTestRun:
    """podman/docker composeによる構築・起動・スモークテストの1回の実行記録。"""

    run_id: str
    compose_config: str
    executed_at: datetime
    result: str
    compatibility_checks: str

    def __post_init__(self) -> None:
        _require(bool(self.compose_config), "compose_config は必須です")
        _require(self.result in COMPAT_RESULTS, f"result は {COMPAT_RESULTS} のいずれかでなければなりません: {self.result!r}")
        _require(bool(self.compatibility_checks), "compatibility_checks は必須です")


# --- ImagePublisher が所有するエンティティ --------------------------------------

@dataclass
class PublishedImage:
    """Docker Hubへ公開されたイメージの記録。"""

    image_tag: str
    component_name: str
    published_at: datetime
    source_scan_run_ids: List[str] = field(default_factory=list)
    registry: str = "Docker Hub"

    def __post_init__(self) -> None:
        _require(
            self.component_name in COMPONENT_NAMES,
            f"component_name は {COMPONENT_NAMES} のいずれかでなければなりません: {self.component_name!r}",
        )
        _short_component = (
            self.component_name[len("zabbix-"):]
            if self.component_name.startswith("zabbix-")
            else self.component_name
        )
        _require(
            self.image_tag.startswith(f"tamacat/zabbix-{_short_component}"),
            f"BR4.1違反: image_tag は tamacat/zabbix-{_short_component} 形式でなければなりません"
            f"(tagging.short_component_name参照): {self.image_tag!r}",
        )
        _require(
            len(self.source_scan_run_ids) == 2,
            f"BR3.1違反: source_scan_run_idsはSCA用・SAST用の2件でなければなりません(現在{len(self.source_scan_run_ids)}件)",
        )
