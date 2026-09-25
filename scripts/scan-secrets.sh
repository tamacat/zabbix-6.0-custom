#!/usr/bin/env bash
# SecretScanner(CI側)— gitleaksによる2つのサブステップを実行し、両方Cleanの場合のみ
# SecretScanRun(trigger=ci).result=Clean とする集約ロジック
# [FR5.4][NFR3](NFR3.1: シークレットスキャンの二重チェック)。
#
#   サブステップ1: Git差分・履歴スキャン(pre-commit側と同じ対象のCI側再確認)
#   サブステップ2: イメージレイヤースキャン(ビルド済みイメージのファイルシステム)
#
# 使用法: scripts/scan-secrets.sh <イメージ参照> [<イメージ参照> ...]
#
# BR6.1: 失敗時(ツール未インストール・いずれかのサブステップがBlocked)は
# 自動リトライを行わない。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail() {
	echo "!! ERROR: $1" >&2
	echo "!! BR6.1: 自動リトライは行いません。原因を解消した上で本スクリプトを再実行してください。" >&2
	exit 1
}

if [ "$#" -lt 1 ]; then
	fail "使用法: $0 <イメージ参照> [<イメージ参照> ...]"
fi

# `python3` という名前がPATH上に存在していても実際に動作するインタプリタとは限らない
# (build-images.sh等と同じ判定方式)。docker saveのmanifest.jsonを読むために使う。
if python3 -c "import sys" >/dev/null 2>&1; then
	PY=python3
elif python -c "import sys" >/dev/null 2>&1; then
	PY=python
else
	fail "python3(またはpython)の実行可能なインタプリタが見つかりません"
fi

if ! command -v gitleaks >/dev/null 2>&1; then
	fail "gitleaks が見つかりません。インストールしてから再実行してください(https://github.com/gitleaks/gitleaks)。"
fi

OVERALL_RESULT="Clean"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

echo "=================================================================="
echo "サブステップ1: Git差分・履歴スキャン"
echo "=================================================================="
GIT_REPORT="${WORKDIR}/gitleaks-git.json"
if gitleaks detect --source . --no-banner --report-format json --report-path "${GIT_REPORT}"; then
	echo "Git差分・履歴スキャン: Clean"
else
	echo "Git差分・履歴スキャン: Blocked"
	OVERALL_RESULT="Blocked"
fi

echo ""
echo "=================================================================="
echo "サブステップ2: イメージレイヤースキャン"
echo "=================================================================="
for image in "$@"; do
	image_workdir="${WORKDIR}/$(echo "${image}" | tr '/:' '__')"
	saved_dir="${image_workdir}/saved"
	rootfs="${image_workdir}/rootfs"
	mkdir -p "${saved_dir}" "${rootfs}"

	echo "---- ${image} ----"
	docker save "${image}" -o "${image_workdir}/image.tar" \
		|| fail "docker save に失敗しました(${image})"
	tar -xf "${image_workdir}/image.tar" -C "${saved_dir}" \
		|| fail "docker save の出力を展開できませんでした(${image})"
	[ -f "${saved_dir}/manifest.json" ] \
		|| fail "docker save の出力に manifest.json がありません(${image})。レイヤーを特定できないため、スキャンできません。"

	# レイヤーの場所は docker save の形式で異なる(<id>/layer.tar・<hash>.tar・blobs/sha256/<hash>)。
	# 固定のパターンで探すと新しい形式で1枚も見つからず、空のディレクトリをスキャンして
	# 「Clean」になってしまうため、必ず manifest.json のLayersから展開する。
	layer_count=0
	while IFS= read -r layer; do
		layer="${layer%$'\r'}" # Windows版Pythonはprintの行末にCRを付ける
		[ -n "${layer}" ] || continue
		[ -f "${saved_dir}/${layer}" ] || fail "manifest.json のレイヤー '${layer}' が見つかりません(${image})"
		# 特殊ファイル(デバイスノード等)の展開エラーは、スキャン対象の内容に影響しないため許容する。
		tar -xf "${saved_dir}/${layer}" -C "${rootfs}" 2>/dev/null || true
		layer_count=$((layer_count + 1))
	done < <("${PY}" -c 'import json, sys; [print(layer) for entry in json.load(open(sys.argv[1])) for layer in entry["Layers"]]' "${saved_dir}/manifest.json")
	[ "${layer_count}" -gt 0 ] || fail "イメージ '${image}' のレイヤーが1枚も展開されませんでした。空のディレクトリをスキャンしてClean扱いにしないよう、ここで停止します。"
	echo "  展開したレイヤー数: ${layer_count}"

	image_report="${image_workdir}/gitleaks-image.json"
	if gitleaks detect --source "${rootfs}" --no-git --no-banner \
		--report-format json --report-path "${image_report}"; then
		echo "イメージレイヤースキャン (${image}): Clean"
	else
		echo "イメージレイヤースキャン (${image}): Blocked"
		OVERALL_RESULT="Blocked"
	fi
done

echo ""
echo "=================================================================="
echo "SecretScanRun(trigger=ci) result: ${OVERALL_RESULT}"
echo "=================================================================="

[ "${OVERALL_RESULT}" = "Clean" ]
