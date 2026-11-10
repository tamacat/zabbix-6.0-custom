#!/usr/bin/env bats
# scripts/check-zabbix-version.sh のテスト。上流のタグ一覧は git ls-remote のスタブで与える。

setup() {
	REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
	TEST_TMPDIR="$(mktemp -d)"
	STUB_BIN="${TEST_TMPDIR}/bin"
	mkdir -p "${STUB_BIN}"
	ENV_FILE="${TEST_TMPDIR}/env"
	printf 'ZABBIX_VERSION=6.0.48\n' > "${ENV_FILE}"
	TAGS_FILE="${TEST_TMPDIR}/tags"
	SUMMARY_FILE="${TEST_TMPDIR}/summary.md"

	cat > "${STUB_BIN}/git" <<EOF
#!/bin/sh
if [ "\$1" = "ls-remote" ]; then
	echo "git \$*" >> "${TEST_TMPDIR}/git.log"
	[ -z "\${FAKE_GIT_FAIL:-}" ] || exit 128
	while read -r tag; do
		[ -n "\${tag}" ] && printf '0123456789abcdef0123456789abcdef01234567\trefs/tags/%s\n' "\${tag}"
	done < "${TAGS_FILE}"
	exit 0
fi
exec /usr/bin/git "\$@"
EOF
	chmod +x "${STUB_BIN}/git"
}

teardown() {
	rm -rf "${TEST_TMPDIR}"
}

run_check() {
	cd "${REPO_ROOT}"
	run env PATH="${STUB_BIN}:${PATH}" ENV_FILE="${ENV_FILE}" "$@" bash scripts/check-zabbix-version.sh
}

@test "取り込み済みが最新なら成功し、6.0系列のタグだけを問い合わせる" {
	printf '6.0.47\n6.0.48\n' > "${TAGS_FILE}"
	run_check
	[ "$status" -eq 0 ]
	[[ "$output" == *"up to date"* ]]
	grep -q "refs/tags/6.0.\*" "${TEST_TMPDIR}/git.log"
}

@test "新しい正式リリースがあれば失敗し、その版を示す" {
	printf '6.0.48\n6.0.49\n' > "${TAGS_FILE}"
	run_check
	[ "$status" -ne 0 ]
	[[ "$output" == *"OUTDATED"* ]]
	[[ "$output" == *"6.0.49"* ]]
}

@test "版の比較は文字列順ではなく数値順で行う(6.0.9 より 6.0.10 が新しい)" {
	printf 'ZABBIX_VERSION=6.0.9\n' > "${ENV_FILE}"
	printf '6.0.9\n6.0.10\n' > "${TAGS_FILE}"
	run_check
	[ "$status" -ne 0 ]
	[[ "$output" == *"上流の最新=6.0.10"* ]]
}

@test "プレリリース(rc・beta・alpha)は追従の対象にしない" {
	printf '6.0.48\n6.0.49rc1\n6.0.50alpha1\n6.0.50beta2\n' > "${TAGS_FILE}"
	run_check
	[ "$status" -eq 0 ]
	[[ "$output" == *"up to date"* ]]
}

@test "取り込み済みの方が新しい場合(タグの反映が遅れている)は古いとは言わない" {
	printf 'ZABBIX_VERSION=6.0.50\n' > "${ENV_FILE}"
	printf '6.0.48\n6.0.49\n' > "${TAGS_FILE}"
	run_check
	[ "$status" -eq 0 ]
	[[ "$output" == *"up to date"* ]]
}

@test "タグを取得できない・正式リリースが1つも無い場合は、成功扱いにせず停止する(BR6.1)" {
	printf '6.0.48\n' > "${TAGS_FILE}"
	run_check FAKE_GIT_FAIL=1
	[ "$status" -ne 0 ]
	[[ "$output" == *"取得できませんでした"* ]]

	: > "${TAGS_FILE}"
	run_check
	[ "$status" -ne 0 ]
	[[ "$output" == *"タグが1つもありません"* ]]

	printf '6.0.49rc1\n' > "${TAGS_FILE}"
	run_check
	[ "$status" -ne 0 ]
	[[ "$output" == *"正式リリースのタグがありません"* ]]
}

@test "取り込み済みのバージョンが X.Y.Z でなければ停止する" {
	printf 'ZABBIX_VERSION=6.0.48rc1\n' > "${ENV_FILE}"
	printf '6.0.49\n' > "${TAGS_FILE}"
	run_check
	[ "$status" -ne 0 ]
	[[ "$output" == *"X.Y.Z の形式ではありません"* ]]
}

@test "GITHUB_STEP_SUMMARY があれば、結果の表を書き足す" {
	printf '6.0.48\n6.0.49\n' > "${TAGS_FILE}"
	run_check GITHUB_STEP_SUMMARY="${SUMMARY_FILE}"
	[ "$status" -ne 0 ]
	grep -q "| 6.0 | 6.0.48 | 6.0.49 |" "${SUMMARY_FILE}"
	grep -q "更新があります" "${SUMMARY_FILE}"

	printf '6.0.48\n' > "${TAGS_FILE}"
	run_check GITHUB_STEP_SUMMARY="${SUMMARY_FILE}"
	[ "$status" -eq 0 ]
	grep -q "最新です" "${SUMMARY_FILE}"
}

@test "実際の .env.example から取り込み済みのバージョンを読める" {
	printf '6.0.48\n' > "${TAGS_FILE}"
	cd "${REPO_ROOT}"
	run env PATH="${STUB_BIN}:${PATH}" bash scripts/check-zabbix-version.sh
	[[ "$output" == *"取り込み済み="* ]]
}
