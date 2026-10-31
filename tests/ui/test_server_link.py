"""WebからZabbixサーバーへの接続と、entrypoint.shが環境変数から作る設定の反映。

システム情報の「Zabbix server is running」は、PHPのsockets拡張でZBX_SERVER_HOST:ZBX_SERVER_PORTへ
繋いで調べている。サーバーのコンテナの起動を待つ必要があるので、最大ZABBIX_WAIT_SECONDS秒待つ。
"""
import os
import re
import time

import pytest

from conftest import WAIT_SECONDS
from zbxclient import page_problems


def _system_info(admin):
    return admin.get("zabbix.php", params={"action": "report.status"})


def test_the_web_frontend_reaches_the_zabbix_server(admin):
    deadline = time.monotonic() + WAIT_SECONDS
    while True:
        resp = _system_info(admin)
        running = re.search(r"Zabbix server is running\s+(\w+)", resp.visible_text)
        if (running and running.group(1) == "Yes") or time.monotonic() > deadline:
            break
        time.sleep(3)

    assert page_problems(resp) == []
    assert running, "the System information page has no 'Zabbix server is running' row"
    assert running.group(1) == "Yes", f"the web frontend cannot reach the Zabbix server: {running.group(0)}"


def test_the_server_counts_the_seeded_host(admin, seed):
    """サーバーがDBの構成を読み込み、Webの数え上げとつながっていることまで(ホスト数が1以上)。"""
    text = _system_info(admin).visible_text

    match = re.search(r"Number of hosts \(enabled/disabled\)\s+(\d+)", text)
    assert match and int(match.group(1)) >= 1


def test_api_version_matches_the_built_version(api):
    expected = os.environ.get("ZABBIX_VERSION")
    if not expected:
        pytest.skip("ZABBIX_VERSION is not set")

    assert api.call("apiinfo.version", auth=False) == expected


def test_zbx_server_name_reaches_the_page(admin):
    """ZBX_SERVER_NAME(環境変数) → zabbix.conf.php の $ZBX_SERVER_NAME → 画面。"""
    expected = os.environ.get("ZBX_SERVER_NAME")
    if not expected:
        pytest.skip("ZBX_SERVER_NAME is not set")

    resp = admin.get("zabbix.php", params={"action": "dashboard.list"})

    assert resp.title.startswith(f"{expected}: ")
