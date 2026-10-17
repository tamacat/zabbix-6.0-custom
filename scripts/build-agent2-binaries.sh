#!/usr/bin/env bash
# zabbix-agent2 の単体バイナリ(Linux x86_64・Windows 64bit)をビルドし、GitHub Releasesに添付する
# アーカイブとチェックサムを ${DIST_DIR} に書き出す。コンテナイメージのビルド(build-images.sh)とは
# 別の成果物で、Docker Hubには何も公開しない。
#
# 成果物(${DIST_DIR}/ の中):
#   zabbix_agent2-<ZABBIX_VERSION>-b<BUILD_DATE>-linux-amd64.tar.gz
#   zabbix_agent2-<ZABBIX_VERSION>-b<BUILD_DATE>-windows-amd64.zip
#   SHA256SUMS
#
# BR6.1: 失敗時は自動リトライを行わない。ZABBIX_SRC_DIR が存在しない場合は、明確な
# エラーメッセージを出してここで停止する。
#
# 使用する環境変数(.envから読み込み可能。デフォルトは以下の通り):
#   ZABBIX_SRC_DIR   Zabbixソース配置先(既定: sources/zabbix-6.0.48)
#   ZABBIX_VERSION   ビルド対象のZabbixバージョン(例: 6.0.48)。必須。
#   ALPINE_VERSION   ビルド用コンテナのAlpineバージョン(既定: 3.24)
#   BUILD_DATE       アーカイブ名・タグに埋め込むビルド日(既定: 本日、UTC、YYYYMMDD)
#   DIST_DIR         成果物の書き出し先(既定: dist)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Windowsのgit-bash等で、`コンテナ名:/パス` を「パスの列」と誤解して書き換えないようにする。
export MSYS_NO_PATHCONV=1

# .envは既定値のみを補う。既に環境変数としてexportされている値を上書きしない。
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
DIST_DIR="${DIST_DIR:-dist}"

fail() {
	echo "!! ERROR: $1" >&2
	echo "!! BR6.1: 自動リトライは行いません。原因を解消した上で本スクリプトを再実行してください。" >&2
	exit 1
}

# `python3` という名前がPATH上に存在していても実際に動作するインタプリタとは限らない
# (build-images.sh と同じ理由)。存在チェックではなく実行可否で判定する。
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

RELEASE_TAG="$("${PY}" -m release_tools.cli generate-release-tag \
	--zabbix-version "${ZABBIX_VERSION}" --build-date "${BUILD_DATE}")" \
	|| fail "リリースタグの生成に失敗しました"
ASSET_PREFIX="$("${PY}" -m release_tools.cli generate-release-tag \
	--zabbix-version "${ZABBIX_VERSION}" --build-date "${BUILD_DATE}" --asset-prefix)" \
	|| fail "アーカイブ名の生成に失敗しました"

# どのコミットからビルドしたかをREADME.txtに残す(GPLの対応するソースを特定できるようにする)。
SOURCE_REVISION="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"

echo "=================================================================="
echo "zabbix-agent2 単体バイナリをビルドします"
echo "  ZABBIX_SRC_DIR=${ZABBIX_SRC_DIR}  ZABBIX_VERSION=${ZABBIX_VERSION}"
echo "  ALPINE_VERSION=${ALPINE_VERSION}  BUILD_DATE=${BUILD_DATE}  SOURCE_REVISION=${SOURCE_REVISION}"
echo "  RELEASE_TAG=${RELEASE_TAG}  DIST_DIR=${DIST_DIR}"
echo "=================================================================="

BUILDER_IMAGE="localhost/zabbix-agent2-binaries:${RELEASE_TAG}"
CONTAINER_NAME=""
cleanup() {
	if [ -n "${CONTAINER_NAME}" ]; then
		docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
	fi
	docker rmi -f "${BUILDER_IMAGE}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# 成果物だけを入れた(FROM scratch の)ステージまでビルドし、そこからファイルを取り出す。
# `--output` ではなく create + cp を使うのは、BuildKitのないDocker互換エンジン(Podman等)でも
# 同じ手順で動かすため。
docker build \
	-f docker/agent2-binaries/Dockerfile \
	--target artifacts \
	--build-arg "ZABBIX_SRC_DIR=${ZABBIX_SRC_DIR}" \
	--build-arg "ALPINE_VERSION=${ALPINE_VERSION}" \
	--build-arg "ASSET_PREFIX=${ASSET_PREFIX}" \
	--build-arg "ZABBIX_VERSION=${ZABBIX_VERSION}" \
	--build-arg "BUILD_DATE=${BUILD_DATE}" \
	--build-arg "SOURCE_REVISION=${SOURCE_REVISION}" \
	-t "${BUILDER_IMAGE}" \
	. || fail "ビルドに失敗しました"

CONTAINER_NAME="zabbix-agent2-binaries-$$"
docker create --name "${CONTAINER_NAME}" "${BUILDER_IMAGE}" /artifacts >/dev/null \
	|| fail "成果物取り出し用のコンテナを作れませんでした"

rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"
docker cp "${CONTAINER_NAME}:/." "${DIST_DIR}/" || fail "成果物をコンテナから取り出せませんでした"

EXPECTED_FILES=(
	"${ASSET_PREFIX}-linux-amd64.tar.gz"
	"${ASSET_PREFIX}-windows-amd64.zip"
	SHA256SUMS
)
for f in "${EXPECTED_FILES[@]}"; do
	[ -s "${DIST_DIR}/${f}" ] || fail "期待する成果物がありません: ${DIST_DIR}/${f}"
done

# 取り出したファイルが、ビルド中に計算したチェックサムと一致することを確認する。
(cd "${DIST_DIR}" && sha256sum -c SHA256SUMS) || fail "SHA256SUMS の検証に失敗しました"

echo ""
echo "=================================================================="
echo "ビルド完了。リリースタグ: ${RELEASE_TAG}"
ls -l "${DIST_DIR}"
echo "=================================================================="
