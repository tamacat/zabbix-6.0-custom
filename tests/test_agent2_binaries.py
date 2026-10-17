"""zabbix-agent2 単体バイナリのビルド定義(docker/agent2-binaries/)の整合性テスト。

実際のビルドは時間がかかり、Dockerが要る。ここでは、ビルド定義が他のファイル(イメージ用の
docker/agent2/Dockerfile、アップストリームZabbixのMakefile、ビルドスクリプト)とずれていないことを、
ソースだけを見て確認する。Zabbixのソースを更新したとき・Goのバージョンを上げたときに、片方だけ
直し忘れるのを防ぐ。
"""
from __future__ import annotations

import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
BINARIES_DIR = REPO_ROOT / "docker" / "agent2-binaries"
BINARIES_DOCKERFILE = BINARIES_DIR / "Dockerfile"
WINDOWS_SCRIPT = BINARIES_DIR / "build-windows.sh"
IMAGE_DOCKERFILE = REPO_ROOT / "docker" / "agent2" / "Dockerfile"
UPSTREAM = REPO_ROOT / "sources" / "zabbix-6.0.48"
UPSTREAM_MINGW_MAKEFILE = UPSTREAM / "build" / "mingw" / "Makefile"
UPSTREAM_CGO_WINDOWS = UPSTREAM / "src" / "go" / "pkg" / "zbxlib" / "globals_windows.go"

needs_upstream = pytest.mark.skipif(not UPSTREAM.is_dir(), reason="Zabbix source is not checked out")


def _text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def test_go_toolchain_matches_the_agent2_image():
    # Both builds embed the Go standard library; they must be pinned to the same patch release,
    # otherwise the image would be fixed against a Go CVE and the downloadable binary would not (or the reverse).
    image = re.search(r"^ENV GOTOOLCHAIN=(go[\d.]+)$", _text(IMAGE_DOCKERFILE), re.MULTILINE)
    binaries = re.search(r"^ARG GOTOOLCHAIN=(go[\d.]+)$", _text(BINARIES_DOCKERFILE), re.MULTILINE)

    assert image is not None, "docker/agent2/Dockerfile no longer pins GOTOOLCHAIN with ENV"
    assert binaries is not None, "docker/agent2-binaries/Dockerfile does not pin GOTOOLCHAIN with ARG"
    assert binaries.group(1) == image.group(1)


@pytest.mark.parametrize("library", ["OPENSSL", "PCRE2", "LIBICONV"])
def test_statically_built_libraries_are_pinned_to_a_version_and_a_sha256(library):
    dockerfile = _text(BINARIES_DOCKERFILE)

    assert re.search(rf"^ARG {library}_VERSION=\d+(\.\d+)+$", dockerfile, re.MULTILINE)
    assert re.search(rf"^ARG {library}_SHA256=[0-9a-f]{{64}}$", dockerfile, re.MULTILINE)
    # The download is checked against that hash; a download with no check would make the pin meaningless.
    assert f'echo "${{{library}_SHA256}}' in dockerfile


def test_downloaded_library_sources_are_only_used_after_the_hash_check():
    dockerfile = _text(BINARIES_DOCKERFILE)

    # Every tarball that is downloaded is checked against its pinned hash in the same RUN.
    downloads = re.findall(r"curl -fsSL -o (\S+\.tar\.gz)", dockerfile)
    assert sorted(downloads) == ["libiconv.tar.gz", "openssl.tar.gz", "pcre2.tar.gz"]
    for name in downloads:
        assert f'  {name}" | sha256sum -c -' in dockerfile


def _upstream_object_rules() -> dict:
    """upstream build/mingw/Makefile の `$(OUTPUTDIR)\\<name>.o: $(TOPDIR)\\src\\<path>.c` を {name: path} にする。"""
    pattern = re.compile(r"^\$\(OUTPUTDIR\)\\(\w+)\.o:\s*\$\(TOPDIR\)\\src\\(\S+\.c)\s*$", re.MULTILINE)
    return {name: path.replace("\\", "/") for name, path in pattern.findall(_text(UPSTREAM_MINGW_MAKEFILE))}


