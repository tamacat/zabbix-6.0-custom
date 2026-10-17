#!/usr/bin/env bats
# scripts/build-agent2-binaries.sh のテスト。
#
# `docker` は常にテスト用スタブへ差し替え、実際のビルドは行わない(実ビルドは時間がかかり、
# Dockerが要る)。スタブは `docker cp` で、実際のビルドと同じ名前の成果物を書き出す。
# `python3` はpytestの実行にも必要な実依存であるため、実バイナリのタグ生成呼び出しを
# そのまま検証する。

setup() {
	REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
	TEST_TMPDIR="$(mktemp -d)"
	STUB_BIN="${TEST_TMPDIR}/bin"
	DOCKER_LOG="${TEST_TMPDIR}/docker.log"
	DIST="${TEST_TMPDIR}/dist"
	PREFIX="zabbix_agent2-6.0.48-b20260920"
	mkdir -p "${STUB_BIN}"

	# `docker cp <container>:/. <dest>/` は <dest> にアーカイブとSHA256SUMSを書き出す。
	# STUB_CP_EMPTY=1 のときは何も書かず、成果物が欠けた状態を再現する。
	cat > "${STUB_BIN}/docker" <<EOF
#!/usr/bin/env bash
echo "STUB docker \$*" >> "${DOCKER_LOG}"
case "\$1" in
	cp)
		if [ -z "\${STUB_CP_EMPTY:-}" ]; then
			dest="\${@: -1}"
			printf 'linux' > "\${dest}${PREFIX}-linux-amd64.tar.gz"
			printf 'windows' > "\${dest}${PREFIX}-windows-amd64.zip"
			(cd "\${dest}" && sha256sum "${PREFIX}-linux-amd64.tar.gz" "${PREFIX}-windows-amd64.zip" > SHA256SUMS)
		fi
		;;
esac
exit 0
EOF
	chmod +x "${STUB_BIN}/docker"

	# CI installs tools to /usr/local/bin; see tests/scripts/build-images.bats for why that is excluded here.
	export PATH="${STUB_BIN}:$(echo "${PATH}" | sed -e 's#:/usr/local/bin:#:#g' -e 's#^/usr/local/bin:##' -e 's#:/usr/local/bin$##')"

	# 開発者のローカル.env(バージョン管理対象外)があるとテストの前提が崩れるので、
	# テスト中は退避してCIと同じ「.envなし」の状態にする(build-images.bats と同じ理由)。
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
		DIST_DIR="${DIST}" \
		bash scripts/build-agent2-binaries.sh

	[ "$status" -ne 0 ]
	[[ "$output" == *"ZABBIX_SRC_DIR"* ]]
	[[ "$output" == *"自動リトライは行いません"* ]]
	# ビルドには進まない
	[ ! -f "${DOCKER_LOG}" ]
}

@test "必須環境変数ZABBIX_VERSION未設定時にエラーで停止する" {
	cd "${REPO_ROOT}"
	run env \
		--unset=ZABBIX_VERSION \
		ZABBIX_SRC_DIR="${TEST_TMPDIR}" \
		DIST_DIR="${DIST}" \
		bash scripts/build-agent2-binaries.sh

	[ "$status" -ne 0 ]
	[[ "$output" == *"ZABBIX_VERSION"* ]]
	[ ! -f "${DOCKER_LOG}" ]
}

@test "BUILD_DATEの形式が不正な場合、ビルドに進まず停止する" {
	cd "${REPO_ROOT}"
	run env \
		ZABBIX_SRC_DIR="${TEST_TMPDIR}" \
		ZABBIX_VERSION=6.0.48 \
		BUILD_DATE=2026-09-20 \
		DIST_DIR="${DIST}" \
		bash scripts/build-agent2-binaries.sh

	[ "$status" -ne 0 ]
	[[ "$output" == *"リリースタグの生成に失敗"* ]]
	[ ! -f "${DOCKER_LOG}" ]
}

