"""Job Summary(release_tools/ci_summary.py)のテスト。

サマリーは表示専用なので、(1) 記録の内訳が scan-gate の判定と食い違わないこと、
(2) 記録に失敗しても判定が変わらないこと、(3) 前回のSBOMとの差分が正しく出ること、を確かめる。
"""
from __future__ import annotations

import io
import json
from datetime import date

import pytest

from release_tools import cli
from release_tools.ci_summary import (
    append_record,
    build_scan_record,
    diff_packages,
    load_records,
    load_sbom_dir,
    main_render,
    render_summary,
)
from release_tools.models import Finding
from release_tools.registry import VulnerabilityRegistry


def _finding(idx, severity, cve_id=None):
    return Finding(finding_id=f"f{idx}", scan_run_id="", severity=severity, cve_id=cve_id)


# --- 記録の内訳 -----------------------------------------------------------------


def test_scan_record_splits_findings_into_waived_blocking_and_ungated():
    findings = [
        _finding(1, "High", "CVE-2026-00001"),    # waiver済み
        _finding(2, "Medium", "CVE-2026-00002"),  # 未対応(ゲート対象)
        _finding(3, "Low", "CVE-2026-00003"),     # ゲート対象外
        _finding(4, "Critical", None),            # 未棚卸し=未対応
    ]
    blocking = [findings[1], findings[3]]

    record = build_scan_record("trivy", "img:1", "Fail", findings, findings, blocking)

    assert record["counts"] == {"Critical": 1, "High": 1, "Medium": 1, "Low": 1}
    assert record["waived"] == 1
    assert record["blocking"] == 2
    assert record["baseline_known"] == 0
    assert record["waived_ids"] == ["CVE-2026-00001"]


def test_scan_record_counts_what_the_baseline_absorbed():
    all_findings = [_finding(i, "Medium") for i in range(5)]
    remaining = all_findings[3:]  # baselineが3件を吸収

    record = build_scan_record("cppcheck", "範囲: full", "Fail", all_findings, remaining, remaining)

    assert record["baseline_known"] == 3
    assert record["blocking"] == 2
    assert record["waived"] == 0


# --- scan-gate 経由 ---------------------------------------------------------------


def _trivy_json(tmp_path, vulns):
    path = tmp_path / "trivy.json"
    path.write_text(json.dumps({"Results": [{"Target": "t", "Vulnerabilities": vulns}]}), encoding="utf-8")
    return path


def test_scan_gate_writes_a_record_that_matches_the_verdict(tmp_path):
    registry_path = tmp_path / "registry.yaml"
    registry = VulnerabilityRegistry(registry_path)
    registry.register_cve("CVE-2026-00001", "zabbix-web", "High")
    registry.issue_waiver("waiver-cve-2026-00001", "CVE-2026-00001", "修正版未公開", date(2026, 9, 1), date(2026, 12, 1))
    registry.save()
    scan = _trivy_json(tmp_path, [
        {"VulnerabilityID": "CVE-2026-00001", "Severity": "HIGH"},
        {"VulnerabilityID": "CVE-2026-00002", "Severity": "LOW"},
    ])
    summary = tmp_path / "out" / "summary.jsonl"  # 親ディレクトリが無くても作る

    exit_code = cli.main([
        "scan-gate", "--tool", "trivy", "--input", str(scan), "--registry", str(registry_path),
        "--today", "2026-10-01", "--summary-file", str(summary), "--label", "tamacat/zabbix-web:x",
    ])

    assert exit_code == 0
    [record] = load_records(summary)
    assert record["verdict"] == "Pass"
    assert record["target"] == "tamacat/zabbix-web:x"
    assert record["counts"]["High"] == 1 and record["counts"]["Low"] == 1
    assert record["waived"] == 1 and record["blocking"] == 0
    assert record["waived_ids"] == ["CVE-2026-00001"]


