#!/usr/bin/env bats
# docker/web/entrypoint.sh のテスト — 公式 zabbix/zabbix-web-nginx-mysql イメージと同じ環境変数から、
# zabbix.conf.php・PHPの設定・nginxの設定が正しく作られることを検証する。実物のスクリプトを
# そのまま実行し、コンテナ内の絶対パスだけを作業用ディレクトリへ向け、php-fpm と nginx はスタブにする。

setup() {
	REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
	TEST_TMPDIR="$(mktemp -d)"
	SB="${TEST_TMPDIR}/sandbox"
	STUB_BIN="${TEST_TMPDIR}/bin"
	PHPCONF="${SB}/zabbix.conf.php"
	INI="${SB}/99-zabbix.ini"
	POOL="${SB}/zz-zabbix.conf"
	NGX="${SB}/nginx"
	SSL="${SB}/ssl"
	mkdir -p "${STUB_BIN}" "${SB}" "${SSL}"

	SCRIPT="${TEST_TMPDIR}/entrypoint.sh"
	sed -e "s#^CONFIG_FILE=.*#CONFIG_FILE=\"${PHPCONF}\"#" \
	    -e "s#^PHP_INI_FILE=.*#PHP_INI_FILE=\"${INI}\"#" \
	    -e "s#^FPM_POOL_FILE=.*#FPM_POOL_FILE=\"${POOL}\"#" \
	    -e "s#^NGINX_SNIPPET_DIR=.*#NGINX_SNIPPET_DIR=\"${NGX}\"#" \
	    -e "s#^SSL_DIR=.*#SSL_DIR=\"${SSL}\"#" \
	    "${REPO_ROOT}/docker/web/entrypoint.sh" > "${SCRIPT}"
	for v in "CONFIG_FILE=\"${PHPCONF}\"" "PHP_INI_FILE=\"${INI}\"" "FPM_POOL_FILE=\"${POOL}\"" \
	         "NGINX_SNIPPET_DIR=\"${NGX}\"" "SSL_DIR=\"${SSL}\""; do
		grep -qF "${v}" "${SCRIPT}"
	done

	for b in php-fpm83 nginx; do
		cat > "${STUB_BIN}/${b}" <<EOF
#!/bin/sh
echo "${b} \$*" >> "${TEST_TMPDIR}/started.log"
EOF
		chmod +x "${STUB_BIN}/${b}"
	done
}

teardown() {
	rm -rf "${TEST_TMPDIR}"
}

run_entrypoint() {
	run env -i PATH="${STUB_BIN}:${PATH}" HOME="${TEST_TMPDIR}" MYSQL_PASSWORD=pw "$@" bash "${SCRIPT}"
}

php_has() { grep -qxF -- "$1" "${PHPCONF}"; }
ini_has() { grep -qxF -- "$1" "${INI}"; }
http_has() { grep -qxF -- "$1" "${NGX}/http.conf"; }
srv_has() { grep -qxF -- "$1" "${NGX}/server.conf"; }

@test "既定値: 公式と同じPHPの制限値・DB既定値で、php-fpmを起動してnginxを前面で起動する" {
	run_entrypoint
	[ "$status" -eq 0 ]
	php_has "\$DB['SERVER']   = 'mysql-server';"
	php_has "\$DB['PORT']     = '3306';"
	php_has "\$DB['DATABASE'] = 'zabbix';"
	php_has "\$DB['USER']     = 'zabbix';"
	php_has "\$DB['PASSWORD'] = 'pw';"
	php_has "\$DB['ENCRYPTION']  = false;"
	php_has "\$DB['DOUBLE_IEEE754'] = true;"
	php_has "\$ZBX_SERVER      = 'zabbix-server';"
	php_has "\$ZBX_SERVER_PORT = '10051';"
	ini_has "max_execution_time = 300"
	ini_has "memory_limit = 128M"
	ini_has "post_max_size = 16M"
	ini_has "upload_max_filesize = 2M"
	ini_has "max_input_time = 300"
	ini_has "date.timezone = UTC"
	http_has "server_tokens on;"
	http_has "access_log /dev/stdout;"
	srv_has "index index.php;"
	! grep -q "listen 8443" "${NGX}/server.conf"
	grep -q "^php-fpm83 --nodaemonize$" "${TEST_TMPDIR}/started.log"
	grep -q '^nginx -e /dev/stderr -g daemon off;$' "${TEST_TMPDIR}/started.log"
}

