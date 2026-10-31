"""管理画面の操作(POST)。画面を開くだけでは通らない経路。"""
from zbxclient import page_problems


def test_module_directory_scan_works(admin):
    """管理 → 一般 → モジュール →「ディレクトリのスキャン」。

    ui/modules/ が無いとDirectoryIteratorが例外を投げる。Zabbixのtarballでは空ディレクトリだが、gitは
    空ディレクトリを保存しないので、gitから取り出したソースでビルドしたイメージには無かった。
    """
    resp = admin.post("zabbix.php", {"action": "module.scan", "sid": admin.sid()})

    assert page_problems(resp) == []
    assert "No new modules discovered" in resp.visible_text or "Modules updated" in resp.visible_text


def test_the_expected_empty_directories_exist(admin):
    """local/ 配下(サイト固有のコントローラー・ビュー・設定の置き場所)を使うページが開く。"""
    resp = admin.get("zabbix.php", params={"action": "module.list"})

    assert page_problems(resp) == []
    assert "Scan directory" in resp.text


def test_user_profile_update_round_trips(api, make_user, base_url):
    """プロフィールの更新(POST、sid必須)が通り、保存した値が画面に戻る。"""
    from zbxclient import ZabbixClient

    name, password = make_user()
    client = ZabbixClient(base_url)
    assert client.login(name, password).status == 302
    userid = api.call("user.get", {"output": ["userid"], "filter": {"username": name}})[0]["userid"]

    resp = client.post(
        "zabbix.php",
        {
            "action": "userprofile.update",
            "userid": userid,
            "sid": client.sid(),
            "lang": "default",
            "timezone": "default",
            "theme": "dark-theme",
            "autologin": "0",
            "autologout": "0",
            "refresh": "45s",
            "rows_per_page": "30",
            "url": "",
        },
    )

    assert page_problems(resp) == []
    again = client.get("zabbix.php", params={"action": "userprofile.edit"})
    assert 'value="45s"' in again.text
