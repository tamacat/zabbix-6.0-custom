"""zabbix-webのPHP(docker/web/Dockerfile でソースからビルドする)の整合性テスト。

実際のビルドは時間がかかりDockerが要る。ここでは、ビルド定義が(1)固定したバージョンとハッシュで
取得していること、(2)これまで使っていたAlpineのphp83パッケージと同じ拡張の集合であること、
(3)entrypoint.shが前提にするパス・コマンド名と合っていること、(4)ビルド側の-devに対応する
実行時ライブラリを実行用イメージに入れていることを、ファイルを見て確認する。
"""
from __future__ import annotations

import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
DOCKERFILE = REPO_ROOT / "docker" / "web" / "Dockerfile"
ENTRYPOINT = REPO_ROOT / "docker" / "web" / "entrypoint.sh"
FPM_CONF = REPO_ROOT / "docker" / "web" / "conf" / "php-fpm.conf"
FPM_POOL = REPO_ROOT / "docker" / "web" / "conf" / "php-fpm-www.conf"

# Alpineのphp83パッケージ(8.3.33)で有効だった拡張(php -m)。ソースビルドでもこの集合に揃える。
EXPECTED_MODULES = {
    "bcmath": "--enable-bcmath",
    "ctype": "--enable-ctype",
    "dom": "--enable-dom",
    "fileinfo": "--enable-fileinfo",
    "filter": "--enable-filter",
    "gd": "--enable-gd",
    "gettext": "--with-gettext",
    "iconv": "--with-iconv",
    "mbstring": "--enable-mbstring",
    "mysqli": "--with-mysqli=mysqlnd",
    "mysqlnd": "--enable-mysqlnd",
    "openssl": "--with-openssl",
    "session": "--enable-session",
    "sockets": "--enable-sockets",
    "tokenizer": "--enable-tokenizer",
    "xml": "--enable-xml",
    "xmlreader": "--enable-xmlreader",
    "xmlwriter": "--enable-xmlwriter",
    "libxml": "--with-libxml",
    "zlib": "--with-zlib",
    "phar": "--enable-phar",
    "opcache": "--enable-opcache",
}

# Zabbixが使わず、含めると攻撃面と依存ライブラリが増えるだけの拡張。
UNWANTED_FLAGS = [
    "--with-curl", "--enable-ftp", "--with-sodium", "--with-sqlite3", "--with-pdo", "--enable-pdo",
    "--enable-posix", "--enable-simplexml", "--enable-soap", "--enable-intl", "--with-ldap", "--with-zip",
    "--with-gmp", "--enable-pcntl", "--enable-exif", "--with-bz2",
]

# ビルド側の-dev と、それに対応する実行用イメージのパッケージ。
RUNTIME_FOR_DEV = {
    "libxml2-dev": "libxml2",
    "openssl-dev": "libssl3",
    "zlib-dev": "zlib",
    "pcre2-dev": "pcre2",
    "oniguruma-dev": "oniguruma",
    "gettext-dev": "gettext-libs",
    "libpng-dev": "libpng",
    "libjpeg-turbo-dev": "libjpeg-turbo",
    "freetype-dev": "freetype",
    "libwebp-dev": "libwebp",
    # opcache.so is a separate shared library that needs the GCC runtime.
    "build-base": "libgcc",
}


def _dockerfile() -> str:
    return DOCKERFILE.read_text(encoding="utf-8")


def _stage(name: str) -> str:
    """`FROM ... AS <name>` から次の `FROM` までのDockerfileの部分。"""
    text = _dockerfile()
    match = re.search(rf"^FROM [^\n]*AS {re.escape(name)}\n(.*?)(?=^FROM |\Z)", text, re.MULTILINE | re.DOTALL)
    assert match, f"stage {name!r} not found"
    return match.group(1)


def _final_stage() -> str:
    text = _dockerfile()
    return text[text.rindex("\nFROM ") :]


def _configure_flags() -> list:
    build = _stage("php-build")
    match = re.search(r"\./configure\s*(.*?)\n\s*&& make", build, re.DOTALL)
    assert match, "could not find the ./configure command"
    return re.findall(r"--[\w-]+(?:=[\w/.\-]+)?", match.group(1))


def test_php_version_and_hash_are_pinned_and_checked():
    dockerfile = _dockerfile()

    assert re.search(r"^ARG PHP_VERSION=\d+\.\d+\.\d+$", dockerfile, re.MULTILINE)
    assert re.search(r"^ARG PHP_SHA256=[0-9a-f]{64}$", dockerfile, re.MULTILINE)
    build = _stage("php-build")
    # 取得したtarballは、固定したハッシュと一致しなければ使わない。
    assert 'echo "${PHP_SHA256}  php.tar.xz" | sha256sum -c -' in build
    assert build.index("sha256sum -c -") < build.index("tar -xJf")


