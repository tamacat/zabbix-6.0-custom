"""画面の翻訳(PHPのgettext拡張と、イメージ内のロケール)。

翻訳はPHPのgettext()で引く。拡張が無い、OS側にロケールが無い、.moが読めない、のどれでも英語のまま
になるだけでエラーにはならないので、画面の文字を見ないと壊れたことに気付けない。
"""
from zbxclient import ZabbixClient, page_problems


def test_a_user_with_a_japanese_profile_sees_the_japanese_ui(base_url, make_user):
    name, password = make_user(lang="ja_JP")
    client = ZabbixClient(base_url)
    assert client.login(name, password).status == 302

    # 「User role」が開ける画面で見る(システム情報はスーパー管理者だけ)。
    resp = client.get("zabbix.php", params={"action": "problem.view"})

    assert page_problems(resp) == []
    assert resp.title.endswith(": 障害")
    assert "Problems" not in resp.title


def test_the_default_language_is_english(admin):
    resp = admin.get("zabbix.php", params={"action": "report.status"})

    assert "System information" in resp.text
