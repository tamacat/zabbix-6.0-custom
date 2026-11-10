#!/usr/bin/env bash
# docker/web/Dockerfile が固定しているPHPのバージョンより新しいリリースが出ていないかを確認する。
#
# zabbix-webのPHPは、Alpineのパッケージではなくソースからビルドしている。そのためTrivyは
# PHP本体の脆弱性を判定できず、バージョンを上げ忘れても、どのスキャンも失敗しない。
# このスクリプトがその代わりの目印で、同じ系列(例: 8.3)に新しいリリースがあれば失敗する。
# 失敗したら、php.netが公開しているSHA-256で確認して、DockerfileのPHP_VERSIONとPHP_SHA256を
# 更新し、Zabbixの画面の前提条件チェックと scripts/compat-test.sh を通す。
#
# 使用法: scripts/check-php-version.sh
#   PHP_RELEASES_URL  リリース情報のURL(既定: https://www.php.net/releases/index.php)
#   DOCKERFILE        確認するDockerfile(既定: docker/web/Dockerfile)
#
# BR6.1: 失敗時は自動リトライを行わない。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DOCKERFILE="${DOCKERFILE:-docker/web/Dockerfile}"
RELEASES_URL="${PHP_RELEASES_URL:-https://www.php.net/releases/index.php}"

fail() {
	echo "!! ERROR: $1" >&2
	echo "!! BR6.1: 自動リトライは行いません。原因を解消した上で本スクリプトを再実行してください。" >&2
	exit 1
}

# GitHub Actionsの実行ページ($GITHUB_STEP_SUMMARY)へ、結果の表を書き足す。書けなくても確認の結果は変えない。
write_summary() {
	if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
		{
			echo "## PHP バージョンの確認"
			echo ""
			echo "| 系列 | Dockerfileの固定 | php.netの最新 | 結果 |"
			echo "|---|---|---|---|"
			echo "| ${SERIES} | ${PINNED} | ${LATEST} | $1 |"
			echo ""
		} >> "${GITHUB_STEP_SUMMARY}" || true
	fi
}

if python3 -c "import sys" >/dev/null 2>&1; then
	PY=python3
elif python -c "import sys" >/dev/null 2>&1; then
	PY=python
else
	fail "python3(またはpython)の実行可能なインタプリタが見つかりません"
fi

[ -f "${DOCKERFILE}" ] || fail "${DOCKERFILE} が見つかりません"
PINNED="$(sed -n 's/^ARG PHP_VERSION=\([0-9][0-9.]*\)$/\1/p' "${DOCKERFILE}" | head -n 1)"
[ -n "${PINNED}" ] || fail "${DOCKERFILE} に 'ARG PHP_VERSION=X.Y.Z' が見つかりません"
SERIES="${PINNED%.*}"

RESPONSE="$(curl -fsSL "${RELEASES_URL}?json&version=${SERIES}")" \
	|| fail "PHPのリリース情報を取得できませんでした(${RELEASES_URL})"
LATEST="$(printf '%s' "${RESPONSE}" | "${PY}" -c 'import json,sys; print(json.load(sys.stdin)["version"])')" \
	|| fail "PHPのリリース情報を解釈できませんでした(${SERIES}系列の最新バージョンが含まれていません)"

echo "PHP ${SERIES}系列: Dockerfileの固定=${PINNED}  php.netの最新=${LATEST}"

if [ "${LATEST}" = "${PINNED}" ]; then
	echo "PHP version check: up to date"
	write_summary "✅ 最新です"
	exit 0
fi

# 固定の方が新しい(php.netの情報が遅れている)場合は、古いとは言わない。
if [ "$(printf '%s\n%s\n' "${PINNED}" "${LATEST}" | sort -V | tail -n 1)" = "${PINNED}" ]; then
	echo "PHP version check: up to date (pinned version is newer than the release list)"
	write_summary "✅ 最新です(固定の方が新しい)"
	exit 0
fi

write_summary "❌ 更新があります"
echo "PHP version check: OUTDATED — ${LATEST} is available; update PHP_VERSION and PHP_SHA256 in ${DOCKERFILE}" >&2
exit 1
