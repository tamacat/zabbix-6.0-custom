# zabbix-server(監視サーバー本体、C言語)— Alpine Linuxベースのカスタムイメージ [FR1.1][FR3.1]。
#
# 前提: この時点ではまだZabbix 6.0ソースがこのディレクトリに配置されていない
# (将来 ${ZABBIX_SRC_DIR} — 既定 sources/zabbix-6.0.48 — に配置される想定)。そのため本
# Dockerfileは ARG ZABBIX_SRC_DIR を通じてソース配置先を参照するスキャフォールドとして
# 書かれており、ソース追加前は `docker build` を実行できない。ソース追加後、
# 実ソースのconfigureオプション名・依存パッケージ名に差異があれば調整が必要になる。
#
# ビルドコンテキストはこのディレクトリ(zabbix-6.0-custom/)自身(compose.yml参照)。
# マルチステージビルドで、ビルド専用ステージでコンパイルし、最終イメージには
# ビルド済みバイナリと実行時共有ライブラリのみを含める(zabbix-5.0の前例
# docker/server/Dockerfile を踏襲)。
#
# データベースエンジンはMySQLのみ(BR5.1)。amd64のみ対象(BR5.2)。

ARG ALPINE_VERSION=3.24

FROM alpine:${ALPINE_VERSION} AS builder

ARG ZABBIX_SRC_DIR=sources/zabbix-6.0.48

RUN apk add --no-cache \
		build-base \
		pkgconf \
		pcre-dev \
		mariadb-connector-c-dev \
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
# 別種の問題で、それだけでは防げない)。configure.ac/aclocal.m4だけでなくm4/配下の
# マクロ等、依存関係の全体像を個別に追うのは壊れやすいため、コピーされたツリー全体を
# 同一タイムスタンプへ揃え、「新しい方が存在しない」状態にして再生成条件そのものを
# 成立させない。
RUN find . -exec touch -d '2000-01-01 00:00:00' {} +

# --with-mysql: BR5.1(zabbix-serverはMySQLのみ)。net-snmp/libcurl/libxml2/opensslは
# 公式zabbix/zabbix-server-mysqlイメージが持つ任意統合(SNMP監視・Web監視・XML/TLS)を
# 維持し、公式イメージとの環境変数・ボリューム互換性を保つために含める。
# --disable-dependency-tracking: レイヤー抽出時のタイムスタンプ変化でautomakeの
# 依存関係追跡が壊れる既知のautotools問題を避ける(1回限りのイメージビルドに
# インクリメンタルビルドは不要なため実害はない)。
RUN sh ./configure \
		--disable-dependency-tracking \
		--enable-server \
		--enable-ipv6 \
		--with-mysql \
		--with-net-snmp \
		--with-libcurl \
		--with-libxml2 \
		--with-openssl \
	&& make -j"$(nproc)"

FROM alpine:${ALPINE_VERSION}

RUN apk add --no-cache \
		mariadb-connector-c \
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

# UID/GID 1997: zabbix-5.0の前例に合わせ、webイメージのnginxグループ(101)との
# 衝突を避ける値を全コンポーネントで統一する。
RUN addgroup -g 1997 -S zabbix \
	&& adduser -D -S -H -u 1997 -G zabbix -s /sbin/nologin zabbix

COPY --from=builder /build/src/zabbix_server/zabbix_server /usr/sbin/zabbix_server
COPY --from=builder /build/conf/zabbix_server.conf /etc/zabbix/zabbix_server.conf.default

RUN mkdir -p /etc/zabbix /var/lib/zabbix/alertscripts /var/lib/zabbix/externalscripts /var/lib/zabbix/enc \
		/var/lib/zabbix/export /var/lib/zabbix/modules /run/zabbix \
	&& chown -R zabbix:zabbix /etc/zabbix /var/lib/zabbix /run/zabbix

COPY docker/server/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

VOLUME ["/var/lib/zabbix/alertscripts", "/var/lib/zabbix/externalscripts", "/var/lib/zabbix/enc"]

# USERディレクティブは指定しない — entrypoint.shがsu-exec経由でzabbixユーザーへ降格して
# zabbix_serverをexecするため(su-exec自体の実行にroot権限が必要)。daemonプロセス自体は
# rootで動作しない。

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
	CMD test -f /run/zabbix/zabbix_server.pid && kill -0 "$(cat /run/zabbix/zabbix_server.pid)" || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