@pytest.mark.parametrize("module", sorted(EXPECTED_MODULES))
def test_every_module_the_alpine_package_had_is_built(module):
    assert EXPECTED_MODULES[module] in _configure_flags()


def test_modules_not_needed_by_zabbix_are_not_built():
    flags = _configure_flags()

    assert "--disable-all" in flags, "start from --disable-all so only the listed modules are built"
    for unwanted in UNWANTED_FLAGS:
        assert unwanted not in flags, unwanted


def test_the_layout_matches_what_the_entrypoint_expects():
    flags = _configure_flags()
    entrypoint = ENTRYPOINT.read_text(encoding="utf-8")

    assert "--prefix=/usr" in flags
    assert "--sysconfdir=/etc/php83" in flags
    assert "--with-config-file-scan-dir=/etc/php83/conf.d" in flags
    assert "--program-suffix=83" in flags
    assert 'PHP_INI_FILE="/etc/php83/conf.d/99-zabbix.ini"' in entrypoint
    assert 'FPM_POOL_FILE="/etc/php83/php-fpm.d/zz-zabbix.conf"' in entrypoint
    assert 'PHP_FPM_BIN="${PHP_FPM_BIN:-php-fpm83}"' in entrypoint


def test_php_comes_from_the_source_build_not_from_alpine_packages():
    final = _final_stage()

    # Only /usr and /etc are copied: the build result also holds /var/run as a directory, and in Alpine
    # /var/run is a symlink, which BuildKit refuses to copy a directory over ("cannot copy to non-directory").
    assert "COPY --from=php-build /php-root/usr/ /usr/" in final
    assert "COPY --from=php-build /php-root/etc/ /etc/" in final
    assert "COPY --from=php-build /php-root/ /" not in final
    # The apk add list of the runtime image has no php83 packages (they would shadow the build).
    apk_add = re.findall(r"apk add --no-cache \\\n(.*?)\n\n", final, re.DOTALL)
    assert apk_add, "runtime apk add list not found"
    assert "php83" not in apk_add[0] and "${PHP_PKG}" not in apk_add[0]


@pytest.mark.parametrize("dev,runtime", sorted(RUNTIME_FOR_DEV.items()))
def test_each_build_dependency_has_its_runtime_library_in_the_final_image(dev, runtime):
    build = _stage("php-build")
    final = _final_stage()

    assert re.search(rf"\b{re.escape(dev)}\b", build)
    assert re.search(rf"\b{re.escape(runtime)}\b", final)


def test_the_build_checks_that_no_shared_library_is_missing():
    assert 'ldd /usr/bin/php83 /usr/sbin/php-fpm83 | grep -i "not found"' in _final_stage()


def test_the_fpm_configuration_matches_what_the_alpine_package_shipped():
    fpm = FPM_CONF.read_text(encoding="utf-8")
    pool = FPM_POOL.read_text(encoding="utf-8")

    # php-fpm logs to stderr (a log file is not writable by the non-root zabbix user).
    assert re.search(r"^error_log = /proc/self/fd/2$", fpm, re.MULTILINE)
    assert re.search(r"^include=/etc/php83/php-fpm\.d/\*\.conf$", fpm, re.MULTILINE)
    # nginx.conf sends PHP to this address.
    assert re.search(r"^listen = 127\.0\.0\.1:9000$", pool, re.MULTILINE)
    nginx = (REPO_ROOT / "docker" / "web" / "conf" / "nginx.conf").read_text(encoding="utf-8")
    assert "fastcgi_pass 127.0.0.1:9000;" in nginx
    final = _final_stage()
    assert "COPY docker/web/conf/php-fpm.conf /etc/${PHP_PKG}/php-fpm.conf" in final
    assert "COPY docker/web/conf/php-fpm-www.conf /etc/${PHP_PKG}/php-fpm.d/www.conf" in final


def test_the_production_php_ini_is_installed():
    # The Alpine package shipped a production php.ini (display_errors off, errors logged, not shown).
    # A source build installs none, so the Dockerfile must put PHP's own production template in place.
    build = _stage("php-build")

    assert "cp php.ini-production /php-root/etc/php83/php.ini" in build


def test_opcache_is_installed_and_loaded():
    # OPcache is built as a shared module: it must be installed (install-modules) and loaded by an ini file,
    # and the image build must fail if it is not active.
    build = _stage("php-build")
    final = _final_stage()

    assert "install-modules" in build
    assert 'echo "zend_extension=opcache" > /php-root/etc/php83/conf.d/00_opcache.ini' in build
    assert 'php83 -m | grep -qx "Zend OPcache"' in final


def test_the_default_mysql_socket_matches_the_alpine_package():
    # With DB host "localhost" PHP connects through this socket; the Alpine package built it in.
    assert "--with-mysql-sock=/run/mysqld/mysqld.sock" in _configure_flags()
