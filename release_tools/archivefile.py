"""配布用アーカイブ(.tar.gz・.zip)から、展開せずに1ファイルを取り出す。

zabbix-agent2の単体バイナリ(scripts/build-agent2-binaries.sh の成果物)を、govulncheckで解析する
ために取り出すのに使う。アーカイブを展開しないので、メンバー名に `../` が入っていても
展開先の外へは何も書かれない(名前を指定して中身のバイト列を読むだけ)。
"""
from __future__ import annotations

import tarfile
import zipfile
from pathlib import Path


class ArchiveFileError(Exception):
    """アーカイブを開けない、または対象ファイルが無い。"""


def _normalize(name: str) -> str:
    while name.startswith("./"):
        name = name[2:]
    return name.lstrip("/")


def _read_from_tar(archive: Path, target: str) -> bytes | None:
    with tarfile.open(archive, "r:*") as tar:
        for member in tar.getmembers():
            if _normalize(member.name) == target and member.isfile():
                extracted = tar.extractfile(member)
                return extracted.read() if extracted else None
    return None


def _read_from_zip(archive: Path, target: str) -> bytes | None:
    with zipfile.ZipFile(archive) as zf:
        for info in zf.infolist():
            if _normalize(info.filename) == target and not info.is_dir():
                return zf.read(info)
    return None


def extract_archive_file(archive: Path, path_in_archive: str, output: Path) -> int:
    """アーカイブ内の `path_in_archive` をoutputへ書き出し、バイト数を返す。"""
    target = _normalize(path_in_archive)
    name = archive.name.lower()
    try:
        if name.endswith(".zip"):
            content = _read_from_zip(archive, target)
        elif name.endswith((".tar.gz", ".tgz", ".tar")):
            content = _read_from_tar(archive, target)
        else:
            raise ArchiveFileError(f"未対応のアーカイブ形式です(.tar.gz・.tgz・.tar・.zipのみ): {archive.name}")
    except (tarfile.TarError, zipfile.BadZipFile, OSError) as exc:
        raise ArchiveFileError(f"アーカイブを開けません: {exc}") from exc

    if content is None:
        raise ArchiveFileError(f"アーカイブ内に '{target}' がありません: {archive.name}")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(content)
    return len(content)
