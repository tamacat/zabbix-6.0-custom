#!/usr/bin/env bash
# ScanRunner(SCA, Go)— scripts/build-agent2-binaries.sh が書き出したLinux版・Windows版の
# zabbix_agent2を、govulncheckで解析し、VulnerabilityRegistryのwaiver状態と突合してBR2.1の
# ゲート判定を行う。コンテナイメージ向けの scan-go-vuln.sh と同じ解析・同じゲートを、アーカイブの
# 中のバイナリに対して行う(Linux版・Windows版の両方が対象。Windows版はPE形式のバイナリ)。
#
# govulncheck はGoのコードの脆弱性(標準ライブラリ・依存モジュール)を見る。バイナリに静的リンク
# されたC言語のライブラリ(OpenSSL・PCRE2・libiconv など)は見ないので、それらはDockerfileに
# 固定したバージョンを、上流のセキュリティ情報で定期的に確認する(README.md参照)。
#
# 使用法: scripts/scan-agent2-binaries.sh [<成果物のディレクトリ>]
#   既定は ${DIST_DIR:-dist}。そこに <prefix>-linux-amd64.tar.gz と <prefix>-windows-amd64.zip が
#   1つずつあること。
#
# BR6.1: 失敗時(ツール未インストール・成果物なし・ゲートFail)は自動リトライを行わない。
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
DIST_DIR="${1:-${DIST_DIR:-dist}}"

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

if ! command -v govulncheck >/dev/null 2>&1; then
	fail "govulncheck が見つかりません。インストールしてから再実行してください(go install golang.org/x/vuln/cmd/govulncheck@latest。Go 1.26以上が必要)。"
fi

[ -d "${DIST_DIR}" ] || fail "成果物のディレクトリがありません: ${DIST_DIR}(先に scripts/build-agent2-binaries.sh を実行してください)"

# <prefix>-<os>-amd64.<拡張子> を1つずつ探す。複数あると、どれを検査したのか曖昧になるので止める。
find_one() {
	local pattern="$1" matches=()
	shopt -s nullglob
	# shellcheck disable=SC2206 # ${pattern} はglobとして展開させる(nullglobで、一致なしは空の配列)
	matches=("${DIST_DIR}"/${pattern})
	shopt -u nullglob
	[ "${#matches[@]}" -eq 1 ] || fail "${DIST_DIR} に '${pattern}' がちょうど1つ必要です(見つかった数: ${#matches[@]})"
	echo "${matches[0]}"
}
LINUX_ARCHIVE="$(find_one 'zabbix_agent2-*-linux-amd64.tar.gz')"
WINDOWS_ARCHIVE="$(find_one 'zabbix_agent2-*-windows-amd64.zip')"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

# アーカイブの名前から、中のバイナリのパスを決める(build-agent2-binaries.sh の配置と同じ)。
scan_one() { # scan_one <ラベル> <アーカイブ> <アーカイブ内のバイナリのパス>
	local label="$1" archive="$2" inner="$3" binary="${WORKDIR}/${1}.bin" report="${WORKDIR}/${1}.json" status=0

	echo "=================================================================="
	echo "Go vulnerability scan (govulncheck): ${label} — $(basename "${archive}")"
	echo "=================================================================="

	"${PY}" -m release_tools.cli extract-archive-file \
		--archive "${archive}" --path "${inner}" --output "${binary}" \
		|| fail "アーカイブ内のバイナリ '${inner}' を取り出せませんでした(${archive})"

	# `-format json` は脆弱性があっても終了コード0で終わるため、終了コードではなく出力で判定する。
	# 終了コードが非0のときは、解析自体の失敗(DB取得失敗・バイナリがGoでない等)として止める。
	govulncheck -mode=binary -format json "${binary}" > "${report}" \
		|| fail "govulncheck の実行に失敗しました(${label})。脆弱性DB(vuln.go.dev)へ到達できているか確認してください。"

	echo "---- ScanRunner ゲート判定(BR2.1, govulncheck, ${label}) ----"
	"${PY}" -m release_tools.cli scan-gate \
		--tool govulncheck \
		--input "${report}" \
		--registry "${REGISTRY_PATH}" \
		|| status=$?
	if [ "${status}" -eq 0 ]; then
		echo "Go vulnerability verdict (${label}): Pass"
	else
		echo "Go vulnerability verdict (${label}): Fail"
	fi
	return "${status}"
}

linux_prefix="$(basename "${LINUX_ARCHIVE}" -linux-amd64.tar.gz)"
windows_prefix="$(basename "${WINDOWS_ARCHIVE}" -windows-amd64.zip)"

# どちらかがFailでも、両方の結果が見えるよう、両方を検査してから終了コードを決める。
OVERALL=0
scan_one linux "${LINUX_ARCHIVE}" "${linux_prefix}-linux-amd64/sbin/zabbix_agent2" || OVERALL=1
scan_one windows "${WINDOWS_ARCHIVE}" "${windows_prefix}-windows-amd64/bin/zabbix_agent2.exe" || OVERALL=1

if [ "${OVERALL}" -eq 0 ]; then
	echo "Go vulnerability verdict (all binaries): Pass"
else
	echo "Go vulnerability verdict (all binaries): Fail"
fi
exit "${OVERALL}"