@test "MYSQL_PASSWORD も MYSQL_PASSWORD_FILE も無ければ起動せず停止する" {
	run env -i PATH="${STUB_BIN}:${PATH}" HOME="${TEST_TMPDIR}" bash "${SCRIPT}"
	[ "$status" -ne 0 ]
	[[ "$output" == *"MYSQL_PASSWORD"* ]]
	[ ! -f "${TEST_TMPDIR}/started.log" ]
}

@test "MYSQL_USER_FILE / MYSQL_PASSWORD_FILE から資格情報を読み、両方指定は拒否する" {
	printf 'fileuser\n' > "${TEST_TMPDIR}/u"; printf 'filepw' > "${TEST_TMPDIR}/p"
	run env -i PATH="${STUB_BIN}:${PATH}" HOME="${TEST_TMPDIR}" MYSQL_USER_FILE="${TEST_TMPDIR}/u" MYSQL_PASSWORD_FILE="${TEST_TMPDIR}/p" bash "${SCRIPT}"
	[ "$status" -eq 0 ]
	php_has "\$DB['USER']     = 'fileuser';"
	php_has "\$DB['PASSWORD'] = 'filepw';"

	run_entrypoint MYSQL_PASSWORD_FILE="${TEST_TMPDIR}/p"
	[ "$status" -ne 0 ]
	[[ "$output" == *"both set"* ]]
}

@test "パスワードに ' や \\ を含んでも、zabbix.conf.php のPHP文字列が壊れない" {
	run_entrypoint "MYSQL_PASSWORD=a'b\\c\$d"
	[ "$status" -eq 0 ]
	php_has "\$DB['PASSWORD'] = 'a\\'b\\\\c\$d';"
}

@test "zabbix.conf.php は 600 で作られる(DBパスワードを含むため)" {
	run_entrypoint
	[ "$status" -eq 0 ]
	if [ "$(uname -s | cut -c1-5)" = "Linux" ]; then
		[ "$(stat -c %a "${PHPCONF}")" = "600" ]
	fi
}

@test "PHP_TZ に / を含む(Asia/Tokyo)値を入れても date.timezone に正しく入る" {
	run_entrypoint PHP_TZ=Asia/Tokyo
	[ "$status" -eq 0 ]
	ini_has "date.timezone = Asia/Tokyo"
}

@test "PHPの制限値と ZBX_SESSION_NAME が php.ini に反映される" {
	run_entrypoint ZBX_MAXEXECUTIONTIME=600 ZBX_MEMORYLIMIT=256M ZBX_POSTMAXSIZE=32M ZBX_UPLOADMAXFILESIZE=8M ZBX_MAXINPUTTIME=120 ZBX_SESSION_NAME=mysess
	[ "$status" -eq 0 ]
	ini_has "max_execution_time = 600"
	ini_has "memory_limit = 256M"
	ini_has "post_max_size = 32M"
	ini_has "upload_max_filesize = 8M"
	ini_has "max_input_time = 120"
	ini_has "session.name = mysess"
}

@test "PHP_FPM_PM* が php-fpm のプール設定になり、未指定の項目は出さない" {
	run_entrypoint PHP_FPM_PM=static PHP_FPM_PM_MAX_CHILDREN=20 PHP_FPM_PM_MAX_REQUESTS=500
	[ "$status" -eq 0 ]
	grep -qxF "[www]" "${POOL}"
	grep -qxF "pm = static" "${POOL}"
	grep -qxF "pm.max_children = 20" "${POOL}"
	grep -qxF "pm.max_requests = 500" "${POOL}"
	! grep -q "start_servers" "${POOL}"
}

@test "DBのTLS(ZBX_DB_*)、DB_DOUBLE_IEEE754=false が zabbix.conf.php に反映される" {
	run_entrypoint ZBX_DB_ENCRYPTION=true ZBX_DB_VERIFY_HOST=true ZBX_DB_CA_FILE=/ca.pem ZBX_DB_CERT_FILE=/c.pem \
		ZBX_DB_KEY_FILE=/k.pem ZBX_DB_CIPHER_LIST=HIGH DB_DOUBLE_IEEE754=false
	[ "$status" -eq 0 ]
	php_has "\$DB['ENCRYPTION']  = true;"
	php_has "\$DB['VERIFY_HOST'] = true;"
	php_has "\$DB['CA_FILE']     = '/ca.pem';"
	php_has "\$DB['CERT_FILE']   = '/c.pem';"
	php_has "\$DB['KEY_FILE']    = '/k.pem';"
	php_has "\$DB['CIPHER_LIST'] = 'HIGH';"
	php_has "\$DB['DOUBLE_IEEE754'] = false;"
}

