#!/usr/bin/env bats
# docker/agent2/entrypoint.sh のテスト — 公式 zabbix/zabbix-agent2 イメージと同じ環境変数から
# zabbix_agent2.conf が正しく作られることを検証する。実物のスクリプトをそのまま実行し、
# コンテナ内の絶対パスだけを作業用ディレクトリへ向け、zabbix_agent2 はスタブにする。

setup() {
	REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
	TEST_TMPDIR="$(mktemp -d)"
	SANDBOX="${TEST_TMPDIR}/sandbox"
	STUB_BIN="${TEST_TMPDIR}/bin"
	CONF="${SANDBOX}/zabbix_agent2.conf"
	HOME_SB="${SANDBOX}/var/lib/zabbix"
	mkdir -p "${STUB_BIN}" "${HOME_SB}/enc" "${HOME_SB}/enc_internal"

	SCRIPT="${TEST_TMPDIR}/entrypoint.sh"
	sed -e "s#^CONFIG_FILE=.*#CONFIG_FILE=\"${CONF}\"#" \
	    -e "s#^HOME_DIR=.*#HOME_DIR=\"${HOME_SB}\"#" \
	    "${REPO_ROOT}/docker/agent2/entrypoint.sh" > "${SCRIPT}"
	grep -qF "CONFIG_FILE=\"${CONF}\"" "${SCRIPT}"
	grep -qF "HOME_DIR=\"${HOME_SB}\"" "${SCRIPT}"

	cat > "${STUB_BIN}/zabbix_agent2" <<EOF
#!/bin/sh
echo "zabbix_agent2 \$*" >> "${TEST_TMPDIR}/started.log"
env | sed -n 's/^\(ZBX_[A-Za-z0-9_]*\)=.*/\1/p' | sort > "${TEST_TMPDIR}/agent-env.log"
EOF
	chmod +x "${STUB_BIN}/zabbix_agent2"
}

teardown() {
	rm -rf "${TEST_TMPDIR}"
}

run_entrypoint() {
	run env -i PATH="${STUB_BIN}:${PATH}" HOME="${TEST_TMPDIR}" "$@" bash "${SCRIPT}"
}

conf_has() { grep -qxF -- "$1" "${CONF}"; }
conf_lacks() { ! grep -qE -- "$1" "${CONF}"; }

@test "何も指定しなければ、Server=ServerActive=zabbix-server、EnablePersistentBuffer=0(従来どおり)" {
	run_entrypoint
	[ "$status" -eq 0 ]
	conf_has "Server=zabbix-server"
	conf_has "ServerActive=zabbix-server"
	conf_has "EnablePersistentBuffer=0"
	conf_has "LogType=console"
	conf_lacks '^Hostname='
	grep -q "^zabbix_agent2 --foreground -c ${CONF}$" "${TEST_TMPDIR}/started.log"
}

@test "ZBX_HOSTNAME が Hostname になる" {
	run_entrypoint ZBX_HOSTNAME=agent-1
	[ "$status" -eq 0 ]
	conf_has "Hostname=agent-1"
}

@test "ZBX_SERVER_HOST にプロキシを指定でき、アクティブ側のポートは ZBX_SERVER_PORT で変えられる" {
	run_entrypoint ZBX_SERVER_HOST=zabbix-proxy ZBX_SERVER_PORT=10061
	[ "$status" -eq 0 ]
	conf_has "Server=zabbix-proxy"
	conf_has "ServerActive=zabbix-proxy:10061"
}

@test "ZBX_PASSIVESERVERS / ZBX_ACTIVESERVERS は、ZBX_SERVER_HOST に足されて Server / ServerActive になる" {
	run_entrypoint ZBX_SERVER_HOST=a ZBX_PASSIVESERVERS=b,c ZBX_ACTIVESERVERS=zabbix-server:10061,zabbix-proxy:10072
	[ "$status" -eq 0 ]
	conf_has "Server=a,b,c"
	conf_has "ServerActive=a,zabbix-server:10061,zabbix-proxy:10072"
}

@test "ZBX_PASSIVE_ALLOW=false ならServerを出さず、ZBX_ACTIVE_ALLOW=false ならServerActiveを出さない" {
	run_entrypoint ZBX_PASSIVE_ALLOW=false
	[ "$status" -eq 0 ]
	conf_lacks '^Server='
	conf_has "ServerActive=zabbix-server"

	run_entrypoint ZBX_ACTIVE_ALLOW=FALSE
	[ "$status" -eq 0 ]
	conf_has "Server=zabbix-server"
	conf_lacks '^ServerActive='
}

@test "公式の変数が対応するパラメータへ反映される(Plugins.*を含む)" {
	run_entrypoint ZBX_DEBUGLEVEL=4 ZBX_TIMEOUT=10 ZBX_LISTENPORT=10055 ZBX_METADATA=linux ZBX_REFRESHACTIVECHECKS=60 \
		ZBX_BUFFERSIZE=200 ZBX_LOGREMOTECOMMANDS=1 ZBX_MAXLINESPERSECOND=40 ZBX_FORCEACTIVECHECKSONSTART=1 ZBX_PLUGINTIMEOUT=5
	[ "$status" -eq 0 ]
	conf_has "DebugLevel=4"
	conf_has "Timeout=10"
	conf_has "ListenPort=10055"
	conf_has "HostMetadata=linux"
	conf_has "RefreshActiveChecks=60"
	conf_has "BufferSize=200"
	conf_has "Plugins.SystemRun.LogRemoteCommands=1"
	conf_has "Plugins.Log.MaxLinesPerSecond=40"
	conf_has "ForceActiveChecksOnStart=1"
	conf_has "PluginTimeout=5"
}

