"""release_tools.cli の統合テスト(Build and Test — integration-test-instructions.md)。

release_tools/test_registry.py・test_gate.py・test_tagging.py は各モジュールを
単体で検証する。本ファイルはCLIサブコマンドを実際に呼び出し、
CLI → registry.py / gate.py / tagging.py の連携が壊れていないことを確認する
「主要な境界テスト」(Standard戦略)である。
"""
from __future__ import annotations

import json

import pytest

from release_tools import cli
from release_tools.registry import VulnerabilityRegistry


def _run(monkeypatch, capsys, argv):
    """cli.main(argv) を実行し、(exit_code, stdout) を返す。"""
    exit_code = cli.main(argv)
    captured = capsys.readouterr()
    return exit_code, captured.out


def test_register_then_list_roundtrip_via_cli(tmp_path, capsys):
    registry_path = tmp_path / "registry.yaml"
    argv_register = [
        "register-cve",
        "--cve-id", "CVE-2026-00001",
        "--component", "zabbix-server",
        "--severity", "High",
        "--registry", str(registry_path),
    ]
    exit_code, _ = _run(None, capsys, argv_register)
    assert exit_code == 0

    exit_code, out = _run(None, capsys, ["list", "--registry", str(registry_path)])
    assert exit_code == 0
    listed = json.loads(out)
    assert len(listed) == 1
    assert listed[0]["cve_id"] == "CVE-2026-00001"
    assert listed[0]["status"] == "Open"


def test_waive_updates_status_to_waived_via_cli(tmp_path, capsys):
    registry_path = tmp_path / "registry.yaml"
    _run(None, capsys, [
        "register-cve",
        "--cve-id", "CVE-2026-00002",
        "--component", "zabbix-web",
        "--severity", "Critical",
        "--registry", str(registry_path),
    ])

    exit_code, _ = _run(None, capsys, [
        "waive",
        "--cve-id", "CVE-2026-00002",
        "--waiver-id", "waiver-cve-2026-00002",
        "--reason", "修正版未公開のため",
        "--issued-at", "2026-09-20",
        "--expires-at", "2026-12-31",
        "--registry", str(registry_path),
    ])
    assert exit_code == 0

    exit_code, out = _run(None, capsys, [
        "list", "--status", "Waived", "--registry", str(registry_path),
    ])
    assert exit_code == 0
    listed = json.loads(out)
    assert [v["cve_id"] for v in listed] == ["CVE-2026-00002"]


def test_fixed_status_survives_expired_waiver_via_scan_gate_cli(tmp_path, capsys):
    """BR2.3の例外(Fixedはwaiver失効で自動的にOpenへ戻らない)を、
    CLI経由(scan-gateサブコマンドがregistry.is_waiver_active_for_gate経由で
    evaluate_waiver_expiryを呼び出す実際の経路)で確認する。"""
    registry_path = tmp_path / "registry.yaml"
    _run(None, capsys, [
        "register-cve",
        "--cve-id", "CVE-2026-00003",
        "--component", "zabbix-agent2",
        "--severity", "Medium",
        "--registry", str(registry_path),
    ])
    # 既に期限切れのwaiverを発行する(issued_atも過去日付にして BR1.1 を満たす)。
    _run(None, capsys, [
        "waive",
        "--cve-id", "CVE-2026-00003",
        "--waiver-id", "waiver-cve-2026-00003",
        "--reason", "テスト用の期限切れwaiver",
        "--issued-at", "2026-01-01",
        "--expires-at", "2026-01-31",
        "--registry", str(registry_path),
    ])

    registry = VulnerabilityRegistry(registry_path)
    registry.update_status("CVE-2026-00003", "Fixed")
    registry.save()

    trivy_input = tmp_path / "trivy-output.json"
    trivy_input.write_text(
        json.dumps({
            "Results": [
                {
                    "Target": "tamacat/zabbix-agent2:probe",
                    "Vulnerabilities": [
                        {"VulnerabilityID": "CVE-2026-00003", "Severity": "MEDIUM"},
                    ],
                }
            ]
        }),
        encoding="utf-8",
    )

    exit_code, out = _run(None, capsys, [
        "scan-gate",
        "--tool", "trivy",
        "--input", str(trivy_input),
        "--today", "2026-09-20",  # waiverは既に期限切れの日付
        "--registry", str(registry_path),
    ])
    # 未waiver扱いになりFail(waiverが失効しているため)。
    assert exit_code == 1
    assert out.strip() == "Fail"

    # BR2.3: Fixedであるため、waiver失効評価(scan-gate内部で実行済み)を経ても
    # OpenへはUnauthorized。
    reloaded = VulnerabilityRegistry(registry_path)
    assert reloaded.get_vulnerability("CVE-2026-00003").status == "Fixed"


@pytest.mark.parametrize("component", ["zabbix-server", "zabbix-web", "zabbix-agent2", "zabbix-proxy"])
def test_generate_tag_via_cli_matches_br41_format(component, capsys):
    exit_code, out = _run(None, capsys, [
        "generate-tag",
        "--component", component,
        "--zabbix-version", "6.0.48",
        "--build-date", "20260920",
    ])
    assert exit_code == 0
    short = component.removeprefix("zabbix-")
    assert out.strip() == f"tamacat/zabbix-{short}:6.0.48-r20260920-amd64"
