#!/usr/bin/env bats
# scripts/check-php-version.sh のテスト。curl は常にテスト用スタブへ差し替え、実際のネットワーク
# アクセスはしない。

setup() {
	REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
	TEST_TMPDIR="$(mktemp -d)"
	STUB_BIN="${TEST_TMPDIR}/bin"
	mkdir -p "${STUB_BIN}"
	export PATH="${STUB_BIN}:$(echo "${PATH}" | sed -e 's#:/usr/local/bin:#:#g' -e 's#^/usr/local/bin:##' -e 's#:/usr/local/bin$##')"
	DOCKERFILE_COPY="${TEST_TMPDIR}/Dockerfile"
	printf 'ARG ALPINE_VERSION=3.24\nARG PHP_VERSION=8.3.36\nARG PHP_SHA256=abc\n' > "${DOCKERFILE_COPY}"
}

teardown() {
	rm -rf "${TEST_TMPDIR}"
}

# $1: curlが返すJSON、$2: 終了コード(省略時0)。呼ばれたURLを記録する。
stub_curl() {
	local json="$1" code="${2:-0}"
	cat > "${STUB_BIN}/curl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "${TEST_TMPDIR}/curl-calls.log"
cat <<'JSON'
${json}
JSON
exit ${code}
EOF
	chmod +x "${STUB_BIN}/curl"
}

@test "固定しているバージョンが最新なら成功する" {
	cd "${REPO_ROOT}"
	stub_curl '{"version": "8.3.36", "date": "21 Oct 2026"}'
	run env DOCKERFILE="${DOCKERFILE_COPY}" bash scripts/check-php-version.sh

	[ "$status" -eq 0 ]
	[[ "$output" == *"up to date"* ]]
	# 固定したバージョンの系列(8.3)を問い合わせる
	grep -q "version=8.3" "${TEST_TMPDIR}/curl-calls.log"
}

@test "同じ系列に新しいリリースがあれば失敗し、更新するファイルを案内する" {
	cd "${REPO_ROOT}"
	stub_curl '{"version": "8.3.37", "date": "05 Nov 2026"}'
	run env DOCKERFILE="${DOCKERFILE_COPY}" bash scripts/check-php-version.sh

	[ "$status" -ne 0 ]
	[[ "$output" == *"OUTDATED"* ]]
	[[ "$output" == *"8.3.37"* ]]
	[[ "$output" == *"PHP_SHA256"* ]]
}

@test "バージョンの比較は文字列順ではなくバージョン順(8.3.9 より 8.3.10 が新しい)" {
	cd "${REPO_ROOT}"
	printf 'ARG PHP_VERSION=8.3.9\n' > "${DOCKERFILE_COPY}"
	stub_curl '{"version": "8.3.10"}'
	run env DOCKERFILE="${DOCKERFILE_COPY}" bash scripts/check-php-version.sh

	[ "$status" -ne 0 ]
	[[ "$output" == *"OUTDATED"* ]]
}

@test "固定の方が新しい(php.netの情報が遅れている)場合は失敗しない" {
	cd "${REPO_ROOT}"
	stub_curl '{"version": "8.3.35"}'
	run env DOCKERFILE="${DOCKERFILE_COPY}" bash scripts/check-php-version.sh

	[ "$status" -eq 0 ]
}

@test "リリース情報を取得できない場合は、成功扱いにせず停止する(BR6.1)" {
	cd "${REPO_ROOT}"
	stub_curl '' 22
	run env DOCKERFILE="${DOCKERFILE_COPY}" bash scripts/check-php-version.sh

	[ "$status" -ne 0 ]
	[[ "$output" == *"取得できませんでした"* ]]
	[[ "$output" == *"自動リトライは行いません"* ]]
}

@test "応答にバージョンが含まれない場合は、成功扱いにせず停止する" {
	cd "${REPO_ROOT}"
	stub_curl '{"error": "Unknown version"}'
	run env DOCKERFILE="${DOCKERFILE_COPY}" bash scripts/check-php-version.sh

	[ "$status" -ne 0 ]
	[[ "$output" == *"解釈できませんでした"* ]]
}

@test "DockerfileにPHP_VERSIONが無い場合は停止する" {
	cd "${REPO_ROOT}"
	printf 'FROM alpine\n' > "${DOCKERFILE_COPY}"
	stub_curl '{"version": "8.3.36"}'
	run env DOCKERFILE="${DOCKERFILE_COPY}" bash scripts/check-php-version.sh

	[ "$status" -ne 0 ]
	[[ "$output" == *"ARG PHP_VERSION"* ]]
}

@test "実際のdocker/web/Dockerfileから、固定しているバージョンを読める" {
	cd "${REPO_ROOT}"
	stub_curl '{"version": "99.99.99"}'
	run bash scripts/check-php-version.sh

	[ "$status" -ne 0 ]
	[[ "$output" == *"Dockerfileの固定="* ]]
}
