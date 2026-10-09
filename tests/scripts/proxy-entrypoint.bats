#!/usr/bin/env bats
# docker/proxy/entrypoint.sh のテスト — 公式 zabbix/zabbix-proxy-sqlite3 イメージ(および
# zabbix-5.0-custom の同名イメージ)と同じ環境変数から、zabbix_proxy.conf が正しく作られることを検証する。
#
# 実物のスクリプトをそのまま実行する。コンテナ内の絶対パス(CONFIG_FILE/HOME_DIR)だけを作業用
# ディレクトリへ向け直し、zabbix_proxy・su-exec・id・chown はスタブに置き換える(実際には起動しない)。
# 旧版は ZBX_PROXY_HOSTNAME しか読まず、公式の ZBX_HOSTNAME で渡した名前が黙って無視され、サーバー側で
# 「proxy not found」になっていた(公開済みイメージを使った実機の疎通確認で発覚)。

setup() {
	REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
	TEST_TMPDIR="$(mktemp -d)"
	SANDBOX="${TEST_TMPDIR}/sandbox"
	STUB_BIN="${TEST_TMPDIR}/bin"
	CONF="${SANDBOX}/zabbix_proxy.conf"
	HOME_SB="${SANDBOX}/var/lib/zabbix"
	mkdir -p "${STUB_BIN}" "${HOME_SB}/enc" "${HOME_SB}/enc_internal" "${HOME_SB}/db_data"

	# 実物のスクリプトのコピー。書き換えるのは2つの代入行だけ(それ以外はそのまま)。
	SCRIPT="${TEST_TMPDIR}/entrypoint.sh"
	sed -e "s#^CONFIG_FILE=.*#CONFIG_FILE=\"${CONF}\"#" \
	    -e "s#^HOME_DIR=.*#HOME_DIR=\"${HOME_SB}\"#" \
	    "${REPO_ROOT}/docker/proxy/entrypoint.sh" > "${SCRIPT}"
	# 書き換えが効いていなければ、テストが実環境のパスを触ってしまうので、ここで止める。
	grep -qF "CONFIG_FILE=\"${CONF}\"" "${SCRIPT}"
	grep -qF "HOME_DIR=\"${HOME_SB}\"" "${SCRIPT}"

	# zabbix_proxy: 受け取った引数、見えているZBX_*環境変数、設定ファイルの有無を記録する。
	cat > "${STUB_BIN}/zabbix_proxy" <<EOF
#!/bin/sh
echo "zabbix_proxy \$*" >> "${TEST_TMPDIR}/started.log"
env | sed -n 's/^\(ZBX_[A-Za-z0-9_]*\)=.*/\1/p' | sort > "${TEST_TMPDIR}/proxy-env.log"
EOF
	# su-exec <user> <cmd...>: 呼ばれたことを記録して、そのままコマンドを実行する。
	cat > "${STUB_BIN}/su-exec" <<EOF
#!/bin/sh
echo "su-exec \$1" >> "${TEST_TMPDIR}/started.log"
shift
exec "\$@"
EOF
	# id -u: FAKE_UID(既定1000=非root)を返す。rootでの動作はFAKE_UID=0で試す。
	cat > "${STUB_BIN}/id" <<'EOF'
#!/bin/sh
echo "${FAKE_UID:-1000}"
EOF
	# chown: 実際には変更せず、呼び出しを記録する。
	cat > "${STUB_BIN}/chown" <<EOF
#!/bin/sh
echo "chown \$*" >> "${TEST_TMPDIR}/chown.log"
EOF
	chmod +x "${STUB_BIN}"/*
}

teardown() {
	rm -rf "${TEST_TMPDIR}"
}

# 環境変数(VAR=値 ...)を渡してエントリポイントを実行する。ホストの環境は引き継がない。
run_entrypoint() {
	run env -i PATH="${STUB_BIN}:${PATH}" HOME="${TEST_TMPDIR}" "$@" bash "${SCRIPT}"
}

conf_has() { grep -qxF -- "$1" "${CONF}"; }
conf_lacks() { ! grep -qE -- "$1" "${CONF}"; }

# --- 既定値 ---------------------------------------------------------------------

@test "何も指定しなければ、公式と同じ既定(Server=zabbix-server、Hostname=zabbix-proxy-sqlite3)になる" {
	run_entrypoint
	[ "$status" -eq 0 ]
	conf_has "Server=zabbix-server"
	conf_has "Hostname=zabbix-proxy-sqlite3"
	conf_has "DBName=${HOME_SB}/db_data/zabbix-proxy-sqlite3.sqlite"
	conf_has "LogType=console"
	grep -q "^zabbix_proxy --foreground -c ${CONF}$" "${TEST_TMPDIR}/started.log"
}

@test "6.0で非推奨のServerPortは、何も指定しなければ出力しない(起動のたびの警告を避ける)" {
	run_entrypoint
	[ "$status" -eq 0 ]
	conf_lacks '^ServerPort='
}

@test "指定の無い・空の変数は、設定ファイルへ出さずZabbixの既定値のままにする" {
	run_entrypoint ZBX_STARTPOLLERS= ZBX_TIMEOUT=
	[ "$status" -eq 0 ]
	conf_lacks '^(StartPollers|Timeout)='
}

# --- プロキシ名(今回の不具合) --------------------------------------------------------

@test "公式の ZBX_HOSTNAME で渡した名前がそのままHostnameとSQLiteのファイル名になる" {
	run_entrypoint ZBX_HOSTNAME=name-official
	[ "$status" -eq 0 ]
	conf_has "Hostname=name-official"
	conf_has "DBName=${HOME_SB}/db_data/name-official.sqlite"
}

@test "従来の ZBX_PROXY_HOSTNAME も別名として引き続き使える(後方互換)" {
	run_entrypoint ZBX_PROXY_HOSTNAME=name-legacy
	[ "$status" -eq 0 ]
	conf_has "Hostname=name-legacy"
	conf_lacks 'name-official'
}

@test "両方指定された場合は公式の ZBX_HOSTNAME を優先する" {
	run_entrypoint ZBX_HOSTNAME=name-official ZBX_PROXY_HOSTNAME=name-legacy
	[ "$status" -eq 0 ]
	conf_has "Hostname=name-official"
}

@test "ZBX_HOSTNAME が空文字なら ZBX_PROXY_HOSTNAME へフォールバックする" {
	run_entrypoint ZBX_HOSTNAME= ZBX_PROXY_HOSTNAME=name-legacy
	[ "$status" -eq 0 ]
	conf_has "Hostname=name-legacy"
}

@test "ZBX_HOSTNAMEITEM だけが指定されたときはHostnameItemを使い、Hostnameは出さない" {
	run_entrypoint ZBX_HOSTNAMEITEM=system.hostname
	[ "$status" -eq 0 ]
	conf_has "HostnameItem=system.hostname"
	conf_lacks '^Hostname='
}

@test "ZBX_USE_NODE_NAME_AS_DB_NAME=true ならSQLiteのファイル名にコンテナ自身のホスト名を使う" {
	run_entrypoint ZBX_HOSTNAME=name-official ZBX_USE_NODE_NAME_AS_DB_NAME=TRUE
	[ "$status" -eq 0 ]
	conf_has "Hostname=name-official"
	conf_has "DBName=${HOME_SB}/db_data/$(uname -n).sqlite"
}

@test "ZBX_HOSTNAME に / が含まれる場合は(SQLiteのファイル名になるので)起動せず停止する" {
	run_entrypoint ZBX_HOSTNAME=a/b
	[ "$status" -ne 0 ]
	[[ "$output" == *"must not contain a '/'"* ]]
	[ ! -f "${TEST_TMPDIR}/started.log" ]
}

# --- サーバーとポート -------------------------------------------------------------------

@test "ZBX_SERVER_HOST に host:port の形でポートを書ける(公式と同じ)" {
	run_entrypoint ZBX_SERVER_HOST=zabbix-server:10061
	[ "$status" -eq 0 ]
	conf_has "Server=zabbix-server:10061"
	conf_lacks '^ServerPort='
}

@test "5.0の ZBX_SERVER_PORT は、指定されたときだけ Server=host:port へ反映し、ServerPortは出さない" {
	run_entrypoint ZBX_SERVER_HOST=srv ZBX_SERVER_PORT=10061
	[ "$status" -eq 0 ]
	conf_has "Server=srv:10061"
	conf_lacks '^ServerPort='
	[[ "$output" != *"WARNING"* ]]
}

@test "ZBX_SERVER_HOST が既にポートを含むときは ZBX_SERVER_PORT を無視し、警告する" {
	run_entrypoint ZBX_SERVER_HOST=srv:10061 ZBX_SERVER_PORT=9999
	[ "$status" -eq 0 ]
	conf_has "Server=srv:10061"
	[[ "$output" == *"ZBX_SERVER_PORT is ignored"* ]]
}

# --- スカラー値のパラメータ -------------------------------------------------------------

@test "ZBX_PROXYMODE=1(passive)など、公式の変数が対応するパラメータへ反映される" {
	run_entrypoint ZBX_PROXYMODE=1 ZBX_CONFIGFREQUENCY=600 ZBX_STARTPOLLERS=7 ZBX_DEBUGLEVEL=4 ZBX_CACHESIZE=16M
	[ "$status" -eq 0 ]
	conf_has "ProxyMode=1"
	conf_has "ConfigFrequency=600"
	conf_has "StartPollers=7"
	conf_has "DebugLevel=4"
	conf_has "CacheSize=16M"
}

@test "6.0で追加された公式の変数(ZBX_HEARTBEATFREQUENCY、ZBX_STARTHISTORYPOLLERS)に対応する" {
	run_entrypoint ZBX_HEARTBEATFREQUENCY=30 ZBX_STARTHISTORYPOLLERS=2
	[ "$status" -eq 0 ]
	conf_has "HeartbeatFrequency=30"
	conf_has "StartHistoryPollers=2"
}

@test "5.0側の ZBX_PROXYHEARTBEATFREQUENCY も別名として使え、両方あれば公式の名前を優先する(重複して出さない)" {
	run_entrypoint ZBX_PROXYHEARTBEATFREQUENCY=45
	[ "$status" -eq 0 ]
	conf_has "HeartbeatFrequency=45"

	run_entrypoint ZBX_PROXYHEARTBEATFREQUENCY=45 ZBX_HEARTBEATFREQUENCY=30
	[ "$status" -eq 0 ]
	conf_has "HeartbeatFrequency=30"
	[ "$(grep -c '^HeartbeatFrequency=' "${CONF}")" -eq 1 ]
}

@test "ZBX_LOADMODULE はカンマ区切りで、LoadModulePathと各LoadModuleになる" {
	run_entrypoint ZBX_LOADMODULE=a.so,b.so
	[ "$status" -eq 0 ]
	conf_has "LoadModulePath=${HOME_SB}/modules"
	conf_has "LoadModule=a.so"
	conf_has "LoadModule=b.so"
}

@test "値に改行を含む変数は、設定ファイルを壊さないよう起動せず停止する" {
	run_entrypoint "ZBX_TIMEOUT=3
EnableRemoteCommands=1"
	[ "$status" -ne 0 ]
	[[ "$output" == *"contains a line break"* ]]
	[ ! -f "${TEST_TMPDIR}/started.log" ]
}

# 設定した項目を、実際の6.0.48のzabbix_proxyが受け付けるか(未知のパラメータがあると起動できない)。
@test "このスクリプトが出力するパラメータは、すべて6.0.48のzabbix_proxyが受け付ける名前である" {
	local proxy_c="${REPO_ROOT}/sources/zabbix-6.0.48/src/zabbix_proxy/proxy.c"
	[ -f "${proxy_c}" ]
	local accepted emitted
	accepted="$(grep -oE '^\s*\{"[A-Za-z0-9]+",\s*&' "${proxy_c}" | grep -oE '"[A-Za-z0-9]+"' | tr -d '"' | sort -u)"
	[ -n "${accepted}" ]
	# SCALARSの<変数>:<パラメータ>の右側と、TLS_FILESの左端
	emitted="$( { sed -n '/^SCALARS="/,/^"$/p' "${REPO_ROOT}/docker/proxy/entrypoint.sh" | grep -oE ':[A-Za-z0-9]+$' | tr -d ':'; \
	              sed -n '/^TLS_FILES="/,/^"$/p' "${REPO_ROOT}/docker/proxy/entrypoint.sh" | grep -oE '^TLS[A-Za-z]+File' ; \
	              printf '%s\n' ProxyMode Server Hostname HostnameItem DBName LoadModule LoadModulePath LogType PidFile SocketDir ExternalScripts; } | sort -u)"
	local unknown
	unknown="$(comm -23 <(printf '%s\n' "${emitted}") <(printf '%s\n' "${accepted}"))"
	[ -z "${unknown}" ] || { echo "6.0.48が受け付けないパラメータ: ${unknown}" >&2; return 1; }
	# 表が空だったり読めていなかったりして「何もチェックしていない」状態を防ぐ。
	[ "$(printf '%s\n' "${emitted}" | wc -l)" -gt 40 ]
}

# --- TLS -----------------------------------------------------------------------------

@test "TLSのスカラー値(ZBX_TLSCONNECT、ZBX_TLSPSKIDENTITY等)が反映される" {
	run_entrypoint ZBX_TLSCONNECT=psk ZBX_TLSACCEPT=psk ZBX_TLSPSKIDENTITY=proxy-id
	[ "$status" -eq 0 ]
	conf_has "TLSConnect=psk"
	conf_has "TLSAccept=psk"
	conf_has "TLSPSKIdentity=proxy-id"
}

@test "TLSのファイルは、絶対パスはそのまま、相対パスは enc ボリューム内として扱う" {
	run_entrypoint ZBX_TLSCAFILE=/etc/ssl/ca.pem ZBX_TLSCERTFILE=proxy.crt
	[ "$status" -eq 0 ]
	conf_has "TLSCAFile=/etc/ssl/ca.pem"
	conf_has "TLSCertFile=${HOME_SB}/enc/proxy.crt"
}

@test "TLS素材を値そのもので渡すと enc_internal へ600で書き出し、パスの指定より優先する" {
	run_entrypoint ZBX_TLSPSK=0123456789abcdef ZBX_TLSPSKFILE=ignored.psk
	[ "$status" -eq 0 ]
	conf_has "TLSPSKFile=${HOME_SB}/enc_internal/TLSPSKFile"
	[ "$(cat "${HOME_SB}/enc_internal/TLSPSKFile")" = "0123456789abcdef" ]
	# モードはUnix系でのみ確認できる(Windowsのgit-bashでは意味を持たない)。
	if [ "$(uname -s | cut -c1-5)" = "Linux" ]; then
		[ "$(stat -c %a "${HOME_SB}/enc_internal/TLSPSKFile")" = "600" ]
	fi
}

@test "rootで起動したときは、書き出したTLSファイルをzabbixユーザーが読めるよう所有者を変更する" {
	run_entrypoint FAKE_UID=0 ZBX_TLSPSK=0123456789abcdef
	[ "$status" -eq 0 ]
	grep -q "chown zabbix:zabbix ${HOME_SB}/enc_internal/TLSPSKFile" "${TEST_TMPDIR}/chown.log"
}

@test "非rootで起動したときは所有者を変更しようとしない(できないため)" {
	run_entrypoint FAKE_UID=1000 ZBX_TLSPSK=0123456789abcdef
	[ "$status" -eq 0 ]
	[ ! -f "${TEST_TMPDIR}/chown.log" ]
}

# --- 起動の仕方 ---------------------------------------------------------------------------

@test "rootで起動したときは su-exec でzabbixユーザーへ降格して zabbix_proxy を起動する" {
	run_entrypoint FAKE_UID=0
	[ "$status" -eq 0 ]
	grep -qx "su-exec zabbix" "${TEST_TMPDIR}/started.log"
	grep -q "^zabbix_proxy --foreground" "${TEST_TMPDIR}/started.log"
}

@test "最初から非rootで起動されたときは、降格せずにそのまま zabbix_proxy を起動する" {
	run_entrypoint FAKE_UID=1000
	[ "$status" -eq 0 ]
	run grep -c "^su-exec" "${TEST_TMPDIR}/started.log"
	[ "$output" = "0" ]
	grep -q "^zabbix_proxy --foreground" "${TEST_TMPDIR}/started.log"
}

# --- 警告と環境変数の消去 -----------------------------------------------------------------

@test "このイメージが扱わない変数(Javaゲートウェイ等)は、黙って無視せず警告する" {
	run_entrypoint ZBX_JAVAGATEWAY=somewhere ZBX_STARTIPMIPOLLERS=1 ZBX_ENABLE_SNMP_TRAPS=true
	[ "$status" -eq 0 ]
	[[ "$output" == *"ZBX_JAVAGATEWAY is set but is not supported"* ]]
	[[ "$output" == *"ZBX_STARTIPMIPOLLERS is set but is not supported"* ]]
	[[ "$output" == *"ZBX_ENABLE_SNMP_TRAPS is set but is not supported"* ]]
	conf_lacks 'JavaGateway|StartIPMIPollers'
}

@test "扱う変数(別名・TLS・公式の変数)では、警告を出さない" {
	run_entrypoint ZBX_HOSTNAME=a ZBX_PROXY_HOSTNAME=b ZBX_PROXYHEARTBEATFREQUENCY=30 ZBX_SERVER_HOST=s ZBX_TLSPSK=xx ZBX_TLSCONNECT=psk ZBX_PROXYMODE=0
	[ "$status" -eq 0 ]
	[[ "$output" != *"WARNING"* ]]
}

@test "zabbix_proxy が動く環境からは、PSK等が入りうる ZBX_* を取り除く" {
	run_entrypoint ZBX_TLSPSK=0123456789abcdef ZBX_HOSTNAME=a ZBX_TLSCONNECT=psk
	[ "$status" -eq 0 ]
	[ ! -s "${TEST_TMPDIR}/proxy-env.log" ]
}

@test "ZBX_CLEAR_ENV=false なら ZBX_* を残す" {
	run_entrypoint ZBX_CLEAR_ENV=false ZBX_HOSTNAME=a
	[ "$status" -eq 0 ]
	grep -qx "ZBX_HOSTNAME" "${TEST_TMPDIR}/proxy-env.log"
}
