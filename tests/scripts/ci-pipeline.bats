#!/usr/bin/env bats
# scripts/ci-pipeline.sh のテスト — ビルド→SCA→SAST→シークレットスキャン→SBOM生成→
# 互換性テスト→公開前提条件ゲート判定(ステージ3-9)のオーケストレーションを検証する。
#
# docker/trivy/semgrep/cppcheck/gitleaksはすべてテスト用スタブへ差し替え、実スキャン・
# 実イメージ操作・実コンテナ起動は行わない。

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

	# scan-runner.bats / compat-test.bats と同じ理由: 実運用データ・開発者ローカルの
	# .envに結果が左右されないよう、隔離する。
	export REGISTRY_PATH="${TEST_TMPDIR}/vulnerability-registry.yaml"
	if [ -f "${REPO_ROOT}/.env" ]; then
		ENV_BACKUP="${TEST_TMPDIR}/env.backup"
		mv "${REPO_ROOT}/.env" "${ENV_BACKUP}"
	fi

	# build-images.sh / scan-sast.sh が要求するソースディレクトリ(中身は問わない)。
	SRC_DIR="${TEST_TMPDIR}/sources/zabbix-6.0.48"
	mkdir -p "${SRC_DIR}"

	# SAST: ソースがgitリポジトリ外のため全体スキャン+空のbaselineで実行する。
	BASELINE_DIR="${TEST_TMPDIR}/baselines"
	mkdir -p "${BASELINE_DIR}"
	for tool in semgrep cppcheck; do
		printf '{"version": 1, "tool": "%s", "note": "", "entries": {}}\n' "${tool}" > "${BASELINE_DIR}/${tool}.json"
	done

	# docker: build / image inspect / save / compose / stats のすべてに成功で応答する
	# 汎用スタブ(build-images.bats・scan-runner.bats・scan-secrets.bats・
	# compat-test.batsのスタブを1つに統合)。
	cat > "${STUB_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
	save)
		out=""
		prev=""
		for arg in "$@"; do
			if [ "${prev}" = "-o" ]; then
				out="${arg}"
			fi
			prev="${arg}"
		done
		# scan-secrets.sh はmanifest.jsonのLayersからレイヤーを展開するため、最小限の実物を作る。
		work="$(mktemp -d)"
		mkdir -p "${work}/blobs/sha256" "${work}/layer/app"
		echo hello > "${work}/layer/app/config.txt"
		tar -cf "${work}/blobs/sha256/abc123" -C "${work}/layer" .
		rm -rf "${work}/layer"
		echo '[{"Config":"cfg","Layers":["blobs/sha256/abc123"]}]' > "${work}/manifest.json"
		tar -cf "${out}" -C "${work}" .
		rm -rf "${work}"
		exit 0
		;;
	*)
		exit 0
		;;
esac
EOF
	chmod +x "${STUB_BIN}/docker"

	# trivy: `image --format json --output <f> <img>`(scan-sca.sh)と
	# `image --format cyclonedx --output <f> <img>`(SBOM生成)の両方に空/最小結果で応答する。
	cat > "${STUB_BIN}/trivy" <<'EOF'
#!/usr/bin/env bash
format=""
out=""
prev=""
for arg in "$@"; do
	if [ "${prev}" = "--format" ]; then
		format="${arg}"
	fi
	if [ "${prev}" = "--output" ]; then
		out="${arg}"
	fi
	prev="${arg}"
done
if [ "${format}" = "cyclonedx" ]; then
	echo '{"bomFormat": "CycloneDX", "components": []}' > "${out}"
else
	echo '{"Results": []}' > "${out}"
fi
exit 0
EOF
	chmod +x "${STUB_BIN}/trivy"

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

	cat > "${STUB_BIN}/gitleaks" <<'EOF'
#!/usr/bin/env bash
report_path=""
prev=""
for arg in "$@"; do
	if [ "${prev}" = "--report-path" ]; then
		report_path="${arg}"
	fi
	prev="${arg}"
done
[ -n "${report_path}" ] && echo '[]' > "${report_path}"
exit 0
EOF
	chmod +x "${STUB_BIN}/gitleaks"
}

