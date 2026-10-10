#!/bin/sh
# zabbix-server エントリポイント [FR3.2]。公式 zabbix/zabbix-server-mysql イメージと同じ環境変数から
# /etc/zabbix/zabbix_server.conf を生成し、zabbix_server をフォアグラウンドで起動する。
# 公式と同様に、未指定または空の変数はZabbix自身の既定値のままにする。LogType=console で、ログは
# ファイルではなく標準出力へ出す。
#
# 対応するもの: DB接続(DB_SERVER_HOST/DB_SERVER_PORT/MYSQL_USER/MYSQL_PASSWORD/MYSQL_DATABASE と、
# Docker secrets用の MYSQL_USER_FILE/MYSQL_PASSWORD_FILE)、DBのTLS、下のSCALARSの表にあるスカラー値の
# パラメータ、サーバー自身のTLS(値そのものでの指定を含む)、ZBX_LOADMODULE、HAのノード名・
# ノードアドレス(自動設定を含む)。VAULT_TOKEN は公式と同じくzabbix_serverが環境変数から直接読む。
# 対応しないもの(このイメージがその機能なしでビルドされている、または用のボリュームが無い):
# Javaゲートウェイ、IPMI、ODBC、SNMPトラップ、SMS。それ以外でも、設定されたZBX_*のうち対応して
# いないものは、起動時に警告を出して無視したことを必ず知らせる。
#
# このスクリプトはrootで起動し(su-exec自体の実行にrootが必要)、最後にzabbixユーザーへ降格して
# zabbix_serverを起動する。--userで最初から非rootで起動された場合は、降格せずにそのまま起動する。

set -eu

CONFIG_FILE="/etc/zabbix/zabbix_server.conf"
HOME_DIR="/var/lib/zabbix"
ENC_DIR="${HOME_DIR}/enc"
INTERNAL_ENC_DIR="${HOME_DIR}/enc_internal"
NL='
'

