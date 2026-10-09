#!/usr/bin/env bash
# ScanRunner(SCA, Go)— ビルド済みイメージ内のGoバイナリ(zabbix_agent2)をgovulncheckで解析し、
# VulnerabilityRegistryのwaiver状態と突合してBR2.1のゲート判定を行う。
#
# Trivyは依存モジュールとGo標準ライブラリのバージョンを自前のDBと照合するが、Go公式の脆弱性DB
# (vuln.go.dev)の反映が遅れ、Goの新しいパッチリリースで公開された標準ライブラリの脆弱性を見逃す
# ことがある(go1.26.8の9件はTrivyで0件だった)。govulncheckはGo公式のDBで、バイナリが実際に
# 呼び出すコード(関数レベル)だけを判定するため、Trivyの死角を補う2つ目のSCAとして使う。
#
# 使用法: scripts/scan-go-vuln.sh <イメージ参照> [<イメージ内のバイナリのパス>]
#   例:   scripts/scan-go-vuln.sh tamacat/zabbix-agent2:6.0.48-alpine-b20261008
#         (パスの既定は usr/sbin/zabbix_agent2)
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
	fail "使用法: $0 <イメージ参照> [<イメージ内のバイナリのパス>]"
fi
IMAGE_REF="$1"
BINARY_PATH="${2:-usr/sbin/zabbix_agent2}"

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

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

echo "=================================================================="
echo "Go vulnerability scan (govulncheck): ${IMAGE_REF} (${BINARY_PATH})"
echo "=================================================================="

docker save "${IMAGE_REF}" -o "${WORKDIR}/image.tar" \
	|| fail "docker save に失敗しました(${IMAGE_REF})。先に scripts/build-images.sh でビルドしてください。"
"${PY}" -m release_tools.cli extract-image-file \
	--tar "${WORKDIR}/image.tar" --path "${BINARY_PATH}" --output "${WORKDIR}/binary" \
	|| fail "イメージ内のバイナリ '${BINARY_PATH}' を取り出せませんでした(${IMAGE_REF})"

# `-format json` は脆弱性があっても終了コード0で終わるため、終了コードではなく出力で判定する。
# 終了コードが非0のときは、解析自体の失敗(DB取得失敗・バイナリがGoでない等)として止める。
govulncheck -mode=binary -format json "${WORKDIR}/binary" > "${WORKDIR}/govulncheck.json" \
	|| fail "govulncheck の実行に失敗しました(${IMAGE_REF})。脆弱性DB(vuln.go.dev)へ到達できているか確認してください。"

echo "---- ScanRunner ゲート判定(BR2.1, govulncheck) ----"
VERDICT_STATUS=0
"${PY}" -m release_tools.cli scan-gate \
	--tool govulncheck \
	--input "${WORKDIR}/govulncheck.json" \
	--registry "${REGISTRY_PATH}" \
	|| VERDICT_STATUS=$?

if [ "${VERDICT_STATUS}" -eq 0 ]; then
	echo "Go vulnerability verdict: Pass"
else
	echo "Go vulnerability verdict: Fail"
fi

exit "${VERDICT_STATUS}"