def _upstream_built_objects() -> set:
    """upstream が実際にビルドするオブジェクト(`OBJS = ...` の一覧 + OpenSSL有効時の tls_version)。

    Makefileには、OBJSに入っておらずどこからもリンクされない規則(version.o)も残っているため、
    規則の一覧ではなくOBJSで比べる。resource.syso は別の手順(windres)で作る。
    """
    block = re.search(r"^OBJS = \\\n((?:\t.*\n)+)", _text(UPSTREAM_MINGW_MAKEFILE), re.MULTILINE)
    assert block, "could not find the OBJS list in the upstream build/mingw/Makefile"
    names = set(re.findall(r"\$\(OUTPUTDIR\)\\(\w+)\.o", block.group(1)))
    # `OBJS += $(OUTPUTDIR)\tls_version.o` is added upstream when OPENSSL is set; this build always enables TLS.
    return names | {"tls_version"}


def _script_objects() -> dict:
    pattern = re.compile(r"^compile (\w+) (\S+\.c)(?: .*)?$", re.MULTILINE)
    return {name: path for name, path in pattern.findall(_text(WINDOWS_SCRIPT))}


@needs_upstream
def test_windows_script_builds_the_objects_the_upstream_makefile_builds():
    rules = _upstream_object_rules()
    script = _script_objects()

    assert rules, "could not read any object rule from the upstream build/mingw/Makefile"
    assert set(script) == _upstream_built_objects()
    # ... and each one is compiled from the same source file the upstream rule names.
    for name, path in script.items():
        assert rules[name] == path, name
        assert (UPSTREAM / "src" / path).is_file(), path


@needs_upstream
def test_every_object_the_go_code_links_is_built_by_the_windows_script():
    linked = set(re.findall(r"build/mingw/output/(\w+)\.o", _text(UPSTREAM_CGO_WINDOWS)))
    built = set(_script_objects())

    assert linked, "could not read the linked objects from globals_windows.go"
    assert linked <= built, f"linked but not built: {sorted(linked - built)}"


@needs_upstream
def test_windows_script_uses_the_same_compile_definitions_as_the_upstream_makefile():
    makefile = _text(UPSTREAM_MINGW_MAKEFILE)
    script = _text(WINDOWS_SCRIPT)

    for definition in ("-DHAVE_STDINT_H=1", "-DZBX_BUILD_AGENT2=1", "-DHAVE_THREAD_LOCAL=1"):
        assert definition in makefile
        assert definition in script
    # The default config name and the application name are baked into the binary at link time.
    for ldflag in ("main.confDefault=zabbix_agent2.win.conf", "main.applicationName=zabbix_agent2"):
        assert ldflag in makefile
        assert ldflag in script


def test_archive_names_agree_between_the_dockerfile_and_the_build_script():
    dockerfile = _text(BINARIES_DOCKERFILE)
    script = _text(REPO_ROOT / "scripts" / "build-agent2-binaries.sh")

    for suffix in ("-linux-amd64.tar.gz", "-windows-amd64.zip"):
        assert f"${{ASSET_PREFIX}}{suffix}" in dockerfile
        assert f"${{ASSET_PREFIX}}{suffix}" in script
    assert "SHA256SUMS" in dockerfile
    assert "SHA256SUMS" in script


def test_readme_templates_only_use_placeholders_the_dockerfile_fills_in():
    dockerfile = _text(BINARIES_DOCKERFILE)
    filled = set(re.findall(r"s\|@(\w+)@\|", dockerfile))

    for name in ("README-linux.txt", "README-windows.txt"):
        used = set(re.findall(r"@(\w+)@", _text(BINARIES_DIR / name)))
        assert used <= filled, f"{name} uses unfilled placeholders: {sorted(used - filled)}"