# <公式の環境変数>:<zabbix_server.conf のパラメータ>(いずれも 6.0.48 の zabbix_server が受け付ける)
SCALARS="
ZBX_ALLOWUNSUPPORTEDDBVERSIONS:AllowUnsupportedDBVersions
ZBX_DBTLSCIPHER:DBTLSCipher
ZBX_DBTLSCIPHER13:DBTLSCipher13
ZBX_VAULTDBPATH:VaultDBPath
ZBX_VAULTURL:VaultURL
ZBX_LISTENIP:ListenIP
ZBX_LISTENPORT:ListenPort
ZBX_LISTENBACKLOG:ListenBacklog
ZBX_STARTREPORTWRITERS:StartReportWriters
ZBX_WEBSERVICEURL:WebServiceURL
ZBX_SERVICEMANAGERSYNCFREQUENCY:ServiceManagerSyncFrequency
ZBX_HISTORYSTORAGEURL:HistoryStorageURL
ZBX_HISTORYSTORAGETYPES:HistoryStorageTypes
ZBX_STARTPOLLERS:StartPollers
ZBX_STARTPREPROCESSORS:StartPreprocessors
ZBX_STARTPOLLERSUNREACHABLE:StartPollersUnreachable
ZBX_STARTTRAPPERS:StartTrappers
ZBX_STARTPINGERS:StartPingers
ZBX_STARTDISCOVERERS:StartDiscoverers
ZBX_STARTHISTORYPOLLERS:StartHistoryPollers
ZBX_STARTHTTPPOLLERS:StartHTTPPollers
ZBX_STARTTIMERS:StartTimers
ZBX_STARTESCALATORS:StartEscalators
ZBX_STARTALERTERS:StartAlerters
ZBX_STARTLLDPROCESSORS:StartLLDProcessors
ZBX_STATSALLOWEDIP:StatsAllowedIP
ZBX_STARTVMWARECOLLECTORS:StartVMwareCollectors
ZBX_VMWAREFREQUENCY:VMwareFrequency
ZBX_VMWAREPERFFREQUENCY:VMwarePerfFrequency
ZBX_VMWARECACHESIZE:VMwareCacheSize
ZBX_VMWARETIMEOUT:VMwareTimeout
ZBX_SOURCEIP:SourceIP
ZBX_HOUSEKEEPINGFREQUENCY:HousekeepingFrequency
ZBX_MAXHOUSEKEEPERDELETE:MaxHousekeeperDelete
ZBX_PROBLEMHOUSEKEEPINGFREQUENCY:ProblemHousekeepingFrequency
ZBX_CACHESIZE:CacheSize
ZBX_CACHEUPDATEFREQUENCY:CacheUpdateFrequency
ZBX_STARTDBSYNCERS:StartDBSyncers
ZBX_EXPORTFILESIZE:ExportFileSize
ZBX_EXPORTTYPE:ExportType
ZBX_HANODENAME:HANodeName
ZBX_NODEADDRESS:NodeAddress
ZBX_HISTORYCACHESIZE:HistoryCacheSize
ZBX_HISTORYINDEXCACHESIZE:HistoryIndexCacheSize
ZBX_HISTORYSTORAGEDATEINDEX:HistoryStorageDateIndex
ZBX_TRENDCACHESIZE:TrendCacheSize
ZBX_TRENDFUNCTIONCACHESIZE:TrendFunctionCacheSize
ZBX_VALUECACHESIZE:ValueCacheSize
ZBX_TRAPPERTIMEOUT:TrapperTimeout
ZBX_UNREACHABLEPERIOD:UnreachablePeriod
ZBX_UNAVAILABLEDELAY:UnavailableDelay
ZBX_UNREACHABLEDELAY:UnreachableDelay
ZBX_LOGSLOWQUERIES:LogSlowQueries
ZBX_STARTPROXYPOLLERS:StartProxyPollers
ZBX_PROXYCONFIGFREQUENCY:ProxyConfigFrequency
ZBX_PROXYDATAFREQUENCY:ProxyDataFrequency
ZBX_TLSCIPHERALL:TLSCipherAll
ZBX_TLSCIPHERALL13:TLSCipherAll13
ZBX_TLSCIPHERCERT:TLSCipherCert
ZBX_TLSCIPHERCERT13:TLSCipherCert13
ZBX_TLSCIPHERPSK:TLSCipherPSK
ZBX_TLSCIPHERPSK13:TLSCipherPSK13
ZBX_DEBUGLEVEL:DebugLevel
ZBX_TIMEOUT:Timeout
"

# <パラメータ>:<ファイルのパスを入れる変数>:<ファイルの中身そのものを入れる変数>
TLS_FILES="
TLSCAFile:ZBX_TLSCAFILE:ZBX_TLSCA
TLSCRLFile:ZBX_TLSCRLFILE:ZBX_TLSCRL
TLSCertFile:ZBX_TLSCERTFILE:ZBX_TLSCERT
TLSKeyFile:ZBX_TLSKEYFILE:ZBX_TLSKEY
"

# DBのTLS(パスはそのまま渡す。公式と同じ)
DB_TLS_SCALARS="
ZBX_DBTLSCONNECT:DBTLSConnect
ZBX_DBTLSCAFILE:DBTLSCAFile
ZBX_DBTLSCERTFILE:DBTLSCertFile
ZBX_DBTLSKEYFILE:DBTLSKeyFile
"

fail() {
	echo "**** ERROR: $1" >&2
	echo "**** Exiting..." >&2
	exit 1
}

zbx_env_names() {
	env | sed -n 's/^\(ZBX_[A-Za-z0-9_]*\)=.*/\1/p'
}

# conf_set <パラメータ> <値> — 値が空でなければ設定ファイルへ追記する。
conf_set() {
	[ -n "$2" ] || return 0
	case "$2" in
		*"${NL}"*) fail "the value for $1 contains a line break" ;;
	esac
	printf '%s=%s\n' "$1" "$2" >> "${CONFIG_FILE}"
}

