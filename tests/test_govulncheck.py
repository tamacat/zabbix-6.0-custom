"""govulncheck(Goバイナリの脆弱性)のゲート正規化と、イメージからのファイル取り出しのテスト。

入力は `govulncheck -mode=binary -format json` の実出力(zabbix_agent2 6.0.48-alpine-b20261008、
go1.26.8)の構造をそのまま小さくしたもの。Trivyは標準ライブラリの当該脆弱性をまだ知らず0件と
判定していたが、govulncheckは関数レベルで9件を「呼ばれる」と判定した。
"""
from __future__ import annotations

import io
import json
import tarfile
from datetime import date

import pytest

from release_tools import cli
from release_tools.gate import normalize_govulncheck_findings, scan_gate
from release_tools.imagefile import ImageFileError, extract_image_file
from release_tools.registry import VulnerabilityRegistry


def _stream(*messages) -> str:
    """govulncheckと同じく、インデント付きのJSON値を空白で連結した文字列。"""
    return "\n".join(json.dumps(m, indent=2) for m in messages) + "\n"


CONFIG = {"config": {"scanner_name": "govulncheck", "scan_level": "symbol", "scan_mode": "binary"}}
PROGRESS = {"progress": {"message": "Scanning your binary for known vulnerabilities..."}}


def _osv(osv_id, aliases):
    return {"osv": {"id": osv_id, "aliases": aliases, "summary": "x", "affected": [], "references": []}}


def _called(osv_id, fixed="go1.26.9"):
    # 関数レベルの発見(=バイナリが脆弱なコードを実際に呼ぶ)
    return {"finding": {"osv": osv_id, "fixed_version": fixed, "trace": [
        {"module": "stdlib", "version": "go1.26.8", "package": "net/http", "function": "Do", "receiver": "Client"},
    ]}}


def _module_only(osv_id):
    # モジュール(またはパッケージ)が含まれるだけで、呼び出しは無い
    return {"finding": {"osv": osv_id, "fixed_version": "v0.41.0", "trace": [
        {"module": "golang.org/x/text", "version": "v0.39.0"},
    ]}}


# --- 正規化 --------------------------------------------------------------------


def test_only_symbol_level_findings_become_gate_findings():
    text = _stream(
        CONFIG, PROGRESS,
        _osv("GO-2026-6603", ["CVE-2026-78659"]), _osv("GO-2026-6629", ["CVE-2026-56851"]),
        _called("GO-2026-6603"), _module_only("GO-2026-6629"),
    )

    findings = normalize_govulncheck_findings(text)

    assert [f.baseline_key for f in findings] == ["govulncheck|GO-2026-6603"]
    assert findings[0].cve_id == "CVE-2026-78659"
    assert findings[0].severity == "Medium"  # Go脆弱性DBにCVSSは無い。呼ばれるものは保守的にゲート対象


def test_many_findings_for_one_osv_collapse_to_one_finding():
    text = _stream(CONFIG, _osv("GO-2026-6603", ["CVE-2026-78659"]),
                   *[_called("GO-2026-6603") for _ in range(358)])

    assert len(normalize_govulncheck_findings(text)) == 1


def test_cve_alias_preferred_then_ghsa_then_go_id():
    text = _stream(
        CONFIG,
        _osv("GO-2026-0001", ["GHSA-abcd-efgh-ijkl", "CVE-2026-11111"]),
        _osv("GO-2026-0002", ["GHSA-abcd-efgh-ijkl"]),
        _osv("GO-2026-0003", []),
        _called("GO-2026-0001"), _called("GO-2026-0002"), _called("GO-2026-0003"),
    )

    ids = [f.cve_id for f in normalize_govulncheck_findings(text)]

    assert ids == ["CVE-2026-11111", "GHSA-abcd-efgh-ijkl", "GO-2026-0003"]


def test_no_called_findings_means_no_findings():
    assert normalize_govulncheck_findings(_stream(CONFIG, PROGRESS, _osv("GO-2026-6629", []), _module_only("GO-2026-6629"))) == []


def test_output_that_is_not_govulncheck_json_is_rejected():
    # 空の出力や別ツールのJSONを「脆弱性なし=Pass」と取り違えない。
    for bad in ("", '{"Results": []}', "not json at all"):
        with pytest.raises(ValueError):
            normalize_govulncheck_findings(bad)


