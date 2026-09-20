#!/usr/bin/env bash
# ImagePublisher — BR3.1(4条件ゲート)・BR3.2(セルフレビュー承認)を確認した上で
# Docker Hubへ公開し、cosign keyless署名とSBOM添付を試みる
# [FR6.1][FR6.2]。
#
# 使用法:
#   scripts/push-images.sh \
#     --tag <イメージタグ> \
#     --sca <Pass|Fail> --sast <Pass|Fail> --compat <Pass|Fail> --secret <Clean|Blocked> \
#     [--sbom <SBOMファイルパス>] [--yes|--no]
#
# --yes/--no はBR3.2のセルフレビュー承認を非対話で指定する(CI/テスト向け)。
# 省略時は対話的に確認する。
#
# BR6.1: いずれかのゲートに未達な場合は公開処理へ進まない(自動リトライしない)。
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

fail() {
	echo "!! ERROR: $1" >&2
	echo "!! BR6.1: 自動リトライは行いません。原因を解消した上で本スクリプトを再実行してください。" >&2
	exit 1
}

TAG=""
SCA=""
SAST=""
COMPAT=""
SECRET=""
SBOM_FILE=""
CONFIRM_FLAG=""

while [ "$#" -gt 0 ]; do
	case "$1" in
		--tag) TAG="$2"; shift 2 ;;
		--sca) SCA="$2"; shift 2 ;;
		--sast) SAST="$2"; shift 2 ;;
		--compat) COMPAT="$2"; shift 2 ;;
		--secret) SECRET="$2"; shift 2 ;;
		--sbom) SBOM_FILE="$2"; shift 2 ;;
		--yes) CONFIRM_FLAG="--yes"; shift ;;
		--no) CONFIRM_FLAG="--no"; shift ;;
		*) fail "未知の引数です: $1" ;;
	esac
done

for required in TAG SCA SAST COMPAT SECRET; do
	eval "value=\${${required}:-}"
	if [ -z "${value}" ]; then
		fail "--${required,,} は必須です(使用法はスクリプト冒頭のコメントを参照)"
	fi
done

if python3 -c "import sys" >/dev/null 2>&1; then
	PY=python3
elif python -c "import sys" >/dev/null 2>&1; then
	PY=python
else
	fail "python3(またはpython)の実行可能なインタプリタが見つかりません"
fi

echo "=================================================================="
echo "BR3.1 公開前提条件ゲート判定"
echo "  SCA=${SCA}  SAST=${SAST}  Compat=${COMPAT}  Secret=${SECRET}"
echo "=================================================================="
if ! "${PY}" -m release_tools.cli publish-gate \
	--sca "${SCA}" --sast "${SAST}" --compat "${COMPAT}" --secret "${SECRET}"; then
	fail "BR3.1違反: 公開前提条件を満たしていません。未達の条件を解消してから再実行してください。"
fi
echo "BR3.1: 公開前提条件を満たしています。"

echo ""
echo "=================================================================="
echo "BR3.2 公開直前セルフレビュー承認"
echo "=================================================================="
if [ -n "${CONFIRM_FLAG}" ]; then
	if ! "${PY}" -m release_tools.cli confirm-publish "${CONFIRM_FLAG}"; then
		fail "BR3.2: セルフレビュー承認が得られなかったため、公開を保留します。"
	fi
else
	echo "公開対象タグ: ${TAG}"
	if ! "${PY}" -m release_tools.cli confirm-publish; then
		fail "BR3.2: セルフレビュー承認が得られなかったため、公開を保留します。"
	fi
fi
echo "BR3.2: セルフレビュー承認を確認しました。"

echo ""
echo "=================================================================="
echo "Docker Hubへ公開: ${TAG}"
echo "=================================================================="
docker push "${TAG}" || fail "docker push に失敗しました(${TAG})"

echo ""
echo "=================================================================="
echo "cosign keyless署名(公開後のレジストリダイジェストが対象)"
echo "=================================================================="
if ! command -v cosign >/dev/null 2>&1; then
	echo "!! WARNING: cosign が見つからないため署名をスキップします(ローカル実行時の想定内挙動)。"
	echo "!! CI(GitHub Actions OIDCコンテキスト)では必ずcosignを導入してください。"
elif [ -z "${GITHUB_ACTIONS:-}" ]; then
	echo "!! WARNING: GitHub Actions OIDCコンテキスト外での実行のため、keyless署名をスキップします。"
	echo "!! ローカル実行時は署名なしで公開のみ行われます(単独運用者が後でCI経由の再実行を検討してください)。"
else
	cosign sign --yes "${TAG}" \
		|| fail "cosign による署名に失敗しました(${TAG})。手動で再実行してください(BR6.1)。"
	echo "cosign署名が完了しました。"

	echo ""
	echo "=================================================================="
	echo "SBOM添付(cosign attest)"
	echo "=================================================================="
	if [ -z "${SBOM_FILE}" ]; then
		echo "!! WARNING: --sbom が指定されていないため、SBOM添付をスキップします。"
		echo "!! 公開前にSBOM生成(Trivy --format cyclonedx)を実行し、--sbomで渡してください。"
	else
		cosign attest --yes --type cyclonedx --predicate "${SBOM_FILE}" "${TAG}" \
			|| fail "cosign attest によるSBOM添付に失敗しました(${TAG})。手動で再実行してください(BR6.1)。"
		echo "SBOM添付が完了しました。"
	fi
fi

echo ""
echo "PublishedImage: ${TAG} を公開しました。"