env_value() {
	printenv "$1" || true
}

is_root() {
	[ "$(id -u)" = "0" ]
}

# secret_value <変数名> — <変数名> か <変数名>_FILE(Docker secretsのファイル)のどちらか一方から値を得て、
# 変数 secret_result へ入れる。公式と同じく、両方指定された場合は曖昧なので停止する。ファイルの末尾の
# 改行は取り除く。$(...) の中ではfailのexitが親を止められないので、呼び出し側でサブシェルを使わない。
secret_value() {
	direct="$(env_value "$1")"
	path="$(env_value "$1_FILE")"
	if [ -n "${direct}" ] && [ -n "${path}" ]; then
		fail "$1 and $1_FILE are exclusive; set only one of them"
	fi
	if [ -n "${path}" ]; then
		[ -r "${path}" ] || fail "$1_FILE points to '${path}', which cannot be read"
		secret_result="$(cat "${path}")"
	else
		secret_result="${direct}"
	fi
}

# tls_file <パラメータ> <パスの変数> <中身の変数> — 中身の変数に値があれば enc_internal 配下のファイルへ
# 書き出してそれを使い(こちらが優先)、無ければパスの変数を使う(相対パスは enc ボリューム内を探す)。
# rootで書いたファイルはzabbixユーザーが読めるよう、所有者を変更する。
tls_file() {
	file="$(env_value "$2")"
	content="$(env_value "$3")"
	if [ -n "${content}" ]; then
		file="${INTERNAL_ENC_DIR}/$1"
		( umask 077 && printf '%s\n' "${content}" > "${file}" )
		if is_root; then
			chown zabbix:zabbix "${file}"
		fi
	elif [ -n "${file}" ]; then
		case "${file}" in
			/*) ;;
			*) file="${ENC_DIR}/${file}" ;;
		esac
	fi
	conf_set "$1" "${file}"
}

# auto_name <fqdn|hostname> — HAのノード名/アドレスの自動設定用。結果は変数 auto_result へ入れる。
# $(...) の中ではfailのexitが親を止められないので、呼び出し側でサブシェルを使わない。
auto_name() {
	case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
		fqdn) auto_result="$(hostname -f 2>/dev/null || uname -n)" ;;
		hostname) auto_result="$(uname -n)" ;;
		*) fail "the value '$1' is not allowed here (use fqdn or hostname)" ;;
	esac
}

: "${DB_SERVER_HOST:=mysql-server}"
: "${DB_SERVER_PORT:=3306}"
: "${MYSQL_DATABASE:=zabbix}"
secret_value MYSQL_USER
db_user="${secret_result}"
secret_value MYSQL_PASSWORD
db_password="${secret_result}"
: "${db_user:=zabbix}"

if [ -z "${db_password}" ]; then
	fail "MYSQL_PASSWORD (or MYSQL_PASSWORD_FILE) is not set. This variable is mandatory for Zabbix server to connect to the database."
fi

echo "**** Generating ${CONFIG_FILE} from environment variables..."

# DBのパスワードを含むので、zabbixユーザーだけが読めるようにする(rootで作るため所有者を変更する)。
( umask 077 && : > "${CONFIG_FILE}" )
cat >> "${CONFIG_FILE}" <<'CONF'
# Generated by docker/server/entrypoint.sh at container start — do not edit by hand, it is
# overwritten on every restart.

LogType=console
PidFile=/run/zabbix/zabbix_server.pid
SocketDir=/run/zabbix

AlertScriptsPath=/var/lib/zabbix/alertscripts
ExternalScripts=/var/lib/zabbix/externalscripts
ExportDir=/var/lib/zabbix/export
CONF

conf_set DBHost "${DB_SERVER_HOST}"
conf_set DBPort "${DB_SERVER_PORT}"
conf_set DBName "${MYSQL_DATABASE}"
conf_set DBUser "${db_user}"
conf_set DBPassword "${db_password}"

# 未設定(既定)の場合はDBTLSConnect行を生成しない — TLSなしで接続する(公式と同じ変数名)。
for pair in ${DB_TLS_SCALARS}; do
	conf_set "${pair#*:}" "$(env_value "${pair%%:*}")"
done

for pair in ${SCALARS}; do
	conf_set "${pair#*:}" "$(env_value "${pair%%:*}")"
done

for entry in ${TLS_FILES}; do
	key="${entry%%:*}"
	rest="${entry#*:}"
	tls_file "${key}" "${rest%%:*}" "${rest#*:}"
done

if [ -n "$(env_value ZBX_LOADMODULE)" ]; then
	conf_set LoadModulePath "${HOME_DIR}/modules"
	old_ifs="${IFS}"
	IFS=','
	for module in $(env_value ZBX_LOADMODULE); do
		conf_set LoadModule "${module}"
	done
	IFS="${old_ifs}"
fi

# HA(6.0以降)。ノード名: ZBX_HANODENAME(明示)が優先、無ければZBX_AUTOHANODENAME。
# ノードアドレス: ZBX_NODEADDRESS(明示)が優先、無ければZBX_AUTONODEADDRESSと ZBX_NODEADDRESSPORT(既定10051)。
if [ -n "$(env_value ZBX_HANODENAME)" ]; then
	conf_set HANodeName "$(env_value ZBX_HANODENAME)"
elif [ -n "$(env_value ZBX_AUTOHANODENAME)" ]; then
	auto_name "$(env_value ZBX_AUTOHANODENAME)"
	conf_set HANodeName "${auto_result}"
fi
if [ -n "$(env_value ZBX_NODEADDRESS)" ]; then
	conf_set NodeAddress "$(env_value ZBX_NODEADDRESS)"
elif [ -n "$(env_value ZBX_AUTONODEADDRESS)" ]; then
	auto_name "$(env_value ZBX_AUTONODEADDRESS)"
	node_port="$(env_value ZBX_NODEADDRESSPORT)"
	conf_set NodeAddress "${auto_result}:${node_port:-10051}"
fi

# 設定ファイルはzabbixユーザーだけが読める(DBのパスワードを含む)。
if is_root; then
	chown zabbix:zabbix "${CONFIG_FILE}"
fi

# 設定されているのにこのイメージが扱わない変数を、運用者へ知らせる。
known=" ZBX_LOADMODULE ZBX_HANODENAME ZBX_AUTOHANODENAME ZBX_NODEADDRESS ZBX_AUTONODEADDRESS ZBX_NODEADDRESSPORT ZBX_CLEAR_ENV"
for pair in ${SCALARS} ${DB_TLS_SCALARS}; do
	known="${known} ${pair%%:*}"
done
for entry in ${TLS_FILES}; do
	rest="${entry#*:}"
	known="${known} ${rest%%:*} ${rest#*:}"
done
for name in $(zbx_env_names); do
	case "${known} " in
		*" ${name} "*) ;;
		*) echo "**** WARNING: ${name} is set but is not supported by this image; it is ignored." >&2 ;;
	esac
done

# 公式のイメージと同じく、zabbix_server が動く環境からZBX_*を取り除く(TLSの鍵の中身などが入っている
# ことがあるため)。ZBX_CLEAR_ENV=false なら残す。DBのユーザー/パスワードは設定ファイルへ書いた後は不要なので、
# 同じ理由でこの環境にも残さない。
if [ "${ZBX_CLEAR_ENV:-true}" != "false" ]; then
	for name in $(zbx_env_names); do
		unset "${name}"
	done
	unset MYSQL_USER MYSQL_PASSWORD MYSQL_USER_FILE MYSQL_PASSWORD_FILE
fi

echo "**** Starting Zabbix server..."
if is_root; then
	exec su-exec zabbix zabbix_server --foreground -c "${CONFIG_FILE}"
fi
exec zabbix_server --foreground -c "${CONFIG_FILE}"