# --- ゲート判定(waiverとの連携) ------------------------------------------------


@pytest.fixture()
def registry(tmp_path):
    return VulnerabilityRegistry(tmp_path / "registry.yaml")


def test_called_vulnerability_fails_the_gate_until_it_is_waived(registry):
    findings = normalize_govulncheck_findings(
        _stream(CONFIG, _osv("GO-2026-6603", ["CVE-2026-78659"]), _called("GO-2026-6603")))
    today = date(2026, 10, 9)

    assert scan_gate(findings, registry, today=today) == "Fail"

    registry.register_cve("CVE-2026-78659", "zabbix-agent2", "Medium")
    registry.issue_waiver("waiver-cve-2026-78659", "CVE-2026-78659", "修正版のGoが未提供", today, date(2026, 11, 9))
    assert scan_gate(findings, registry, today=today) == "Pass"


def test_go_id_only_vulnerability_can_be_registered_and_waived(registry):
    # CVEの別名が無いGoの脆弱性も、waiverで進められる(必須ルール: 修正版未公開で永久にブロックしない)。
    findings = normalize_govulncheck_findings(_stream(CONFIG, _osv("GO-2026-0003", []), _called("GO-2026-0003")))
    today = date(2026, 10, 9)

    registry.register_cve("GO-2026-0003", "zabbix-agent2", "Medium")
    registry.issue_waiver("waiver-go-2026-0003", "GO-2026-0003", "修正版未提供", today, date(2026, 11, 9))

    assert scan_gate(findings, registry, today=today) == "Pass"


# --- CLI ------------------------------------------------------------------------


def test_scan_gate_cli_fails_and_lists_the_called_vulnerability(tmp_path, capsys):
    scan = tmp_path / "g.json"
    scan.write_text(_stream(CONFIG, _osv("GO-2026-6603", ["CVE-2026-78659"]), _called("GO-2026-6603")), encoding="utf-8")

    exit_code = cli.main(["scan-gate", "--tool", "govulncheck", "--input", str(scan),
                          "--registry", str(tmp_path / "r.yaml")])
    captured = capsys.readouterr()

    assert exit_code == 1
    assert captured.out.splitlines()[-1] == "Fail"
    assert "govulncheck|GO-2026-6603" in captured.err


def test_scan_gate_cli_passes_when_nothing_is_called(tmp_path, capsys):
    scan = tmp_path / "g.json"
    scan.write_text(_stream(CONFIG, _osv("GO-2026-6629", ["CVE-2026-56851"]), _module_only("GO-2026-6629")), encoding="utf-8")

    exit_code = cli.main(["scan-gate", "--tool", "govulncheck", "--input", str(scan),
                          "--registry", str(tmp_path / "r.yaml")])

    assert exit_code == 0
    assert capsys.readouterr().out.splitlines()[-1] == "Pass"


def test_scan_gate_cli_reports_garbage_input_without_a_traceback(tmp_path, capsys):
    scan = tmp_path / "g.json"
    scan.write_text("", encoding="utf-8")

    exit_code = cli.main(["scan-gate", "--tool", "govulncheck", "--input", str(scan),
                          "--registry", str(tmp_path / "r.yaml")])

    assert exit_code == 1
    assert "入力の解析に失敗" in capsys.readouterr().err


def test_baseline_is_rejected_for_govulncheck(tmp_path, capsys):
    scan = tmp_path / "g.json"
    scan.write_text(_stream(CONFIG), encoding="utf-8")
    baseline = tmp_path / "b.json"
    baseline.write_text('{"version": 1, "entries": {}}', encoding="utf-8")

    exit_code = cli.main(["scan-gate", "--tool", "govulncheck", "--input", str(scan), "--baseline", str(baseline),
                          "--registry", str(tmp_path / "r.yaml")])

    assert exit_code == 1
    assert "SAST" in capsys.readouterr().err


# --- イメージからのファイル取り出し -----------------------------------------------


def _layer(files: dict) -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as t:
        for name, data in files.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            t.addfile(info, io.BytesIO(data))
    return buf.getvalue()


