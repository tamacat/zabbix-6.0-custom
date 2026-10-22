# zabbix-web(Webフロントエンド、PHP + nginx)— Alpine Linuxベースのカスタムイメージ
# [FR1.2][FR3.1]。公式zabbix-web-nginx-mysqlイメージとの環境変数・ボリューム互換性を
# 維持する。
#
# 前提: docker/server/Dockerfile 冒頭のコメントと同じ — ${ZABBIX_SRC_DIR}(既定
# sources/zabbix-6.0.48)にZabbix 6.0ソース(ui/ ディレクトリ)が配置されるまで
# `docker build` は実行できない。
#
# ビルドコンテキストはこのディレクトリ(zabbix-6.0-custom/)自身(compose.yml参照)。
# UIは既存アップストリームソースへのパッチ対象であり(トラックA)、本Dockerfileは
# ビルド/実行環境のみを新規に定義する(トラックB)。
#
# PHPはAlpineのパッケージではなく、公式のソースからビルドする。PHPのセキュリティリリース
# (2026-10-21の8.3.36: 認証なしのリモートコード実行2件)に対し、Alpineのphp83が追いつくのを
# 待たずに修正版を取り込むため。有効にする拡張は、これまで使っていたAlpineのphp83パッケージと
# 同じ集合に揃えている(下のconfigureと、tests/test_web_php.pyの一覧を参照)。

ARG ALPINE_VERSION=3.24

# PHPのバージョンとSHA-256。バージョンを上げるときは、php.netが公開しているSHA-256
# (https://www.php.net/releases/index.php?json&version=<X.Y>)で確認した値に更新する。現在の値は
# 2026-10-22に確認した。PHP本体はTrivyが脆弱性を判定できない(Alpineのパッケージではないため)ので、
# 新しいリリースが出ていないかは scripts/check-php-version.sh と定期実行のCIが確認する。
ARG PHP_VERSION=8.3.36
ARG PHP_SHA256=dd54693aa334c5c4d72e9aee96b082c2473750a18a6c1d105789c93a3b1692fd

# ---------------------------------------------------------------------------------------
# PHP(php-fpm と CLI)のビルド
# ---------------------------------------------------------------------------------------
FROM alpine:${ALPINE_VERSION} AS php-build

ARG PHP_VERSION
ARG PHP_SHA256

# hadolint ignore=DL3017
RUN apk upgrade --no-cache

# linux-headers: socketsがカーネルのヘッダー(linux/filter.h)を使う。
RUN apk add --no-cache \
		build-base linux-headers autoconf bison re2c pkgconf curl xz \
		libxml2-dev openssl-dev zlib-dev pcre2-dev oniguruma-dev gettext-dev \
		libpng-dev libjpeg-turbo-dev freetype-dev libwebp-dev

WORKDIR /usr/src
RUN curl -fsSL -o php.tar.xz "https://www.php.net/distributions/php-${PHP_VERSION}.tar.xz" \
	&& echo "${PHP_SHA256}  php.tar.xz" | sha256sum -c - \
	&& tar -xJf php.tar.xz --strip-components=1

# --disable-all から、Zabbixが必要とする拡張だけを足す。これまで使っていたAlpineのphp83パッケージと
# 同じ集合(bcmath ctype dom fileinfo filter gd gettext iconv mbstring mysqli mysqlnd openssl session
# sockets tokenizer xml xmlreader xmlwriter zlib、加えてphar・opcache)で、curl・ftp・sodium・
# sqlite3などZabbixが使わない拡張は含めない。拡張は共有ライブラリではなくPHP本体に組み込む。
# 配置はAlpineのパッケージに合わせ(/etc/php83、php83・php-fpm83)、entrypoint.shを変えずに済むようにしている。
RUN ./configure \
		--prefix=/usr \
		--sysconfdir=/etc/php83 \
		--localstatedir=/var \
		--program-suffix=83 \
		--with-config-file-path=/etc/php83 \
		--with-config-file-scan-dir=/etc/php83/conf.d \
		--disable-all --disable-cgi --disable-phpdbg --without-pear \
		--enable-cli --enable-fpm \
		--enable-bcmath --enable-ctype --enable-dom --enable-fileinfo --enable-filter \
		--enable-gd --with-freetype --with-jpeg --with-webp \
		--with-gettext --with-iconv --enable-mbstring \
		--enable-mysqlnd --with-mysqli=mysqlnd --with-mysql-sock=/run/mysqld/mysqld.sock \
		--with-openssl --enable-session --enable-sockets --enable-tokenizer \
		--enable-xml --enable-xmlreader --enable-xmlwriter --with-libxml \
		--with-zlib --with-external-pcre --enable-phar --enable-opcache \
	&& make -j"$(nproc)" \
	&& make install-cli install-fpm install-modules INSTALL_ROOT=/php-root \
	&& strip /php-root/usr/bin/php83 /php-root/usr/sbin/php-fpm83 \
	# Alpineのphp83パッケージは本番向けのphp.ini(display_errors=Off、log_errors=On、error_reporting
	# にE_DEPRECATED・E_STRICTを含めない)を置いていた。ソースビルドは置かないので、PHPが同梱する本番向けの
	# 雛形をそのまま使う。Zabbixに必要な値は conf.d/99-zabbix.ini が上書きする。
	&& mkdir -p /php-root/etc/php83/conf.d /php-root/etc/php83/php-fpm.d \
	&& cp php.ini-production /php-root/etc/php83/php.ini \
	# OPcacheだけは共有ライブラリ(opcache.so)として作られ、読み込む設定が要る(Alpineは00_opcache.ini)。
	&& echo "zend_extension=opcache" > /php-root/etc/php83/conf.d/00_opcache.ini

