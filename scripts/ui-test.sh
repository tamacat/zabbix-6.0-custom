#!/usr/bin/env bash
# UiRegressionRunner — Web管理画面のリグレッションテスト(tests/ui/)を、専用のスタックに対して実行する。
#
# compose.yml に docker/ui-test/compose.yml を重ね、プロジェクト名・コンテナ名・ポートを他と分けた
# スタック(dev-mysql + zabbix-server + zabbix-web)を起動し、tests/ui/ を流し、最後に後片付けする。
# 別バージョンのスタックや compat-test.sh のスタックが動いていても衝突しない。
#
# 使い方:
#   ./scripts/ui-test.sh                     # compose.ymlのbuild定義でビルドしてから実行
#   ./scripts/ui-test.sh --no-build          # ビルド済みのイメージを使う(ZABBIX_IMAGE_TAGで指定)
#   ./scripts/ui-test.sh --keep              # 終わってもスタックを残す(画面を目で確認したいとき)
#   ./scripts/ui-test.sh -- -k export -x     # `--` 以降はpytestへ渡す
#
# 環境変数: UI_TEST_WEB_PORT(既定18080)、UI_TEST_MYSQL_PORT(既定13306)。
#
# BR6.1: 失敗時は自動リトライを行わない(スタックの起動待ちは再試行ではなく待機)。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail() {
	echo "!! ERROR: $1" >&2
	echo "!! BR6.1: 自動リトライは行いません。原因を解消した上で本スクリプトを再実行してください。" >&2
	exit 1
}

BUILD_FLAG="--build"
KEEP=0
PYTEST_ARGS=()
while [ $# -gt 0 ]; do
	case "$1" in
		--no-build) BUILD_FLAG="--no-build" ;;
		--keep) KEEP=1 ;;
		--) shift; PYTEST_ARGS=("$@"); break ;;
		*) fail "不明な引数: $1" ;;
	esac
	shift
done

# 隔離スタックの値を先に決める。.envは未設定の変数にだけ既定値を補う(他のスクリプトと同じ方式)ので、
# .envのDB_SERVER_HOSTなどが、ここで決めた隔離用の値を上書きすることはない。
if python3 -c "import sys" >/dev/null 2>&1; then
	PY=python3
elif python -c "import sys" >/dev/null 2>&1; then
	PY=python
else
	fail "python3(またはpython)の実行可能なインタプリタが見つかりません"
fi

export COMPOSE_PROJECT_NAME=zbx6ui
export COMPOSE_PROFILES=dev
export DB_SERVER_HOST=zbx6ui-mysql
export DB_SERVER_PORT=3306
export MYSQL_USER=zabbix
export MYSQL_DATABASE=zabbix
# 使い捨てDBのパスワードは実行ごとに作る(リポジトリに固定値を置かない)。
MYSQL_PASSWORD="$("${PY}" -c 'import secrets; print(secrets.token_hex(16))')"
DEV_MYSQL_ROOT_PASSWORD="$("${PY}" -c 'import secrets; print(secrets.token_hex(16))')"
export MYSQL_PASSWORD DEV_MYSQL_ROOT_PASSWORD
export ZABBIX_WEB_PORT="${UI_TEST_WEB_PORT:-18080}"
export DEV_MYSQL_PORT="${UI_TEST_MYSQL_PORT:-13306}"
# entrypoint.shが環境変数から作る設定が画面に出ること(test_server_link.py)を確かめるための値。
export ZBX_SERVER_NAME=zbx6-ui-regression

if [ -f .env ]; then
	while IFS='=' read -r _env_key _env_val; do
		if [ -z "${!_env_key+x}" ]; then
			export "${_env_key}=${_env_val}"
		fi
	done < <(grep -Ev '^[[:space:]]*(#|$)' .env)
fi

if ! command -v docker >/dev/null 2>&1; then
	fail "docker が見つかりません。インストールしてから再実行してください。"
fi
"${PY}" -c "import pytest, yaml" >/dev/null 2>&1 || fail "pytest と PyYAML が必要です(pip install pytest PyYAML)"

COMPOSE=(docker compose -f compose.yml -f docker/ui-test/compose.yml)
SERVICES=(dev-mysql zabbix-server zabbix-web)

cleanup() {
	status=$?
	if [ "${status}" -ne 0 ]; then
		echo ""
		echo "=================================================================="
		echo "失敗時の診断: zabbix-web / zabbix-server の直近のログ"
		echo "=================================================================="
		"${COMPOSE[@]}" logs --no-color --tail 60 zabbix-web zabbix-server 2>&1 || true
	fi
	if [ "${KEEP}" -eq 1 ]; then
		echo ""
		echo "--keep: スタックを残しました。 http://127.0.0.1:${ZABBIX_WEB_PORT}/ (Admin)"
		echo "        片付けるには: COMPOSE_PROJECT_NAME=zbx6ui docker compose -f compose.yml -f docker/ui-test/compose.yml down -v"
	else
		"${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
	fi
	exit "${status}"
}
trap cleanup EXIT

echo "=================================================================="
echo "docker compose up -d ${BUILD_FLAG} ${SERVICES[*]}  (project=${COMPOSE_PROJECT_NAME}, web port=${ZABBIX_WEB_PORT})"
echo "=================================================================="
"${COMPOSE[@]}" config --quiet || fail "compose.ymlの構文検証に失敗しました"
"${COMPOSE[@]}" up -d "${BUILD_FLAG}" "${SERVICES[@]}" || fail "docker compose up に失敗しました"

echo ""
echo "=================================================================="
echo "tests/ui/ を実行します"
echo "=================================================================="
export ZABBIX_URL="http://127.0.0.1:${ZABBIX_WEB_PORT}"
export ZBX_UI_REQUIRED=1
# Windowsのコンソールの文字コード(cp932など)に依らず、テスト出力をUTF-8で出す。
export PYTHONUTF8=1
export ZABBIX_VERSION="${ZABBIX_VERSION:-}"
"${PY}" -m pytest tests/ui -v -rsx "${PYTEST_ARGS[@]}" || fail "Web管理画面のリグレッションテストに失敗しました"

echo ""
echo "=================================================================="
echo "zabbix-web のログに致命的なPHPエラーが無いこと"
echo "=================================================================="
# 画面に出ずphp-fpmのログだけに残るエラー(テスト中に踏んだ未捕捉の例外など)を拾う。
# tests/ui/test_web_server.py はPHPの内部ファイルを直接取りに行くが、nginxが404で止めるのでPHPには届かない
# (届いてエラーになるなら、それは拒否ルールが効いていないという本物の不具合)。
if "${COMPOSE[@]}" logs --no-color zabbix-web 2>&1 | grep -E 'PHP (Fatal error|Parse error)|Uncaught |SIGSEGV|signal 11'; then
	fail "zabbix-web のログにPHPの致命的エラーが記録されています(上の行)"
fi
echo "OK"

echo ""
echo "UiRegressionTestRun result: Pass"
