#!/usr/bin/env bats
# scripts/build-images.sh のテスト。
#
# `docker` は常にテスト用スタブへ差し替え、実イメージビルドは行わない。
# `python3` はpytestの実行にも必要な実依存であるため、実バイナリのタグ生成呼び出しを
# そのまま検証する。

setup() {
	REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
	TEST_TMPDIR="$(mktemp -d)"
	STUB_BIN="${TEST_TMPDIR}/bin"
	mkdir -p "${STUB_BIN}"

	cat > "${STUB_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
echo "STUB docker $*"
exit 0
EOF
	chmod +x "${STUB_BIN}/docker"

	export PATH="${STUB_BIN}:${PATH}"

	# scripts/build-images.sh はスクリプト自身の配置場所からの相対パスで常に
	# REPO_ROOT/.env を探すため、開発者のローカル.env(バージョン管理対象外)が
	# たまたま存在すると、このテストが期待する「.envも環境変数も無い」状態を
	# 再現できない(build-and-test stage で発覚した実バグ: .envの存在有無に
	# テスト結果が左右されていた)。テスト中は一時的に退避し、確実にCIと同じ
	# 「.envなし」の状態でテストする。
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

@test "ZABBIX_SRC_DIRが存在しない場合、明確なエラーメッセージで停止する(BR6.1: 自動リトライなし)" {
	cd "${REPO_ROOT}"
	run env \
		ZABBIX_VERSION=6.0.48 \
		ZABBIX_SRC_DIR="${TEST_TMPDIR}/does-not-exist" \
		bash scripts/build-images.sh

	[ "$status" -ne 0 ]
	[[ "$output" == *"ZABBIX_SRC_DIR"* ]]
	[[ "$output" == *"自動リトライは行いません"* ]]
}

@test "必須環境変数ZABBIX_VERSION未設定時にエラーで停止する" {
	cd "${REPO_ROOT}"
	run env \
		--unset=ZABBIX_VERSION \
		ZABBIX_SRC_DIR="${TEST_TMPDIR}" \
		bash scripts/build-images.sh

	[ "$status" -ne 0 ]
	[[ "$output" == *"ZABBIX_VERSION"* ]]
}

@test "必須環境変数が揃っている場合、4コンポーネント分のタグ生成とdocker build呼び出しを行う" {
	cd "${REPO_ROOT}"
	run env \
		ZABBIX_SRC_DIR="${TEST_TMPDIR}" \
		ZABBIX_VERSION=6.0.48 \
		BUILD_DATE=20260920 \
		bash scripts/build-images.sh

	[ "$status" -eq 0 ]
	[[ "$output" == *"tamacat/zabbix-server:6.0.48-r20260920-amd64"* ]]
	[[ "$output" == *"tamacat/zabbix-web:6.0.48-r20260920-amd64"* ]]
	[[ "$output" == *"tamacat/zabbix-agent2:6.0.48-r20260920-amd64"* ]]
	[[ "$output" == *"tamacat/zabbix-proxy:6.0.48-r20260920-amd64"* ]]
	[[ "$output" == *"STUB docker build"* ]]
}
