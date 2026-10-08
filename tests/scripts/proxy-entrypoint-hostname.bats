#!/usr/bin/env bats
# docker/proxy/entrypoint.sh のプロキシ名(Hostname)の決定ロジックのテスト。
#
# 公式 zabbix/zabbix-proxy-sqlite3 イメージはプロキシ名を ZBX_HOSTNAME で受け取る。以前は
# このイメージが ZBX_PROXY_HOSTNAME だけを読んでいたため、公式の指定方法で渡した名前が
# 黙って無視され、プロキシは既定名で接続してサーバー側で「proxy not found」と拒否された
# (公開済みイメージを使った実機の疎通確認で発覚)。docker/以下はDockerビルドを要し
# エントリポイントを丸ごと実行できないため、実装から該当の代入行を抜き出して検証する。

setup() {
	REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
}

# entrypoint.shから ZBX_HOSTNAME を決める行をそのまま抜き出して実行し、結果を出力する。
resolve_hostname() {
	local line
	line="$(grep -F ': "${ZBX_HOSTNAME:=' "${REPO_ROOT}/docker/proxy/entrypoint.sh")"
	[ -n "${line}" ] || { echo "ZBX_HOSTNAMEを決める行が見つかりません(entrypoint.shの構造が変わった?)" >&2; return 1; }
	env -i PATH="${PATH}" "$@" bash -euc "${line}"$'\n''printf "%s" "${ZBX_HOSTNAME}"'
}

@test "公式の ZBX_HOSTNAME で渡した名前がそのまま使われる" {
	run resolve_hostname ZBX_HOSTNAME=name-official
	[ "$status" -eq 0 ]
	[ "$output" = "name-official" ]
}

@test "従来の ZBX_PROXY_HOSTNAME も別名として引き続き使える(後方互換)" {
	run resolve_hostname ZBX_PROXY_HOSTNAME=name-legacy
	[ "$status" -eq 0 ]
	[ "$output" = "name-legacy" ]
}

@test "両方指定された場合は公式の ZBX_HOSTNAME を優先する" {
	run resolve_hostname ZBX_HOSTNAME=name-official ZBX_PROXY_HOSTNAME=name-legacy
	[ "$status" -eq 0 ]
	[ "$output" = "name-official" ]
}

@test "どちらも未指定なら既定名 zabbix-proxy になる" {
	run resolve_hostname
	[ "$status" -eq 0 ]
	[ "$output" = "zabbix-proxy" ]
}

@test "ZBX_HOSTNAME が空文字なら ZBX_PROXY_HOSTNAME へフォールバックする" {
	run resolve_hostname ZBX_HOSTNAME= ZBX_PROXY_HOSTNAME=name-legacy
	[ "$status" -eq 0 ]
	[ "$output" = "name-legacy" ]
}

@test "生成される zabbix_proxy.conf の Hostname は決定済みの ZBX_HOSTNAME から作られる" {
	# 決定ロジックだけ正しくても、設定へ書く変数が古いままだと意味がないので、そこも固定する。
	grep -qxF 'Hostname=${ZBX_HOSTNAME}' "${REPO_ROOT}/docker/proxy/entrypoint.sh"
	run grep -F 'Hostname=${ZBX_PROXY_HOSTNAME}' "${REPO_ROOT}/docker/proxy/entrypoint.sh"
	[ "$status" -ne 0 ]
}
