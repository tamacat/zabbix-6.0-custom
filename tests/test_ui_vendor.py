"""UI(ui/)が同梱するPHPライブラリ(ui/vendor/)の整合性テスト。

symfony/yaml はZabbixが自分のコピーに独自のパッチ(Yaml::DUMP_COMPACT_NESTED_MAPPING)を入れて同梱して
いる。脆弱性対応でライブラリを標準版へ上げると、このパッチが失われ、YAMLのエクスポートが
`Undefined constant ...DUMP_COMPACT_NESTED_MAPPING` で壊れる(SCAは通り、画面の実機確認でしか気付けない)。
ここでは、UIが使うYaml::の定数が同梱ライブラリにあること、パッチが残っていることを、ソースだけで確認する。
"""
import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
UI_DIRS = sorted(p for p in (REPO_ROOT / "sources").glob("zabbix-*/ui") if p.is_dir())
YAML_DIR = "vendor/symfony/yaml"

needs_ui = pytest.mark.skipif(not UI_DIRS, reason="Zabbix source is not checked out")


@pytest.fixture(params=UI_DIRS or [None], ids=lambda p: p.parent.name if p else "no-source")
def ui(request):
    return request.param


def _php_files(ui_dir: Path):
    for sub in ("include", "app"):
        yield from (ui_dir / sub).rglob("*.php")


@needs_ui
def test_every_yaml_constant_the_ui_uses_exists_in_the_vendored_library(ui):
    yaml_php = (ui / YAML_DIR / "Yaml.php").read_text(encoding="utf-8")
    defined = set(re.findall(r"\bconst ([A-Z_]+) =", yaml_php))
    used = set()
    for path in _php_files(ui):
        used |= set(re.findall(r"\bYaml::([A-Z][A-Z_]+)\b", path.read_text(encoding="utf-8", errors="replace")))

    assert used, "the UI no longer uses any Yaml:: constant (is this test still meaningful?)"
    assert used <= defined, f"the UI uses Yaml constants the vendored library does not define: {sorted(used - defined)}"


@needs_ui
def test_the_zabbix_compact_nested_mapping_patch_is_still_in_the_dumper(ui):
    dumper = (ui / YAML_DIR / "Dumper.php").read_text(encoding="utf-8")

    assert "$compactNestedMapping = Yaml::DUMP_COMPACT_NESTED_MAPPING & $flags && !$dumpAsMap;" in dumper
    assert "$compactNestedMapping && \\is_array($value)" in dumper


@needs_ui
def test_composer_json_and_lock_agree_on_the_yaml_version(ui):
    composer_json = (ui / "composer.json").read_text(encoding="utf-8")
    composer_lock = (ui / "composer.lock").read_text(encoding="utf-8")

    wanted = re.search(r'"symfony/yaml":\s*"v?([\d.]+)"', composer_json)
    locked = re.search(r'"name": "symfony/yaml",\s*"version": "v?([\d.]+)"', composer_lock)
    installed = re.search(r'"name": "symfony/yaml",\s*"version": "v?([\d.]+)"', (ui / "vendor/composer/installed.json").read_text(encoding="utf-8"))

    assert wanted and locked and installed
    assert wanted.group(1) == locked.group(1) == installed.group(1)
