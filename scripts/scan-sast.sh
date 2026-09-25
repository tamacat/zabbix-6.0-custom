#!/usr/bin/env bash
# ScanRunner(SAST)— Semgrep(PHP/JS等)とcppcheck(C言語)でソースを静的解析し、
# 既知の指摘(baseline)を超える「新規の指摘」だけをVulnerabilityRegistryのwaiver状態と
# 突合してBR2.1のゲート判定にかける [FR5.2]。
#
# 使用法: scripts/scan-sast.sh [--scope patched|full] [--update-baseline] [<ソースディレクトリ>]
#   省略時のソースディレクトリは ZABBIX_SRC_DIR(既定: sources/zabbix-6.0.48)。
#
#   --scope patched(既定) 上流の初回インポート(data/upstream-import-ref)から変更された
#                         ファイル(サードパーティのvendor配下を除く)だけを解析する。
#                         push/PRのゲート用。環境変数 SAST_SCOPE でも指定できる。
#   --scope full          ソースツリー全体(サードパーティのvendor配下を除く)を解析する
#                         (定期実行・手動実行用)。vendor配下は依存関係スキャン(SCA)の対象。
#   --update-baseline     ゲート判定の代わりに、全体スキャンの結果を data/sast-baseline/ へ
#                         書き出す。上流に元からある指摘を人が確認・承認した上で実行し、
#                         差分をレビューしてからコミットすること。
#
# baselineはツール・ルール・ファイル・メッセージ単位の件数(行番号を含まない)。上流の既存の
# 指摘は許容し、パッチや依存更新で増えた指摘だけがFailになる。CVE/GHSA IDと相関しない
# cppcheckの指摘はwaiverできず、baselineを超えれば無条件でFailとなる。
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
SAST_BASELINE_DIR="${SAST_BASELINE_DIR:-data/sast-baseline}"
UPSTREAM_IMPORT_REF_FILE="${UPSTREAM_IMPORT_REF_FILE:-data/upstream-import-ref}"
SAST_SCOPE="${SAST_SCOPE:-patched}"
UPDATE_BASELINE=0
SOURCE_DIR_ARG=""

fail() {
	echo "!! ERROR: $1" >&2
	echo "!! BR6.1: 自動リトライは行いません。原因を解消した上で本スクリプトを再実行してください。" >&2
	exit 1
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--scope)
			[ "$#" -ge 2 ] || fail "--scope には patched または full を指定してください"
			SAST_SCOPE="$2"
			shift 2
			;;
		--update-baseline)
			UPDATE_BASELINE=1
			shift
			;;
		-*)
			fail "不明なオプションです: $1"
			;;
		*)
			SOURCE_DIR_ARG="$1"
			shift
			;;
	esac
done

SOURCE_DIR="${SOURCE_DIR_ARG:-${ZABBIX_SRC_DIR:-sources/zabbix-6.0.48}}"

case "${SAST_SCOPE}" in
	patched | full) ;;
	*) fail "SAST_SCOPE は patched または full でなければなりません: '${SAST_SCOPE}'" ;;
esac
# baselineの更新は「ツリー全体の既知の指摘」を記録するものなので、常に全体スキャンで行う。
if [ "${UPDATE_BASELINE}" -eq 1 ]; then
	SAST_SCOPE=full
fi

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

# 解消済みbaselineの通知は、ツリー全体をスキャンしたときだけ意味がある(patchedでは一部しか見ない)。
STALE_ARGS=()
if [ "${SAST_SCOPE}" = "full" ]; then
	STALE_ARGS=(--report-stale)
fi

SEMGREP_BASELINE="${SAST_BASELINE_DIR}/semgrep.json"
CPPCHECK_BASELINE="${SAST_BASELINE_DIR}/cppcheck.json"
if [ "${UPDATE_BASELINE}" -eq 0 ]; then
	for baseline in "${SEMGREP_BASELINE}" "${CPPCHECK_BASELINE}"; do
		[ -f "${baseline}" ] || fail "baseline '${baseline}' が見つかりません。上流の既存の指摘を確認した上で scripts/scan-sast.sh --update-baseline で作成してください。"
	done
fi

SEMGREP_OUTPUT="$(mktemp)"
CPPCHECK_OUTPUT="$(mktemp)"
PATCHED_LIST="$(mktemp)"
trap 'rm -f "${SEMGREP_OUTPUT}" "${CPPCHECK_OUTPUT}" "${PATCHED_LIST}"' EXIT