def test_scan_gate_verdict_is_unchanged_when_the_summary_cannot_be_written(tmp_path, capsys):
    scan = _trivy_json(tmp_path, [{"VulnerabilityID": "CVE-2026-00009", "Severity": "HIGH"}])
    blocker = tmp_path / "file"
    blocker.write_text("x", encoding="utf-8")  # これを親ディレクトリにすると書けない

    exit_code = cli.main([
        "scan-gate", "--tool", "trivy", "--input", str(scan), "--registry", str(tmp_path / "r.yaml"),
        "--summary-file", str(blocker / "summary.jsonl"),
    ])
    captured = capsys.readouterr()

    assert exit_code == 1  # 未waiverのHighなのでFailのまま
    assert captured.out.strip() == "Fail"
    assert "サマリーの記録に失敗" in captured.err


def test_scan_gate_without_summary_file_writes_nothing(tmp_path):
    scan = _trivy_json(tmp_path, [])
    assert cli.main(["scan-gate", "--tool", "trivy", "--input", str(scan), "--registry", str(tmp_path / "r.yaml")]) == 0
    assert list(tmp_path.glob("*.jsonl")) == []


def test_load_records_skips_blank_and_corrupt_lines(tmp_path):
    path = tmp_path / "r.jsonl"
    path.write_text('{"kind": "step", "name": "a", "result": "Pass"}\n\nnot json\n[1, 2]\n', encoding="utf-8")
    assert load_records(path) == [{"kind": "step", "name": "a", "result": "Pass"}]
    assert load_records(tmp_path / "missing.jsonl") == []
    assert load_records(None) == []


# --- SBOM差分 -----------------------------------------------------------------------


def _write_sbom(directory, key, tag, components):
    directory.mkdir(parents=True, exist_ok=True)
    (directory / f"{key}_{tag}.cyclonedx.json").write_text(
        json.dumps({"components": components}), encoding="utf-8")


def _apk(name, version):
    return {"type": "library", "name": name, "version": version, "purl": f"pkg:apk/alpine/{name}@{version}?arch=x86_64"}


OS = {"type": "operating-system", "name": "alpine", "version": "3.24.4"}


def test_sbom_diff_reports_updated_added_and_removed_packages(tmp_path):
    _write_sbom(tmp_path / "prev", "tamacat_zabbix-web", "6.0.48-alpine-b20261102",
                [{**OS, "version": "3.24.3"}, _apk("openssl", "3.5.4-r0"), _apk("curl", "8.0-r0"), _apk("old", "1-r0")])
    _write_sbom(tmp_path / "new", "tamacat_zabbix-web", "6.0.48-alpine-b20261109",
                [OS, _apk("openssl", "3.5.5-r0"), _apk("curl", "8.0-r0"), _apk("fresh", "2-r0")])

    prev = load_sbom_dir(tmp_path / "prev")["tamacat_zabbix-web"]
    new = load_sbom_dir(tmp_path / "new")["tamacat_zabbix-web"]
    added, removed, changed = diff_packages(prev["packages"], new["packages"])

    assert changed == [("openssl", "3.5.4-r0", "3.5.5-r0")]
    assert added == [("fresh", "2-r0")]
    assert removed == [("old", "1-r0")]
    assert (prev["os"], new["os"]) == ("alpine 3.24.3", "alpine 3.24.4")
    assert (prev["tag"], new["tag"]) == ("6.0.48-alpine-b20261102", "6.0.48-alpine-b20261109")


def test_sbom_loader_ignores_files_and_unversioned_components(tmp_path):
    _write_sbom(tmp_path, "img", "t", [
        {"type": "file", "name": "/etc/passwd", "version": "1"},
        {"type": "application", "name": "composer.lock"},
        _apk("busybox", "1.0-r0"),
    ])
    assert list(load_sbom_dir(tmp_path)["img"]["packages"].values()) == [("busybox", "1.0-r0")]


# --- Markdown -----------------------------------------------------------------------


META = {"zabbix_version": "6.0.48", "alpine_version": "3.24", "event": "schedule", "build_date": "20261109"}


def _passing_records():
    return [
        {"kind": "scan", "tool": "trivy", "target": "tamacat/zabbix-web:x", "verdict": "Pass",
         "counts": {"Critical": 0, "High": 1, "Medium": 0, "Low": 4}, "baseline_known": 0, "waived": 1, "blocking": 0,
         "waived_ids": ["CVE-2026-00001"]},
        {"kind": "scan", "tool": "semgrep", "target": "範囲: full", "verdict": "Pass",
         "counts": {"Critical": 0, "High": 0, "Medium": 7, "Low": 0}, "baseline_known": 7, "waived": 0, "blocking": 0,
         "waived_ids": []},
        {"kind": "step", "name": "シークレットスキャン", "result": "Clean"},
        {"kind": "step", "name": "公開前提条件", "result": "Pass"},
    ]


