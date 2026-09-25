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

	# TEST_TMPDIRはgitリポジトリ外なので、全体スキャン+空のbaselineで検証する。
	write_baseline semgrep "${TEST_TMPDIR}/baselines" '{}'
	write_baseline cppcheck "${TEST_TMPDIR}/baselines" '{}'
	run env SAST_SCOPE=full SAST_BASELINE_DIR="${TEST_TMPDIR}/baselines" bash scripts/scan-sast.sh "${TEST_TMPDIR}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Semgrep verdict: Pass"* ]]
	[[ "$output" == *"cppcheck verdict: Pass"* ]]
	[[ "$output" == *"SAST verdict: Pass"* ]]
}

# --- scan-sast.sh: スコープ(patched/full)とbaseline -------------------------------

write_baseline() {
	# $1: tool, $2: 出力ディレクトリ, $3: entriesのJSONオブジェクト
	mkdir -p "$2"
	printf '{"version": 1, "tool": "%s", "note": "", "entries": %s}\n' "$1" "$3" > "$2/$1.json"
}

stub_sast_tools() {
	# 呼び出し引数を記録し、cppcheckは ${CPPCHECK_STUB_XML}(既定: 指摘なし)をstderrへ出す。
	cat > "${STUB_BIN}/semgrep" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "${TEST_TMPDIR}/semgrep-calls.log"
out=""
prev=""
for arg in "\$@"; do
	if [ "\${prev}" = "--output" ]; then
		out="\${arg}"
	fi
	prev="\${arg}"
done
echo '{"results": []}' > "\${out}"
EOF
	cat > "${STUB_BIN}/cppcheck" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "${TEST_TMPDIR}/cppcheck-calls.log"
if [ -n "\${CPPCHECK_STUB_XML:-}" ]; then
	echo "\${CPPCHECK_STUB_XML}" >&2
else
	echo '<results version="2"><errors></errors></results>' >&2
fi
EOF
	chmod +x "${STUB_BIN}/semgrep" "${STUB_BIN}/cppcheck"
}

make_sast_repo() {
	# scan-sast.sh+release_toolsだけを持つ隔離gitリポジトリ。初回コミットを上流インポートとみなす。
	SAST_REPO="${TEST_TMPDIR}/repo"
	local src="${SAST_REPO}/sources/zabbix-6.0.48"
	mkdir -p "${SAST_REPO}/scripts" "${src}/src/libs" "${src}/src/go/vendor/x" "${src}/ui"
	cp "${REPO_ROOT}/scripts/scan-sast.sh" "${SAST_REPO}/scripts/"
	cp -r "${REPO_ROOT}/release_tools" "${SAST_REPO}/"
	echo 'int a;' > "${src}/src/libs/a.c"
	echo 'int b;' > "${src}/src/libs/b.c"
	echo 'int v;' > "${src}/src/go/vendor/x/v.c"
	echo '<?php echo 1;' > "${src}/ui/index.php"
	write_baseline semgrep "${SAST_REPO}/data/sast-baseline" '{}'
	write_baseline cppcheck "${SAST_REPO}/data/sast-baseline" '{}'
	export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
	git -C "${SAST_REPO}" init -q .
	git -C "${SAST_REPO}" add -A
	git -C "${SAST_REPO}" commit -q -m "upstream import"
	git -C "${SAST_REPO}" rev-parse HEAD > "${SAST_REPO}/data/upstream-import-ref"
}

CPPCHECK_FINDING_XML='<results version="2"><errors><error id="nullPointer" severity="warning" msg="Null pointer dereference: p"><location file="sources/zabbix-6.0.48/src/libs/a.c" line="3"/></error></errors></results>'

@test "scan-sast.sh(patched): 変更ファイルがなければSemgrep/cppcheckをスキップしてPassする" {
	make_sast_repo
	stub_sast_tools
	cd "${SAST_REPO}"
	run bash scripts/scan-sast.sh
	[ "$status" -eq 0 ]
	[[ "$output" == *"SAST verdict: Pass"* ]]
	[ ! -f "${TEST_TMPDIR}/semgrep-calls.log" ]
	[ ! -f "${TEST_TMPDIR}/cppcheck-calls.log" ]
}