@test "Vault・履歴ストレージ・SSO の設定は、指定したときだけ書かれる" {
	run_entrypoint
	! grep -qE "VAULT|HISTORY\['url'\]|SSO\[" "${PHPCONF}"

	run_entrypoint ZBX_VAULTURL=https://vault:8200 ZBX_VAULTDBPATH=secret/zbx VAULT_TOKEN=tok \
		ZBX_HISTORYSTORAGEURL=http://es:9200 'ZBX_HISTORYSTORAGETYPES=["uint","dbl"]' \
		ZBX_SSO_SP_KEY=/k ZBX_SSO_SP_CERT=/c ZBX_SSO_IDP_CERT=/i
	[ "$status" -eq 0 ]
	php_has "\$DB['VAULT_URL']     = 'https://vault:8200';"
	php_has "\$DB['VAULT_DB_PATH'] = 'secret/zbx';"
	php_has "\$DB['VAULT_TOKEN']   = 'tok';"
	php_has "\$HISTORY['url'] = 'http://es:9200';"
	php_has "\$HISTORY['types'] = ['uint', 'dbl'];"
	php_has "\$SSO['SP_KEY'] = '/k';"
	php_has "\$SSO['IDP_CERT'] = '/i';"
}

@test "nginx: アクセスログ無効・サーバー情報非表示・index・real_ip が反映される" {
	run_entrypoint ENABLE_WEB_ACCESS_LOG=false EXPOSE_WEB_SERVER_INFO=off HTTP_INDEX_FILE=index.html \
		WEB_REAL_IP_FROM=10.0.0.0/8,192.168.0.1 WEB_REAL_IP_HEADER=X-Real-IP
	[ "$status" -eq 0 ]
	http_has "access_log off;"
	http_has "server_tokens off;"
	http_has "set_real_ip_from 10.0.0.0/8;"
	http_has "set_real_ip_from 192.168.0.1;"
	http_has "real_ip_header X-Real-IP;"
	srv_has "index index.html;"
}

@test "HTTPS: ssl.crt と ssl.key がある場合だけ 8443 を開き、dhparam は任意" {
	: > "${SSL}/ssl.crt"; : > "${SSL}/ssl.key"
	run_entrypoint
	[ "$status" -eq 0 ]
	srv_has "listen 8443 ssl;"
	srv_has "ssl_certificate ${SSL}/ssl.crt;"
	srv_has "ssl_certificate_key ${SSL}/ssl.key;"
	! grep -q dhparam "${NGX}/server.conf"

	: > "${SSL}/dhparam.pem"
	run_entrypoint
	srv_has "ssl_dhparam ${SSL}/dhparam.pem;"
}

@test "GUIアクセス制限: 許可IP以外を拒否し、警告メッセージをHTMLエスケープして返す" {
	run_entrypoint ZBX_DENY_GUI_ACCESS=true 'ZBX_GUI_ACCESS_IP_RANGE=["127.0.0.1","10.0.0.0/24"]' 'ZBX_GUI_WARNING_MSG=Down <b>now</b>'
	[ "$status" -eq 0 ]
	srv_has "allow 127.0.0.1;"
	srv_has "allow 10.0.0.0/24;"
	srv_has "deny all;"
	grep -q "return 503 '<html><body><h1>Down &lt;b&gt;now&lt;/b&gt;</h1></body></html>';" "${NGX}/server.conf"

	run_entrypoint
	! grep -q "deny all" "${NGX}/server.conf"
}

@test "警告メッセージに nginx の設定を壊す文字(' \\ \$)があれば停止する" {
	run_entrypoint ZBX_DENY_GUI_ACCESS=true "ZBX_GUI_WARNING_MSG=a';}"
	[ "$status" -ne 0 ]
	[ ! -f "${TEST_TMPDIR}/started.log" ]
}

@test "値に改行を含む変数は、設定ファイルを壊さないよう起動せず停止する" {
	run_entrypoint "ZBX_MEMORYLIMIT=1M
evil=1"
	[ "$status" -ne 0 ]
	[[ "$output" == *"contains a line break"* ]]
	[ ! -f "${TEST_TMPDIR}/started.log" ]
}

@test "このイメージが扱わない公式の変数は黙って無視せず警告する" {
	run_entrypoint ZBX_AUTH_TYPE=saml
	[ "$status" -eq 0 ]
	[[ "$output" == *"ZBX_AUTH_TYPE is set but is not supported"* ]]
}