@test "正常系: 成果物のステージをビルドし、アーカイブ2つとSHA256SUMSを書き出す" {
	cd "${REPO_ROOT}"
	run env \
		ZABBIX_SRC_DIR="${TEST_TMPDIR}" \
		ZABBIX_VERSION=6.0.48 \
		BUILD_DATE=20260920 \
		DIST_DIR="${DIST}" \
		bash scripts/build-agent2-binaries.sh

	[ "$status" -eq 0 ]
	[[ "$output" == *"リリースタグ: agent2-6.0.48-b20260920"* ]]
	[ -s "${DIST}/${PREFIX}-linux-amd64.tar.gz" ]
	[ -s "${DIST}/${PREFIX}-windows-amd64.zip" ]
	[ -s "${DIST}/SHA256SUMS" ]

	# 専用のDockerfileの成果物ステージを、アーカイブ名・バージョン・ビルド日付を渡してビルドする
	grep -q "STUB docker build .*-f docker/agent2-binaries/Dockerfile" "${DOCKER_LOG}"
	grep -q -- "--target artifacts" "${DOCKER_LOG}"
	grep -q -- "--build-arg ASSET_PREFIX=${PREFIX}" "${DOCKER_LOG}"
	grep -q -- "--build-arg ZABBIX_VERSION=6.0.48" "${DOCKER_LOG}"
	grep -q -- "--build-arg BUILD_DATE=20260920" "${DOCKER_LOG}"
}

@test "正常系でも、作った一時コンテナとイメージを片付ける" {
	cd "${REPO_ROOT}"
	run env \
		ZABBIX_SRC_DIR="${TEST_TMPDIR}" \
		ZABBIX_VERSION=6.0.48 \
		BUILD_DATE=20260920 \
		DIST_DIR="${DIST}" \
		bash scripts/build-agent2-binaries.sh

	[ "$status" -eq 0 ]
	grep -q "STUB docker rm -f zabbix-agent2-binaries-" "${DOCKER_LOG}"
	grep -q "STUB docker rmi -f localhost/zabbix-agent2-binaries:agent2-6.0.48-b20260920" "${DOCKER_LOG}"
}

@test "成果物が欠けている場合は失敗し、リトライしない(BR6.1)" {
	cd "${REPO_ROOT}"
	run env \
		STUB_CP_EMPTY=1 \
		ZABBIX_SRC_DIR="${TEST_TMPDIR}" \
		ZABBIX_VERSION=6.0.48 \
		BUILD_DATE=20260920 \
		DIST_DIR="${DIST}" \
		bash scripts/build-agent2-binaries.sh

	[ "$status" -ne 0 ]
	[[ "$output" == *"期待する成果物がありません"* ]]
	[[ "$output" == *"自動リトライは行いません"* ]]
	# 失敗時も一時コンテナ・イメージは片付ける
	grep -q "STUB docker rmi -f" "${DOCKER_LOG}"
}

@test "SHA256SUMSと実際のファイルが食い違う場合は失敗する" {
	cd "${REPO_ROOT}"
	# スタブのcpが書いたSHA256SUMSをこのテスト用に壊す: cp の後にファイルを書き換えるdockerスタブ
	cat > "${STUB_BIN}/docker" <<EOF
#!/usr/bin/env bash
echo "STUB docker \$*" >> "${DOCKER_LOG}"
if [ "\$1" = "cp" ]; then
	dest="\${@: -1}"
	printf 'linux' > "\${dest}${PREFIX}-linux-amd64.tar.gz"
	printf 'windows' > "\${dest}${PREFIX}-windows-amd64.zip"
	echo "0000000000000000000000000000000000000000000000000000000000000000  ${PREFIX}-linux-amd64.tar.gz" > "\${dest}SHA256SUMS"
fi
exit 0
EOF
	run env \
		ZABBIX_SRC_DIR="${TEST_TMPDIR}" \
		ZABBIX_VERSION=6.0.48 \
		BUILD_DATE=20260920 \
		DIST_DIR="${DIST}" \
		bash scripts/build-agent2-binaries.sh

	[ "$status" -ne 0 ]
	[[ "$output" == *"SHA256SUMS の検証に失敗"* ]]
}

@test "コンテナのルートごとではなく、成果物のファイルだけを取り出す(dev/ 等が dist に混ざらない)" {
	cd "${REPO_ROOT}"
	run env \
		ZABBIX_SRC_DIR="${TEST_TMPDIR}" \
		ZABBIX_VERSION=6.0.48 \
		BUILD_DATE=20260920 \
		DIST_DIR="${DIST}" \
		bash scripts/build-agent2-binaries.sh

	[ "$status" -eq 0 ]
	! grep -q "docker cp .*:/\. " "${DOCKER_LOG}"
	grep -q "docker cp .*:/${PREFIX}-linux-amd64.tar.gz" "${DOCKER_LOG}"
	grep -q "docker cp .*:/SHA256SUMS" "${DOCKER_LOG}"
	[ "$(ls "${DIST}" | wc -l)" -eq 3 ]
}