@test "scan-sast.sh(patched): 変更されたCファイルだけをcppcheckへ渡し、vendor配下は対象外にする" {
	make_sast_repo
	stub_sast_tools
	cd "${SAST_REPO}"
	echo 'int a2;' >> sources/zabbix-6.0.48/src/libs/a.c
	echo 'int v2;' >> sources/zabbix-6.0.48/src/go/vendor/x/v.c
	echo '<?php echo 2;' >> sources/zabbix-6.0.48/ui/index.php
	run bash scripts/scan-sast.sh
	[ "$status" -eq 0 ]
	grep -q "sources/zabbix-6.0.48/src/libs/a.c" "${TEST_TMPDIR}/cppcheck-calls.log"
	run grep -qF "libs/b.c" "${TEST_TMPDIR}/cppcheck-calls.log"
	[ "$status" -ne 0 ]
	run grep -q "vendor" "${TEST_TMPDIR}/cppcheck-calls.log"
	[ "$status" -ne 0 ]
	grep -q -- "--include sources/zabbix-6.0.48/ui/index.php" "${TEST_TMPDIR}/semgrep-calls.log"
	run grep -q "vendor" "${TEST_TMPDIR}/semgrep-calls.log"
	[ "$status" -ne 0 ]
}

@test "scan-sast.sh(patched): baseline外の新規cppcheck指摘があればFailし、指摘を表示する" {
	make_sast_repo
	stub_sast_tools
	cd "${SAST_REPO}"
	echo 'int a2;' >> sources/zabbix-6.0.48/src/libs/a.c
	run env CPPCHECK_STUB_XML="${CPPCHECK_FINDING_XML}" bash scripts/scan-sast.sh
	[ "$status" -ne 0 ]
	[[ "$output" == *"cppcheck verdict: Fail"* ]]
	[[ "$output" == *"cppcheck|nullPointer|src/libs/a.c|Null pointer dereference: p"* ]]
	[[ "$output" == *"SAST verdict: Fail"* ]]
}

@test "scan-sast.sh: --update-baselineで記録した既知の指摘はpatchedスコープでPassする" {
	make_sast_repo
	stub_sast_tools
	cd "${SAST_REPO}"
	run env CPPCHECK_STUB_XML="${CPPCHECK_FINDING_XML}" bash scripts/scan-sast.sh --update-baseline
	[ "$status" -eq 0 ]
	grep -q "nullPointer" data/sast-baseline/cppcheck.json

	echo 'int a2;' >> sources/zabbix-6.0.48/src/libs/a.c
	run env CPPCHECK_STUB_XML="${CPPCHECK_FINDING_XML}" bash scripts/scan-sast.sh
	[ "$status" -eq 0 ]
	[[ "$output" == *"cppcheck verdict: Pass"* ]]
}

@test "scan-sast.sh(full): vendor配下を除いてツリー全体をcppcheckへ渡す" {
	make_sast_repo
	stub_sast_tools
	cd "${SAST_REPO}"
	run bash scripts/scan-sast.sh --scope full
	[ "$status" -eq 0 ]
	grep -q -- "-i sources/zabbix-6.0.48/src/go/vendor" "${TEST_TMPDIR}/cppcheck-calls.log"
}

@test "scan-sast.sh: baselineが無ければ、作成方法を示して停止する" {
	make_sast_repo
	stub_sast_tools
	cd "${SAST_REPO}"
	rm "data/sast-baseline/cppcheck.json"
	run bash scripts/scan-sast.sh
	[ "$status" -ne 0 ]
	[[ "$output" == *"--update-baseline"* ]]
}

@test "scan-sast.sh(patched): 上流インポートのコミットが存在しない(浅いclone)場合は明確なエラーで停止する" {
	make_sast_repo
	stub_sast_tools
	cd "${SAST_REPO}"
	echo "0000000000000000000000000000000000000000" > data/upstream-import-ref
	run bash scripts/scan-sast.sh
	[ "$status" -ne 0 ]
	[[ "$output" == *"fetch-depth: 0"* ]]
}