def test_summary_for_a_clean_run_says_so_and_shows_the_tables():
    text = render_summary(_passing_records(), {}, {}, META)

    assert "✅" in text.splitlines()[0]
    assert "Zabbix 6.0.48" in text
    assert "すべてPassしました" in text
    assert "| `tamacat/zabbix-web:x` | trivy | 0 | 1 | 0 | 4 | 1 | 0 | ✅ |" in text
    assert "| semgrep | 範囲: full | 0 | 0 | 7 | 0 | 7 | 0 | 0 | ✅ |" in text
    assert "CVE-2026-00001" in text
    assert "production" in text  # Publishが承認待ちで止まる旨


def test_summary_names_the_failing_gate():
    records = _passing_records()
    records[0] = {**records[0], "verdict": "Fail", "blocking": 2}
    records[3] = {"kind": "step", "name": "公開前提条件", "result": "Fail"}

    text = render_summary(records, {}, {}, META)

    assert "❌" in text.splitlines()[0]
    assert "trivy (tamacat/zabbix-web:x)" in text


def test_summary_of_an_interrupted_run_is_not_reported_as_success():
    records = [r for r in _passing_records() if r.get("name") != "公開前提条件"]

    text = render_summary(records, {}, {}, META)

    assert "✅" not in text.splitlines()[0]
    assert "途中で止まった" in text


def test_summary_without_any_records_warns():
    assert "記録がありません" in render_summary([], {}, {}, META)


def test_summary_shows_changes_and_no_change(tmp_path):
    _write_sbom(tmp_path / "prev", "a", "t1", [_apk("openssl", "1-r0"), _apk("same", "1-r0")])
    _write_sbom(tmp_path / "new", "a", "t2", [_apk("openssl", "2-r0"), _apk("same", "1-r0")])
    _write_sbom(tmp_path / "prev", "b", "t1", [_apk("same", "1-r0")])
    _write_sbom(tmp_path / "new", "b", "t2", [_apk("same", "1-r0")])

    text = render_summary(_passing_records(), load_sbom_dir(tmp_path / "new"), load_sbom_dir(tmp_path / "prev"), META)

    assert "<code>a</code>: 更新1" in text
    assert "| 更新 | `openssl` | 1-r0 → 2-r0 |" in text
    assert "`b`: 変更なし" in text


def test_summary_without_previous_sbom_says_it_cannot_compare(tmp_path):
    _write_sbom(tmp_path / "new", "a", "t2", [_apk("x", "1")])
    text = render_summary(_passing_records(), load_sbom_dir(tmp_path / "new"), {}, META)
    assert "比較できません" in text


def test_long_change_lists_are_truncated(tmp_path):
    _write_sbom(tmp_path / "prev", "a", "t1", [_apk(f"p{i}", "1") for i in range(60)])
    _write_sbom(tmp_path / "new", "a", "t2", [_apk(f"p{i}", "2") for i in range(60)])

    text = render_summary([], load_sbom_dir(tmp_path / "new"), load_sbom_dir(tmp_path / "prev"), META)

    assert "更新60" in text
    assert "ほか20件" in text


def test_ci_summary_command_always_exits_zero_even_on_internal_errors(tmp_path, monkeypatch):
    out = io.StringIO()

    def boom(*args, **kwargs):
        raise RuntimeError("壊れた")

    monkeypatch.setattr("release_tools.ci_summary.render_summary", boom)
    assert main_render(None, None, None, {}, query_trivy_db=False, stream=out) == 0
    assert "サマリーを作れませんでした" in out.getvalue()


def test_ci_summary_cli_prints_markdown(tmp_path, capsys):
    records = tmp_path / "r.jsonl"
    for record in _passing_records():
        append_record(records, record)

    exit_code = cli.main(["ci-summary", "--records", str(records), "--zabbix-version", "6.0.48", "--event", "schedule"])
    captured = capsys.readouterr()

    assert exit_code == 0
    assert "Zabbix 6.0.48" in captured.out
    assert "schedule" in captured.out
