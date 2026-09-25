"""SAST baseline(既知の指摘の台帳)のテスト。

上流ソースの既存の指摘は件数付きでbaselineに記録し、それを超える新規の指摘だけを
ゲート対象にする。ツール(cppcheck/Semgrep)は実行せず、出力を模したフィクスチャを使う。
"""
from __future__ import annotations

import json

import pytest

from release_tools import cli
from release_tools.gate import (
    apply_baseline,
    build_baseline,
    load_baseline,
    normalize_cppcheck_findings,
    normalize_semgrep_findings,
    save_baseline,
    stale_baseline_entries,
)

CPPCHECK_XML = """<?xml version="1.0" encoding="UTF-8"?>
<results version="2">
  <errors>
    <error id="nullPointer" severity="warning" msg="Null pointer dereference: p">
      <location file="sources/zabbix-6.0.48/src/libs/zbxdb/db.c" line="120" column="5"/>
    </error>
    <error id="nullPointer" severity="warning" msg="Null pointer dereference: p">
      <location file="sources/zabbix-6.0.48/src/libs/zbxdb/db.c" line="480" column="9"/>
    </error>
    <error id="unknownMacro" severity="error" msg="There is an unknown macro here somewhere." file0="sources/zabbix-6.0.48/src/libs/zbxdb/db.c"/>
    <error id="constVariablePointer" severity="style" msg="Variable 'x' can be declared as pointer to const">
      <location file="sources/zabbix-6.0.48/src/libs/zbxdb/db.c" line="10" column="1"/>
    </error>
  </errors>
</results>
"""

SEMGREP_JSON = {
    "results": [
        {"check_id": "php.lang.security.xss", "path": "sources/zabbix-6.0.48/ui/a.php", "extra": {"severity": "ERROR"}},
        {"check_id": "php.lang.security.xss", "path": "sources/zabbix-6.0.48/ui/a.php", "extra": {"severity": "ERROR"}},
        {"check_id": "js.lang.eval", "path": "sources/zabbix-6.0.48/ui/b.js", "extra": {"severity": "WARNING"}},
    ]
}

SOURCE_ROOT = "sources/zabbix-6.0.48"


def test_cppcheck_baseline_key_ignores_line_numbers_and_uses_file0_fallback():
    findings = normalize_cppcheck_findings(CPPCHECK_XML, source_root=SOURCE_ROOT)
    keys = [f.baseline_key for f in findings]

    assert keys[0] == keys[1] == "cppcheck|nullPointer|src/libs/zbxdb/db.c|Null pointer dereference: p"
    assert keys[2] == "cppcheck|unknownMacro|src/libs/zbxdb/db.c|There is an unknown macro here somewhere."