@test "ZBX_ALLOWKEY / ZBX_DENYKEY は、キーにカンマを含んでもそのまま1行で渡る" {
	run_entrypoint 'ZBX_DENYKEY=system.run[*]' 'ZBX_ALLOWKEY=vfs.file.contents[/etc/hosts,utf8]'
	[ "$status" -eq 0 ]
	conf_has "DenyKey=system.run[*]"
	conf_has "AllowKey=vfs.file.contents[/etc/hosts,utf8]"
}

@test "永続バッファ: true/1 で有効にしてファイルの場所も設定し、false/未指定は0" {
	run_entrypoint ZBX_ENABLEPERSISTENTBUFFER=true ZBX_PERSISTENTBUFFERPERIOD=2h
	[ "$status" -eq 0 ]
	conf_has "EnablePersistentBuffer=1"
	conf_has "PersistentBufferFile=${HOME_SB}/buffer/agent2.db"
	conf_has "PersistentBufferPeriod=2h"

	run_entrypoint ZBX_ENABLEPERSISTENTBUFFER=false
	conf_has "EnablePersistentBuffer=0"
	conf_lacks '^PersistentBufferFile='
}

@test "ZBX_ENABLESTATUSPORT=true で StatusPort=31999 になる" {
	run_entrypoint ZBX_ENABLESTATUSPORT=true
	[ "$status" -eq 0 ]
	conf_has "StatusPort=31999"
}

@test "指定の無い・空の変数は、設定ファイルへ出さずZabbixの既定値のままにする" {
	run_entrypoint ZBX_TIMEOUT= ZBX_LISTENPORT=
	[ "$status" -eq 0 ]
	conf_lacks '^(Timeout|ListenPort)='
}

@test "値に改行を含む変数は、設定ファイルを壊さないよう起動せず停止する" {
	run_entrypoint "ZBX_TIMEOUT=3
UnsafeUserParameters=1"
	[ "$status" -ne 0 ]
	[[ "$output" == *"contains a line break"* ]]
	[ ! -f "${TEST_TMPDIR}/started.log" ]
}

@test "このスクリプトが出力するパラメータは、すべて6.0.48のzabbix_agent2.confにあるパラメータである" {
	local sample="${REPO_ROOT}/sources/zabbix-6.0.48/src/go/conf/zabbix_agent2.conf"
	[ -f "${sample}" ]
	local accepted emitted unknown
	accepted="$(grep -oE '^#+ Option: ?[A-Za-z0-9.]+' "${sample}" | sed 's/.*Option: *//' | sort -u)"
	emitted="$( { sed -n '/^SCALARS="/,/^"$/p' "${REPO_ROOT}/docker/agent2/entrypoint.sh" | grep -oE ':[A-Za-z0-9.]+$' | tr -d ':'; \
	              sed -n '/^TLS_FILES="/,/^"$/p' "${REPO_ROOT}/docker/agent2/entrypoint.sh" | grep -oE '^TLS[A-Za-z]+File'; \
	              printf '%s\n' Server ServerActive Hostname EnablePersistentBuffer PersistentBufferFile StatusPort LogType PidFile ControlSocket; } | sort -u)"
	unknown="$(comm -23 <(printf '%s\n' "${emitted}") <(printf '%s\n' "${accepted}"))"
	[ -z "${unknown}" ] || { echo "6.0.48のzabbix_agent2.confに無いパラメータ: ${unknown}" >&2; return 1; }
	[ "$(printf '%s\n' "${emitted}" | wc -l)" -gt 25 ]
}

@test "TLS: スカラー値、ファイルのパス(相対は enc 内)、値そのもの(enc_internalへ600で書き出し、パスより優先)" {
	run_entrypoint ZBX_TLSCONNECT=psk ZBX_TLSACCEPT=psk ZBX_TLSPSKIDENTITY=id1 ZBX_TLSCAFILE=/etc/ssl/ca.pem ZBX_TLSCERTFILE=a.crt \
		ZBX_TLSPSK=0123456789abcdef ZBX_TLSPSKFILE=ignored
	[ "$status" -eq 0 ]
	conf_has "TLSConnect=psk"
	conf_has "TLSPSKIdentity=id1"
	conf_has "TLSCAFile=/etc/ssl/ca.pem"
	conf_has "TLSCertFile=${HOME_SB}/enc/a.crt"
	conf_has "TLSPSKFile=${HOME_SB}/enc_internal/TLSPSKFile"
	[ "$(cat "${HOME_SB}/enc_internal/TLSPSKFile")" = "0123456789abcdef" ]
}

@test "このイメージが扱わない変数は黙って無視せず警告し、扱う変数では警告しない" {
	run_entrypoint ZBX_NOSUCHTHING=1
	[ "$status" -eq 0 ]
	[[ "$output" == *"ZBX_NOSUCHTHING is set but is not supported"* ]]

	run_entrypoint ZBX_HOSTNAME=a ZBX_SERVER_HOST=s ZBX_SERVER_PORT=1 ZBX_PASSIVESERVERS=p ZBX_ACTIVESERVERS=q ZBX_PASSIVE_ALLOW=true ZBX_TLSPSK=x ZBX_DENYKEY=k
	[[ "$output" != *"WARNING"* ]]
}

@test "zabbix_agent2 が動く環境からは ZBX_* を取り除き、ZBX_CLEAR_ENV=false なら残す" {
	run_entrypoint ZBX_TLSPSK=0123 ZBX_HOSTNAME=a
	[ "$status" -eq 0 ]
	[ ! -s "${TEST_TMPDIR}/agent-env.log" ]

	run_entrypoint ZBX_CLEAR_ENV=false ZBX_HOSTNAME=a
	grep -qx "ZBX_HOSTNAME" "${TEST_TMPDIR}/agent-env.log"
}
