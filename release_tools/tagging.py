"""ImagePublisher — タグ生成(BR4.1)と公開直前セルフレビュー確認(BR3.2)。

タグ形式(BR4.1):
`tamacat/zabbix-<component>:<zabbix-version>-r<YYYYMMDD>-<arch>`
(例: `6.0.48-r20260919-amd64`)。コード変更を伴わない定期再ビルドでも
ビルド日付が異なる限りタグが衝突しないこと、および `latest` のような
floatingタグを一切生成しないことを保証する。
"""
from __future__ import annotations

import re
from typing import Callable, Optional

from .models import ARCHITECTURES, COMPONENT_NAMES

TAG_PREFIX = "tamacat/zabbix-"
_BUILD_DATE_PATTERN = re.compile(r"^\d{8}$")
_ZABBIX_VERSION_PATTERN = re.compile(r"^\d+\.\d+\.\d+$")
_VERSION_SUFFIX_PATTERN = re.compile(r"^\d+\.\d+\.\d+-r\d{8}-[a-z0-9]+$")


def short_component_name(component: str) -> str:
    """component_name("zabbix-server"等)からタグ用の短縮名("server"等)を導出する。

    Key Decision: component_nameは既に"zabbix-"を含む(例: "zabbix-server")。
    BR4.1の擬似コード `image_tag = 'tamacat/zabbix-' + component_name + ...` を
    そのまま逐語適用すると "tamacat/zabbix-zabbix-server" のような二重prefixに
    なってしまい、FR6.2が明示的に踏襲を指示するzabbix-5.0の前例
    (`tamacat/zabbix-server-mysql`等、"zabbix-"は1回だけ)と矛盾する。よって
    タグ生成時のみ、component_nameから先頭の"zabbix-"を取り除いた短縮名を
    使用する(component_name自体は変更しない)。
    """
    prefix = "zabbix-"
    return component[len(prefix):] if component.startswith(prefix) else component


def generate_tag(component: str, zabbix_version: str, build_date: str, arch: str = "amd64") -> str:
    """BR4.1に従い `tamacat/zabbix-<component>:<zabbix_version>-r<build_date>-<arch>` を生成する。

    build_dateは常にYYYYMMDD(ビルド実行日)の8桁でなければならず、"latest" 等の
    floatingタグは決して生成しない(不正な入力はValueErrorで拒否する)。
    """
    if component not in COMPONENT_NAMES:
        raise ValueError(f"未対応のコンポーネントです: {component!r}(許可値: {COMPONENT_NAMES})")
    if arch not in ARCHITECTURES:
        raise ValueError(f"BR5.2違反: 初回リリースはamd64のみ対応です: {arch!r}")
    if not zabbix_version or not _ZABBIX_VERSION_PATTERN.match(zabbix_version):
        raise ValueError(f"zabbix_version はX.Y.Z形式でなければなりません(例: 6.0.48): {zabbix_version!r}")
    if not build_date or not _BUILD_DATE_PATTERN.match(build_date):
        raise ValueError(f"build_date はYYYYMMDD形式の8桁でなければなりません: {build_date!r}")

    version_suffix = f"{zabbix_version}-r{build_date}-{arch}"
    tag = f"{TAG_PREFIX}{short_component_name(component)}:{version_suffix}"
    if is_floating_tag(tag):
        # 上記の検証を通過した組み立て済みタグがfloating判定になることは通常起こり得ないが、
        # 「latestのようなfloatingタグを生成しないことをコードで保証する」(Step 5.2)という
        # 要件に対する明示的な最終防衛線として残す。
        raise ValueError(f"floatingタグの生成は禁止されています(アーキテクチャレビューR-07): {tag!r}")
    return tag


def is_floating_tag(tag: str) -> bool:
    """タグが `latest` 等、指す先が更新され得るfloatingタグかどうかを判定する。"""
    if ":" not in tag:
        return True
    version_suffix = tag.split(":", 1)[1]
    if version_suffix.strip().lower() in ("latest", ""):
        return True
    return not bool(_VERSION_SUFFIX_PATTERN.match(version_suffix))


def require_self_review_confirmation(
    confirmed: Optional[bool] = None,
    prompt_fn: Callable[[str], str] = input,
) -> bool:
    """BR3.2: 公開直前に単独運用者の明示的な承認を要求する。

    `confirmed` を明示的に渡した場合はそれを真偽値として扱う(スクリプト/テストからの
    非対話呼び出し向け)。Noneの場合のみ `prompt_fn` で対話的に確認する。
    Trueを返した場合のみ、呼び出し側は公開処理(docker push)へ進んでよい。
    """
    if confirmed is not None:
        return bool(confirmed)
    answer = prompt_fn("Docker Hubへの公開を承認しますか? 'yes' と入力してください: ")
    return answer.strip().lower() == "yes"
