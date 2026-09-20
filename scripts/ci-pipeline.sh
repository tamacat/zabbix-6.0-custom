#!/usr/bin/env bash
# ci-pipeline.sh — CI検証パイプライン(BuildPipeline→ScanRunner(SCA)→ScanRunner(SAST)→
# SecretScanner→SBOM生成→CompatibilityTestRunner→公開前提条件ゲート判定〈BR3.1〉)を
# ローカル・CI(GitHub Actions)の両方から同じ手順で再現するオーケストレーションスクリプト。
#
# lintはpre-commit/CI別ジョブの役割、公開・署名・SBOM添付(BR3.2のセルフレビュー承認含む)
# は scripts/push-images.sh のスコープであり、本スクリプトは検証ステージのみを担当する。
#
# BR6.1: いずれかのゲートがFailした時点で即座に停止する(自動リトライしない)。
# SCA(コンポーネントごと)・SAST(Semgrep/cppcheck)と同様に、複数コンポーネントの
# SCA結果は全件実行してから判定する(最初の1件で打ち切らず、診断情報を最大化する)。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# .envは既定値のみを補う。既に環境変数としてexportされている値を上書きしない
# (build-images.sh等と同じ方式。build-and-test stageで発覚した「単純なsource .envは
# 呼び出し側が明示的に渡した値を無視してしまう」バグを踏襲しない)。
if [ -f .env ]; then
	while IFS='=' read -r _env_key _env_val; do
		if [ -z "${!_env_key+x}" ]; then
			export "${_env_key}=${_env_val}"
		fi
	done < <(grep -Ev '^[[:space:]]*(#|$)' .env)
fi

ZABBIX_VERSION="${ZABBIX_VERSION:-}"
BUILD_DATE="${BUILD_DATE:-$(date -u +%Y%m%d)}"
IMAGE_ARCH="${IMAGE_ARCH:-amd64}"
SBOM_DIR="${SBOM_DIR:-$(mktemp -d)}"

fail() {
	echo "!! ERROR: $1" >&2
	echo "!! BR6.1: 自動リトライは行いません。原因を解消した上で本スクリプトを再実行してください。" >&2
	exit 1
}

# `python3` という名前がPATH上に存在していても実際に動作するインタプリタとは限らない
# (build-images.sh等と同じ判定方式)。
if python3 -c "import sys" >/dev/null 2>&1; then
	PY=python3
elif python -c "import sys" >/dev/null 2>&1; then
	PY=python
else
	fail "python3(またはpython)の実行可能なインタプリタが見つかりません"
fi

if [ -z "${ZABBIX_VERSION}" ]; then
	fail "ZABBIX_VERSION が設定されていません(.env または環境変数で指定してください。例: ZABBIX_VERSION=6.0.48)"
fi

if ! command -v trivy >/dev/null 2>&1; then
	fail "trivy が見つかりません。インストールしてから再実行してください(https://aquasecurity.github.io/trivy/)。"
fi

# docker/<dir>/ : component_name の対応表(build-images.shと同じ4コンポーネント)。
COMPONENTS=(
	"server:zabbix-server"
	"web:zabbix-web"
	"agent2:zabbix-agent2"
	"proxy:zabbix-proxy"
)

echo "=================================================================="
echo "ci-pipeline: 検証ステージ(3-9)を開始します"
echo "  ZABBIX_VERSION=${ZABBIX_VERSION}  BUILD_DATE=${BUILD_DATE}  ARCH=${IMAGE_ARCH}"
echo "=================================================================="

echo ""
echo "=================================================================="
echo "Step 3/9: BuildPipeline"
echo "=================================================================="
./scripts/build-images.sh || fail "ビルドに失敗しました"

TAGS=()
for pair in "${COMPONENTS[@]}"; do
	component_name="${pair#*:}"
	tag="$("${PY}" -m release_tools.cli generate-tag \
		--component "${component_name}" \
		--zabbix-version "${ZABBIX_VERSION}" \
		--build-date "${BUILD_DATE}" \
		--arch "${IMAGE_ARCH}")" || fail "タグ生成に失敗しました(${component_name})"
	TAGS+=("${tag}")
done

echo ""
echo "=================================================================="
echo "Step 4/9: ScanRunner(SCA) — ${#TAGS[@]}コンポーネント"
echo "=================================================================="
SCA_STATUS=0
for tag in "${TAGS[@]}"; do
	./scripts/scan-sca.sh "${tag}" || SCA_STATUS=$?
done
[ "${SCA_STATUS}" -eq 0 ] || fail "SCAスキャンでFail判定が出ました(上記ログ参照)"

echo ""
echo "=================================================================="
echo "Step 5/9: ScanRunner(SAST)"
echo "=================================================================="
./scripts/scan-sast.sh || fail "SASTスキャンでFail判定が出ました(上記ログ参照)"

echo ""
echo "=================================================================="
echo "Step 6/9: SecretScanner(CI) — Git差分・履歴 + イメージレイヤー(${#TAGS[@]}件)"
echo "=================================================================="
./scripts/scan-secrets.sh "${TAGS[@]}" || fail "シークレットスキャンでBlocked判定が出ました(上記ログ参照)"

echo ""
echo "=================================================================="
echo "Step 7/9: SBOM生成(Trivy --format cyclonedx)"
echo "=================================================================="
mkdir -p "${SBOM_DIR}"
for tag in "${TAGS[@]}"; do
	sbom_file="${SBOM_DIR}/$(echo "${tag}" | tr '/:' '__').cyclonedx.json"
	trivy image --format cyclonedx --output "${sbom_file}" "${tag}" \
		|| fail "SBOM生成に失敗しました(${tag})"
	echo "  -> ${sbom_file}"
done

echo ""
echo "=================================================================="
echo "Step 8/9: CompatibilityTestRunner"
echo "=================================================================="
./scripts/compat-test.sh || fail "互換性テストに失敗しました"

echo ""
echo "=================================================================="
echo "Step 9/9: 公開前提条件ゲート判定(BR3.1)"
echo "=================================================================="
if ! "${PY}" -m release_tools.cli publish-gate \
	--sca Pass --sast Pass --compat Pass --secret Clean; then
	fail "BR3.1: 公開前提条件を満たしていません(このスクリプト内の各ゲートはすべてPassしているはずのため、到達した場合はロジックの不整合を疑ってください)"
fi

echo ""
echo "=================================================================="
echo "ci-pipeline: 検証ステージ(3-9)がすべてPassしました。"
echo "公開・署名・SBOM添付(ステージ10-13)は scripts/push-images.sh で別途実行してください。"
echo "生成されたタグ:"
printf '  %s\n' "${TAGS[@]}"
echo "SBOM_DIR=${SBOM_DIR}"
echo "=================================================================="