def _image(tmp_path, layers: dict, order: list) -> "Path":
    """docker save 相当のtar。layersは {tar内のパス: レイヤーの中身}、orderはmanifestのLayers。"""
    path = tmp_path / "image.tar"
    with tarfile.open(path, "w") as t:
        for name, data in layers.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            t.addfile(info, io.BytesIO(data))
        manifest = json.dumps([{"Config": "cfg", "Layers": order}]).encode()
        info = tarfile.TarInfo("manifest.json")
        info.size = len(manifest)
        t.addfile(info, io.BytesIO(manifest))
    return path


@pytest.mark.parametrize("layer_path", ["blobs/sha256/abc123", "abc123/layer.tar", "abc123.tar"])
def test_extract_finds_the_file_in_any_layer_layout(tmp_path, layer_path):
    image = _image(tmp_path, {layer_path: _layer({"usr/sbin/zabbix_agent2": b"BINARY"})}, [layer_path])
    out = tmp_path / "out" / "agent2"

    assert extract_image_file(image, "usr/sbin/zabbix_agent2", out) == 6
    assert out.read_bytes() == b"BINARY"


def test_extract_accepts_a_leading_dot_slash_in_layer_member_names(tmp_path):
    image = _image(tmp_path, {"l1": _layer({"./usr/sbin/zabbix_agent2": b"X"})}, ["l1"])

    assert extract_image_file(image, "/usr/sbin/zabbix_agent2", tmp_path / "o") == 1


def test_a_later_layer_overrides_an_earlier_one(tmp_path):
    image = _image(tmp_path, {"l1": _layer({"usr/sbin/a": b"old"}), "l2": _layer({"usr/sbin/a": b"newer"})}, ["l1", "l2"])

    extract_image_file(image, "usr/sbin/a", tmp_path / "o")

    assert (tmp_path / "o").read_bytes() == b"newer"


def test_a_whiteout_in_a_later_layer_deletes_the_file(tmp_path):
    image = _image(tmp_path, {"l1": _layer({"usr/sbin/a": b"x"}), "l2": _layer({"usr/sbin/.wh.a": b""})}, ["l1", "l2"])

    with pytest.raises(ImageFileError, match="ありません"):
        extract_image_file(image, "usr/sbin/a", tmp_path / "o")


def test_missing_file_manifest_or_layers_fail_loudly(tmp_path):
    only_other = _image(tmp_path, {"l1": _layer({"etc/os-release": b"x"})}, ["l1"])
    with pytest.raises(ImageFileError, match="ありません"):
        extract_image_file(only_other, "usr/sbin/zabbix_agent2", tmp_path / "o")

    empty_layers = _image(tmp_path, {}, [])
    with pytest.raises(ImageFileError, match="空"):
        extract_image_file(empty_layers, "usr/sbin/zabbix_agent2", tmp_path / "o")

    not_a_tar = tmp_path / "bad.tar"
    not_a_tar.write_bytes(b"this is not a tar")
    with pytest.raises(ImageFileError):
        extract_image_file(not_a_tar, "usr/sbin/zabbix_agent2", tmp_path / "o")


def test_extract_cli_reports_success_and_failure(tmp_path, capsys):
    image = _image(tmp_path, {"l1": _layer({"usr/sbin/zabbix_agent2": b"BIN"})}, ["l1"])

    assert cli.main(["extract-image-file", "--tar", str(image), "--path", "usr/sbin/zabbix_agent2",
                     "--output", str(tmp_path / "o")]) == 0
    assert cli.main(["extract-image-file", "--tar", str(image), "--path", "usr/sbin/nope",
                     "--output", str(tmp_path / "o2")]) == 1
    assert "extract-image-file失敗" in capsys.readouterr().err


def test_extract_reads_tars_whose_member_names_start_with_dot_slash(tmp_path):
    # `tar -C dir .` で作ったtar(メンバー名が ./manifest.json, ./blobs/...)。テストのスタブや一部の環境が作る。
    path = tmp_path / "dotslash.tar"
    layer = _layer({"usr/sbin/zabbix_agent2": b"BIN"})
    manifest = json.dumps([{"Config": "cfg", "Layers": ["blobs/sha256/abc"]}]).encode()
    with tarfile.open(path, "w") as t:
        for name, data in (("./blobs/sha256/abc", layer), ("./manifest.json", manifest)):
            info = tarfile.TarInfo(name)
            info.size = len(data)
            t.addfile(info, io.BytesIO(data))

    assert extract_image_file(path, "usr/sbin/zabbix_agent2", tmp_path / "o") == 3
