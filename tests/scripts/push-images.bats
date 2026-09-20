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
	export PATH="${STUB_BIN}:${PATH}"

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
		--tag tamacat/zabbix-server:6.0.48-r20260920-amd64 \
		--sca Pass --sast Fail --compat Pass --secret Clean --yes

	[ "$status" -ne 0 ]
	[[ "$output" == *"BR3.1違反"* ]]
	[ ! -f "${TEST_TMPDIR}/docker-calls.log" ]
}

@test "BR3.2未承認(セルフレビュー拒否)の場合、docker pushへ進まない" {
	cd "${REPO_ROOT}"
	run bash scripts/push-images.sh \
		--tag tamacat/zabbix-server:6.0.48-r20260920-amd64 \
		--sca Pass --sast Pass --compat Pass --secret Clean --no

	[ "$status" -ne 0 ]
	[[ "$output" == *"BR3.2"* ]]
	[ ! -f "${TEST_TMPDIR}/docker-calls.log" ]
}

@test "BR3.1・BR3.2をいずれも満たす場合はdocker pushを実行する" {
	cd "${REPO_ROOT}"
	run bash scripts/push-images.sh \
		--tag tamacat/zabbix-server:6.0.48-r20260920-amd64 \
		--sca Pass --sast Pass --compat Pass --secret Clean --yes

	[ "$status" -eq 0 ]
	[ -f "${TEST_TMPDIR}/docker-calls.log" ]
	grep -q "push tamacat/zabbix-server:6.0.48-r20260920-amd64" "${TEST_TMPDIR}/docker-calls.log"
}
