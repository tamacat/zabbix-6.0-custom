# zabbix-agent2 の単体バイナリ(Linux・Windows)をビルドし、GitHub Releasesに添付するアーカイブにまとめる。
# コンテナイメージ(docker/agent2/Dockerfile)とは別の成果物で、Docker Hubには公開しない。
#
#   Linux   : Alpine(musl)で完全に静的リンクする。どのLinuxディストリビューション(glibc系を含む)でも、
#             共有ライブラリなしで動く。
#   Windows : Alpine上のMinGW-w64でクロスコンパイルする(docker/agent2-binaries/build-windows.sh)。
#             AlpineにはMinGW向けのOpenSSL・PCRE2・libiconvが無いため、固定したバージョンのソースから
#             静的ライブラリとしてビルドする。
#
# 前提: docker/agent2/Dockerfile と同じ — ${ZABBIX_SRC_DIR}(既定 sources/zabbix-6.0.48)に
# Zabbix 6.0ソースが配置されていること。ビルドコンテキストはzabbix-6.0-custom/自身。
#
# 成果物は `--target artifacts` で取り出す(scripts/build-agent2-binaries.sh が行う)。
# アーカイブの名前は ASSET_PREFIX(release_tools.cli generate-release-tag --asset-prefix)で決まる。

ARG ALPINE_VERSION=3.24
ARG ZABBIX_SRC_DIR=sources/zabbix-6.0.48

# agent2のバイナリにはGo標準ライブラリがそのまま組み込まれる。docker/agent2/Dockerfile と同じ理由・
# 同じ値で固定する(この2つが食い違っていないことは tests/test_agent2_binaries.py が確認する)。
ARG GOTOOLCHAIN=go1.26.9

# Windows向けに静的ビルドする依存ライブラリ。取得したtarballは、ここに書いたSHA-256と一致しなければ
# 使わない(取得元の差し替え・改ざんを検知する)。バージョンを上げるときは、上流の公開値
# (OpenSSL: .sha256ファイル、PCRE2: GitHubのリリース資産のdigest、libiconv: GNUの署名)で確認した
# 値に更新する。現在の値は2026-10-17に、OpenSSLは公開された .sha256 ファイル、PCRE2はGitHubの
# リリース資産のdigest、libiconvはGNUのキーリングによる署名(Bruno Haible、鍵9001B85AF9E1B83D
# F1BDA942F5BE8B267C6A406D)と照合して確認した。これらはTrivyの対象外(静的リンクされたCライブラリ)
# なので、定期的に上流のセキュリティ情報を確認して更新する(README.md「Standalone agent2
# binaries」参照)。
ARG OPENSSL_VERSION=3.5.9
ARG OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
ARG PCRE2_VERSION=10.47
ARG PCRE2_SHA256=c08ae2388ef333e8403e670ad70c0a11f1eed021fd88308d7e02f596fcd9dc16
ARG LIBICONV_VERSION=1.18
ARG LIBICONV_SHA256=3b08f5f4f9b4eb82f151a7040bfd6fe6c6fb922efe4b1659c66ea933276965e8

# ---------------------------------------------------------------------------------------
# 依存ライブラリのソースを取得してSHA-256を検証し、ライセンス文書だけを取り出す
# ---------------------------------------------------------------------------------------
FROM alpine:${ALPINE_VERSION} AS sources

ARG OPENSSL_VERSION
ARG OPENSSL_SHA256
ARG PCRE2_VERSION
ARG PCRE2_SHA256
ARG LIBICONV_VERSION
ARG LIBICONV_SHA256

# hadolint ignore=DL3017,DL3018
RUN apk upgrade --no-cache && apk add --no-cache curl

WORKDIR /sources
RUN curl -fsSL -o openssl.tar.gz "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" \
	&& echo "${OPENSSL_SHA256}  openssl.tar.gz" | sha256sum -c - \
	&& curl -fsSL -o pcre2.tar.gz "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.gz" \
	&& echo "${PCRE2_SHA256}  pcre2.tar.gz" | sha256sum -c - \
	&& curl -fsSL -o libiconv.tar.gz "https://ftp.gnu.org/pub/gnu/libiconv/libiconv-${LIBICONV_VERSION}.tar.gz" \
	&& echo "${LIBICONV_SHA256}  libiconv.tar.gz" | sha256sum -c -

# 配布物に同梱するライセンス文書(Apache-2.0はバイナリの再配布でも文面の同梱が必要)。
RUN mkdir -p /licenses/openssl /licenses/pcre2 /licenses/libiconv \
	&& tar -xzf openssl.tar.gz --strip-components=1 -C /licenses/openssl "openssl-${OPENSSL_VERSION}/LICENSE.txt" \
	&& tar -xzf pcre2.tar.gz --strip-components=1 -C /licenses/pcre2 "pcre2-${PCRE2_VERSION}/LICENCE.md" \
	&& tar -xzf libiconv.tar.gz --strip-components=1 -C /licenses/libiconv "libiconv-${LIBICONV_VERSION}/COPYING.LIB"

