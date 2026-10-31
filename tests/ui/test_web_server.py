"""nginx(docker/web/conf/nginx.conf)の配信と、外から見えてはいけないファイル。

静的ファイル、PHPの処理、ソースツリー内の非公開のはずのファイルの扱い。
"""
import pytest

from zbxclient import page_problems


@pytest.mark.parametrize(
    "path,content_type",
    [
        ("assets/styles/blue-theme.css", "text/css"),
        ("js/common.js", "application/javascript"),
        ("jsLoader.php?lang=en_US", "application/javascript"),
    ],
)
def test_static_assets_are_served_with_the_right_type(anonymous, path, content_type):
    resp = anonymous.get(path)

    assert resp.status == 200
    assert resp.content_type in (content_type, "text/javascript")


def test_php_files_run_and_are_never_returned_as_source(anonymous):
    resp = anonymous.get("index.php")

    assert "<?php" not in resp.text


def test_dotfiles_are_denied(anonymous):
    assert anonymous.get(".htaccess").status in (403, 404)


@pytest.mark.parametrize(
    "path",
    [
        "conf/zabbix.conf.php",
        "conf/zabbix.conf.php.example",
        "include/defines.inc.php",
        "app/controllers/CControllerModuleScan.php",
        "vendor/autoload.php",
        "vendor/composer/installed.json",
        "locale/ja/LC_MESSAGES/frontend.po",
        "composer.json",
        "composer.lock",
    ],
)
def test_internal_files_are_not_exposed(anonymous, path):
    """設定・同梱ライブラリの一覧(版が分かる)・コントローラーのソースは、外から取れない/実行できない。

    docker/web/conf/nginx.conf に /app /conf /include /local /locale /vendor と composer.json/lock の
    拒否ルールが無かった間は、composer.json/lock と vendor/composer/installed.json が同梱ライブラリの版を
    丸ごと返し、PHPの内部ファイルは単体で実行されて500や空の200を返していた。
    """
    resp = anonymous.get(path)

    assert resp.status in (403, 404), f"/{path} answered HTTP {resp.status}"


@pytest.mark.parametrize("directory", ["local/conf/", "modules/"])
def test_directories_are_not_listed(anonymous, directory):
    assert anonymous.get(directory).status in (403, 404)


def test_the_setup_wizard_is_not_reachable_once_configured(anonymous):
    resp = anonymous.get("setup.php")

    assert "Welcome to" not in resp.visible_text
    assert "Check of pre-requisites" not in resp.visible_text


def test_a_missing_page_is_a_clean_404(anonymous):
    resp = anonymous.get("no-such-page.php")

    assert resp.status == 404
    assert "Fatal error" not in resp.text


def test_a_missing_php_action_does_not_crash(admin):
    resp = admin.get("zabbix.php", params={"action": "no.such.action"})

    assert resp.status in (200, 404)
    assert "Fatal error" not in resp.text and "Stack trace" not in resp.text
