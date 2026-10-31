"""ログイン、セッション、ログアウト、APIの認証。

index.php / zabbix.php のセッション処理はPHPのsession拡張とphp.ini(session.*)に依存し、
entrypoint.shが生成するzabbix.conf.php(DB接続・セッション名)にも依存する。
"""
import json
import re

import pytest

from conftest import ADMIN_PASSWORD, ADMIN_USER
from zbxclient import ApiError, ZabbixApi, ZabbixClient, page_problems


def test_login_page_renders_the_form(anonymous):
    resp = anonymous.get("index.php")

    assert page_problems(resp) == []
    for field in ('name="name"', 'name="password"', 'name="enter"'):
        assert field in resp.text


def test_wrong_password_is_rejected_and_the_right_one_works(base_url, make_user):
    # 実在するユーザーで確かめる。Adminで失敗を重ねると一定時間ロックされ、以降のテストが巻き込まれる。
    name, password = make_user()
    client = ZabbixClient(base_url)

    bad = client.login(name, password + "x")
    assert bad.status == 200
    assert "Incorrect user name or password" in bad.visible_text
    assert "You are not logged in" in client.get("zabbix.php", params={"action": "problem.view"}).visible_text

    good = client.login(name, password)
    assert good.status == 302
    assert "action=dashboard.view" in good.headers["Location"]
    # 直前の失敗は「1 failed login attempt logged」と赤い枠で知らされる(製品の仕様)。それ以外の問題は無い。
    problems = page_problems(client.get(good.headers["Location"]))
    assert [p for p in problems if "failed login attempt" not in p] == []


def test_session_cookie_is_httponly(base_url):
    client = ZabbixClient(base_url)

    resp = client.login(ADMIN_USER, ADMIN_PASSWORD)

    cookies = [c for c in resp.headers.get_all("Set-Cookie") or [] if c.startswith("zbx_session=")]
    assert cookies, "login did not set the zbx_session cookie"
    assert "httponly" in cookies[0].lower()


def test_pages_require_a_login(anonymous):
    resp = anonymous.get("zabbix.php", params={"action": "problem.view"})

    assert "You are not logged in" in resp.visible_text
    assert "Problems" not in resp.title


def test_logout_ends_the_session(base_url, make_user):
    name, password = make_user()
    client = ZabbixClient(base_url)
    assert client.login(name, password).status == 302
    sid = client.sid()

    assert "Problems" in client.get("zabbix.php", params={"action": "problem.view"}).title

    out = client.get("index.php", params={"reconnect": "1", "sid": sid})
    assert out.status == 200

    after = client.get("zabbix.php", params={"action": "problem.view"})
    assert "You are not logged in" in after.visible_text


def test_api_version_needs_no_login_and_matches_the_6_0_line(base_url):
    version = ZabbixApi(base_url).call("apiinfo.version", auth=False)

    assert re.fullmatch(r"6\.0\.\d+", version), version


def test_api_login_rejects_a_wrong_password(base_url, make_user):
    name, password = make_user()
    api = ZabbixApi(base_url)

    with pytest.raises(ApiError) as err:
        api.login(name, password + "x")

    assert "incorrect" in err.value.error_message.lower() or "incorrect" in str(err.value.data).lower()


def test_api_rejects_calls_without_a_token(base_url):
    with pytest.raises(ApiError) as err:
        ZabbixApi(base_url).call("host.get", {"output": ["hostid"]}, auth=False)

    assert "not authorized" in (err.value.error_message + str(err.value.data)).lower() or err.value.code == -32602


def test_api_answers_json_rpc_to_a_malformed_request(anonymous):
    resp = anonymous.post("api_jsonrpc.php", b"{not json", headers={"Content-Type": "application/json-rpc"})

    assert resp.status == 200
    assert json.loads(resp.body)["error"]["code"] == -32700