# ---------------------------------------------------------------------------------------
# Windows (64bit)
# ---------------------------------------------------------------------------------------
FROM alpine:${ALPINE_VERSION} AS win-toolchain

# hadolint ignore=DL3017
RUN apk upgrade --no-cache

RUN apk add --no-cache \
		go \
		build-base \
		git \
		perl \
		mingw-w64-gcc \
		mingw-w64-binutils \
		mingw-w64-crt \
		mingw-w64-headers \
		mingw-w64-winpthreads

FROM win-toolchain AS win-deps

ARG PCRE2_VERSION
ARG LIBICONV_VERSION
ARG OPENSSL_VERSION

COPY --from=sources /sources/ /sources/
WORKDIR /tmp/build

# いずれもMinGW向けの静的ライブラリ(DLLは作らない)として /opt/deps に入れる。
RUN tar -xzf /sources/pcre2.tar.gz \
	&& cd "pcre2-${PCRE2_VERSION}" \
	&& ./configure --host=x86_64-w64-mingw32 --prefix=/opt/deps --disable-shared --enable-static \
		--disable-pcre2-16 --disable-pcre2-32 --disable-pcre2grep-libz --disable-pcre2grep-libbz2 \
	&& make -j"$(nproc)" && make install

RUN tar -xzf /sources/libiconv.tar.gz \
	&& cd "libiconv-${LIBICONV_VERSION}" \
	&& ./configure --host=x86_64-w64-mingw32 --prefix=/opt/deps --disable-shared --enable-static \
	&& make -j"$(nproc)" && make install

RUN tar -xzf /sources/openssl.tar.gz \
	&& cd "openssl-${OPENSSL_VERSION}" \
	&& ./Configure mingw64 --cross-compile-prefix=x86_64-w64-mingw32- no-shared no-tests no-docs \
		--prefix=/opt/deps --libdir=lib \
	&& make -j"$(nproc)" build_libs && make install_dev

FROM win-toolchain AS win-build

ARG ZABBIX_SRC_DIR
ARG GOTOOLCHAIN
ENV GOTOOLCHAIN=${GOTOOLCHAIN}

COPY --from=win-deps /opt/deps /opt/deps

WORKDIR /build
COPY ${ZABBIX_SRC_DIR}/ /build/
COPY docker/agent2-binaries/build-windows.sh /usr/local/bin/build-windows.sh
RUN OUT_DIR=/out sh /usr/local/bin/build-windows.sh

# ---------------------------------------------------------------------------------------
# Linux (x86_64, 完全な静的リンク)
# ---------------------------------------------------------------------------------------
FROM alpine:${ALPINE_VERSION} AS linux-build

ARG ZABBIX_SRC_DIR
ARG GOTOOLCHAIN
ENV GOTOOLCHAIN=${GOTOOLCHAIN}

# hadolint ignore=DL3017
RUN apk upgrade --no-cache

# *-static: 共有ライブラリの代わりに取り込む静的ライブラリ(libssl.a等)。PCRE2はdocker/agent2/Dockerfile
# が使う旧PCRE(8.x、上流で保守終了)ではなくPCRE2を使う。
RUN apk add --no-cache go build-base git autoconf automake libtool \
		pcre2-dev pcre2-static openssl-dev openssl-libs-static zlib-dev zlib-static

WORKDIR /build
COPY ${ZABBIX_SRC_DIR}/ /build/

# docker/agent2/Dockerfile と同じ理由で、ツリー全体のタイムスタンプを揃えてautotoolsの再生成を防ぐ。
RUN find . -exec touch -d '2000-01-01 00:00:00' {} +

RUN sh ./configure --disable-dependency-tracking --enable-agent2 --with-openssl --with-libpcre2

# CC="gcc -static": agent2のMakefileは go build を CGO_LDFLAGS 付きで呼ぶため、リンクオプションを
# 後から足せない。goはCGOのコンパイラ(リンカの呼び出しを含む)として CC を使うので、ここで -static を渡す。
# -D_LARGEFILE64_SOURCE は docker/agent2/Dockerfile と同じ(go-sqlite3がmuslでpread64等を要求する)。
# 出力は src/go/bin という名前のファイルそのもの(docker/agent2/Dockerfile のコメント参照)。
RUN make -j"$(nproc)" CC="gcc -static" CGO_CFLAGS="-I/build/include -D_LARGEFILE64_SOURCE" \
	&& mkdir -p /out \
	&& cp src/go/bin /out/zabbix_agent2 \
	&& apk list --installed openssl-libs-static pcre2-static zlib-static | cut -d' ' -f1 > /out/linked-libraries.txt

# ---------------------------------------------------------------------------------------
# 配布用アーカイブにまとめる
# ---------------------------------------------------------------------------------------
FROM alpine:${ALPINE_VERSION} AS package

ARG ZABBIX_SRC_DIR
ARG ASSET_PREFIX
ARG ZABBIX_VERSION
ARG BUILD_DATE
ARG SOURCE_REVISION=unknown
ARG OPENSSL_VERSION
ARG PCRE2_VERSION
ARG LIBICONV_VERSION

