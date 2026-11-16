#!/usr/bin/env bash
# 上流Zabbixに、取り込み済みより新しい同じ系列のポイントリリース(例: 6.0.49)が出ていないかを確認する。
#
# 公式のコンテナイメージは更新が遅いので、このプロジェクトは上流のソースのリリース(gitのタグ)に
# 直接追従する。Trivyはソースから作ったZabbix本体の脆弱性を判定できないため、このスクリプトが
# 「上流で修正版が出たのに取り込み忘れている」ことを知らせる目印になる(scripts/check-php-version.sh
# と同じく、週次のCIで動かす)。
#
# 比べるのは正式リリース(X.Y.Z)だけ。alpha・beta・rcは追従の対象にしない。取り込み済みの方が
# 新しい、または同じなら成功する。
#
# 使用法: scripts/check-zabbix-version.sh
#   ZBX_GIT_URL  タグを引くgitリポジトリ(既定: https://git.zabbix.com/scm/zbx/zabbix.git)
#   ENV_FILE     取り込み済みのバージョン(ZABBIX_VERSION=)を読むファイル(既定: .env.example)
#
# GitHub Actionsでは $GITHUB_STEP_SUMMARY があれば、結果の表も実行ページへ書き足す。
# BR6.1: 失敗時は自動リトライを行わない。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

ZBX_GIT_URL="${ZBX_GIT_URL:-https://git.zabbix.com/scm/zbx/zabbix.git}"
ENV_FILE="${ENV_FILE:-.env.example}"

fail() {
	echo "!! ERROR: $1" >&2
	echo "!! BR6.1: 自動リトライは行いません。原因を解消した上で本スクリプトを再実行してください。" >&2
	exit 1
}

# 実行ページ用の表。書けなくても確認の結果は変えない。
write_summary() {
	if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
		{
			echo "## Zabbix 上流バージョンの確認"
			echo ""
			echo "| 系列 | 取り込み済み | 上流の最新 | 結果 |"
			echo "|---|---|---|---|"
			echo "| ${LINE} | ${CURRENT} | ${LATEST} | $1 |"
			echo ""
			if [ -n "${2:-}" ]; then
				echo "$2"
				echo ""
			fi
		} >> "${GITHUB_STEP_SUMMARY}" || true
	fi
}

[ -f "${ENV_FILE}" ] || fail "${ENV_FILE} が見つかりません"
CURRENT="$(sed -n 's/^ZABBIX_VERSION=//p' "${ENV_FILE}" | head -n 1)"
[ -n "${CURRENT}" ] || fail "${ENV_FILE} に 'ZABBIX_VERSION=' が見つかりません"
if ! [[ "${CURRENT}" =~ ^([0-9]+\.[0-9]+)\.[0-9]+$ ]]; then
	fail "${ENV_FILE} の ZABBIX_VERSION=${CURRENT} は X.Y.Z の形式ではありません"
fi
LINE="${BASH_REMATCH[1]}"

# 注釈付きタグは ^{} 付きの行も出るので --refs で除く。
TAGS="$(git ls-remote --tags --refs "${ZBX_GIT_URL}" "refs/tags/${LINE}.*" 2>/dev/null)" \
	|| fail "上流のタグを取得できませんでした(${ZBX_GIT_URL})"
NAMES="$(printf '%s\n' "${TAGS}" | awk '{print $2}' | sed -n 's#^refs/tags/##p' | sort -u)"
[ -n "${NAMES}" ] || fail "上流に ${LINE} 系列のタグが1つもありません(${ZBX_GIT_URL})。取得先が正しいか確認してください"

# 正式リリース(6.0.49 など)だけにする。該当が無くてもgrepの終了コードで止まらないようにする。
RELEASES="$(printf '%s\n' "${NAMES}" | grep -E "^${LINE//./\\.}\.[0-9]+$" || true)"
[ -n "${RELEASES}" ] || fail "上流に ${LINE} 系列の正式リリースのタグがありません(${ZBX_GIT_URL})"
LATEST="$(printf '%s\n' "${RELEASES}" | sort -V | tail -n 1)"

echo "Zabbix ${LINE}系列: 取り込み済み=${CURRENT}  上流の最新=${LATEST}"

# 取り込み済みが最新と同じか、より新しい(タグの反映が遅れている)なら、古いとは言わない。
if [ "$(printf '%s\n%s\n' "${CURRENT}" "${LATEST}" | sort -V | tail -n 1)" = "${CURRENT}" ]; then
	echo "Zabbix version check: up to date"
	write_summary "✅ 最新です"
	exit 0
fi

echo "Zabbix version check: OUTDATED — ${LATEST} is available upstream. See README.md (\"To move to a later ${LINE}.x point release\")." >&2
write_summary "❌ 更新があります" "${LATEST} が上流で公開されています。README.md の「To move to a later ${LINE}.x point release」の手順で取り込んでください。"
exit 1
