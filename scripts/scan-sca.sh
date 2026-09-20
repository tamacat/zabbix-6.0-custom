#!/usr/bin/env bash
# ScanRunner(SCA)— Trivyでビルド済みイメージをスキャンし、VulnerabilityRegistryの
# waiver状態と突合してBR2.1のゲート判定を行う
# [FR5.1]。
#
# 使用法: scripts/scan-sca.sh <イメージ参照> [追加のtrivy引数...]
#   例:   scripts/scan-sca.sh tamacat/zabbix-server:6.0.48-r20260920-amd64
#
# BR6.1: 失敗時(ツール未インストール・イメージ未存在・ゲートFail)は自動リトライを行わない。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# .envは既定値のみを補う。既に環境変数としてexportされている値を上書きしない。
if [ -f .env ]; then
	while IFS='=' read -r _env_key _env_val; do
		if [ -z "${!_env_key+x}" ]; then
			export "${_env_key}=${_env_val}"
		fi
	done < <(grep -Ev '^[[:space:]]*(#|$)' .env)
fi

REGISTRY_PATH="${REGISTRY_PATH:-data/vulnerability-registry.yaml}"

fail() {
	echo "!! ERROR: $1" >&2
	echo "!! BR6.1: 自動リトライは行いません。原因を解消した上で本スクリプトを再実行してください。" >&2
	exit 1
}

if [ "$#" -lt 1 ]; then
	fail "使用法: $0 <イメージ参照> [追加のtrivy引数...]"
fi
IMAGE_REF="$1"
shift

if python3 -c "import sys" >/dev/null 2>&1; then
	PY=python3
elif python -c "import sys" >/dev/null 2>&1; then
	PY=python
else
	fail "python3(またはpython)の実行可能なインタプリタが見つかりません"
fi

if ! command -v trivy >/dev/null 2>&1; then
	fail "trivy が見つかりません。インストールしてから再実行してください(https://aquasecurity.github.io/trivy/)。"
fi

if ! docker image inspect "${IMAGE_REF}" >/dev/null 2>&1; then
	fail "イメージ '${IMAGE_REF}' が見つかりません。先に scripts/build-images.sh でビルドしてください。"
fi

TRIVY_OUTPUT="$(mktemp)"
trap 'rm -f "${TRIVY_OUTPUT}"' EXIT

echo "=================================================================="
echo "SCA scan (Trivy): ${IMAGE_REF}"
echo "=================================================================="
trivy image --format json --output "${TRIVY_OUTPUT}" "$@" "${IMAGE_REF}" \
	|| fail "trivy image の実行に失敗しました(${IMAGE_REF})"

echo "---- ScanRunner ゲート判定(BR2.1) ----"
VERDICT_STATUS=0
"${PY}" -m release_tools.cli scan-gate \
	--tool trivy \
	--input "${TRIVY_OUTPUT}" \
	--registry "${REGISTRY_PATH}" \
	|| VERDICT_STATUS=$?

if [ "${VERDICT_STATUS}" -eq 0 ]; then
	echo "SCA verdict: Pass"
else
	echo "SCA verdict: Fail"
fi

exit "${VERDICT_STATUS}"
