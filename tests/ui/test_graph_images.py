"""グラフとマップの画像(PHPのgd拡張とフォント)。

グラフ(chart*.php)とマップ(map.php)はPHPのgdで描いたPNGを返す。gdは自前ビルドしたPHPが
freetype・jpeg・webpを付けてリンクしており、ライブラリが欠けると画像が出ない(または文字が描けない)。
グラフ内の文字はIPAゴシック(IPAPGothic.ttf)で描く。入っていないと日本語は□になる。
"""
import json
import struct

import pytest

from conftest import PREFIX

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
# 描画のたびに変わらないよう、時間範囲は過去の固定値にする(現在時刻の影響を受けない)。
FIXED_RANGE = {"from": "2020-01-01 00:00:00", "to": "2020-01-01 01:00:00"}


def png_size(body: bytes) -> tuple[int, int]:
    assert body.startswith(PNG_SIGNATURE), f"not a PNG: {body[:80]!r}"
    return struct.unpack(">II", body[16:24])


def test_custom_graph_is_a_png(admin, seed):
    resp = admin.get("chart2.php", params={"graphid": seed.graphid, "width": 900, **FIXED_RANGE})

    assert resp.status == 200
    assert resp.content_type == "image/png"
    width, height = png_size(resp.body)
    assert width >= 900 and height >= 200


def test_simple_item_graph_is_a_png(admin, seed):
    resp = admin.get("chart.php", params={"itemids[]": seed.itemid, "width": 600, "height": 150, **FIXED_RANGE})

    assert resp.status == 200
    assert resp.content_type == "image/png"
    png_size(resp.body)


def test_map_data_is_served_for_the_browser_to_draw(admin, seed):
    """6.0のマップはブラウザ(SVG)が描く。map.phpは描画に要る要素・座標をJSONで返す。"""
    resp = admin.get("map.php", params={"sysmapid": seed.sysmapid})

    assert resp.status == 200
    assert resp.content_type == "application/json"
    data = json.loads(resp.body)
    assert data["canvas"] == {"width": "400", "height": "300"}
    assert len(data["elements"]) == 1


@pytest.mark.parametrize("params", [{}, {"width": 24, "height": 24}], ids=["original", "thumbnail"])
def test_map_icons_are_served_as_png_and_resized_by_gd(admin, api, params):
    """アイコン(マップ・ホストの絵)。サイズ指定のときはgdで縮小して返す。"""
    iconid = api.call("image.get", {"output": ["imageid"], "filter": {"imagetype": 1}, "limit": 1})[0]["imageid"]

    resp = admin.get("imgstore.php", params={"iconid": iconid, **params})

    assert resp.status == 200
    assert resp.content_type == "image/png"
    width, height = png_size(resp.body)
    if params:
        # 縦横比を保って、指定の枠に収まる大きさへ縮める。
        assert width == params["width"] and 0 < height <= params["height"]


def test_the_graph_requires_a_login(anonymous, seed):
    resp = anonymous.get("chart2.php", params={"graphid": seed.graphid, **FIXED_RANGE})

    assert not resp.body.startswith(PNG_SIGNATURE)


def _graph_png(admin, api, seed, key, name):
    """name という名前のトラッパーアイテムと、その1本だけのグラフを作って、描いたPNGを返す。"""
    itemid = api.call(
        "item.create", {"name": name, "key_": key, "hostid": seed.hostid, "type": 2, "value_type": 0}
    )["itemids"][0]
    graphid = api.call(
        "graph.create", {"name": name, "width": 400, "height": 120, "gitems": [{"itemid": itemid, "color": "00AA00"}]}
    )["graphids"][0]
    try:
        resp = admin.get("chart2.php", params={"graphid": graphid, "width": 400, **FIXED_RANGE})
        assert resp.content_type == "image/png"
        return resp.body
    finally:
        api.call("graph.delete", [graphid])
        api.call("item.delete", [itemid])


@pytest.mark.parametrize(
    "first,second",
    [("日本語", "漢字表"), ("ひらがな", "カタカナ")],
    ids=["kanji", "kana"],
)
def test_japanese_text_is_drawn_with_real_glyphs(admin, api, seed, first, second):
    """フォントに日本語のグリフが無いと、どの文字も同じ□(豆腐)で描かれる。

    同じ長さで文字の違うアイテム名でグラフを2枚描き、画像が違うことを確かめる。時間範囲は固定なので、
    違いが出るのは凡例の文字だけ。ASCIIの対照で「文字が違えば画像が違う」ことを先に確認する。
    """
    ascii_a = _graph_png(admin, api, seed, f"{PREFIX}a", "abc")
    ascii_b = _graph_png(admin, api, seed, f"{PREFIX}b", "xyz")
    assert ascii_a != ascii_b, "control failed: graphs with different ASCII names rendered identically"

    one = _graph_png(admin, api, seed, f"{PREFIX}c", first)
    two = _graph_png(admin, api, seed, f"{PREFIX}d", second)

    assert one != two, f"{first!r} and {second!r} rendered identically: the graph font has no Japanese glyphs"
