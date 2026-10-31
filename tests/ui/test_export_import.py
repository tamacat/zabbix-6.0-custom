"""構成のエクスポート/インポート(YAML・XML・JSON)。

YAMLの書き出しはui/vendor/symfony/yamlを通る。ZabbixはこのライブラリのコピーにDUMP_COMPACT_NESTED_MAPPING
という独自パッチを入れており、脆弱性対応で標準版へ上げるとエクスポートが「Undefined constant」で壊れる
(SCAは通る。実際にあった)。XML/JSONの書き出しと、インポート側の読み込みはPHPのxml/dom/xmlreader/
xmlwriter拡張を通る。ここでは画面のエクスポートボタンと同じ経路(zabbix.php?action=export.*)を叩く。
"""
import json
import uuid
import xml.etree.ElementTree as ET

import pytest
import yaml

from conftest import PREFIX
from zbxclient import page_problems

FORMATS = ["yaml", "xml", "json"]
MIME = {"yaml": "text/yaml", "xml": "text/xml", "json": "application/json"}


def _export(admin, action, key, ids, fmt):
    return admin.post(
        "zabbix.php",
        {"action": action, key: ids, "format": fmt, "backurl": "zabbix.php?action=dashboard.view", "sid": admin.sid()},
    )


def _parse(fmt, body):
    """書き出された文字列を、形式ごとの標準的なパーサーで読み戻した辞書にそろえる。"""
    if fmt == "yaml":
        return yaml.safe_load(body)["zabbix_export"]
    if fmt == "json":
        return json.loads(body)["zabbix_export"]
    root = ET.fromstring(body)
    assert root.tag == "zabbix_export"
    return {child.tag: child for child in root}


@pytest.fixture
def mediatypeid(api):
    return api.call("mediatype.get", {"output": ["mediatypeid"], "filter": {"name": "Email"}})[0]["mediatypeid"]


@pytest.mark.parametrize("fmt", FORMATS)
def test_export_template(admin, seed, fmt):
    resp = _export(admin, "export.templates", "templates[]", [seed.templateid], fmt)

    assert resp.status == 200
    assert resp.content_type == MIME[fmt]
    assert f"zbx_export_templates.{fmt}" in resp.headers["Content-Disposition"]
    assert seed.template_host in resp.text
    assert "zbx6ui.cpu" in resp.text
    exported = _parse(fmt, resp.body)
    if fmt != "xml":
        assert exported["version"] == "6.0"
        assert [t["template"] for t in exported["templates"]] == [seed.template_host]


@pytest.mark.parametrize("fmt", FORMATS)
def test_export_host(admin, seed, fmt):
    resp = _export(admin, "export.hosts", "hostids[]", [seed.hostid], fmt)

    assert resp.status == 200
    assert resp.content_type == MIME[fmt]
    assert seed.host_host in resp.text
    exported = _parse(fmt, resp.body)
    if fmt != "xml":
        assert [h["host"] for h in exported["hosts"]] == [seed.host_host]


@pytest.mark.parametrize("fmt", FORMATS)
def test_export_map(admin, seed, fmt):
    resp = _export(admin, "export.sysmaps", "maps[]", [seed.sysmapid], fmt)

    assert resp.status == 200
    assert resp.content_type == MIME[fmt]
    assert f"{seed.prefix} map" in resp.text
    _parse(fmt, resp.body)


@pytest.mark.parametrize("fmt", FORMATS)
def test_export_media_type(admin, mediatypeid, fmt):
    resp = _export(admin, "export.mediatypes", "mediatypeids[]", [mediatypeid], fmt)

    assert resp.status == 200
    assert resp.content_type == MIME[fmt]
    exported = _parse(fmt, resp.body)
    if fmt != "xml":
        assert [m["name"] for m in exported["media_types"]] == ["Email"]


