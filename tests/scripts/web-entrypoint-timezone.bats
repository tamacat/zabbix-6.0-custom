#!/usr/bin/env bats
# docker/web/entrypoint.sh の date.timezone 置換ロジックのテスト。
#
# PHP_TZ(例: Asia/Tokyo)には`/`を含むIANAタイムゾーン名が入るのが通常だが、実装の
# sedコマンドが`/`区切りのままだと、置換文字列側の`/`がsedコマンド自身の区切りと
# 衝突して構文エラーになる(entrypoint.shはset -euのため、コンテナがそこで即座に
# 落ちる)。docker/以下はDockerビルドを要するため他のbatsのようにスクリプトを直接
# 実行できず、実装から該当のsedコマンド行を抜き出して検証する。

setup() {
	REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
	TEST_TMPDIR="$(mktemp -d)"
	FIXTURE_INI="${TEST_TMPDIR}/99-zabbix.ini"
	printf '; comment\ndate.timezone = UTC\nmbstring.func_overload = 0\n' > "${FIXTURE_INI}"
}

teardown() {
	rm -rf "${TEST_TMPDIR}"
}

# entrypoint.shから`ZBX_INI_CONTENT=...`の行(sedコマンド本体)をそのまま抜き出し、
# 対象パスだけをフィクスチャへ差し替えて実行する。実装の変更(区切り文字など)を
# そのまま追跡するため、sedコマンド自体はここで書き写さない。
run_timezone_sed() {
	local php_tz="$1"
	local line script
	line="$(grep -F 'ZBX_INI_CONTENT=' "${REPO_ROOT}/docker/web/entrypoint.sh")"
	[ -n "${line}" ] || { echo "ZBX_INI_CONTENT行が見つかりません(entrypoint.shの構造が変わった?)" >&2; return 1; }
	line="${line//\/etc\/php83\/conf.d\/99-zabbix.ini/${FIXTURE_INI}}"
	script="${line}"$'\n''printf "%s\n" "${ZBX_INI_CONTENT}"'
	PHP_TZ="${php_tz}" bash -c "${script}"
}

@test "PHP_TZ=UTC(デフォルト、/を含まない)は従来通り置換できる" {
	run run_timezone_sed "UTC"
	[ "$status" -eq 0 ]
	[[ "$output" == *"date.timezone = UTC"* ]]
}

@test "PHP_TZ=Asia/Tokyo(/を含むIANAタイムゾーン名)でもsedが構文エラーにならず正しく置換される" {
	run run_timezone_sed "Asia/Tokyo"
	[ "$status" -eq 0 ]
	[[ "$output" == *"date.timezone = Asia/Tokyo"* ]]
	[[ "$output" != *"unknown option"* ]]
	[[ "$output" != *"bad option"* ]]
}

@test "PHP_TZ=America/Argentina/Buenos_Aires(/を2つ含む)でも正しく置換される" {
	run run_timezone_sed "America/Argentina/Buenos_Aires"
	[ "$status" -eq 0 ]
	[[ "$output" == *"date.timezone = America/Argentina/Buenos_Aires"* ]]
}

@test "置換後もファイルの他の行は変更されない" {
	run run_timezone_sed "Asia/Tokyo"
	[ "$status" -eq 0 ]
	[[ "$output" == *"; comment"* ]]
	[[ "$output" == *"mbstring.func_overload = 0"* ]]
}