# hadolint ignore=DL3017,DL3018
RUN apk upgrade --no-cache && apk add --no-cache tar zip

COPY ${ZABBIX_SRC_DIR}/COPYING /stage/COPYING
COPY ${ZABBIX_SRC_DIR}/src/go/conf/zabbix_agent2.conf /stage/conf-linux/zabbix_agent2.conf
COPY ${ZABBIX_SRC_DIR}/src/go/conf/zabbix_agent2.win.conf /stage/conf-windows/zabbix_agent2.win.conf
COPY ${ZABBIX_SRC_DIR}/src/go/conf/zabbix_agent2.d/ /stage/plugins.d/
COPY --from=sources /licenses/ /stage/licenses/
COPY --from=linux-build /out/ /stage/linux-out/
COPY --from=win-build /out/zabbix_agent2.exe /stage/windows-out/zabbix_agent2.exe
COPY docker/agent2-binaries/THIRD-PARTY-NOTICES.txt docker/agent2-binaries/README-linux.txt docker/agent2-binaries/README-windows.txt /stage/

# 各アーカイブは公式配布物と同じ配置にする(Linux: sbin/ conf/、Windows: bin/ conf/)。設定ファイルの
# `Include=./zabbix_agent2.d/plugins.d/*.conf` は設定ファイルのあるフォルダからの相対なので、
# conf/zabbix_agent2.d/ にプラグイン用の設定を置けばそのまま読まれる。
RUN set -eu; \
	date_iso="$(echo "${BUILD_DATE}" | sed -E 's/^(....)(..)(..)$/\1-\2-\3/')"; \
	subst() { sed \
		-e "s|@ZABBIX_VERSION@|${ZABBIX_VERSION}|g" -e "s|@BUILD_DATE@|${BUILD_DATE}|g" \
		-e "s|@SOURCE_REVISION@|${SOURCE_REVISION}|g" -e "s|@ASSET_PREFIX@|${ASSET_PREFIX}|g" \
		-e "s|@OPENSSL_VERSION@|${OPENSSL_VERSION}|g" -e "s|@PCRE2_VERSION@|${PCRE2_VERSION}|g" \
		-e "s|@LIBICONV_VERSION@|${LIBICONV_VERSION}|g" "$1"; }; \
	assemble() { \
		platform="$1"; dir="/pkg/${ASSET_PREFIX}-${platform}-amd64"; \
		mkdir -p "${dir}/conf/zabbix_agent2.d/plugins.d" "${dir}/licenses"; \
		cp /stage/COPYING "${dir}/COPYING"; \
		cp /stage/THIRD-PARTY-NOTICES.txt "${dir}/THIRD-PARTY-NOTICES.txt"; \
		cp /stage/plugins.d/plugins.d/*.conf "${dir}/conf/zabbix_agent2.d/plugins.d/"; \
		cp -r /stage/licenses/. "${dir}/licenses/"; \
	}; \
	assemble linux; \
	d="/pkg/${ASSET_PREFIX}-linux-amd64"; \
	mkdir -p "${d}/sbin"; \
	cp /stage/linux-out/zabbix_agent2 "${d}/sbin/zabbix_agent2"; \
	cp /stage/conf-linux/zabbix_agent2.conf "${d}/conf/zabbix_agent2.conf"; \
	subst /stage/README-linux.txt > "${d}/README.txt"; \
	{ echo; echo "Statically linked system libraries in this build (Alpine packages):"; sed 's/^/  /' /stage/linux-out/linked-libraries.txt; } >> "${d}/README.txt"; \
	assemble windows; \
	d="/pkg/${ASSET_PREFIX}-windows-amd64"; \
	mkdir -p "${d}/bin"; \
	cp /stage/windows-out/zabbix_agent2.exe "${d}/bin/zabbix_agent2.exe"; \
	cp /stage/conf-windows/zabbix_agent2.win.conf "${d}/conf/zabbix_agent2.win.conf"; \
	subst /stage/README-windows.txt > "${d}/README.txt"; \
	find /pkg -type d -exec chmod 755 {} +; \
	find /pkg -type f -exec chmod 644 {} +; \
	chmod 755 /pkg/*/sbin/zabbix_agent2 /pkg/*/bin/zabbix_agent2.exe; \
	find /pkg -exec touch -d "${date_iso} 00:00:00" {} +; \
	mkdir -p /out; \
	( cd /pkg && tar --sort=name --owner=0 --group=0 --numeric-owner -cf - "${ASSET_PREFIX}-linux-amd64" | gzip -n -9 > "/out/${ASSET_PREFIX}-linux-amd64.tar.gz" ); \
	( cd /pkg && zip -X -r -q "/out/${ASSET_PREFIX}-windows-amd64.zip" "${ASSET_PREFIX}-windows-amd64" ); \
	( cd /out && sha256sum "${ASSET_PREFIX}-linux-amd64.tar.gz" "${ASSET_PREFIX}-windows-amd64.zip" > SHA256SUMS )

FROM scratch AS artifacts
COPY --from=package /out/ /
