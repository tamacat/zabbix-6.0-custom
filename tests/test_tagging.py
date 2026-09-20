"""ImagePublisher タグ生成・公開直前セルフレビュー確認(tagging.py)のテスト。

対応ビジネスルール: BR4.1(タグ命名規約)、BR3.2(セルフレビュー承認)。
"""
import pytest

from release_tools.tagging import (
    generate_tag,
    is_floating_tag,
    require_self_review_confirmation,
)


def test_generate_tag_produces_expected_format():
    tag = generate_tag("zabbix-server", "6.0.48", "20260919", "amd64")

    assert tag == "tamacat/zabbix-server:6.0.48-r20260919-amd64"


def test_generate_tag_rejects_unknown_component():
    with pytest.raises(ValueError):
        generate_tag("zabbix-java-gateway", "6.0.48", "20260919", "amd64")


def test_generate_tag_rejects_non_amd64_arch():
    with pytest.raises(ValueError):
        generate_tag("zabbix-proxy", "6.0.48", "20260919", "arm64")


def test_generate_tag_rejects_malformed_build_date():
    with pytest.raises(ValueError):
        generate_tag("zabbix-web", "6.0.48", "2026-09-19", "amd64")


def test_generate_tag_rejects_malformed_zabbix_version():
    with pytest.raises(ValueError):
        generate_tag("zabbix-agent2", "6.0", "20260919", "amd64")


def test_generate_tag_never_produces_latest_or_other_floating_tag():
    with pytest.raises(ValueError):
        generate_tag("zabbix-server", "6.0.48", "latest", "amd64")


def test_is_floating_tag_detects_latest():
    assert is_floating_tag("tamacat/zabbix-server:latest") is True


def test_is_floating_tag_accepts_dated_tag():
    assert is_floating_tag("tamacat/zabbix-server:6.0.48-r20260919-amd64") is False


def test_require_self_review_confirmation_true_when_pre_confirmed():
    assert require_self_review_confirmation(confirmed=True) is True


def test_require_self_review_confirmation_false_when_explicitly_declined():
    assert require_self_review_confirmation(confirmed=False) is False


def test_require_self_review_confirmation_uses_prompt_when_not_preconfirmed():
    assert require_self_review_confirmation(prompt_fn=lambda _: "yes") is True
    assert require_self_review_confirmation(prompt_fn=lambda _: "no") is False
