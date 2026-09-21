#!/usr/bin/env bats
# scripts/scan-sca.sh / scripts/scan-sast.sh のテスト。
#
# trivy/semgrep/cppcheck/dockerは常にテスト用スタブへ差し替え、実スキャン・実イメージ
# 操作は行わない。

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
	# 実運用データ(data/vulnerability-registry.yaml)へ書き込まないよう、レジストリ先を
	# テスト専用の一時ファイルへ差し替える。
	export REGISTRY_PATH="${TEST_TMPDIR}/vulnerability-registry.yaml"
}

teardown() {
	rm -rf "${TEST_TMPDIR}"
}

stub_docker_image_exists() {
	cat > "${STUB_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
	chmod +x "${STUB_BIN}/docker"
}

stub_docker_image_missing() {
	cat > "${STUB_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
	chmod +x "${STUB_BIN}/docker"
}

stub_trivy_empty_results() {
	cat > "${STUB_BIN}/trivy" <<'EOF'
#!/usr/bin/env bash
# --format json --output <file> ... <image> という呼び出しを想定し、<file>へ空の結果を書く。
out=""
prev=""
for arg in "$@"; do
	if [ "${prev}" = "--output" ]; then
		out="${arg}"
	fi
	prev="${arg}"
done
echo '{"Results": []}' > "${out}"
exit 0
EOF
	chmod +x "${STUB_BIN}/trivy"
}

@test "scan-sca.sh: trivyが見つからない場合エラーで停止する" {
	cd "${REPO_ROOT}"
	stub_docker_image_exists
	run bash scripts/scan-sca.sh tamacat/zabbix-server:6.0.48-r20260920-amd64
	[ "$status" -ne 0 ]
	[[ "$output" == *"trivy"* ]]
}

@test "scan-sca.sh: 対象イメージが存在しない場合エラーで停止する" {
	cd "${REPO_ROOT}"
	stub_docker_image_missing
	stub_trivy_empty_results
	run bash scripts/scan-sca.sh tamacat/zabbix-server:6.0.48-r20260920-amd64
	[ "$status" -ne 0 ]
	[[ "$output" == *"見つかりません"* ]]
}

@test "scan-sca.sh: 正常系ではPass判定を出力する" {
	cd "${REPO_ROOT}"
	stub_docker_image_exists
	stub_trivy_empty_results
	run bash scripts/scan-sca.sh tamacat/zabbix-server:6.0.48-r20260920-amd64
	[ "$status" -eq 0 ]
	[[ "$output" == *"SCA verdict: Pass"* ]]
}

@test "scan-sast.sh: semgrepが見つからない場合エラーで停止する" {
	cd "${REPO_ROOT}"
	cat > "${STUB_BIN}/cppcheck" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
	chmod +x "${STUB_BIN}/cppcheck"
	run bash scripts/scan-sast.sh "${TEST_TMPDIR}"
	[ "$status" -ne 0 ]
	[[ "$output" == *"semgrep"* ]]
}

@test "scan-sast.sh: 正常系ではSemgrep/cppcheck双方のPass判定を出力する" {
	cd "${REPO_ROOT}"
	cat > "${STUB_BIN}/semgrep" <<'EOF'
#!/usr/bin/env bash
out=""
prev=""
for arg in "$@"; do
	if [ "${prev}" = "--output" ]; then
		out="${arg}"
	fi
	prev="${arg}"
done
echo '{"results": []}' > "${out}"
exit 0
EOF
	chmod +x "${STUB_BIN}/semgrep"

	cat > "${STUB_BIN}/cppcheck" <<'EOF'
#!/usr/bin/env bash
>&2 echo '<results><errors></errors></results>'
exit 0
EOF
	chmod +x "${STUB_BIN}/cppcheck"

	run bash scripts/scan-sast.sh "${TEST_TMPDIR}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Semgrep verdict: Pass"* ]]
	[[ "$output" == *"cppcheck verdict: Pass"* ]]
	[[ "$output" == *"SAST verdict: Pass"* ]]
}
