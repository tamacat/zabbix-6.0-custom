"""Web管理画面のリグレッションテスト(tests/ui/)の共通フィクスチャ。

稼働中のZabbix 6.0スタックに対して動く。接続先は環境変数 ZABBIX_URL(例: http://127.0.0.1:8080)で、
scripts/ui-test.sh が専用のスタックを立てて設定する。ZABBIX_URL が無いときはこのディレクトリの
テストは全部スキップされる(`python -m pytest tests` を素のまま実行してもスタック無しで通る)。
ZBX_UI_REQUIRED=1 のときはスキップせず、接続できなければ失敗にする(scripts/ui-test.sh と CI 用)。

テストデータはAPIで作り、名前の先頭を `zbx6ui-` にそろえる。終了時に消し、前回が途中で
落ちて残ったものは開始時に消す。使い捨てではない既存のスタックに向けても、他のデータには触れない。
"""
from __future__ import annotations

import os
import secrets
from dataclasses import dataclass

import pytest

from zbxclient import ApiError, ZabbixApi, ZabbixClient, wait_for_login_page

PREFIX = "zbx6ui-"
ADMIN_USER = os.environ.get("ZABBIX_ADMIN_USER", "Admin")
# Zabbixの初期ユーザー(Admin)の初期パスワード。使い捨ての検証スタック向けの値で、本番の値ではない。
ADMIN_PASSWORD = os.environ.get("ZABBIX_ADMIN_PASSWORD", "zabbix")
WAIT_SECONDS = float(os.environ.get("ZABBIX_WAIT_SECONDS", "180"))


def _base_url() -> str | None:
    return os.environ.get("ZABBIX_URL") or None


@pytest.fixture(scope="session")
def base_url() -> str:
    # このディレクトリのテストは、どれも最終的にこのフィクスチャを通る。
    url = _base_url()
    if url is None:
        if os.environ.get("ZBX_UI_REQUIRED") == "1":
            pytest.fail("ZBX_UI_REQUIRED=1 but ZABBIX_URL is not set")
        pytest.skip("ZABBIX_URL is not set (run scripts/ui-test.sh, or point ZABBIX_URL at a running stack)")
    return url.rstrip("/")


@pytest.fixture(scope="session")
def anonymous(base_url) -> ZabbixClient:
    """ログインしていないクライアント。スタックが応答するまで待つ。"""
    client = ZabbixClient(base_url)
    wait_for_login_page(client, WAIT_SECONDS)
    return client


@pytest.fixture(scope="session")
def admin(base_url, anonymous) -> ZabbixClient:
    """スーパー管理者でログイン済みのクライアント(画面用)。"""
    client = ZabbixClient(base_url)
    resp = client.login(ADMIN_USER, ADMIN_PASSWORD)
    assert resp.status == 302 and client.cookie("zbx_session"), (
        f"could not log in as {ADMIN_USER}: HTTP {resp.status} {resp.visible_text[:200]}"
    )
    return client


@pytest.fixture(scope="session")
def api(base_url, anonymous) -> ZabbixApi:
    client = ZabbixApi(base_url)
    client.login(ADMIN_USER, ADMIN_PASSWORD)
    yield client
    client.logout()


def _delete_leftovers(api: ZabbixApi) -> None:
    """前回の実行が途中で落ちて残した zbx6ui- のデータを消す(新しいデータを作る前に)。"""
    search = {"search": {"name": PREFIX}, "startSearch": True}
    for method, id_field, extra in (
        ("map", "sysmapid", {}),
        ("host", "hostid", {}),
        ("template", "templateid", {}),
        ("hostgroup", "groupid", {}),
    ):
        found = api.call(f"{method}.get", {"output": [id_field], **search, **extra})
        if found:
            api.call(f"{method}.delete", [row[id_field] for row in found])
    users = api.call("user.get", {"output": ["userid"], "search": {"username": PREFIX}, "startSearch": True})
    if users:
        api.call("user.delete", [row["userid"] for row in users])


@dataclass
class Seed:
    prefix: str
    groupid: str
    templateid: str
    template_host: str
    hostid: str
    host_host: str
    itemid: str
    triggerid: str
    graphid: str
    sysmapid: str


