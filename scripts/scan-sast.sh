#!/usr/bin/env bash
# ScanRunner(SAST)— Semgrep(PHP/JS対象)とcppcheck(C言語対象)でパッチ対象ソースを
# 静的解析し、VulnerabilityRegistryのwaiver状態と突合してBR2.1のゲート判定を行う
# [FR5.2]。
#
# 使用法: scripts/scan-sast.sh [<ソースディレクトリ>]
#   省略時は ZABBIX_SRC_DIR(既定: sources/zabbix-6.0.48)を対象とする。
#
# BR6.1: 失敗時(ツール未インストール・ソース未存在・いずれかのゲートFail)は
# 自動リトライを行わない。SemgrepとcppcheckはそれぞれのScanRunとして独立に判定し、
# いずれか一方でもFailなら本スクリプト全体をFailとする。
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
SOURCE_DIR="${1:-${ZABBIX_SRC_DIR:-sources/zabbix-6.0.48}}"

fail() {
	echo "!! ERROR: $1" >&2
	echo "!! BR6.1: 自動リトライは行いません。原因を解消した上で本スクリプトを再実行してください。" >&2
	exit 1
}

if python3 -c "import sys" >/dev/null 2>&1; then
	PY=python3
elif python -c "import sys" >/dev/null 2>&1; then
	PY=python
else
	fail "python3(またはpython)の実行可能なインタプリタが見つかりません"
fi

if ! command -v semgrep >/dev/null 2>&1; then
	fail "semgrep が見つかりません。インストールしてから再実行してください(https://semgrep.dev/)。"
fi
if ! command -v cppcheck >/dev/null 2>&1; then
	fail "cppcheck が見つかりません。インストールしてから再実行してください。"
fi
if [ ! -d "${SOURCE_DIR}" ]; then
	fail "ソースディレクトリ '${SOURCE_DIR}' が見つかりません。Zabbix 6.0ソースをまだ追加していない可能性があります。"
fi

SEMGREP_OUTPUT="$(mktemp)"
CPPCHECK_OUTPUT="$(mktemp)"
trap 'rm -f "${SEMGREP_OUTPUT}" "${CPPCHECK_OUTPUT}"' EXIT

OVERALL_STATUS=0

echo "=================================================================="
echo "SAST scan (Semgrep, PHP/JS): ${SOURCE_DIR}"
echo "=================================================================="
semgrep scan --config auto --json --output "${SEMGREP_OUTPUT}" "${SOURCE_DIR}" \
	|| fail "semgrep scan の実行に失敗しました"

echo "---- ScanRunner ゲート判定(BR2.1, Semgrep) ----"
SEMGREP_STATUS=0
"${PY}" -m release_tools.cli scan-gate \
	--tool semgrep \
	--input "${SEMGREP_OUTPUT}" \
	--registry "${REGISTRY_PATH}" \
	|| SEMGREP_STATUS=$?
if [ "${SEMGREP_STATUS}" -eq 0 ]; then
	echo "Semgrep verdict: Pass"
else
	echo "Semgrep verdict: Fail"
	OVERALL_STATUS=1
fi

echo ""
echo "=================================================================="
echo "SAST scan (cppcheck, C): ${SOURCE_DIR}"
echo "=================================================================="
cppcheck --xml --xml-version=2 --enable=warning,style,performance,portability "${SOURCE_DIR}" \
	2> "${CPPCHECK_OUTPUT}" \
	|| fail "cppcheck の実行に失敗しました"

echo "---- ScanRunner ゲート判定(BR2.1, cppcheck) ----"
CPPCHECK_STATUS=0
"${PY}" -m release_tools.cli scan-gate \
	--tool cppcheck \
	--input "${CPPCHECK_OUTPUT}" \
	--registry "${REGISTRY_PATH}" \
	|| CPPCHECK_STATUS=$?
if [ "${CPPCHECK_STATUS}" -eq 0 ]; then
	echo "cppcheck verdict: Pass"
else
	echo "cppcheck verdict: Fail"
	OVERALL_STATUS=1
fi

echo ""
echo "=================================================================="
if [ "${OVERALL_STATUS}" -eq 0 ]; then
	echo "SAST verdict: Pass"
else
	echo "SAST verdict: Fail"
fi
echo "=================================================================="

exit "${OVERALL_STATUS}"
