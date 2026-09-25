#!/usr/bin/env bats
# scripts/scan-secrets.sh のテスト — 2サブステップ(Git差分・イメージレイヤー)の
# 集約ロジック(NFR3.1: シークレットスキャンの二重チェック)を検証する。
#
# gitleaks/docker/tarは常にテスト用スタブへ差し替える(tarはPATH解決される限りスタブに
# 差し替え可能。実イメージ・実Gitリポジトリはスキャンしない)。

setup() {
	REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
	TEST_TMPDIR="$(mktemp -d)"
	STUB_BIN="${TEST_TMPDIR}/bin"
	mkdir -p "${STUB_BIN}"
	# CI installs trivy/gitleaks to /usr/local/bin (see .github/workflows/ci-release.yml);
	# without excluding it here, removing a stub to simulate "tool missing" would still find
	# the real one there, and PATH order alone can't be trusted to keep the stub authoritative
	# either (confirmed against a real CI run: several tool-stubbing tests passed locally but
	# failed on GitHub Actions specifically because of this).
	export PATH="${STUB_BIN}:$(echo "${PATH}" | sed -e 's#:/usr/local/bin:#:#g' -e 's#^/usr/local/bin:##' -e 's#:/usr/local/bin$##')"

	# `docker save <image> -o <path>` の出力を模す。レイヤーの置き場所は docker のバージョンで
	# 異なるため、形式を STUB_IMAGE_LAYOUT で切り替える:
	#   oci(既定)   blobs/sha256/<hash>(拡張子なし)  … 新しいdocker。旧実装はこれを1枚も見つけられなかった
	#   classic     <id>/layer.tar
	#   empty       Layersが空
	#   nomanifest  manifest.jsonなし
	# レイヤーには app/config.txt が1つ入っている。
	cat > "${STUB_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
out=""
prev=""
for arg in "$@"; do
	if [ "${prev}" = "-o" ]; then
		out="${arg}"
	fi
	prev="${arg}"
done
work="$(mktemp -d)"
layer_src="$(mktemp -d)"
mkdir -p "${layer_src}/app"
echo "hello" > "${layer_src}/app/config.txt"
case "${STUB_IMAGE_LAYOUT:-oci}" in
	oci)
		mkdir -p "${work}/blobs/sha256"
		tar -cf "${work}/blobs/sha256/abc123" -C "${layer_src}" .
		echo '[{"Config":"blobs/sha256/cfg","Layers":["blobs/sha256/abc123"]}]' > "${work}/manifest.json"
		;;
	classic)
		mkdir -p "${work}/abc123"
		tar -cf "${work}/abc123/layer.tar" -C "${layer_src}" .
		echo '[{"Config":"cfg.json","Layers":["abc123/layer.tar"]}]' > "${work}/manifest.json"
		;;
	empty)
		echo '[{"Config":"cfg.json","Layers":[]}]' > "${work}/manifest.json"
		;;
	nomanifest)
		echo x > "${work}/something"
		;;
esac
tar -cf "${out}" -C "${work}" .
rm -rf "${work}" "${layer_src}"
exit 0
EOF
	chmod +x "${STUB_BIN}/docker"
}

teardown() {
	rm -rf "${TEST_TMPDIR}"
}

stub_gitleaks() {
	# $1: "clean" または "blocked"(順にGit差分・イメージレイヤー呼び出しへ適用)
	local behaviors=("$@")
	local state_file="${TEST_TMPDIR}/gitleaks-call-count"
	echo 0 > "${state_file}"
	cat > "${STUB_BIN}/gitleaks" <<EOF
#!/usr/bin/env bash
call_index=\$(cat "${state_file}")
echo \$((call_index + 1)) > "${state_file}"
behaviors=(${behaviors[@]})
behavior="\${behaviors[\$call_index]:-clean}"

report_path=""
source_dir=""
no_git=0
prev=""
for arg in "\$@"; do
	if [ "\${prev}" = "--report-path" ]; then
		report_path="\${arg}"
	fi
	if [ "\${prev}" = "--source" ]; then
		source_dir="\${arg}"
	fi
	if [ "\${arg}" = "--no-git" ]; then
		no_git=1
	fi
	prev="\${arg}"
done
# イメージ層スキャン(--no-git)のとき、実際に渡されたディレクトリの中身を記録する。
if [ "\${no_git}" = "1" ]; then
	(cd "\${source_dir}" && find . -type f | sed "s#^\./##") >> "${TEST_TMPDIR}/image-scanned-files.log"
fi
[ -n "\${report_path}" ] && echo '[]' > "\${report_path}"

if [ "\${behavior}" = "clean" ]; then
	exit 0
else
	exit 1
fi
EOF
	chmod +x "${STUB_BIN}/gitleaks"
}

