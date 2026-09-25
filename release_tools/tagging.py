"""ImagePublisher — タグ生成(BR4.1)と公開直前セルフレビュー確認(BR3.2)。

公開名・タグ形式(BR4.1)は zabbix-5.0-custom と同じ規約に揃える:
`tamacat/<リポジトリ名>:<zabbix-version>-alpine-b<YYYYMMDD>`
(例: `tamacat/zabbix-server-mysql:6.0.48-alpine-b20260919`)。リポジトリ名は公式の
zabbix/zabbix-* イメージと同じ(models.IMAGE_REPOSITORIES)。コード変更を伴わない
定期再ビルドでもビルド日付が異なる限りタグが衝突しないこと、および `latest` のような
floatingタグを一切生成しないことを保証する。
"""
from __future__ import annotations

import re
from typing import Callable, Optional

from .models import ARCHITECTURES, COMPONENT_NAMES, IMAGE_REPOSITORIES, REGISTRY_NAMESPACE

_BUILD_DATE_PATTERN = re.compile(r"^\d{8}$")
_ZABBIX_VERSION_PATTERN = re.compile(r"^\d+\.\d+\.\d+$")
_VERSION_SUFFIX_PATTERN = re.compile(r"^\d+\.\d+\.\d+-alpine-b\d{8}$")


def image_repository(component: str) -> str:
    """component_name("zabbix-server"等)から、Docker Hub上のリポジトリ名
    ("tamacat/zabbix-server-mysql"等)を返す。"""
    if component not in COMPONENT_NAMES:
        raise ValueError(f"未対応のコンポーネントです: {component!r}(許可値: {COMPONENT_NAMES})")
    return f"{REGISTRY_NAMESPACE}/{IMAGE_REPOSITORIES[component]}"


def generate_tag(component: str, zabbix_version: str, build_date: str, arch: str = "amd64") -> str:
    """BR4.1に従い `tamacat/<リポジトリ名>:<zabbix_version>-alpine-b<build_date>` を生成する。

    build_dateは常にYYYYMMDD(ビルド実行日)の8桁でなければならず、"latest" 等の
    floatingタグは決して生成しない(不正な入力はValueErrorで拒否する)。

    archはタグには含めない(zabbix-5.0-customと同じ形式)。BR5.2(初回リリースはamd64のみ)を
    ここで強制するための検証にだけ使う。
    """
    repository = image_repository(component)
    if arch not in ARCHITECTURES:
        raise ValueError(f"BR5.2違反: 初回リリースはamd64のみ対応です: {arch!r}")
    if not zabbix_version or not _ZABBIX_VERSION_PATTERN.match(zabbix_version):
        raise ValueError(f"zabbix_version はX.Y.Z形式でなければなりません(例: 6.0.48): {zabbix_version!r}")
    if not build_date or not _BUILD_DATE_PATTERN.match(build_date):
        raise ValueError(f"build_date はYYYYMMDD形式の8桁でなければなりません: {build_date!r}")

    tag = f"{repository}:{zabbix_version}-alpine-b{build_date}"
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
