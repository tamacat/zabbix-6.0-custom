#!/usr/bin/env bash
# BuildPipeline — zabbix-server/web/agent2/proxy の4コンポーネントをビルドする
# [FR3.1-FR3.4]。
#
# BR6.1: 失敗時は自動リトライを行わない。ZABBIX_SRC_DIR が存在しない場合(Zabbixソース
# 未追加の状態を含む)は、明確なエラーメッセージを出してここで停止する。
#
# 使用する環境変数(.envから読み込み可能。デフォルトは以下の通り):
#   ZABBIX_SRC_DIR   Zabbixソース配置先(既定: sources/zabbix-6.0.48)
#   ZABBIX_VERSION   ビルド対象のZabbixバージョン(例: 6.0.48)。必須。
#   ALPINE_VERSION   ベースイメージのAlpineバージョン(既定: 3.24)
#   BUILD_DATE       タグに埋め込むビルド日(既定: 本日、UTC、YYYYMMDD)
#   IMAGE_ARCH       対象アーキテクチャ(既定: amd64。BR5.2により初回リリースはamd64のみ)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# .envは既定値のみを補う。既に環境変数としてexportされている値を上書きしない
# (bats build-images.bats実行時に発覚: 単純なsource .envは常に上書きしてしまい、
# 呼び出し側が明示的に渡した値を無視してしまうバグだった)。
if [ -f .env ]; then
	while IFS='=' read -r _env_key _env_val; do
		if [ -z "${!_env_key+x}" ]; then
			export "${_env_key}=${_env_val}"
		fi
	done < <(grep -Ev '^[[:space:]]*(#|$)' .env)
fi

ZABBIX_SRC_DIR="${ZABBIX_SRC_DIR:-sources/zabbix-6.0.48}"
ALPINE_VERSION="${ALPINE_VERSION:-3.24}"
BUILD_DATE="${BUILD_DATE:-$(date -u +%Y%m%d)}"
IMAGE_ARCH="${IMAGE_ARCH:-amd64}"

fail() {
	echo "!! ERROR: $1" >&2
	echo "!! BR6.1: 自動リトライは行いません。原因を解消した上で本スクリプトを再実行してください。" >&2
	exit 1
}

# `python3` という名前がPATH上に存在していても実際に動作するインタプリタとは限らない
# (例: Windows Store App Execution Aliasの`python3`スタブはコマンド自体は存在するが
# 何も実行しない)。単なる存在チェック(command -v)ではなく実行可否で判定する。
# GitHub Actions ubuntu-latest等の通常環境では`python3 -c ...`が即座に成功するため、
# この分岐は事実上常にPY=python3を選ぶだけになる。
if python3 -c "import sys" >/dev/null 2>&1; then
	PY=python3
elif python -c "import sys" >/dev/null 2>&1; then
	PY=python
else
	fail "python3(またはpython)の実行可能なインタプリタが見つかりません"
fi

if [ -z "${ZABBIX_VERSION:-}" ]; then
	fail "ZABBIX_VERSION が設定されていません(.env または環境変数で指定してください。例: ZABBIX_VERSION=6.0.48)"
fi

if [ ! -d "${ZABBIX_SRC_DIR}" ]; then
	fail "ZABBIX_SRC_DIR='${ZABBIX_SRC_DIR}' が見つかりません。Zabbix 6.0ソースをまだ追加していない可能性があります(README.md参照)。"
fi

# ディレクトリ名(docker/<dir>/) : component_name の対応表
COMPONENTS=(
	"server:zabbix-server"
	"web:zabbix-web"
	"agent2:zabbix-agent2"
	"proxy:zabbix-proxy"
)

echo "=================================================================="
echo "BuildPipeline: ${#COMPONENTS[@]}コンポーネントをビルドします"
echo "  ZABBIX_SRC_DIR=${ZABBIX_SRC_DIR}  ZABBIX_VERSION=${ZABBIX_VERSION}"
echo "  ALPINE_VERSION=${ALPINE_VERSION}  BUILD_DATE=${BUILD_DATE}  ARCH=${IMAGE_ARCH}"
echo "=================================================================="

BUILT_TAGS_FILE="$(mktemp)"
trap 'rm -f "${BUILT_TAGS_FILE}"' EXIT

for pair in "${COMPONENTS[@]}"; do
	dir_name="${pair%%:*}"
	component_name="${pair#*:}"

	echo ""
	echo "------------------------------------------------------------------"
	echo "Building ${component_name} (docker/${dir_name}/Dockerfile)"
	echo "------------------------------------------------------------------"

	tag="$("${PY}" -m release_tools.cli generate-tag \
		--component "${component_name}" \
		--zabbix-version "${ZABBIX_VERSION}" \
		--build-date "${BUILD_DATE}" \
		--arch "${IMAGE_ARCH}")" || fail "タグ生成に失敗しました(${component_name})"

	echo "  -> ${tag}"

	docker build \
		-f "docker/${dir_name}/Dockerfile" \
		--build-arg "ZABBIX_SRC_DIR=${ZABBIX_SRC_DIR}" \
		--build-arg "ALPINE_VERSION=${ALPINE_VERSION}" \
		-t "${tag}" \
		. || fail "ビルドに失敗しました(${component_name})"

	echo "${tag}" >> "${BUILT_TAGS_FILE}"
done

echo ""
echo "=================================================================="
echo "ビルド完了。生成されたタグ:"
cat "${BUILT_TAGS_FILE}"
echo "=================================================================="
