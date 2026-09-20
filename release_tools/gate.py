"""ScanRunner ゲート評価と、外部スキャンツール出力の正規化アダプタ。

対応ビジネスルール: BR2.1(ScanRunゲート)、BR3.1(公開前提条件ゲート)。
実際のTrivy/Semgrep/cppcheckは呼び出さない — ここではツール出力
(パース済みJSON、またはcppcheckのXML文字列)をFindingへ正規化するだけの
純粋関数として実装し、テストはツール出力を模したフィクスチャを渡して検証する。
"""
from __future__ import annotations

import xml.etree.ElementTree as ET
from datetime import date
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


def normalize_semgrep_findings(data: Dict[str, Any]) -> List[Finding]:
    """Semgrep `--json` の出力(SAST、PHP/JS対象)をFinding一覧へ正規化する。"""
    findings: List[Finding] = []
    for idx, result in enumerate(data.get("results", []) or []):
        extra = result.get("extra", {}) or {}
        severity = _SEMGREP_SEVERITY_MAP.get((extra.get("severity") or "").upper(), "Medium")
        metadata = extra.get("metadata", {}) or {}
        cve_candidate = metadata.get("cve")
        cve_id = cve_candidate if _looks_like_known_id(cve_candidate) else None
        check_id = result.get("check_id", "unknown-rule")
        findings.append(
            Finding(
                finding_id=f"semgrep:{check_id}:{idx}",
                scan_run_id="",
                severity=severity,
                cve_id=cve_id,
            )
        )
    return findings


def normalize_cppcheck_findings(xml_text: str) -> List[Finding]:
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
        findings.append(
            Finding(
                finding_id=f"cppcheck:{error_id}:{idx}",
                scan_run_id="",
                severity=severity,
                cve_id=None,
            )
        )
    return findings


def scan_gate(
    findings: List[Finding],
    registry: VulnerabilityRegistry,
    today: Optional[date] = None,
) -> str:
    """BR2.1: Critical/High/Mediumかつ未waiverのFindingが1件でもあればFail。

    cve_idが判明しない(=未棚卸しの)findingは、そもそもwaiverが存在し得ないため
    無条件でFailの対象に含める(棚卸し・トリアージを促す)。
    """
    today = today or date.today()
    for finding in findings:
        if finding.severity not in ("Critical", "High", "Medium"):
            continue
        has_waiver = bool(finding.cve_id) and registry.is_waiver_active_for_gate(finding.cve_id, today)
        if not has_waiver:
            return "Fail"
    return "Pass"


def publish_gate(sca_verdict: str, sast_verdict: str, compat_result: str, secret_result: str) -> bool:
    """BR3.1: SCA用ScanRun=Pass かつ SAST用ScanRun=Pass かつ CompatibilityTestRun=Pass
    かつ SecretScanRun(ci)=Clean の4条件すべてを満たす場合のみ公開前提条件を満たす。
    """
    return sca_verdict == "Pass" and sast_verdict == "Pass" and compat_result == "Pass" and secret_result == "Clean"
