# zabbix-proxy(プロキシ、C言語)— Alpine Linuxベースのカスタムイメージ [FR1.4][FR3.1]。
#
# 前提: docker/server/Dockerfile 冒頭のコメントと同じ — ${ZABBIX_SRC_DIR}(既定
# sources/zabbix-6.0.48)にZabbix 6.0ソースが配置されるまで `docker build` は実行できない。
#
# docker/server/Dockerfile と同じ構造だが、--with-mysql の代わりに --with-sqlite3 を
# 指定する点のみが意図的な差分(BR5.1: zabbix-proxyのローカルバッファに限り
# SQLite3を例外として許容する)。

ARG ALPINE_VERSION=3.24

FROM alpine:${ALPINE_VERSION} AS builder

ARG ZABBIX_SRC_DIR=sources/zabbix-6.0.48

RUN apk add --no-cache \
		build-base \
		pkgconf \
		pcre-dev \
		sqlite-dev \
		openssl-dev \
		libevent-dev \
		zlib-dev \
		libxml2-dev \
		curl-dev \
		net-snmp-dev

WORKDIR /build
COPY ${ZABBIX_SRC_DIR}/ /build/

# git checkoutはtarball展開時のmtime順序を保持しないため、autotoolsが「ソースの方が
# ビルド成果物より新しい」と誤判定し、このビルドステージには存在しないautomake/aclocal
# の再実行を試みて失敗する(既知のautotools問題。--disable-dependency-trackingとは
# 別種の問題で、それだけでは防げない)。コピーされたツリー全体を同一タイムスタンプへ
# 揃え、再生成条件そのものを成立させない(docker/server/Dockerfileと同じ対応)。
RUN find . -exec touch -d '2000-01-01 00:00:00' {} +

RUN sh ./configure \
		--disable-dependency-tracking \
		--enable-proxy \
		--enable-ipv6 \
		--with-sqlite3 \
		--with-net-snmp \
		--with-libcurl \
		--with-libxml2 \
		--with-openssl \
	&& make -j"$(nproc)"

FROM alpine:${ALPINE_VERSION}

RUN apk add --no-cache \
		sqlite-libs \
		pcre \
		openssl \
		libevent \
		zlib \
		libxml2 \
		libcurl \
		net-snmp-libs \
		tzdata \
		ca-certificates \
		su-exec

RUN addgroup -g 1997 -S zabbix \
	&& adduser -D -S -H -u 1997 -G zabbix -s /sbin/nologin zabbix

COPY --from=builder /build/src/zabbix_proxy/zabbix_proxy /usr/sbin/zabbix_proxy
COPY --from=builder /build/conf/zabbix_proxy.conf /etc/zabbix/zabbix_proxy.conf.default

# db_dataはSQLiteバッファファイル専用の永続領域(BR5.1の例外規定はここに限定される。
# 主データベースはあくまでMySQLであり、このボリュームはproxy自身のローカルバッファのみを保持する)。
RUN mkdir -p /etc/zabbix /var/lib/zabbix/db_data /var/lib/zabbix/enc /var/lib/zabbix/externalscripts /run/zabbix \
	&& chown -R zabbix:zabbix /etc/zabbix /var/lib/zabbix /run/zabbix

COPY docker/proxy/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

VOLUME ["/var/lib/zabbix/db_data", "/var/lib/zabbix/enc", "/var/lib/zabbix/externalscripts"]

# USERディレクティブは指定しない — entrypoint.shがsu-exec経由でzabbixユーザーへ降格して
# zabbix_proxyをexecするため(su-exec自体の実行にroot権限が必要。server/Dockerfileと同じ方針)。
EXPOSE 10051

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
	CMD test -f /run/zabbix/zabbix_proxy.pid && kill -0 "$(cat /run/zabbix/zabbix_proxy.pid)" || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