# ---------------------------------------------------------------------------------------
# 実行用イメージ
# ---------------------------------------------------------------------------------------
FROM alpine:${ALPINE_VERSION}

ARG ZABBIX_SRC_DIR=sources/zabbix-6.0.48
ARG PHP_PKG=php83

# ベースイメージ(alpine:${ALPINE_VERSION})は取得した時点のスナップショットで、その後にAlpineが
# 公開した修正がまだ入っていないことがある(zlib 1.3.2-r0のCVE-2026-85091は、リポジトリに
# 修正版1.3.2-r1があるのにベースイメージが古く、SCAゲートで落ちた)。ビルドのたびに公開済みの
# 修正をすべて取り込む。再現性はビルド日付入りのタグ単位で担保する。
# hadolint ignore=DL3017
RUN apk upgrade --no-cache

# PHPが動的にリンクするライブラリ(ビルド側の *-dev に対応する実行時のパッケージ)。足りないものが
# ないことは、tests/test_web_php.py と下のldd確認が見る。
RUN apk add --no-cache \
		font-ipa \
		nginx \
		libxml2 libssl3 libcrypto3 zlib pcre2 oniguruma gettext-libs \
		libpng libjpeg-turbo freetype libwebp libgcc \
		tzdata

# /php-root全体(/ へ)ではなく /usr と /etc だけをコピーする。ビルド結果には /var/run が
# ディレクトリとして含まれ、Alpineでは /var/run が /run へのシンボリックリンクなので、
# BuildKit(Docker本体)は「ディレクトリでないものへコピーできない」と失敗する。
COPY --from=php-build /php-root/usr/ /usr/
COPY --from=php-build /php-root/etc/ /etc/

# UID/GID 1997: server/agent2/proxyと統一。apk add nginxが作成するnginxグループ(101)との
# 衝突を避ける。
RUN addgroup -g 1997 -S zabbix \
	&& adduser -D -S -H -u 1997 -G zabbix -s /sbin/nologin zabbix

COPY docker/web/conf/nginx.conf /etc/nginx/nginx.conf
COPY docker/web/conf/php-fpm.conf /etc/${PHP_PKG}/php-fpm.conf
COPY docker/web/conf/php-fpm-www.conf /etc/${PHP_PKG}/php-fpm.d/www.conf
COPY docker/web/conf/zabbix.ini /etc/${PHP_PKG}/conf.d/99-zabbix.ini

# 実行時に必要な共有ライブラリが全部あること(足りなければ、ここでビルドを止める)。OPcacheは
# phpの外の共有ライブラリ(opcache.so)で、lddの結果に出ないlibgcc_s.so.1も要るため、読み込めること
# (php -m)まで確認する。
RUN ! ldd /usr/bin/php83 /usr/sbin/php-fpm83 | grep -i "not found" \
	&& php83 -m | grep -qx mysqli && php83 -m | grep -qx "Zend OPcache" && php-fpm83 -t

# ui/conf/zabbix.conf.php はソースに存在しない(.exampleのみ) — entrypoint.shが
# 環境変数からコンテナ起動時に生成するため、イメージには焼き込まない。
COPY --chown=zabbix:zabbix ${ZABBIX_SRC_DIR}/ui/ /usr/share/zabbix/

# グラフ内の文字に日本語フォントを使う。ZBX_GRAPH_FONT_NAMEは'IPAPGothic'(include/defines.inc.php)で、
# assets/fonts/IPAPGothic.ttf として探される。同梱のDejaVuSans.ttfには日本語のグリフが無く、
# 日本語のアイテム名・ホスト名・凡例がグラフで□になっていた。font-ipa(IPAゴシック/明朝、TTF)は上で導入済み。
# (回転して描く数字に使うZBX_FONT_NAMEはDejaVuSansのまま。)
RUN ln -s /usr/share/fonts/ipafont/ipagp.ttf /usr/share/zabbix/assets/fonts/IPAPGothic.ttf

RUN mkdir -p /usr/share/zabbix/conf /tmp/zabbix-nginx /tmp/nginx-client-body /tmp/nginx-proxy /tmp/nginx-fastcgi \
		/tmp/nginx-uwsgi /tmp/nginx-scgi \
	&& chown -R zabbix:zabbix /usr/share/zabbix /tmp/zabbix-nginx /tmp/nginx-client-body /tmp/nginx-proxy \
		/tmp/nginx-fastcgi /tmp/nginx-uwsgi /tmp/nginx-scgi \
	# entrypoint.shが環境変数(PHP_TZ、ZBX_MEMORYLIMIT、PHP_FPM_PM*など)から99-zabbix.iniと
	# php-fpm.d/zz-zabbix.confを書き直せるよう、この2ファイルだけ非rootのzabbixユーザーに
	# 書き込み権限を付与する(ディレクトリはrootのまま。root常駐を避けるため)。
	&& touch /etc/${PHP_PKG}/php-fpm.d/zz-zabbix.conf \
	&& chown zabbix:zabbix /etc/${PHP_PKG}/conf.d/99-zabbix.ini /etc/${PHP_PKG}/php-fpm.d/zz-zabbix.conf

COPY docker/web/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

VOLUME ["/usr/share/zabbix/conf"]

USER zabbix
EXPOSE 8080 8443

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
	CMD wget -q -O /dev/null http://127.0.0.1:8080/ || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
