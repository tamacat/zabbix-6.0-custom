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
	export PATH="${STUB_BIN}:${PATH}"

	# docker save / tar は実バイナリで十分小さく安全(空のtarを作るだけ)なので、
	# dockerだけをスタブし、tarは実物を使う。
	cat > "${STUB_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
# scan-secrets.sh は `docker save <image> -o <path>` の形式でのみ呼び出す。
out=""
prev=""
for arg in "$@"; do
	if [ "${prev}" = "-o" ]; then
		out="${arg}"
	fi
	prev="${arg}"
done
tar -cf "${out}" --files-from /dev/null
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
prev=""
for arg in "\$@"; do
	if [ "\${prev}" = "--report-path" ]; then
		report_path="\${arg}"
	fi
	prev="\${arg}"
done
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