@pytest.fixture(scope="session")
def seed(api) -> Seed:
    """画面に出すための一式: ホストグループ、テンプレート(アイテム・トリガー・グラフ)、それをリンクしたホスト、マップ。"""
    _delete_leftovers(api)

    run = secrets.token_hex(3)
    prefix = f"{PREFIX}{run}"
    created: list[tuple[str, list[str]]] = []

    def create(method: str, params: dict, key: str) -> str:
        result = api.call(f"{method}.create", params)
        ident = result[key][0]
        created.append((method, [ident]))
        return ident

    try:
        groupid = create("hostgroup", {"name": f"{prefix} group"}, "groupids")
        template_host = f"{prefix}-tpl"
        templateid = create(
            "template", {"host": template_host, "name": f"{prefix} template", "groups": [{"groupid": groupid}]}, "templateids"
        )
        tpl_itemid = api.call(
            "item.create",
            {"name": "CPU load", "key_": "zbx6ui.cpu", "hostid": templateid, "type": 2, "value_type": 0},
        )["itemids"][0]
        api.call(
            "trigger.create",
            {"description": "CPU load is too high", "expression": f"last(/{template_host}/zbx6ui.cpu)>90", "priority": 3},
        )
        api.call(
            "graph.create",
            {"name": "CPU load graph", "width": 900, "height": 200, "gitems": [{"itemid": tpl_itemid, "color": "00AA00"}]},
        )

        host_host = f"{prefix}-host"
        hostid = create(
            "host",
            {
                "host": host_host,
                "name": f"{prefix} host",
                "groups": [{"groupid": groupid}],
                "templates": [{"templateid": templateid}],
                "interfaces": [{"type": 1, "main": 1, "useip": 1, "ip": "127.0.0.1", "dns": "", "port": "10050"}],
            },
            "hostids",
        )

        # テンプレートからホストへ引き継がれた分(ホスト自身のID)を引く。
        itemid = api.call("item.get", {"output": ["itemid"], "hostids": [hostid], "filter": {"key_": "zbx6ui.cpu"}})[0]["itemid"]
        triggerid = api.call("trigger.get", {"output": ["triggerid"], "hostids": [hostid]})[0]["triggerid"]
        graphid = api.call("graph.get", {"output": ["graphid"], "hostids": [hostid]})[0]["graphid"]

        iconid = api.call("image.get", {"output": ["imageid"], "filter": {"imagetype": 1}, "limit": 1})[0]["imageid"]
        sysmapid = create(
            "map",
            {
                "name": f"{prefix} map",
                "width": 400,
                "height": 300,
                "selements": [
                    {"selementid": "1", "elementtype": 0, "elements": [{"hostid": hostid}], "iconid_off": iconid, "x": 100, "y": 100}
                ],
            },
            "sysmapids",
        )

        yield Seed(prefix, groupid, templateid, template_host, hostid, host_host, itemid, triggerid, graphid, sysmapid)
    finally:
        for method, ids in reversed(created):
            try:
                api.call(f"{method}.delete", ids)
            except ApiError:
                pass  # ホストを消すとマップの要素なども消えるなど、順序で既に無いことがある。残りの片付けを続ける。


@pytest.fixture
def make_user(api):
    """ログインテスト用の使い捨てユーザー(スーパー管理者ではない「User role」)を作る。"""
    made: list[str] = []

    def factory(lang: str | None = None) -> tuple[str, str]:
        name = f"{PREFIX}{secrets.token_hex(3)}-user"
        password = secrets.token_urlsafe(18)
        role = api.call("role.get", {"output": ["roleid"], "filter": {"name": "User role"}})[0]["roleid"]
        group = api.call("usergroup.get", {"output": ["usrgrpid"], "filter": {"name": "Zabbix administrators"}})[0]["usrgrpid"]
        params = {"username": name, "passwd": password, "roleid": role, "usrgrps": [{"usrgrpid": group}]}
        if lang:
            params["lang"] = lang
        made.append(api.call("user.create", params)["userids"][0])
        return name, password

    yield factory
    if made:
        api.call("user.delete", made)
