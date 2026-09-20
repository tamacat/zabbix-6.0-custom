# zabbix-agent2(エージェント、Go言語)— Alpine Linuxベースのカスタムイメージ [FR1.3][FR3.1]。
#
# 前提: docker/server/Dockerfile 冒頭のコメントと同じ — ${ZABBIX_SRC_DIR}(既定
# sources/zabbix-6.0.48)にZabbix 6.0ソース(src/go/ を含む)が配置されるまで
# `docker build` は実行できない。
#
# zabbix_agent2はスタンドアロンのGoモジュールではなく、C側の静的ライブラリ
# (libzbxcommon.a等)とcgoでリンクするため、`go build` 単体ではなく、
# `./configure --enable-agent2` の後にトップレベルの `make` を実行する必要がある
# (zabbix-5.0の前例 docker/agent2/Dockerfile のコメント参照。ソース未配置のため
# 6.0での再現確認はソース追加後に行う)。

ARG ALPINE_VERSION=3.24

FROM alpine:${ALPINE_VERSION} AS builder

ARG ZABBIX_SRC_DIR=sources/zabbix-6.0.48

RUN apk add --no-cache go build-base git autoconf automake libtool pcre-dev openssl-dev zlib-dev

WORKDIR /build
COPY ${ZABBIX_SRC_DIR}/ /build/

# git checkoutはtarball展開時のmtime順序を保持しないため、autotoolsが「ソースの方が
# ビルド成果物より新しい」と誤判定し、automake/aclocalの再実行を試みる(既知のautotools
# 問題。--disable-dependency-trackingとは別種の問題で、それだけでは防げない)。本ステージは
# autoconf/automakeを導入済みだが、コピーされたツリー全体を同一タイムスタンプへ揃えて
# 再生成条件そのものを成立させない方が、バージョン差異による再生成失敗のリスクがなく
# 確実なため、他コンポーネントと同じ対応を取る。
RUN find . -exec touch -d '2000-01-01 00:00:00' {} +

RUN sh ./configure --disable-dependency-tracking --enable-agent2 --with-openssl

# -D_LARGEFILE64_SOURCE: go-sqlite3(agent2の依存プラグインの一つ)がglibc専用の
# pread64/pwrite64シンボルを要求するため、musl(Alpine)で同名エイリアスを提供させる。
#
# src/go/Makefile.amは `go build -o bin ...` を実行する。`bin`はソース側に
# ディレクトリとして存在しないため、Goはこれを「出力ファイル名」として扱い、
# `src/go/bin`という名のファイル(バイナリそのもの)を生成する — `src/go/bin/`
# ディレクトリの中に`zabbix_agent2`という名で置かれるわけではない(ソース未配置
# 状態で書かれたスキャフォールドの誤った想定だったため、実ソース追加後の実ビルドで
# 判明・修正)。
RUN make -j"$(nproc)" CGO_CFLAGS="-I/build/include -D_LARGEFILE64_SOURCE" \
	&& cp src/go/bin /build/bin/zabbix_agent2

FROM alpine:${ALPINE_VERSION}

RUN apk add --no-cache ca-certificates tzdata openssl libcrypto3 zlib pcre

RUN addgroup -g 1997 -S zabbix \
	&& adduser -D -S -H -u 1997 -G zabbix -s /sbin/nologin zabbix

COPY --from=builder /build/bin/zabbix_agent2 /usr/sbin/zabbix_agent2

RUN mkdir -p /etc/zabbix /var/lib/zabbix/enc /run/zabbix \
	&& chown -R zabbix:zabbix /etc/zabbix /var/lib/zabbix /run/zabbix

COPY docker/agent2/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

VOLUME ["/var/lib/zabbix/enc"]

USER zabbix
EXPOSE 10050

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
	CMD test -f /run/zabbix/zabbix_agent2.pid && kill -0 "$(cat /run/zabbix/zabbix_agent2.pid)" || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
