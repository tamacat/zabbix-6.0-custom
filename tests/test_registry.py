"""VulnerabilityRegistry のテスト。

対応ビジネスルール: BR1.1, BR1.2, BR2.2, BR2.3, BR2.4。
テスト用データは `tmp_path` に都度YAMLを生成し、実運用データ
(`data/vulnerability-registry.yaml`)には書き込まない。
"""
from datetime import date

import pytest

from release_tools.registry import (
    VulnerabilityRegistry,
    VulnerabilityRegistryError,
    compute_finding_status,
)


@pytest.fixture()
def registry(tmp_path):
    return VulnerabilityRegistry(tmp_path / "vulnerability-registry.yaml")


def test_register_cve_derives_priority_from_severity(registry):
    vuln = registry.register_cve("CVE-2026-00001", "zabbix-server", "Critical")

    assert vuln.status == "Open"
    assert vuln.priority == 1  # Critical -> 1 (最優先)
    assert registry.get_vulnerability("CVE-2026-00001") is vuln


def test_register_cve_rejects_duplicate(registry):
    registry.register_cve("CVE-2026-00001", "zabbix-server", "Critical")

    with pytest.raises(VulnerabilityRegistryError):
        registry.register_cve("CVE-2026-00001", "zabbix-server", "Critical")


def test_issue_waiver_sets_vulnerability_to_waived(registry):
    registry.register_cve("CVE-2026-00002", "zabbix-web", "High")

    waiver = registry.issue_waiver(
        waiver_id="waiver-cve-2026-00002",
        cve_id="CVE-2026-00002",
        reason="修正版が未公開のため",
        issued_at=date(2026, 1, 1),
        expires_at=date(2026, 2, 1),
    )

    assert waiver.status == "Active"
    assert registry.get_vulnerability("CVE-2026-00002").status == "Waived"


def test_br1_1_rejects_expires_at_not_after_issued_at(registry):
    registry.register_cve("CVE-2026-00003", "zabbix-agent2", "Medium")

    with pytest.raises(ValueError):
        registry.issue_waiver(
            waiver_id="waiver-cve-2026-00003",
            cve_id="CVE-2026-00003",
            reason="expires_atがissued_at以前(不正)",
            issued_at=date(2026, 2, 1),
            expires_at=date(2026, 1, 1),
        )


def test_br1_2_rejects_waived_transition_without_active_waiver(registry):
    registry.register_cve("CVE-2026-00004", "zabbix-proxy", "Low")

    with pytest.raises(VulnerabilityRegistryError):
        registry.update_status("CVE-2026-00004", "Waived")


def test_br2_2_expires_active_waiver_past_expiry(registry):
    registry.register_cve("CVE-2026-00005", "zabbix-server", "High")
    registry.issue_waiver(
        waiver_id="waiver-cve-2026-00005",
        cve_id="CVE-2026-00005",
        reason="期限切れ確認用",
        issued_at=date(2026, 1, 1),
        expires_at=date(2026, 1, 31),
    )

    changed = registry.evaluate_waiver_expiry(today=date(2026, 2, 1))

    assert "waiver-cve-2026-00005" in changed["expired_waivers"]
    assert registry.get_waiver("waiver-cve-2026-00005").status == "Expired"


def test_br2_3_reverts_to_open_when_no_active_waiver_remains(registry):
    registry.register_cve("CVE-2026-00006", "zabbix-web", "Medium")
    registry.issue_waiver(
        waiver_id="waiver-cve-2026-00006",
        cve_id="CVE-2026-00006",
        reason="期限切れ後のOpen復帰確認用",
        issued_at=date(2026, 1, 1),
        expires_at=date(2026, 1, 31),
    )

    registry.evaluate_waiver_expiry(today=date(2026, 2, 1))

    assert registry.get_vulnerability("CVE-2026-00006").status == "Open"


def test_br2_3_does_not_revert_fixed_vulnerability(registry):
    # Fixedへ遷移済みのVulnerabilityは、waiver期限切れの影響を受けない
    # (statusはWaivedとFixedが排他的なため、Fixed後にevaluate_waiver_expiryが
    # 誤ってstatusを書き換えないことを確認する)。
    vuln = registry.register_cve("CVE-2026-00007", "zabbix-agent2", "Low")
    registry.issue_waiver(
        waiver_id="waiver-cve-2026-00007",
        cve_id="CVE-2026-00007",
        reason="修正完了前提の確認用",
        issued_at=date(2026, 1, 1),
        expires_at=date(2026, 1, 31),
    )
    vuln.status = "Fixed"

    registry.evaluate_waiver_expiry(today=date(2026, 2, 1))

    assert registry.get_vulnerability("CVE-2026-00007").status == "Fixed"


@pytest.mark.parametrize(
    ("vulnerability_status", "expected_finding_status"),
    [
        ("Waived", "Waived"),
        ("Fixed", "Resolved"),
        ("Open", "Open"),
        ("InProgress", "Open"),
        (None, "Open"),
    ],
)
def test_br2_4_compute_finding_status(vulnerability_status, expected_finding_status):
    assert compute_finding_status(vulnerability_status) == expected_finding_status


def test_crud_round_trip_persists_to_yaml(tmp_path):
    path = tmp_path / "vulnerability-registry.yaml"
    registry = VulnerabilityRegistry(path)
    registry.register_cve("CVE-2026-00008", "zabbix-server", "Critical", fix_reference="Fixes: CVE-2026-00008")
    registry.issue_waiver(
        waiver_id="waiver-cve-2026-00008",
        cve_id="CVE-2026-00008",
        reason="ラウンドトリップ確認用",
        issued_at=date(2026, 1, 1),
        expires_at=date(2026, 3, 1),
    )
    registry.save()

    reloaded = VulnerabilityRegistry(path)

    assert reloaded.get_vulnerability("CVE-2026-00008").status == "Waived"
    assert reloaded.get_vulnerability("CVE-2026-00008").fix_reference == "Fixes: CVE-2026-00008"
    assert reloaded.get_waiver("waiver-cve-2026-00008").expires_at == date(2026, 3, 1)
