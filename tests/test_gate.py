"""ScanRunner ゲート評価(gate.py)のテスト。

対応ビジネスルール: BR2.1(ScanRunゲート)、BR3.1(公開前提条件ゲート)。
Trivy/Semgrep/cppcheckは実行しない — ツール出力を模したフィクスチャを
正規化関数に渡して検証する。
"""
from datetime import date

import pytest

from release_tools.gate import (
    normalize_cppcheck_findings,
    normalize_semgrep_findings,
    normalize_trivy_findings,
    publish_gate,
    scan_gate,
)
from release_tools.models import Finding
from release_tools.registry import VulnerabilityRegistry


@pytest.fixture()
def registry(tmp_path):
    return VulnerabilityRegistry(tmp_path / "vulnerability-registry.yaml")


def test_scan_gate_passes_when_critical_finding_has_active_waiver(registry):
    registry.register_cve("CVE-2026-10001", "zabbix-server", "Critical")
    registry.issue_waiver(
        waiver_id="waiver-cve-2026-10001",
        cve_id="CVE-2026-10001",
        reason="修正版未公開",
        issued_at=date(2026, 1, 1),
        expires_at=date(2026, 12, 31),
    )
    findings = [Finding(finding_id="f1", scan_run_id="scan-1", severity="Critical", cve_id="CVE-2026-10001")]

    assert scan_gate(findings, registry, today=date(2026, 6, 1)) == "Pass"


def test_scan_gate_fails_when_critical_finding_has_no_waiver(registry):
    registry.register_cve("CVE-2026-10002", "zabbix-server", "Critical")
    findings = [Finding(finding_id="f2", scan_run_id="scan-1", severity="Critical", cve_id="CVE-2026-10002")]

    assert scan_gate(findings, registry, today=date(2026, 6, 1)) == "Fail"


def test_scan_gate_fails_when_finding_has_no_known_cve(registry):
    # 未棚卸し(cve_id不明)のfindingはwaiverし得ないため無条件でFail対象とする。
    findings = [Finding(finding_id="f3", scan_run_id="scan-1", severity="High", cve_id=None)]

    assert scan_gate(findings, registry, today=date(2026, 6, 1)) == "Fail"


def test_scan_gate_passes_when_only_low_severity_findings_exist(registry):
    # 境界値: Low severityはBR2.1のゲート判定対象外(Critical/High/Mediumのみ判定)。
    findings = [Finding(finding_id="f4", scan_run_id="scan-1", severity="Low", cve_id=None)]

    assert scan_gate(findings, registry, today=date(2026, 6, 1)) == "Pass"


def test_scan_gate_fails_when_waiver_has_expired(registry):
    # BR2.2: expires_atを過ぎたwaiverはActiveとみなさない。
    registry.register_cve("CVE-2026-10003", "zabbix-web", "Medium")
    registry.issue_waiver(
        waiver_id="waiver-cve-2026-10003",
        cve_id="CVE-2026-10003",
        reason="期限切れ確認用",
        issued_at=date(2026, 1, 1),
        expires_at=date(2026, 1, 31),
    )
    findings = [Finding(finding_id="f5", scan_run_id="scan-1", severity="Medium", cve_id="CVE-2026-10003")]

    assert scan_gate(findings, registry, today=date(2026, 2, 15)) == "Fail"


def test_scan_gate_empty_findings_passes(registry):
    assert scan_gate([], registry, today=date(2026, 6, 1)) == "Pass"


@pytest.mark.parametrize(
    ("sca", "sast", "compat", "secret", "expected"),
    [
        ("Pass", "Pass", "Pass", "Clean", True),
        ("Fail", "Pass", "Pass", "Clean", False),
        ("Pass", "Fail", "Pass", "Clean", False),
        ("Pass", "Pass", "Fail", "Clean", False),
        ("Pass", "Pass", "Pass", "Blocked", False),
    ],
)
def test_publish_gate_br3_1_requires_all_four_conditions(sca, sast, compat, secret, expected):
    assert publish_gate(sca, sast, compat, secret) is expected


def test_normalize_trivy_findings_maps_severity_and_cve_id():
    trivy_output = {
        "Results": [
            {
                "Target": "tamacat/zabbix-server:6.0.48-r20260920-amd64",
                "Vulnerabilities": [
                    {"VulnerabilityID": "CVE-2026-20001", "Severity": "CRITICAL"},
                    {"VulnerabilityID": "CVE-2026-20002", "Severity": "LOW"},
                ],
            }
        ]
    }

    findings = normalize_trivy_findings(trivy_output)

    assert [f.severity for f in findings] == ["Critical", "Low"]
    assert [f.cve_id for f in findings] == ["CVE-2026-20001", "CVE-2026-20002"]


def test_normalize_semgrep_findings_maps_severity():
    semgrep_output = {
        "results": [
            {"check_id": "php.lang.security.injection", "extra": {"severity": "ERROR", "metadata": {}}},
        ]
    }

    findings = normalize_semgrep_findings(semgrep_output)

    assert findings[0].severity == "High"
    assert findings[0].cve_id is None


def test_normalize_cppcheck_findings_maps_severity_from_xml():
    cppcheck_xml = (
        "<results><errors>"
        '<error id="nullPointer" severity="error" msg="null pointer" />'
        '<error id="unusedVariable" severity="style" msg="unused" />'
        "</errors></results>"
    )

    findings = normalize_cppcheck_findings(cppcheck_xml)

    assert [f.severity for f in findings] == ["High", "Low"]
    assert all(f.cve_id is None for f in findings)
