"""ScanRunner ゲート評価と、外部スキャンツール出力の正規化アダプタ。

対応ビジネスルール: BR2.1(ScanRunゲート)、BR3.1(公開前提条件ゲート)。
実際のTrivy/Semgrep/cppcheckは呼び出さない — ここではツール出力
(パース済みJSON、またはcppcheckのXML文字列)をFindingへ正規化するだけの
純粋関数として実装し、テストはツール出力を模したフィクスチャを渡して検証する。
"""
from __future__ import annotations

import json
import os
import xml.etree.ElementTree as ET
from datetime import date
from pathlib import Path
from typing import Any, Dict, List, Optional

from .models import CVE_ID_PATTERN, Finding
from .registry import VulnerabilityRegistry

_TRIVY_SEVERITY_MAP = {
    "CRITICAL": "Critical",
    "HIGH": "High",
    "MEDIUM": "Medium",
    "LOW": "Low",
    "UNKNOWN": "Low",
}

_SEMGREP_SEVERITY_MAP = {
    "ERROR": "High",
    "WARNING": "Medium",
    "INFO": "Low",
}

_CPPCHECK_SEVERITY_MAP = {
    "error": "High",
    "warning": "Medium",
    "style": "Low",
    "performance": "Low",
    "portability": "Low",
    "information": "Low",
}


def _looks_like_known_id(candidate: Optional[str]) -> bool:
    """CVE-YYYY-NNNN(N...) またはGHSA-xxxx-xxxx-xxxx形式かどうかを判定する。"""
    return bool(candidate) and bool(CVE_ID_PATTERN.match(candidate))


def normalize_trivy_findings(data: Dict[str, Any]) -> List[Finding]:
    """Trivy `--format json` の出力(SCA)をFinding一覧へ正規化する。"""
    findings: List[Finding] = []
    for result in data.get("Results", []) or []:
        target = result.get("Target", "unknown-target")
        for vuln in result.get("Vulnerabilities", []) or []:
            vuln_id = vuln.get("VulnerabilityID", "") or "UNKNOWN"
            severity = _TRIVY_SEVERITY_MAP.get((vuln.get("Severity") or "").upper(), "Low")
            cve_id = vuln_id if _looks_like_known_id(vuln_id) else None
            findings.append(
                Finding(
                    finding_id=f"trivy:{target}:{vuln_id}:{len(findings)}",
                    scan_run_id="",
                    severity=severity,
                    cve_id=cve_id,
                )
            )
    return findings


def _relative_path(path: str, source_root: Optional[str]) -> str:
    """baselineキー用にパスを `source_root` 相対のPOSIX形式へ正規化する。

    cppcheck/Semgrepは指定されたターゲットの書式(相対/絶対)をそのまま出力するため、
    実行環境(ローカル・CI・コンテナ)が違ってもキーが一致するよう揃える。
    """
    if not source_root:
        return os.path.normpath(path).replace(os.sep, "/")
    rel = os.path.relpath(os.path.abspath(path), os.path.abspath(source_root))
    if rel.startswith(".."):
        return os.path.normpath(path).replace(os.sep, "/")
    return rel.replace(os.sep, "/")


def normalize_semgrep_findings(data: Dict[str, Any], source_root: Optional[str] = None) -> List[Finding]:
    """Semgrep `--json` の出力(SAST、PHP/JS対象)をFinding一覧へ正規化する。"""
    findings: List[Finding] = []
    for idx, result in enumerate(data.get("results", []) or []):
        extra = result.get("extra", {}) or {}
        severity = _SEMGREP_SEVERITY_MAP.get((extra.get("severity") or "").upper(), "Medium")
        metadata = extra.get("metadata", {}) or {}
        cve_candidate = metadata.get("cve")
        cve_id = cve_candidate if _looks_like_known_id(cve_candidate) else None
        check_id = result.get("check_id", "unknown-rule")
        path = _relative_path(result.get("path", "unknown-path"), source_root)
        findings.append(
            Finding(
                finding_id=f"semgrep:{check_id}:{idx}",
                scan_run_id="",
                severity=severity,
                cve_id=cve_id,
                baseline_key=f"semgrep|{check_id}|{path}",
            )
        )
    return findings


def normalize_cppcheck_findings(xml_text: str, source_root: Optional[str] = None) -> List[Finding]:
    """cppcheck `--xml` の出力(SAST、C言語対象)をFinding一覧へ正規化する。

    cppcheckはCVE/GHSA IDを検出しないため、cve_idは常にNoneとなる
    (これらのfindingをwaiverするには人間によるVulnerability登録が
    別途必要になる)。
    """
    findings: List[Finding] = []
    root = ET.fromstring(xml_text)
    for idx, error in enumerate(root.iter("error")):
        severity = _CPPCHECK_SEVERITY_MAP.get(error.get("severity", ""), "Low")
        error_id = error.get("id", "unknown-check")
        location = error.find("location")
        raw_path = (location.get("file") if location is not None else None) or error.get("file0") or "unknown-path"
        path = _relative_path(raw_path, source_root)
        findings.append(
            Finding(
                finding_id=f"cppcheck:{error_id}:{idx}",
                scan_run_id="",
                severity=severity,
                cve_id=None,
                baseline_key=f"cppcheck|{error_id}|{path}|{error.get('msg', '')}",
            )
        )
    return findings


