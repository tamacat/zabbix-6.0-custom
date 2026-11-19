#!/usr/bin/env bats
# scripts/push-images.sh のテスト — BR3.1(公開前提条件ゲート)・BR3.2(セルフレビュー
# 承認)を満たさない限り公開処理(docker push)へ進まないことを検証する。
#
# dockerは常にテスト用スタブへ差し替える。python3/pythonは実行できる実インタプリタを
# そのまま使う(release_tools.cliの実ロジックを検証するため)。

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

	# `docker push` が呼ばれたことを検知できるよう、呼び出しをマーカーファイルへ記録する。
	cat > "${STUB_BIN}/docker" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "${TEST_TMPDIR}/docker-calls.log"
exit 0
EOF
	chmod +x "${STUB_BIN}/docker"
}

teardown() {
	rm -rf "${TEST_TMPDIR}"
}

@test "BR3.1未達(SASTがFail)の場合、docker pushへ進まない" {
	cd "${REPO_ROOT}"
	run bash scripts/push-images.sh \
		--tag tamacat/zabbix-server-mysql:6.0.49-alpine-b20260920 \
		--sca Pass --sast Fail --compat Pass --secret Clean --yes

	[ "$status" -ne 0 ]
	[[ "$output" == *"BR3.1違反"* ]]
	[ ! -f "${TEST_TMPDIR}/docker-calls.log" ]
}

@test "BR3.2未承認(セルフレビュー拒否)の場合、docker pushへ進まない" {
	cd "${REPO_ROOT}"
	run bash scripts/push-images.sh \
		--tag tamacat/zabbix-server-mysql:6.0.49-alpine-b20260920 \
		--sca Pass --sast Pass --compat Pass --secret Clean --no

	[ "$status" -ne 0 ]
	[[ "$output" == *"BR3.2"* ]]
	[ ! -f "${TEST_TMPDIR}/docker-calls.log" ]
}

@test "BR3.1・BR3.2をいずれも満たす場合はdocker pushを実行する" {
	cd "${REPO_ROOT}"
	run bash scripts/push-images.sh \
		--tag tamacat/zabbix-server-mysql:6.0.49-alpine-b20260920 \
		--sca Pass --sast Pass --compat Pass --secret Clean --yes

	[ "$status" -eq 0 ]
	[ -f "${TEST_TMPDIR}/docker-calls.log" ]
	grep -q "push tamacat/zabbix-server-mysql:6.0.49-alpine-b20260920" "${TEST_TMPDIR}/docker-calls.log"
}


# --- 系列の最新タグ(<X.Y>-latest)の付け替え ---------------------------------------------
# 署名とSBOM添付まで成功する場面(GitHub Actions)を再現する: GITHUB_ACTIONS、cosignのスタブ、
# SBOMファイル。dockerスタブは `inspect` に、引数のダイジェスト行(<リポジトリ>@sha256:...)を返す。
_stub_ci_signing() {
	local digest_lines="$1"
	cat > "${STUB_BIN}/docker" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "${TEST_TMPDIR}/docker-calls.log"
if [ "\$1" = "inspect" ]; then
	printf '%s\n' ${digest_lines}
fi
exit 0
EOF
	cat > "${STUB_BIN}/cosign" <<EOF
#!/usr/bin/env bash
echo "cosign \$*" >> "${TEST_TMPDIR}/docker-calls.log"
exit 0
EOF
	chmod +x "${STUB_BIN}/docker" "${STUB_BIN}/cosign"
	echo '{}' > "${TEST_TMPDIR}/sbom.json"
	export GITHUB_ACTIONS=true
}

SAME_DIGEST="tamacat/zabbix-server-mysql@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OTHER_DIGEST="tamacat/zabbix-server-mysql@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

@test "署名とSBOM添付が済んだ公開では、系列の最新タグを同じイメージへ付け替える" {
	cd "${REPO_ROOT}"
	_stub_ci_signing "${SAME_DIGEST}"
	run bash scripts/push-images.sh \
		--tag tamacat/zabbix-server-mysql:6.0.49-alpine-b20260920 \
		--sca Pass --sast Pass --compat Pass --secret Clean \
		--sbom "${TEST_TMPDIR}/sbom.json" --yes

	[ "$status" -eq 0 ]
	grep -qx "tag tamacat/zabbix-server-mysql:6.0.49-alpine-b20260920 tamacat/zabbix-server-mysql:6.0-latest" "${TEST_TMPDIR}/docker-calls.log"
	grep -qx "push tamacat/zabbix-server-mysql:6.0-latest" "${TEST_TMPDIR}/docker-calls.log"
	# 付け替えは、日付つきタグの公開・署名・SBOM添付よりも後でなければならない。
	attest_line="$(grep -n '^cosign attest' "${TEST_TMPDIR}/docker-calls.log" | head -n 1 | cut -d: -f1)"
	latest_line="$(grep -nx 'push tamacat/zabbix-server-mysql:6.0-latest' "${TEST_TMPDIR}/docker-calls.log" | head -n 1 | cut -d: -f1)"
	[ -n "${attest_line}" ]
	[ "${attest_line}" -lt "${latest_line}" ]
}

@test "GitHub Actions外(署名しない実行)では、最新タグを付け替えない" {
	cd "${REPO_ROOT}"
	_stub_ci_signing "${SAME_DIGEST}"
	unset GITHUB_ACTIONS
	run bash scripts/push-images.sh \
		--tag tamacat/zabbix-server-mysql:6.0.49-alpine-b20260920 \
		--sca Pass --sast Pass --compat Pass --secret Clean \
		--sbom "${TEST_TMPDIR}/sbom.json" --yes

	[ "$status" -eq 0 ]
	[[ "$output" == *"最新タグ"* ]]
	run grep -e "-latest" "${TEST_TMPDIR}/docker-calls.log"
	[ "$status" -ne 0 ]
}

@test "SBOMを添付していない公開では、最新タグを付け替えない" {
	cd "${REPO_ROOT}"
	_stub_ci_signing "${SAME_DIGEST}"
	run bash scripts/push-images.sh \
		--tag tamacat/zabbix-server-mysql:6.0.49-alpine-b20260920 \
		--sca Pass --sast Pass --compat Pass --secret Clean --yes

	[ "$status" -eq 0 ]
	run grep -e "-latest" "${TEST_TMPDIR}/docker-calls.log"
	[ "$status" -ne 0 ]
}

@test "最新タグが日付つきタグと別のダイジェストになった場合は失敗する" {
	cd "${REPO_ROOT}"
	_stub_ci_signing "${SAME_DIGEST} ${OTHER_DIGEST}"
	run bash scripts/push-images.sh \
		--tag tamacat/zabbix-server-mysql:6.0.49-alpine-b20260920 \
		--sca Pass --sast Pass --compat Pass --secret Clean \
		--sbom "${TEST_TMPDIR}/sbom.json" --yes

	[ "$status" -ne 0 ]
	[[ "$output" == *"別のダイジェスト"* ]]
}