def test_yaml_export_keeps_japanese_text(admin, api, seed):
    """非ASCII(日本語)の名前がYAMLで文字化け・エスケープ崩れせずに往復する。"""
    name = f"{seed.prefix} 日本語のテンプレート"
    templateid = api.call("template.create", {"host": f"{seed.prefix}-jp", "name": name, "groups": [{"groupid": seed.groupid}]})[
        "templateids"
    ][0]
    try:
        resp = _export(admin, "export.templates", "templates[]", [templateid], "yaml")

        assert yaml.safe_load(resp.body)["zabbix_export"]["templates"][0]["name"] == name
    finally:
        api.call("template.delete", [templateid])


def _as_clone(fmt, exported, template_host, clone_host):
    """書き出したテンプレートを、別名・新しいUUIDの複製として取り込める文字列に直す。

    UUIDが同じだと「既にあるテンプレート」とみなされ、新しくは作られない。トリガーの式やグラフの
    アイテム参照にはテンプレート名が入っているので、名前は文字列ごと置き換える。
    """
    exported = exported.replace(template_host, clone_host)
    if fmt == "xml":
        root = ET.fromstring(exported)
        template = root.find("templates")[0]
        template.find("template").text = template.find("name").text = clone_host
        for element in template.iter("uuid"):
            element.text = uuid.uuid4().hex
        return ET.tostring(root, encoding="unicode")

    doc = json.loads(exported) if fmt == "json" else yaml.safe_load(exported)
    template = doc["zabbix_export"]["templates"][0]
    template["template"] = template["name"] = clone_host

    def renew(node):
        if isinstance(node, dict):
            for key, value in node.items():
                if key == "uuid":
                    node[key] = uuid.uuid4().hex
                else:
                    renew(value)
        elif isinstance(node, list):
            for item in node:
                renew(item)

    renew(template)
    return json.dumps(doc) if fmt == "json" else yaml.safe_dump(doc, allow_unicode=True)


@pytest.mark.parametrize("fmt", FORMATS)
def test_exported_template_imports_back(admin, api, seed, fmt):
    """書き出したテンプレートを別名で取り込み直すと、アイテムごと作られる(インポート側のパーサーも通る)。

    XMLのインポートはPHPの simplexml_load_string() を使う(CXmlImportReader.php)。zabbix-webのPHPを
    --enable-simplexml 無しでビルドしていた間は、ここだけが「Call to undefined function」で落ちた。
    """
    exported = _export(admin, "export.templates", "templates[]", [seed.templateid], fmt).text
    clone_host = f"{PREFIX}{fmt}-clone"
    rules = {
        "templates": {"createMissing": True, "updateExisting": False},
        "items": {"createMissing": True, "updateExisting": False},
        "triggers": {"createMissing": True, "updateExisting": False},
        "graphs": {"createMissing": True, "updateExisting": False},
        "groups": {"createMissing": True},
        "templateLinkage": {"createMissing": True},
    }
    try:
        source = _as_clone(fmt, exported, seed.template_host, clone_host)
        assert api.call("configuration.import", {"format": fmt, "rules": rules, "source": source}) is True

        found = api.call("template.get", {"output": ["host"], "filter": {"host": clone_host}, "selectItems": ["key_"]})
        assert [t["host"] for t in found] == [clone_host]
        assert [i["key_"] for i in found[0]["items"]] == ["zbx6ui.cpu"]
    finally:
        leftover = api.call("template.get", {"output": ["templateid"], "filter": {"host": clone_host}})
        if leftover:
            api.call("template.delete", [t["templateid"] for t in leftover])


def test_import_dialog_opens(admin):
    """インポートのダイアログ(JSONで返るポップアップ)。GETでは「アクセス拒否」になるので、画面のJSと同じくPOSTする。"""
    resp = admin.post("zabbix.php", {"action": "popup.import", "rules_preset": "template", "sid": admin.sid()})

    assert resp.status == 200
    assert resp.content_type == "application/json"
    assert json.loads(resp.body)["header"] == "Import"


def test_export_of_a_missing_entity_reports_an_error_instead_of_crashing(admin):
    resp = _export(admin, "export.templates", "templates[]", ["99999999"], "yaml")

    assert resp.status != 500
    assert "Fatal error" not in resp.text