# --- 解析対象(パッチ対象ファイル)の決定 ---------------------------------------
SEMGREP_TARGET_ARGS=("${SOURCE_DIR}")
CPPCHECK_TARGETS=("${SOURCE_DIR}")
RUN_SEMGREP=1
RUN_CPPCHECK=1

if [ "${SAST_SCOPE}" = "patched" ]; then
	[ -f "${UPSTREAM_IMPORT_REF_FILE}" ] || fail "'${UPSTREAM_IMPORT_REF_FILE}' が見つかりません(上流の初回インポートのコミットを1行で記録するファイルです)。"
	IMPORT_REF="$(tr -d '[:space:]' < "${UPSTREAM_IMPORT_REF_FILE}")"
	if ! git cat-file -e "${IMPORT_REF}^{commit}" 2>/dev/null; then
		fail "上流の初回インポート ${IMPORT_REF} がこのcloneに存在しません。浅いcloneの可能性があります(CIのcheckoutは fetch-depth: 0 が必要です)。"
	fi
	# 変更(追加・変更・改名)されたファイル。作業ツリーの未コミット変更・未追跡ファイルも含める。
	# サードパーティのvendor配下は依存関係スキャン(SCA)の対象であり、SASTの対象外とする。
	# gitコマンドの失敗を「変更ファイルなし=Pass」と取り違えないよう、パイプの外で終了コードを見る。
	CHANGED_TRACKED="$(git diff --name-only --diff-filter=AMR "${IMPORT_REF}" -- "${SOURCE_DIR}")" \
		|| fail "変更ファイルの取得(git diff)に失敗しました。'${SOURCE_DIR}' がこのリポジトリ内にあるか確認してください。"
	CHANGED_UNTRACKED="$(git ls-files --others --exclude-standard -- "${SOURCE_DIR}")" \
		|| fail "未追跡ファイルの取得(git ls-files)に失敗しました。"
	# grepは1行も残らないとき終了コード1を返すため、`|| true` はこの1段にだけ付ける。
	printf '%s\n%s\n' "${CHANGED_TRACKED}" "${CHANGED_UNTRACKED}" \
		| sed '/^$/d' | sort -u | { grep -Ev '(^|/)vendor/' || true; } > "${PATCHED_LIST}"

	echo "=================================================================="
	echo "SAST scope: patched(上流インポート ${IMPORT_REF:0:12} からの変更ファイル: $(wc -l < "${PATCHED_LIST}" | tr -d ' ')件)"
	sed 's/^/  /' "${PATCHED_LIST}"
	echo "=================================================================="

	SEMGREP_TARGET_ARGS=("${SOURCE_DIR}")
	CPPCHECK_TARGETS=()
	while IFS= read -r patched_file; do
		# --include は全体スキャンと同じ .semgrepignore/git追跡の扱いを保つ(baselineとキーを一致させる)。
		SEMGREP_TARGET_ARGS+=("--include" "${patched_file}")
		case "${patched_file}" in
			*.c | *.h | *.cc | *.cpp | *.hpp) CPPCHECK_TARGETS+=("${patched_file}") ;;
		esac
	done < "${PATCHED_LIST}"

	[ -s "${PATCHED_LIST}" ] || RUN_SEMGREP=0
	[ "${#CPPCHECK_TARGETS[@]}" -gt 0 ] || RUN_CPPCHECK=0
fi

OVERALL_STATUS=0

# --- Semgrep ------------------------------------------------------------------
echo "=================================================================="
echo "SAST scan (Semgrep): scope=${SAST_SCOPE}"
echo "=================================================================="
if [ "${RUN_SEMGREP}" -eq 1 ]; then
	# `SEMGREP_TARGET_ARGS` は [<dir>, --include, <file>, ...] の順。semgrepはオプションを
	# ターゲットより後ろに置いても解釈するため、そのまま渡せる。
	semgrep scan --config auto --json --output "${SEMGREP_OUTPUT}" "${SEMGREP_TARGET_ARGS[@]}" \
		|| fail "semgrep scan の実行に失敗しました"
else
	echo "解析対象のファイルがないため、Semgrepはスキップします。"
	echo '{"results": []}' > "${SEMGREP_OUTPUT}"