@test "gitleaksが見つからない場合エラーで停止する" {
	cd "${REPO_ROOT}"
	run bash scripts/scan-secrets.sh tamacat/zabbix-server:6.0.48-r20260920-amd64
	[ "$status" -ne 0 ]
	[[ "$output" == *"gitleaks"* ]]
}

@test "Git差分・イメージレイヤーの両方がCleanならCleanと判定する" {
	cd "${REPO_ROOT}"
	stub_gitleaks clean clean
	run bash scripts/scan-secrets.sh tamacat/zabbix-server:6.0.48-r20260920-amd64
	[ "$status" -eq 0 ]
	[[ "$output" == *"result: Clean"* ]]
}

@test "Git差分がBlockedならCI全体としてBlockedになる" {
	cd "${REPO_ROOT}"
	stub_gitleaks blocked clean
	run bash scripts/scan-secrets.sh tamacat/zabbix-server:6.0.48-r20260920-amd64
	[ "$status" -ne 0 ]
	[[ "$output" == *"Git差分・履歴スキャン: Blocked"* ]]
	[[ "$output" == *"result: Blocked"* ]]
}

@test "イメージレイヤースキャンがBlockedならCI全体としてBlockedになる" {
	cd "${REPO_ROOT}"
	stub_gitleaks clean blocked
	run bash scripts/scan-secrets.sh tamacat/zabbix-server:6.0.48-r20260920-amd64
	[ "$status" -ne 0 ]
	[[ "$output" == *"イメージレイヤースキャン"*"Blocked"* ]]
	[[ "$output" == *"result: Blocked"* ]]
}

@test "イメージのレイヤー(新形式 blobs/sha256/<hash>)を展開し、その中身をgitleaksへ渡す" {
	cd "${REPO_ROOT}"
	stub_gitleaks clean clean
	run bash scripts/scan-secrets.sh tamacat/zabbix-server:6.0.48-r20260920-amd64
	[ "$status" -eq 0 ]
	[[ "$output" == *"展開したレイヤー数: 1"* ]]
	grep -qx "app/config.txt" "${TEST_TMPDIR}/image-scanned-files.log"
}

@test "イメージのレイヤー(旧形式 <id>/layer.tar)も展開し、その中身をgitleaksへ渡す" {
	cd "${REPO_ROOT}"
	stub_gitleaks clean clean
	run env STUB_IMAGE_LAYOUT=classic bash scripts/scan-secrets.sh tamacat/zabbix-server:6.0.48-r20260920-amd64
	[ "$status" -eq 0 ]
	grep -qx "app/config.txt" "${TEST_TMPDIR}/image-scanned-files.log"
}

@test "レイヤーが1枚も展開できないイメージは、空をスキャンしてCleanにせず停止する" {
	cd "${REPO_ROOT}"
	stub_gitleaks clean clean
	run env STUB_IMAGE_LAYOUT=empty bash scripts/scan-secrets.sh tamacat/zabbix-server:6.0.48-r20260920-amd64
	[ "$status" -ne 0 ]
	[[ "$output" == *"レイヤーが1枚も展開されませんでした"* ]]
	[[ "$output" != *"result: Clean"* ]]
}

@test "docker saveの出力にmanifest.jsonがなければ、レイヤーを特定できないので停止する" {
	cd "${REPO_ROOT}"
	stub_gitleaks clean clean
	run env STUB_IMAGE_LAYOUT=nomanifest bash scripts/scan-secrets.sh tamacat/zabbix-server:6.0.48-r20260920-amd64
	[ "$status" -ne 0 ]
	[[ "$output" == *"manifest.json がありません"* ]]
}
