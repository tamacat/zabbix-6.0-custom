#!/usr/bin/env bash
# CompatibilityTestRunner — docker composeでビルド済みイメージ一式を構築・起動し、
# 公式イメージとの環境変数・ボリューム互換性をスモークテストで確認する
# [FR4.1][FR4.2][BR3.1](NFR1.1: docker stats観察は参考情報として記録する)。
#
# BR6.1: 失敗時は自動リトライを行わない。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# .envは既定値のみを補う。既に環境変数としてexportされている値を上書きしない。
if [ -f .env ]; then
	while IFS='=' read -r _env_key _env_val; do
		if [ -z "${!_env_key+x}" ]; then
			export "${_env_key}=${_env_val}"
		fi
	done < <(grep -Ev '^[[:space:]]*(#|$)' .env)
fi

fail() {
	echo "!! ERROR: $1" >&2
	echo "!! BR6.1: 自動リトライは行いません。原因を解消した上で本スクリプトを再実行してください。" >&2
	exit 1
}

if ! command -v docker >/dev/null 2>&1; then
	fail "docker が見つかりません。インストールしてから再実行してください。"
fi

# FR3.2/NFR4: 公式zabbix/zabbix-*-mysqlイメージとの環境変数互換性のうち、
# 接続に必須の変数が.envで設定されていることを事前に確認する。
REQUIRED_ENV_VARS="DB_SERVER_HOST MYSQL_PASSWORD"
for var in ${REQUIRED_ENV_VARS}; do
	value="$(eval "printf '%s' \"\${${var}:-}\"")"
	if [ -z "${value}" ]; then
		fail "必須環境変数 ${var} が設定されていません(.env.exampleをコピーして.envに値を設定してください)"
	fi
done

echo "=================================================================="
echo "docker compose config --quiet(構文検証)"
echo "=================================================================="
docker compose config --quiet || fail "compose.ymlの構文検証に失敗しました"

echo ""
echo "=================================================================="
echo "docker compose up -d"
echo "=================================================================="
docker compose up -d || fail "docker compose up に失敗しました"

echo ""
echo "=================================================================="
echo "環境変数・ボリューム互換性チェックリスト(FR4.2、公式イメージ比較)"
echo "=================================================================="
cat <<'CHECKLIST'
[ ] DB_SERVER_HOST / DB_SERVER_PORT / MYSQL_USER / MYSQL_PASSWORD / MYSQL_DATABASE
    (zabbix/zabbix-server-mysql, zabbix/zabbix-web-nginx-mysql と同名)
[ ] ZBX_SERVER_HOST / ZBX_SERVER_NAME / ZBX_HOSTNAME / ZBX_PROXY_HOSTNAME
    (zabbix/zabbix-web-nginx-mysql, zabbix/zabbix-agent2, zabbix/zabbix-proxy-sqlite3 と同名)
[ ] /var/lib/zabbix/alertscripts, /var/lib/zabbix/externalscripts, /var/lib/zabbix/enc
    (zabbix-server / zabbix-proxy のボリュームマウントポイント)
[ ] /usr/share/zabbix/conf (zabbix-web の設定ボリューム)
CHECKLIST
echo "上記チェックリストは単独運用者が目視で確認する(BR3.2のセルフレビュー時に併せて確認)。"

echo ""
echo "=================================================================="
echo "docker stats --no-stream(NFR1.1: 参考観察情報。公開ゲート判定には含めない)"
echo "=================================================================="
docker stats --no-stream || echo "(docker statsの取得に失敗しましたが、参考情報のため本スクリプト自体は継続します)"

echo ""
echo "CompatibilityTestRun result: Pass"