teardown() {
	if [ -n "${ENV_BACKUP:-}" ] && [ -f "${ENV_BACKUP}" ]; then
		mv "${ENV_BACKUP}" "${REPO_ROOT}/.env"
	fi
	rm -rf "${TEST_TMPDIR}"
}

run_pipeline() {
	env \
		ZABBIX_VERSION=6.0.48 \
		ZABBIX_SRC_DIR="${SRC_DIR}" \
		BUILD_DATE=20260920 \
		DB_SERVER_HOST=mysql.example.internal \
		MYSQL_PASSWORD=secret \
		REGISTRY_PATH="${REGISTRY_PATH}" \
		SAST_SCOPE=full \
		SAST_BASELINE_DIR="${BASELINE_DIR}" \
		bash scripts/ci-pipeline.sh
}

@test "必須環境変数ZABBIX_VERSION未設定時にエラーで停止する" {
	cd "${REPO_ROOT}"
	run env --unset=ZABBIX_VERSION ZABBIX_SRC_DIR="${SRC_DIR}" bash scripts/ci-pipeline.sh
	[ "$status" -ne 0 ]
	[[ "$output" == *"ZABBIX_VERSION"* ]]
	[[ "$output" == *"自動リトライは行いません"* ]]
}

@test "trivyが見つからない場合エラーで停止する" {
	cd "${REPO_ROOT}"
	rm -f "${STUB_BIN}/trivy"
	run run_pipeline
	[ "$status" -ne 0 ]
	[[ "$output" == *"trivy"* ]]
}

@test "正常系ではステージ3-9をすべてPassし、4コンポーネント分のタグとSBOM_DIRを報告する" {
	cd "${REPO_ROOT}"
	run run_pipeline
	[ "$status" -eq 0 ]
	[[ "$output" == *"tamacat/zabbix-server-mysql:6.0.48-alpine-b20260920"* ]]
	[[ "$output" == *"tamacat/zabbix-web-nginx-mysql:6.0.48-alpine-b20260920"* ]]
	[[ "$output" == *"tamacat/zabbix-agent2:6.0.48-alpine-b20260920"* ]]
	[[ "$output" == *"tamacat/zabbix-proxy-sqlite3:6.0.48-alpine-b20260920"* ]]
	[[ "$output" == *"SCA verdict: Pass"* ]]
	[[ "$output" == *"SAST verdict: Pass"* ]]
	[[ "$output" == *"result: Clean"* ]]
	[[ "$output" == *"CompatibilityTestRun result: Pass"* ]]
	[[ "$output" == *"検証ステージ(3-9)がすべてPassしました"* ]]
	[[ "$output" == *"SBOM_DIR="* ]]
}

@test "SCAスキャンでCriticalな未棚卸しfindingがあればSCAで停止し、SAST以降は実行しない" {
	cd "${REPO_ROOT}"
	cat > "${STUB_BIN}/trivy" <<'EOF'
#!/usr/bin/env bash
format=""
out=""
prev=""
for arg in "$@"; do
	if [ "${prev}" = "--format" ]; then
		format="${arg}"
	fi
	if [ "${prev}" = "--output" ]; then
		out="${arg}"
	fi
	prev="${arg}"
done
if [ "${format}" = "cyclonedx" ]; then
	echo '{"bomFormat": "CycloneDX", "components": []}' > "${out}"
else
	cat > "${out}" <<'JSON'
{"Results": [{"Target": "zabbix-server", "Vulnerabilities": [
	{"VulnerabilityID": "CVE-2026-00099", "Severity": "CRITICAL"}
]}]}
JSON
fi
exit 0
EOF
	chmod +x "${STUB_BIN}/trivy"

	run run_pipeline
	[ "$status" -ne 0 ]
	[[ "$output" == *"SCA verdict: Fail"* ]]
	[[ "$output" == *"SCAスキャンでFail判定が出ました"* ]]
	[[ "$output" != *"ScanRunner(SAST)"* ]]
	[[ "$output" != *"CompatibilityTestRun"* ]]
}
