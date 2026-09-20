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

ARG ALPINE_VERSION=3.24

FROM alpine:${ALPINE_VERSION}

ARG ZABBIX_SRC_DIR=sources/zabbix-6.0.48
ARG PHP_PKG=php83

RUN apk add --no-cache \
		nginx \
		${PHP_PKG} \
		${PHP_PKG}-fpm \
		${PHP_PKG}-opcache \
		${PHP_PKG}-mbstring \
		${PHP_PKG}-sockets \
		${PHP_PKG}-bcmath \
		${PHP_PKG}-gd \
		${PHP_PKG}-xml \
		${PHP_PKG}-xmlwriter \
		${PHP_PKG}-xmlreader \
		${PHP_PKG}-openssl \
		${PHP_PKG}-ctype \
		${PHP_PKG}-session \
		${PHP_PKG}-gettext \
		${PHP_PKG}-mysqli \
		${PHP_PKG}-phar \
		${PHP_PKG}-tokenizer \
		${PHP_PKG}-fileinfo \
		${PHP_PKG}-iconv \
		${PHP_PKG}-dom \
		tzdata

# UID/GID 1997: server/agent2/proxyと統一。apk add nginxが作成するnginxグループ(101)との
# 衝突を避ける。
RUN addgroup -g 1997 -S zabbix \
	&& adduser -D -S -H -u 1997 -G zabbix -s /sbin/nologin zabbix

COPY docker/web/conf/nginx.conf /etc/nginx/nginx.conf
COPY docker/web/conf/zabbix.ini /etc/${PHP_PKG}/conf.d/99-zabbix.ini

# Alpineのphp-fpmパッケージのphp-fpm.confは既定で`;error_log = log/php83/error.log`と
# コメントアウトされており、無指定時はコンパイル時既定の絶対パス(/var/log/php83/
# error.log、root所有)が使われ、非rootのzabbixユーザーでは書き込めずFPM初期化そのものが
# 失敗する(docker/web/conf/nginx.confのerror_log問題と同じクラスのバグ、実機テストで判明。
# 実際のコメントアウト行の書式は`;error_log = log/php83/error.log`であり、素朴な
# `^error_log = `一致では捕捉できない)。ここはまだroot権限がある(この後の`USER zabbix`
# より前)ので、ビルド時にコメントを外してstderrへのリダイレクトへ書き換える。
RUN sed -i 's#^;error_log = .*#error_log = /proc/self/fd/2#' /etc/${PHP_PKG}/php-fpm.conf

# ui/conf/zabbix.conf.php はソースに存在しない(.exampleのみ) — entrypoint.shが
# 環境変数からコンテナ起動時に生成するため、イメージには焼き込まない。
COPY --chown=zabbix:zabbix ${ZABBIX_SRC_DIR}/ui/ /usr/share/zabbix/

RUN mkdir -p /usr/share/zabbix/conf /tmp/nginx-client-body /tmp/nginx-proxy /tmp/nginx-fastcgi \
		/tmp/nginx-uwsgi /tmp/nginx-scgi \
	&& chown -R zabbix:zabbix /usr/share/zabbix /tmp/nginx-client-body /tmp/nginx-proxy \
		/tmp/nginx-fastcgi /tmp/nginx-uwsgi /tmp/nginx-scgi \
	# entrypoint.shがPHP_TZ適用のため99-zabbix.iniを書き換えられるよう、非rootのzabbix
	# ユーザーに書き込み権限を付与する(root常駐を避けるため、rootのままにはしない)。
	&& chown zabbix:zabbix /etc/${PHP_PKG}/conf.d/99-zabbix.ini

COPY docker/web/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

VOLUME ["/usr/share/zabbix/conf"]

USER zabbix
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
	CMD wget -q -O /dev/null http://127.0.0.1:8080/ || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