def test_baseline_key_is_identical_for_relative_and_absolute_paths(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    absolute = str((tmp_path / SOURCE_ROOT / "src/libs/zbxdb/db.c").resolve())
    xml = f'<results><errors><error id="x" severity="warning" msg="m"><location file="{absolute}" line="1"/></error></errors></results>'

    (relative_finding,) = normalize_cppcheck_findings(
        '<results><errors><error id="x" severity="warning" msg="m">'
        f'<location file="{SOURCE_ROOT}/src/libs/zbxdb/db.c" line="1"/></error></errors></results>',
        source_root=SOURCE_ROOT,
    )
    (absolute_finding,) = normalize_cppcheck_findings(xml, source_root=SOURCE_ROOT)

    assert relative_finding.baseline_key == absolute_finding.baseline_key


def test_build_baseline_counts_only_gated_severities():
    findings = normalize_cppcheck_findings(CPPCHECK_XML, source_root=SOURCE_ROOT)

    baseline = build_baseline(findings)

    assert baseline == {
        "cppcheck|nullPointer|src/libs/zbxdb/db.c|Null pointer dereference: p": 2,
        "cppcheck|unknownMacro|src/libs/zbxdb/db.c|There is an unknown macro here somewhere.": 1,
    }  # styleは含まれない


def test_apply_baseline_absorbs_known_findings_and_keeps_new_ones():
    findings = normalize_cppcheck_findings(CPPCHECK_XML, source_root=SOURCE_ROOT)
    baseline = build_baseline(findings)

    assert apply_baseline(findings, baseline) == [f for f in findings if f.severity == "Low"]


def test_apply_baseline_flags_findings_beyond_the_recorded_count():
    findings = normalize_cppcheck_findings(CPPCHECK_XML, source_root=SOURCE_ROOT)
    baseline = build_baseline(findings)
    baseline["cppcheck|nullPointer|src/libs/zbxdb/db.c|Null pointer dereference: p"] = 1  # 2件中1件だけ既知

    new = apply_baseline(findings, baseline)

    assert [f.finding_id for f in new if f.severity != "Low"] == ["cppcheck:nullPointer:1"]


def test_apply_baseline_treats_unrecorded_key_as_new():
    findings = normalize_semgrep_findings(SEMGREP_JSON, source_root=SOURCE_ROOT)

    new = apply_baseline(findings, {})

    assert len(new) == 3


def test_stale_baseline_entries_reports_resolved_findings():
    findings = normalize_semgrep_findings(SEMGREP_JSON, source_root=SOURCE_ROOT)
    baseline = build_baseline(findings)
    baseline["semgrep|gone.rule|ui/c.php"] = 2
    baseline["semgrep|php.lang.security.xss|ui/a.php"] = 5

    assert stale_baseline_entries(findings, baseline) == {
        "semgrep|gone.rule|ui/c.php": 2,
        "semgrep|php.lang.security.xss|ui/a.php": 3,
    }


def test_load_baseline_rejects_missing_and_malformed_files(tmp_path):
    with pytest.raises(ValueError, match="見つかりません"):
        load_baseline(tmp_path / "missing.json")

    bad = tmp_path / "bad.json"
    bad.write_text(json.dumps({"version": 99, "entries": {}}), encoding="utf-8")
    with pytest.raises(ValueError, match="形式が不正"):
        load_baseline(bad)


def test_save_then_load_baseline_roundtrip(tmp_path):
    path = tmp_path / "nested" / "cppcheck.json"

    save_baseline(path, "cppcheck", {"b": 2, "a": 1}, note="triaged")

    assert load_baseline(path) == {"a": 1, "b": 2}


# --- CLI経由(scan-gate --baseline / sast-baseline)----------------------------


def _write(tmp_path, name, text):
    path = tmp_path / name
    path.write_text(text, encoding="utf-8")
    return path


def _sast_baseline_argv(tool, input_path, output_path):
    return [
        "sast-baseline", "--tool", tool, "--input", str(input_path),
        "--source-root", SOURCE_ROOT, "--output", str(output_path),
    ]


def test_scan_gate_with_baseline_passes_when_only_known_findings_remain(tmp_path, capsys):
    scan = _write(tmp_path, "cppcheck.xml", CPPCHECK_XML)
    baseline = tmp_path / "baseline.json"
    assert cli.main(_sast_baseline_argv("cppcheck", scan, baseline)) == 0

    exit_code = cli.main([
        "scan-gate", "--tool", "cppcheck", "--input", str(scan), "--baseline", str(baseline),
        "--source-root", SOURCE_ROOT, "--registry", str(tmp_path / "registry.yaml"),
    ])

    assert exit_code == 0
    assert capsys.readouterr().out.splitlines()[-1] == "Pass"


def test_scan_gate_with_baseline_fails_and_lists_new_finding(tmp_path, capsys):
    known = _write(tmp_path, "known.xml", CPPCHECK_XML)
    baseline = tmp_path / "baseline.json"
    assert cli.main(_sast_baseline_argv("cppcheck", known, baseline)) == 0
    capsys.readouterr()

    with_new = CPPCHECK_XML.replace(
        "</errors>",
        '<error id="uninitvar" severity="error" msg="Uninitialized variable: q">'
        '<location file="sources/zabbix-6.0.48/src/libs/zbxdb/db.c" line="7"/></error></errors>',
    )
    scan = _write(tmp_path, "new.xml", with_new)

    exit_code = cli.main([
        "scan-gate", "--tool", "cppcheck", "--input", str(scan), "--baseline", str(baseline),
        "--source-root", SOURCE_ROOT, "--registry", str(tmp_path / "registry.yaml"),
    ])
    captured = capsys.readouterr()

    assert exit_code == 1
    assert captured.out.splitlines()[-1] == "Fail"
    assert "baseline外の新規指摘: 1件" in captured.err
    assert "cppcheck|uninitvar|src/libs/zbxdb/db.c|Uninitialized variable: q" in captured.err


def test_scan_gate_without_baseline_still_fails_on_any_gated_finding(tmp_path, capsys):
    scan = _write(tmp_path, "cppcheck.xml", CPPCHECK_XML)

    exit_code = cli.main([
        "scan-gate", "--tool", "cppcheck", "--input", str(scan), "--registry", str(tmp_path / "registry.yaml"),
    ])

    assert exit_code == 1
    assert "ゲート対象の指摘: 3件" in capsys.readouterr().err


def test_scan_gate_fails_fast_when_baseline_file_is_missing(tmp_path, capsys):
    scan = _write(tmp_path, "cppcheck.xml", CPPCHECK_XML)

    exit_code = cli.main([
        "scan-gate", "--tool", "cppcheck", "--input", str(scan), "--baseline", str(tmp_path / "nope.json"),
        "--registry", str(tmp_path / "registry.yaml"),
    ])

    assert exit_code == 1
    assert "見つかりません" in capsys.readouterr().err


def test_scan_gate_rejects_baseline_for_trivy(tmp_path, capsys):
    scan = _write(tmp_path, "trivy.json", json.dumps({"Results": []}))
    baseline = tmp_path / "baseline.json"
    save_baseline(baseline, "cppcheck", {})

    exit_code = cli.main([
        "scan-gate", "--tool", "trivy", "--input", str(scan), "--baseline", str(baseline),
        "--registry", str(tmp_path / "registry.yaml"),
    ])

    assert exit_code == 1
    assert "SAST" in capsys.readouterr().err


def test_scan_gate_reports_unparseable_cppcheck_xml_without_traceback(tmp_path, capsys):
    scan = _write(tmp_path, "broken.xml", "<results><errors>")

    exit_code = cli.main([
        "scan-gate", "--tool", "cppcheck", "--input", str(scan), "--registry", str(tmp_path / "registry.yaml"),
    ])

    assert exit_code == 1
    assert "入力の解析に失敗" in capsys.readouterr().err
