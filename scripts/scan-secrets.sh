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
	mkdir -p "${image_workdir}/extracted"

	echo "---- ${image} ----"
	docker save "${image}" -o "${image_workdir}/image.tar" \
		|| fail "docker save に失敗しました(${image})"
	tar -xf "${image_workdir}/image.tar" -C "${image_workdir}/extracted"

	# OCI/Dockerイメージのレイヤーtarを展開し、ファイルシステム内容をまとめてスキャン対象にする。
	for layer in "${image_workdir}/extracted"/*/layer.tar; do
		[ -f "${layer}" ] || continue
		tar -xf "${layer}" -C "${image_workdir}/extracted" 2>/dev/null || true
	done

	image_report="${image_workdir}/gitleaks-image.json"
	if gitleaks detect --source "${image_workdir}/extracted" --no-git --no-banner \
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
