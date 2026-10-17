"""配布用アーカイブから1ファイルを取り出す処理(archivefile.py)のテスト。"""
import io
import tarfile
import zipfile

import pytest

from release_tools import cli
from release_tools.archivefile import ArchiveFileError, extract_archive_file


def _tar_gz(tmp_path, files, name="a.tar.gz"):
    path = tmp_path / name
    with tarfile.open(path, "w:gz") as tar:
        for member, data in files.items():
            info = tarfile.TarInfo(member)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    return path


def _zip(tmp_path, files, name="a.zip"):
    path = tmp_path / name
    with zipfile.ZipFile(path, "w") as zf:
        for member, data in files.items():
            zf.writestr(member, data)
    return path


def test_extracts_a_file_from_a_tar_gz(tmp_path):
    archive = _tar_gz(tmp_path, {"pkg/sbin/zabbix_agent2": b"LINUX", "pkg/README.txt": b"x"})
    out = tmp_path / "out" / "agent2"

    assert extract_archive_file(archive, "pkg/sbin/zabbix_agent2", out) == 5
    assert out.read_bytes() == b"LINUX"


def test_extracts_a_file_from_a_zip(tmp_path):
    archive = _zip(tmp_path, {"pkg/bin/zabbix_agent2.exe": b"WINDOWS", "pkg/README.txt": b"x"})
    out = tmp_path / "agent2.exe"

    assert extract_archive_file(archive, "pkg/bin/zabbix_agent2.exe", out) == 7
    assert out.read_bytes() == b"WINDOWS"


def test_accepts_a_leading_dot_slash_in_member_names(tmp_path):
    archive = _tar_gz(tmp_path, {"./pkg/sbin/zabbix_agent2": b"X"})

    assert extract_archive_file(archive, "/pkg/sbin/zabbix_agent2", tmp_path / "o") == 1


@pytest.mark.parametrize("make", [_tar_gz, _zip])
def test_a_missing_member_is_an_error(tmp_path, make):
    archive = make(tmp_path, {"pkg/README.txt": b"x"})

    with pytest.raises(ArchiveFileError, match="ありません"):
        extract_archive_file(archive, "pkg/sbin/zabbix_agent2", tmp_path / "o")
    assert not (tmp_path / "o").exists()


def test_a_directory_entry_is_not_a_file(tmp_path):
    archive = tmp_path / "d.zip"
    with zipfile.ZipFile(archive, "w") as zf:
        zf.writestr("pkg/sbin/", b"")

    with pytest.raises(ArchiveFileError, match="ありません"):
        extract_archive_file(archive, "pkg/sbin/", tmp_path / "o")


def test_a_corrupt_archive_is_an_error(tmp_path):
    bad_zip = tmp_path / "bad.zip"
    bad_zip.write_bytes(b"not a zip")
    bad_tar = tmp_path / "bad.tar.gz"
    bad_tar.write_bytes(b"not a tar")

    with pytest.raises(ArchiveFileError, match="開けません"):
        extract_archive_file(bad_zip, "x", tmp_path / "o")
    with pytest.raises(ArchiveFileError, match="開けません"):
        extract_archive_file(bad_tar, "x", tmp_path / "o")


def test_an_unknown_extension_is_an_error(tmp_path):
    other = tmp_path / "a.rar"
    other.write_bytes(b"x")

    with pytest.raises(ArchiveFileError, match="未対応"):
        extract_archive_file(other, "x", tmp_path / "o")


def test_member_names_with_dot_dot_never_write_outside_the_output(tmp_path):
    # The archive is read, never unpacked: a hostile member name cannot make the tool write anywhere
    # but the single output path it was given.
    archive = _tar_gz(tmp_path, {"../../escape.txt": b"EVIL", "pkg/ok": b"ok"})
    out = tmp_path / "work" / "ok"

    extract_archive_file(archive, "pkg/ok", out)

    assert out.read_bytes() == b"ok"
    assert not (tmp_path.parent / "escape.txt").exists()
    assert sorted(p.name for p in (tmp_path / "work").iterdir()) == ["ok"]


def test_cli_reports_success_and_failure(tmp_path, capsys):
    archive = _zip(tmp_path, {"pkg/bin/zabbix_agent2.exe": b"BIN"})

    assert cli.main(["extract-archive-file", "--archive", str(archive), "--path", "pkg/bin/zabbix_agent2.exe",
                     "--output", str(tmp_path / "o")]) == 0
    assert cli.main(["extract-archive-file", "--archive", str(archive), "--path", "pkg/nope",
                     "--output", str(tmp_path / "o2")]) == 1
    assert "extract-archive-file失敗" in capsys.readouterr().err