fi

if [ "${UPDATE_BASELINE}" -eq 1 ]; then
	"${PY}" -m release_tools.cli sast-baseline --tool semgrep --input "${SEMGREP_OUTPUT}" \
		--source-root "${SOURCE_DIR}" --output "${SEMGREP_BASELINE}" \
		--note "scripts/scan-sast.sh --update-baseline で全体スキャンから生成(上流の既知の指摘を人が確認済み)" \
		|| fail "Semgrepのbaseline書き出しに失敗しました"
else
	echo "---- ScanRunner ゲート判定(BR2.1, Semgrep) ----"
	SEMGREP_STATUS=0
	"${PY}" -m release_tools.cli scan-gate \
		--tool semgrep \
		--input "${SEMGREP_OUTPUT}" \
		--baseline "${SEMGREP_BASELINE}" \
		--source-root "${SOURCE_DIR}" \
		${STALE_ARGS[@]+"${STALE_ARGS[@]}"} \
		--registry "${REGISTRY_PATH}" \
		|| SEMGREP_STATUS=$?
	if [ "${SEMGREP_STATUS}" -eq 0 ]; then
		echo "Semgrep verdict: Pass"
	else
		echo "Semgrep verdict: Fail"
		OVERALL_STATUS=1
	fi
fi

# --- cppcheck -----------------------------------------------------------------
echo ""
echo "=================================================================="
echo "SAST scan (cppcheck, C): scope=${SAST_SCOPE}"
echo "=================================================================="
if [ "${RUN_CPPCHECK}" -eq 1 ]; then
	CPPCHECK_ARGS=(--xml --xml-version=2 --enable=warning,style,performance,portability -j "$(nproc 2>/dev/null || echo 2)")
	# Zabbixのマクロ(ZBX_FS_UI64等)を解決させる。解決できないと unknownMacro でそのファイルの
	# 解析が打ち切られ、実際の指摘を見逃す。
	if [ -d "${SOURCE_DIR}/include" ]; then
		CPPCHECK_ARGS+=(-I "${SOURCE_DIR}/include")
	fi
	# サードパーティのvendor配下はSCAの対象でSASTの対象外(patchedスコープでは変更ファイルの
	# 一覧の段階で除外済み)。特に go-sqlite3 の約9MBのamalgamationは単独で解析に30分以上かかる。
	if [ "${SAST_SCOPE}" = "full" ]; then
		while IFS= read -r vendor_dir; do
			CPPCHECK_ARGS+=(-i "${vendor_dir}")
		done < <(find "${SOURCE_DIR}" -type d -name vendor -prune)
	fi
	# cppcheckの進捗(stdout)はCIログに残し、XML(stderr)だけをファイルへ取る。
	cppcheck "${CPPCHECK_ARGS[@]}" "${CPPCHECK_TARGETS[@]}" 2> "${CPPCHECK_OUTPUT}" \
		|| fail "cppcheck の実行に失敗しました"
else
	echo "解析対象のC/Cヘッダファイルがないため、cppcheckはスキップします。"
	echo '<results version="2"><errors></errors></results>' > "${CPPCHECK_OUTPUT}"
fi

if [ "${UPDATE_BASELINE}" -eq 1 ]; then
	"${PY}" -m release_tools.cli sast-baseline --tool cppcheck --input "${CPPCHECK_OUTPUT}" \
		--source-root "${SOURCE_DIR}" --output "${CPPCHECK_BASELINE}" \
		--note "scripts/scan-sast.sh --update-baseline で全体スキャンから生成(上流の既知の指摘を人が確認済み)" \
		|| fail "cppcheckのbaseline書き出しに失敗しました"
	echo ""
	echo "baselineを更新しました。git diff data/sast-baseline/ で内容を確認してからコミットしてください。"
	exit 0
fi

echo "---- ScanRunner ゲート判定(BR2.1, cppcheck) ----"
CPPCHECK_STATUS=0
"${PY}" -m release_tools.cli scan-gate \
	--tool cppcheck \
	--input "${CPPCHECK_OUTPUT}" \
	--baseline "${CPPCHECK_BASELINE}" \
	--source-root "${SOURCE_DIR}" \
	${STALE_ARGS[@]+"${STALE_ARGS[@]}"} \
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
