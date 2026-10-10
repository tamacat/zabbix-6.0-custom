#!/usr/bin/env bats
# docker/server/entrypoint.sh のテスト — 公式 zabbix/zabbix-server-mysql イメージと同じ環境変数から
# zabbix_server.conf が正しく作られることを検証する。実物のスクリプトをそのまま実行し、コンテナ内の
# 絶対パスだけを作業用ディレクトリへ向け、zabbix_server・su-exec・id・chown はスタブにする。

setup() {
	REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
	TEST_TMPDIR="$(mktemp -d)"
	SANDBOX="${TEST_TMPDIR}/sandbox"
	STUB_BIN="${TEST_TMPDIR}/bin"
	CONF="${SANDBOX}/zabbix_server.conf"
	HOME_SB="${SANDBOX}/var/lib/zabbix"
	mkdir -p "${STUB_BIN}" "${HOME_SB}/enc" "${HOME_SB}/enc_internal"

	SCRIPT="${TEST_TMPDIR}/entrypoint.sh"
	sed -e "s#^CONFIG_FILE=.*#CONFIG_FILE=\"${CONF}\"#" \
	    -e "s#^HOME_DIR=.*#HOME_DIR=\"${HOME_SB}\"#" \
	    "${REPO_ROOT}/docker/server/entrypoint.sh" > "${SCRIPT}"
	grep -qF "CONFIG_FILE=\"${CONF}\"" "${SCRIPT}"
	grep -qF "HOME_DIR=\"${HOME_SB}\"" "${SCRIPT}"

	cat > "${STUB_BIN}/zabbix_server" <<EOF
#!/bin/sh
echo "zabbix_server \$*" >> "${TEST_TMPDIR}/started.log"
env | sed -n 's/^\(ZBX_[A-Za-z0-9_]*\|MYSQL_[A-Z_]*\|VAULT_TOKEN\)=.*/\1/p' | sort > "${TEST_TMPDIR}/server-env.log"
EOF
	cat > "${STUB_BIN}/su-exec" <<EOF
#!/bin/sh
echo "su-exec \$1" >> "${TEST_TMPDIR}/started.log"
shift
exec "\$@"
EOF
	cat > "${STUB_BIN}/id" <<'EOF'
#!/bin/sh
echo "${FAKE_UID:-1000}"
EOF
	cat > "${STUB_BIN}/chown" <<EOF
#!/bin/sh
echo "chown \$*" >> "${TEST_TMPDIR}/chown.log"
EOF
	# hostname -f を決まった値にする(HAの自動ノード名)
	cat > "${STUB_BIN}/hostname" <<'EOF'
#!/bin/sh
[ "$1" = "-f" ] && echo "node1.example.internal" || echo "node1"
EOF
	# uname -n(hostname指定の自動ノード名)も実機のホスト名に依存しないよう固定する。-s などは本物へ渡す。
	cat > "${STUB_BIN}/uname" <<'EOF'
#!/bin/sh
[ "$1" = "-n" ] && { echo "node1"; exit 0; }
exec /usr/bin/uname "$@"
EOF
	chmod +x "${STUB_BIN}"/*
}

teardown() {
	rm -rf "${TEST_TMPDIR}"
}

run_entrypoint() {
	run env -i PATH="${STUB_BIN}:${PATH}" HOME="${TEST_TMPDIR}" "$@" bash "${SCRIPT}"
}

conf_has() { grep -qxF -- "$1" "${CONF}"; }
conf_lacks() { ! grep -qE -- "$1" "${CONF}"; }

# --- DB接続 ---------------------------------------------------------------------------

@test "MYSQL_PASSWORDが無ければ起動せず停止する(従来どおり)" {
	run_entrypoint
	[ "$status" -ne 0 ]
	[[ "$output" == *"MYSQL_PASSWORD"* ]]
	[ ! -f "${TEST_TMPDIR}/started.log" ]
}

@test "既定値: DBHost=mysql-server、DBPort=3306、DBName=zabbix、DBUser=zabbix。DBTLSConnectは出さない" {
	run_entrypoint MYSQL_PASSWORD=secret
	[ "$status" -eq 0 ]
	conf_has "DBHost=mysql-server"
	conf_has "DBPort=3306"
	conf_has "DBName=zabbix"
	conf_has "DBUser=zabbix"
	conf_has "DBPassword=secret"
	conf_has "LogType=console"
	conf_lacks '^DBTLS'
	grep -q "^zabbix_server --foreground -c ${CONF}$" "${TEST_TMPDIR}/started.log"
}

@test "DB_SERVER_HOST / MYSQL_USER / MYSQL_DATABASE が反映される" {
	run_entrypoint MYSQL_PASSWORD=p DB_SERVER_HOST=db.example DB_SERVER_PORT=3307 MYSQL_USER=u1 MYSQL_DATABASE=zbx2
	[ "$status" -eq 0 ]
	conf_has "DBHost=db.example"
	conf_has "DBPort=3307"
	conf_has "DBUser=u1"
	conf_has "DBName=zbx2"
}

@test "パスワードに \$ や # や空白が入っていても、そのまま設定へ渡る" {
	run_entrypoint 'MYSQL_PASSWORD=pa$$ w#rd `x`'
	[ "$status" -eq 0 ]
	conf_has 'DBPassword=pa$$ w#rd `x`'
}

@test "Docker secrets: MYSQL_USER_FILE / MYSQL_PASSWORD_FILE から読む(末尾の改行は取り除く)" {
	printf 'fileuser\n' > "${TEST_TMPDIR}/u"; printf 'filepass\n' > "${TEST_TMPDIR}/p"
	run_entrypoint MYSQL_USER_FILE="${TEST_TMPDIR}/u" MYSQL_PASSWORD_FILE="${TEST_TMPDIR}/p"
	[ "$status" -eq 0 ]
	conf_has "DBUser=fileuser"
	conf_has "DBPassword=filepass"
}

@test "Docker secrets: 同じ項目を直接指定とファイルの両方で渡された場合は、曖昧なので停止する" {
	printf 'filepass' > "${TEST_TMPDIR}/p"
	run_entrypoint MYSQL_PASSWORD=x MYSQL_PASSWORD_FILE="${TEST_TMPDIR}/p"
	[ "$status" -ne 0 ]
	[[ "$output" == *"exclusive"* ]]
}

@test "Docker secrets: 読めないファイルを指していれば停止する" {
	run_entrypoint MYSQL_PASSWORD_FILE="${TEST_TMPDIR}/nope"
	[ "$status" -ne 0 ]
	[[ "$output" == *"cannot be read"* ]]
}

@test "Docker secrets: ユーザー名のファイルが読めない場合も、既定の zabbix へ黙って置き換えず停止する" {
	run_entrypoint MYSQL_PASSWORD=p MYSQL_USER_FILE="${TEST_TMPDIR}/nope"
	[ "$status" -ne 0 ]
	[[ "$output" == *"MYSQL_USER_FILE points to"* ]]
	[ ! -f "${TEST_TMPDIR}/started.log" ]
}

@test "Docker secrets: ユーザー名を直接指定とファイルの両方で渡された場合も停止する" {
	printf 'u' > "${TEST_TMPDIR}/u"
	run_entrypoint MYSQL_PASSWORD=p MYSQL_USER=a MYSQL_USER_FILE="${TEST_TMPDIR}/u"
	[ "$status" -ne 0 ]
	[[ "$output" == *"MYSQL_USER and MYSQL_USER_FILE are exclusive"* ]]
}

# --- DBのTLS(以前からの挙動)-----------------------------------------------------------------

@test "DBのTLS: 指定したときだけ DBTLSConnect と各ファイルを出す(公式と同じ変数名)" {
	run_entrypoint MYSQL_PASSWORD=p ZBX_DBTLSCONNECT=verify_full ZBX_DBTLSCAFILE=/ca.pem ZBX_DBTLSCERTFILE=/c.pem ZBX_DBTLSKEYFILE=/k.pem ZBX_DBTLSCIPHER13=TLS_AES_256_GCM_SHA384
	[ "$status" -eq 0 ]
	conf_has "DBTLSConnect=verify_full"
	conf_has "DBTLSCAFile=/ca.pem"
	conf_has "DBTLSCertFile=/c.pem"
	conf_has "DBTLSKeyFile=/k.pem"
	conf_has "DBTLSCipher13=TLS_AES_256_GCM_SHA384"
}

# --- 公式の変数 -----------------------------------------------------------------------------

@test "公式の変数が対応するパラメータへ反映される" {
	run_entrypoint MYSQL_PASSWORD=p ZBX_STARTPOLLERS=9 ZBX_CACHESIZE=64M ZBX_HISTORYCACHESIZE=32M ZBX_DEBUGLEVEL=4 ZBX_TIMEOUT=10 \
		ZBX_STARTTRAPPERS=7 ZBX_VALUECACHESIZE=16M ZBX_PROXYCONFIGFREQUENCY=300 ZBX_STARTREPORTWRITERS=1 ZBX_WEBSERVICEURL=http://ws:10053/report
	[ "$status" -eq 0 ]
	conf_has "StartPollers=9"
	conf_has "CacheSize=64M"
	conf_has "HistoryCacheSize=32M"
	conf_has "DebugLevel=4"
	conf_has "Timeout=10"
	conf_has "StartTrappers=7"
	conf_has "ValueCacheSize=16M"
	conf_has "ProxyConfigFrequency=300"
	conf_has "StartReportWriters=1"
	conf_has "WebServiceURL=http://ws:10053/report"
}

@test "指定の無い・空の変数は、設定ファイルへ出さずZabbixの既定値のままにする" {
	run_entrypoint MYSQL_PASSWORD=p ZBX_STARTPOLLERS= ZBX_CACHESIZE=
	[ "$status" -eq 0 ]
	conf_lacks '^(StartPollers|CacheSize)='
}

@test "Vault: ZBX_VAULTURL/ZBX_VAULTDBPATHは設定へ、VAULT_TOKENは環境のままzabbix_serverへ渡る" {
	run_entrypoint MYSQL_PASSWORD=p ZBX_VAULTURL=https://vault:8200 ZBX_VAULTDBPATH=secret/zabbix VAULT_TOKEN=tok
	[ "$status" -eq 0 ]
	conf_has "VaultURL=https://vault:8200"
	conf_has "VaultDBPath=secret/zabbix"
	conf_lacks 'tok'
	grep -qx "VAULT_TOKEN" "${TEST_TMPDIR}/server-env.log"
}

@test "ZBX_LOADMODULE はカンマ区切りで、LoadModulePathと各LoadModuleになる" {
	run_entrypoint MYSQL_PASSWORD=p ZBX_LOADMODULE=a.so,b.so
	[ "$status" -eq 0 ]
	conf_has "LoadModulePath=${HOME_SB}/modules"
	conf_has "LoadModule=a.so"
	conf_has "LoadModule=b.so"
}

@test "値に改行を含む変数は、設定ファイルを壊さないよう起動せず停止する" {
	run_entrypoint MYSQL_PASSWORD=p "ZBX_TIMEOUT=3
AllowRoot=1"
	[ "$status" -ne 0 ]
	[[ "$output" == *"contains a line break"* ]]
	[ ! -f "${TEST_TMPDIR}/started.log" ]
}

@test "このスクリプトが出力するパラメータは、すべて6.0.48のzabbix_serverが受け付ける名前である" {
	local server_c="${REPO_ROOT}/sources/zabbix-6.0.48/src/zabbix_server/server.c"
	[ -f "${server_c}" ]
	local accepted emitted unknown
	accepted="$(grep -oE '^\s*\{"[A-Za-z0-9]+",\s*&' "${server_c}" | grep -oE '"[A-Za-z0-9]+"' | tr -d '"' | sort -u)"
	[ -n "${accepted}" ]
	emitted="$( { sed -n '/^SCALARS="/,/^"$/p' "${REPO_ROOT}/docker/server/entrypoint.sh" | grep -oE ':[A-Za-z0-9]+$' | tr -d ':'; \
	              sed -n '/^DB_TLS_SCALARS="/,/^"$/p' "${REPO_ROOT}/docker/server/entrypoint.sh" | grep -oE ':[A-Za-z0-9]+$' | tr -d ':'; \
	              sed -n '/^TLS_FILES="/,/^"$/p' "${REPO_ROOT}/docker/server/entrypoint.sh" | grep -oE '^TLS[A-Za-z]+File'; \
	              printf '%s\n' DBHost DBPort DBName DBUser DBPassword LogType PidFile SocketDir AlertScriptsPath ExternalScripts ExportDir LoadModule LoadModulePath HANodeName NodeAddress; } | sort -u)"
	unknown="$(comm -23 <(printf '%s\n' "${emitted}") <(printf '%s\n' "${accepted}"))"
	[ -z "${unknown}" ] || { echo "6.0.48が受け付けないパラメータ: ${unknown}" >&2; return 1; }
	[ "$(printf '%s\n' "${emitted}" | wc -l)" -gt 60 ]
}

# --- サーバー自身のTLS ---------------------------------------------------------------------------

@test "TLS: ファイルのパス(相対は enc 内)と、値そのもの(enc_internalへ600で書き出し、パスより優先)" {
	run_entrypoint MYSQL_PASSWORD=p ZBX_TLSCAFILE=/etc/ssl/ca.pem ZBX_TLSCERTFILE=srv.crt ZBX_TLSKEY=KEYDATA ZBX_TLSKEYFILE=ignored.key ZBX_TLSCIPHERALL13=TLS_AES_128_GCM_SHA256
	[ "$status" -eq 0 ]
	conf_has "TLSCAFile=/etc/ssl/ca.pem"
	conf_has "TLSCertFile=${HOME_SB}/enc/srv.crt"
	conf_has "TLSKeyFile=${HOME_SB}/enc_internal/TLSKeyFile"
	conf_has "TLSCipherAll13=TLS_AES_128_GCM_SHA256"
	[ "$(cat "${HOME_SB}/enc_internal/TLSKeyFile")" = "KEYDATA" ]
}

@test "rootで起動したときは、TLSファイルと設定ファイル(DBパスワード入り)の所有者をzabbixにする" {
	run_entrypoint FAKE_UID=0 MYSQL_PASSWORD=p ZBX_TLSKEY=KEYDATA
	[ "$status" -eq 0 ]
	grep -q "chown zabbix:zabbix ${HOME_SB}/enc_internal/TLSKeyFile" "${TEST_TMPDIR}/chown.log"
	grep -q "chown zabbix:zabbix ${CONF}" "${TEST_TMPDIR}/chown.log"
}

@test "非rootで起動したときは所有者を変更しようとしない(できないため)" {
	run_entrypoint FAKE_UID=1000 MYSQL_PASSWORD=p ZBX_TLSKEY=KEYDATA
	[ "$status" -eq 0 ]
	[ ! -f "${TEST_TMPDIR}/chown.log" ]
}

@test "設定ファイルは所有者以外が読めない(DBのパスワードを含むため)" {
	run_entrypoint MYSQL_PASSWORD=p
	[ "$status" -eq 0 ]
	if [ "$(uname -s | cut -c1-5)" = "Linux" ]; then
		[ "$(stat -c %a "${CONF}")" = "600" ]
	fi
}

# --- HA -----------------------------------------------------------------------------------------

@test "HA: ZBX_HANODENAME / ZBX_NODEADDRESS は明示した値がそのまま設定になる" {
	run_entrypoint MYSQL_PASSWORD=p ZBX_HANODENAME=zbx-a ZBX_NODEADDRESS=10.0.0.5:10051 ZBX_AUTOHANODENAME=fqdn
	[ "$status" -eq 0 ]
	conf_has "HANodeName=zbx-a"
	conf_has "NodeAddress=10.0.0.5:10051"
}

@test "HA: ZBX_AUTOHANODENAME / ZBX_AUTONODEADDRESS は fqdn または hostname から決める(ポートの既定は10051)" {
	run_entrypoint MYSQL_PASSWORD=p ZBX_AUTOHANODENAME=hostname ZBX_AUTONODEADDRESS=fqdn
	[ "$status" -eq 0 ]
	conf_has "HANodeName=node1"
	conf_has "NodeAddress=node1.example.internal:10051"

	run_entrypoint MYSQL_PASSWORD=p ZBX_AUTOHANODENAME=FQDN ZBX_AUTONODEADDRESS=hostname ZBX_NODEADDRESSPORT=10061
	conf_has "HANodeName=node1.example.internal"
	conf_has "NodeAddress=node1:10061"
}

@test "HA: 自動指定に fqdn / hostname 以外の値を渡したら停止する" {
	run_entrypoint MYSQL_PASSWORD=p ZBX_AUTOHANODENAME=whatever
	[ "$status" -ne 0 ]
	[[ "$output" == *"use fqdn or hostname"* ]]
}

@test "HA: 何も指定しなければ HANodeName / NodeAddress は出さない(スタンドアロン)" {
	run_entrypoint MYSQL_PASSWORD=p
	[ "$status" -eq 0 ]
	conf_lacks '^(HANodeName|NodeAddress)='
}

# --- 起動の仕方・警告・環境の消去 --------------------------------------------------------------------

@test "rootで起動したときは su-exec でzabbixユーザーへ降格し、非rootのときは降格せずそのまま起動する" {
	run_entrypoint FAKE_UID=0 MYSQL_PASSWORD=p
	[ "$status" -eq 0 ]
	grep -qx "su-exec zabbix" "${TEST_TMPDIR}/started.log"

	rm -f "${TEST_TMPDIR}/started.log"
	run_entrypoint FAKE_UID=1000 MYSQL_PASSWORD=p
	[ "$status" -eq 0 ]
	! grep -q "^su-exec" "${TEST_TMPDIR}/started.log"
	grep -q "^zabbix_server --foreground" "${TEST_TMPDIR}/started.log"
}

@test "このイメージが扱わない変数(Java/IPMI/ODBC/SNMPトラップ/SMS)は、黙って無視せず警告する" {
	run_entrypoint MYSQL_PASSWORD=p ZBX_JAVAGATEWAY=jg ZBX_STARTIPMIPOLLERS=1 ZBX_STARTODBCPOLLERS=1 ZBX_ENABLE_SNMP_TRAPS=true ZBX_SMSDEVICES=x ZBX_STARTJAVAPOLLERS=2
	[ "$status" -eq 0 ]
	for v in ZBX_JAVAGATEWAY ZBX_STARTIPMIPOLLERS ZBX_STARTODBCPOLLERS ZBX_ENABLE_SNMP_TRAPS ZBX_SMSDEVICES ZBX_STARTJAVAPOLLERS; do
		[[ "$output" == *"${v} is set but is not supported"* ]]
	done
	conf_lacks 'JavaGateway|StartIPMIPollers|StartODBCPollers|StartJavaPollers'
}

@test "扱う変数(公式の変数・TLS・HA)では警告を出さない" {
	run_entrypoint MYSQL_PASSWORD=p ZBX_STARTPOLLERS=3 ZBX_TLSKEY=k ZBX_DBTLSCONNECT=required ZBX_HANODENAME=a ZBX_LOADMODULE=x.so
	[ "$status" -eq 0 ]
	[[ "$output" != *"WARNING"* ]]
}

@test "zabbix_server が動く環境からは ZBX_* とDBの認証情報を取り除き(VAULT_TOKENは残す)、ZBX_CLEAR_ENV=false なら残す" {
	run_entrypoint MYSQL_PASSWORD=p MYSQL_USER=u ZBX_TLSKEY=k ZBX_STARTPOLLERS=3 VAULT_TOKEN=t
	[ "$status" -eq 0 ]
	[ "$(cat "${TEST_TMPDIR}/server-env.log")" = "VAULT_TOKEN" ]

	run_entrypoint ZBX_CLEAR_ENV=false MYSQL_PASSWORD=p ZBX_STARTPOLLERS=3
	grep -qx "ZBX_STARTPOLLERS" "${TEST_TMPDIR}/server-env.log"
	grep -qx "MYSQL_PASSWORD" "${TEST_TMPDIR}/server-env.log"
}
