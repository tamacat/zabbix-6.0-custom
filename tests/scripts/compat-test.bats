#!/usr/bin/env bats
# scripts/compat-test.sh のテスト。
#
# dockerは常にテスト用スタブへ差し替え、実コンテナ起動は行わない。

setup() {
	REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
	TEST_TMPDIR="$(mktemp -d)"
	STUB_BIN="${TEST_TMPDIR}/bin"
	mkdir -p "${STUB_BIN}"
	export PATH="${STUB_BIN}:${PATH}"

	cat > "${STUB_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
# `docker compose config --quiet` / `docker compose up -d` / `docker stats --no-stream` を
# すべて成功として扱う汎用スタブ。
exit 0
EOF
	chmod +x "${STUB_BIN}/docker"

	# 開発者のローカル.env(バージョン管理対象外)が必須環境変数(MYSQL_PASSWORD等)を
	# 供給してしまうと、「未設定時にエラーになる」テストがローカル環境依存で失敗する
	# (build-and-test stageで発覚)。テスト中は一時的に退避する。
	if [ -f "${REPO_ROOT}/.env" ]; then
		ENV_BACKUP="${TEST_TMPDIR}/env.backup"
		mv "${REPO_ROOT}/.env" "${ENV_BACKUP}"
	fi
}

teardown() {
	if [ -n "${ENV_BACKUP:-}" ] && [ -f "${ENV_BACKUP}" ]; then
		mv "${ENV_BACKUP}" "${REPO_ROOT}/.env"
	fi
	rm -rf "${TEST_TMPDIR}"
}

@test "docker compose config --quiet が通り、必須環境変数が揃っていればPassする" {
	cd "${REPO_ROOT}"
	run env DB_SERVER_HOST=mysql.example.internal MYSQL_PASSWORD=secret bash scripts/compat-test.sh
	[ "$status" -eq 0 ]
	[[ "$output" == *"CompatibilityTestRun result: Pass"* ]]
}

@test "必須環境変数(MYSQL_PASSWORD)が欠落している場合、明確なエラーメッセージで停止する" {
	cd "${REPO_ROOT}"
	run env --unset=MYSQL_PASSWORD DB_SERVER_HOST=mysql.example.internal bash scripts/compat-test.sh
	[ "$status" -ne 0 ]
	[[ "$output" == *"MYSQL_PASSWORD"* ]]
	[[ "$output" == *"自動リトライは行いません"* ]]
}
