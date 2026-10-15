#!/usr/bin/env bats
# グラフ内の日本語表示 — UIが使うフォント(ZBX_GRAPH_FONT_NAME)に日本語のグリフがあること。
# DejaVuSansには日本語のグリフが無く、日本語のアイテム名・ホスト名・凡例がグラフで□になる。
# 静的な整合性(フォント名・Dockerfileのリンク・パッケージ)は常に検証する。実際にグリフが描画
# されるかは、WEB_IMAGE にビルド済みwebイメージを渡したときだけ検証する(無ければskip)。
#
#   WEB_IMAGE=tamacat/zabbix-web-nginx-mysql:6.0-custom bats tests/scripts/web-font.bats

setup() {
	REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
	DEFINES="${REPO_ROOT}/sources/zabbix-6.0.48/ui/include/defines.inc.php"
	DOCKERFILE="${REPO_ROOT}/docker/web/Dockerfile"
	FONT_NAME="$(awk -F"'" '/^define\(.ZBX_GRAPH_FONT_NAME/ {print $4}' "${DEFINES}")"
}

@test "ZBX_GRAPH_FONT_NAMEはDejaVuSans(日本語グリフ無し)ではない" {
	[ -n "${FONT_NAME}" ]
	[ "${FONT_NAME}" != "DejaVuSans" ]
}

@test "Dockerfileが日本語フォントのパッケージ(font-ipa)を導入する" {
	grep -Eq '^[[:space:]]*font-ipa[[:space:]]*\\?$' "${DOCKERFILE}"
}

@test "Dockerfileが assets/fonts/<ZBX_GRAPH_FONT_NAME>.ttf をIPAゴシックへリンクする" {
	grep -Eq "ln -s /usr/share/fonts/ipafont/ipagp\.ttf /usr/share/zabbix/assets/fonts/${FONT_NAME}\.ttf" "${DOCKERFILE}"
}

@test "回転して描く数字用のZBX_FONT_NAMEはDejaVuSansのまま(同梱のttfが存在する)" {
	grep -q "^define('ZBX_FONT_NAME', 'DejaVuSans');" "${DEFINES}"
	[ -f "${REPO_ROOT}/sources/zabbix-6.0.48/ui/assets/fonts/DejaVuSans.ttf" ]
}

@test "webイメージのグラフ用フォントで、異なる2つの漢字が別の字形で描画される(□ではない)" {
	if [ -z "${WEB_IMAGE:-}" ]; then
		skip "WEB_IMAGE が未設定(ビルド済みwebイメージを指定すると実描画を検証する)"
	fi
	engine="${CONTAINER_ENGINE:-docker}"
	# グリフが無いフォントは、どの文字も同じ「欠落」の□を描く。2つの別の漢字の描画結果が
	# 異なれば、実際のグリフがある。イメージに設定されているフォント名をそのまま使う。
	run env MSYS_NO_PATHCONV=1 "${engine}" run --rm -i --entrypoint sh "${WEB_IMAGE}" -s <<'EOS'
cd /usr/share/zabbix
name=$(awk -F"'" '/^define\(.ZBX_GRAPH_FONT_NAME/ {print $4}' include/defines.inc.php)
cat > /tmp/g.php <<'PHP'
<?php
function glyph($font, $ch) {
	$im = imagecreate(60, 60);
	imagecolorallocate($im, 255, 255, 255);
	imagettftext($im, 30, 0, 5, 45, imagecolorallocate($im, 0, 0, 0), $font, $ch);
	ob_start();
	imagepng($im);
	return md5(ob_get_clean());
}
$font = $argv[1];
echo glyph($font, "日") !== glyph($font, "語") ? "real-glyphs" : "boxes";
PHP
echo "${name} $(php83 /tmp/g.php "/usr/share/zabbix/assets/fonts/${name}.ttf")"
EOS
	[ "${status}" -eq 0 ]
	[[ "${output}" == *"real-glyphs" ]]
}
