"""`docker save` / `podman save` のtarから、コンテナを起動せずにイメージ内の1ファイルを取り出す。

レイヤーの置き場所は docker のバージョンで異なる(<id>/layer.tar・<hash>.tar・blobs/sha256/<hash>)ため、
固定のパターンではなく manifest.json の Layers から重ね順に読む(scripts/scan-secrets.sh と同じ方針)。
後のレイヤーが同じパスを上書きし、`.wh.<名前>`(whiteout)が削除を表すので、最終的に見えるファイルだけを返す。
"""
from __future__ import annotations

import io
import json
import posixpath
import tarfile
from pathlib import Path


class ImageFileError(Exception):
    """イメージのtarを解釈できない、または対象ファイルが最終的なファイルシステムに無い。"""


def _normalize(name: str) -> str:
    # `lstrip("./")` は先頭の `.` を全部削ってしまい `.wh.x` のような名前を壊すので、`./` だけを外す。
    while name.startswith("./"):
        name = name[2:]
    return name.lstrip("/")


def extract_image_file(image_tar: Path, path_in_image: str, output: Path) -> int:
    """イメージ内の `path_in_image` をoutputへ書き出し、バイト数を返す。"""
    target = _normalize(path_in_image)
    parent, base = posixpath.split(target)
    whiteout = f"{parent}/.wh.{base}" if parent else f".wh.{base}"
    try:
        image = tarfile.open(image_tar)
    except (tarfile.TarError, OSError) as exc:
        raise ImageFileError(f"イメージのtarを開けません: {exc}") from exc

    with image:
        # `tar -C dir .` で作ったtarのメンバー名は `./manifest.json` になる。`docker save` の実出力は
        # `./` 無しだが、どちらでも読めるよう正規化した名前で引く。
        members = {_normalize(m.name): m for m in image.getmembers()}

        def read(name: str) -> bytes | None:
            member = members.get(_normalize(name))
            extracted = image.extractfile(member) if member is not None and member.isfile() else None
            return extracted.read() if extracted is not None else None

        try:
            layers = json.loads(read("manifest.json") or b"")[0]["Layers"]
        except (KeyError, ValueError, IndexError, TypeError) as exc:
            raise ImageFileError("manifest.json が無い、または形式が不正です(レイヤーを特定できません)") from exc
        if not layers:
            raise ImageFileError("manifest.json のLayersが空です")

        content: bytes | None = None
        for layer in layers:
            layer_bytes = read(layer)
            if layer_bytes is None:
                raise ImageFileError(f"manifest.json のレイヤー '{layer}' が見つかりません")
            with tarfile.open(fileobj=io.BytesIO(layer_bytes)) as layer_tar:
                for member in layer_tar.getmembers():
                    name = _normalize(member.name)
                    if name == whiteout:
                        content = None  # このレイヤーで削除された
                    elif name == target and member.isfile():
                        extracted = layer_tar.extractfile(member)
                        content = extracted.read() if extracted else None

    if content is None:
        raise ImageFileError(f"イメージ内に '{target}' がありません(または削除されています)")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(content)
    return len(content)