# --- SAST baseline(既知の指摘の台帳)------------------------------------------
#
# 上流ソースには本プロジェクトが修正しない既存の指摘が大量にある。全件を毎回Failに
# する代わりに、承認済みの既知の指摘(baseline)を件数付きで記録し、それを超える
# 「新規の指摘」だけをゲート対象にする。キーは行番号を含まないため、上流の行移動や
# 無関係なパッチでは変化しない。

BASELINE_SCHEMA_VERSION = 1
_GATED_SEVERITIES = ("Critical", "High", "Medium")


def build_baseline(findings: List[Finding]) -> Dict[str, int]:
    """ゲート対象severityのfindingを、baselineキーごとの件数へ集計する。"""
    counts: Dict[str, int] = {}
    for finding in findings:
        if finding.severity in _GATED_SEVERITIES and finding.baseline_key:
            counts[finding.baseline_key] = counts.get(finding.baseline_key, 0) + 1
    return dict(sorted(counts.items()))


def load_baseline(path: Path | str) -> Dict[str, int]:
    """`save_baseline` が書いたJSONを読み込む。存在しない・壊れている場合はValueError。"""
    baseline_path = Path(path)
    if not baseline_path.is_file():
        raise ValueError(f"baselineファイルが見つかりません: {baseline_path}")
    data = json.loads(baseline_path.read_text(encoding="utf-8"))
    if data.get("version") != BASELINE_SCHEMA_VERSION or not isinstance(data.get("entries"), dict):
        raise ValueError(f"baselineファイルの形式が不正です: {baseline_path}")
    return {str(key): int(count) for key, count in data["entries"].items()}


def save_baseline(path: Path | str, tool: str, entries: Dict[str, int], note: str = "") -> None:
    baseline_path = Path(path)
    baseline_path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "version": BASELINE_SCHEMA_VERSION,
        "tool": tool,
        "note": note,
        "entries": dict(sorted(entries.items())),
    }
    baseline_path.write_text(json.dumps(payload, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")


def apply_baseline(findings: List[Finding], baseline: Dict[str, int]) -> List[Finding]:
    """baselineで許容された件数を差し引き、残った(=新規の)findingを返す。

    ゲート対象外のseverityやbaseline_keyを持たないfindingは、そのまま残す。
    """
    remaining_allowance = dict(baseline)
    new_findings: List[Finding] = []
    for finding in findings:
        key = finding.baseline_key
        if finding.severity in _GATED_SEVERITIES and key and remaining_allowance.get(key, 0) > 0:
            remaining_allowance[key] -= 1
            continue
        new_findings.append(finding)
    return new_findings


def stale_baseline_entries(findings: List[Finding], baseline: Dict[str, int]) -> Dict[str, int]:
    """baselineの件数より現在の件数が少ない(=解消された)キーと、その差分を返す。

    情報提供のみで、ゲート判定には使わない(baselineの棚卸し・縮小の目安)。
    """
    current = build_baseline(findings)
    return {key: allowed - current.get(key, 0) for key, allowed in baseline.items() if current.get(key, 0) < allowed}


def scan_gate(
    findings: List[Finding],
    registry: VulnerabilityRegistry,
    today: Optional[date] = None,
) -> str:
    """BR2.1: Critical/High/Mediumかつ未waiverのFindingが1件でもあればFail。

    cve_idが判明しない(=未棚卸しの)findingは、そもそもwaiverが存在し得ないため
    無条件でFailの対象に含める(棚卸し・トリアージを促す)。
    """
    return "Fail" if unwaived_findings(findings, registry, today) else "Pass"


def unwaived_findings(
    findings: List[Finding],
    registry: VulnerabilityRegistry,
    today: Optional[date] = None,
) -> List[Finding]:
    """BR2.1でゲート対象(Critical/High/Medium)かつ有効なwaiverを持たないfindingを返す。"""
    today = today or date.today()
    blocking: List[Finding] = []
    for finding in findings:
        if finding.severity not in _GATED_SEVERITIES:
            continue
        has_waiver = bool(finding.cve_id) and registry.is_waiver_active_for_gate(finding.cve_id, today)
        if not has_waiver:
            blocking.append(finding)
    return blocking


def publish_gate(sca_verdict: str, sast_verdict: str, compat_result: str, secret_result: str) -> bool:
    """BR3.1: SCA用ScanRun=Pass かつ SAST用ScanRun=Pass かつ CompatibilityTestRun=Pass
    かつ SecretScanRun(ci)=Clean の4条件すべてを満たす場合のみ公開前提条件を満たす。
    """
    return sca_verdict == "Pass" and sast_verdict == "Pass" and compat_result == "Pass" and secret_result == "Clean"
