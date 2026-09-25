"""ImagePublisher タグ生成・公開直前セルフレビュー確認(tagging.py)のテスト。

対応ビジネスルール: BR4.1(タグ命名規約)、BR3.2(セルフレビュー承認)。
"""
import pytest

from datetime import datetime

from release_tools.models import PublishedImage
from release_tools.tagging import (
    generate_tag,
    image_repository,
    is_floating_tag,
    require_self_review_confirmation,
)


def test_generate_tag_produces_expected_format():
    tag = generate_tag("zabbix-server", "6.0.48", "20260919", "amd64")

    assert tag == "tamacat/zabbix-server-mysql:6.0.48-alpine-b20260919"


@pytest.mark.parametrize(
    "component, repository",
    [
        ("zabbix-server", "tamacat/zabbix-server-mysql"),
        ("zabbix-web", "tamacat/zabbix-web-nginx-mysql"),
        ("zabbix-agent2", "tamacat/zabbix-agent2"),
        ("zabbix-proxy", "tamacat/zabbix-proxy-sqlite3"),
    ],
)
def test_repositories_match_the_zabbix_5_0_custom_registry_names(component, repository):
    # zabbix-5.0-custom publishes to these same Docker Hub repositories (README "Docker Hub").
    assert image_repository(component) == repository
    assert generate_tag(component, "6.0.48", "20260925") == f"{repository}:6.0.48-alpine-b20260925"


def test_generate_tag_does_not_include_the_architecture():
    assert "amd64" not in generate_tag("zabbix-web", "6.0.48", "20260919", "amd64")


def test_image_repository_rejects_unknown_component():
    with pytest.raises(ValueError):
        image_repository("zabbix-java-gateway")


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
    assert is_floating_tag("tamacat/zabbix-server-mysql:latest") is True


def test_is_floating_tag_accepts_dated_tag():
    assert is_floating_tag("tamacat/zabbix-server-mysql:6.0.48-alpine-b20260919") is False


def test_is_floating_tag_rejects_the_old_tag_format():
    # 誤って旧形式(-r<日付>-<arch>)が出力されたら、それも不正として検出する。
    assert is_floating_tag("tamacat/zabbix-server-mysql:6.0.48-r20260919-amd64") is True


def _published(image_tag, component="zabbix-server"):
    return PublishedImage(
        image_tag=image_tag,
        component_name=component,
        published_at=datetime(2026, 9, 25),
        source_scan_run_ids=["sca-1", "sast-1"],
    )


def test_published_image_accepts_the_registry_repository_for_its_component():
    assert _published("tamacat/zabbix-web-nginx-mysql:6.0.48-alpine-b20260925", "zabbix-web").registry == "Docker Hub"


def test_published_image_rejects_a_repository_that_belongs_to_another_component():
    with pytest.raises(ValueError, match="BR4.1"):
        _published("tamacat/zabbix-web-nginx-mysql:6.0.48-alpine-b20260925", "zabbix-server")


def test_published_image_rejects_the_previous_wrong_repository_name():
    with pytest.raises(ValueError, match="BR4.1"):
        _published("tamacat/zabbix-server:6.0.48-r20260925-amd64")


def test_require_self_review_confirmation_true_when_pre_confirmed():
    assert require_self_review_confirmation(confirmed=True) is True


def test_require_self_review_confirmation_false_when_explicitly_declined():
    assert require_self_review_confirmation(confirmed=False) is False


def test_require_self_review_confirmation_uses_prompt_when_not_preconfirmed():
    assert require_self_review_confirmation(prompt_fn=lambda _: "yes") is True
    assert require_self_review_confirmation(prompt_fn=lambda _: "no") is False
