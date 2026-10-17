#!/usr/bin/env bats
# scripts/scan-agent2-binaries.sh のテスト。
#
# govulncheck は常にテスト用スタブへ差し替え、実スキャンは行わない。アーカイブはpythonで
# 実物と同じ配置(<prefix>-linux-amd64/sbin/zabbix_agent2、<prefix>-windows-amd64/bin/
# zabbix_agent2.exe)に作る。スタブは、解析対象のバイナリの中身(LINUX/WINDOWS)で出力を変える。

setup() {
	REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
	TEST_TMPDIR="$(mktemp -d)"
	STUB_BIN="${TEST_TMPDIR}/bin"
	DIST="${TEST_TMPDIR}/dist"
	PREFIX="zabbix_agent2-6.0.48-b20261017"
	mkdir -p "${STUB_BIN}" "${DIST}"
	# CI installs tools to /usr/local/bin; see tests/scripts/build-images.bats for why that is excluded here.
	export PATH="${STUB_BIN}:$(echo "${PATH}" | sed -e 's#:/usr/local/bin:#:#g' -e 's#^/usr/local/bin:##' -e 's#:/usr/local/bin$##')"
	# 実運用データ(data/vulnerability-registry.yaml)へ書き込まない・読まないよう、台帳をテスト専用にする。
	export REGISTRY_PATH="${TEST_TMPDIR}/vulnerability-registry.yaml"
}

teardown() {
	rm -rf "${TEST_TMPDIR}"
}

# build-agent2-binaries.sh の成果物と同じ名前・配置のアーカイブを ${DIST} に作る。
make_archives() {
	python3 - "${DIST}" "${PREFIX}" <<'PY'
import io, sys, tarfile, zipfile
dist, prefix = sys.argv[1], sys.argv[2]
with tarfile.open(f"{dist}/{prefix}-linux-amd64.tar.gz", "w:gz") as tar:
    data = b"LINUX binary"
    info = tarfile.TarInfo(f"{prefix}-linux-amd64/sbin/zabbix_agent2")
    info.size = len(data)
    tar.addfile(info, io.BytesIO(data))
with zipfile.ZipFile(f"{dist}/{prefix}-windows-amd64.zip", "w") as zf:
    zf.writestr(f"{prefix}-windows-amd64/bin/zabbix_agent2.exe", b"WINDOWS binary")
PY
}

CLEAN_JSON='{"config": {"scanner_name": "govulncheck", "scan_mode": "binary"}}'
CALLED_JSON='{"config": {"scanner_name": "govulncheck"}}
{"osv": {"id": "GO-2026-6603", "aliases": ["CVE-2026-78659"]}}
{"finding": {"osv": "GO-2026-6603", "fixed_version": "go1.26.9", "trace": [{"module": "stdlib", "package": "net/http", "function": "Do"}]}}'

# $1: Linux版に出すJSON、$2: Windows版に出すJSON、$3: 終了コード(省略時0)
stub_govulncheck() {
	local linux_json="$1" windows_json="$2" code="${3:-0}"
	cat > "${STUB_BIN}/govulncheck" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "${TEST_TMPDIR}/govulncheck-calls.log"
binary="\${@: -1}"
if grep -q WINDOWS "\${binary}"; then
cat <<'JSON'
${windows_json}
JSON
else
cat <<'JSON'
${linux_json}
JSON
fi
exit ${code}
EOF
	chmod +x "${STUB_BIN}/govulncheck"
}

@test "govulncheckが見つからない場合エラーで停止する" {
	cd "${REPO_ROOT}"
	make_archives
	# スタブを置かず、実物があっても見えないようにする(scan-runner.bats の hide_tool と同じ目的)
	run env PATH="${STUB_BIN}:/usr/bin:/bin" bash scripts/scan-agent2-binaries.sh "${DIST}"

	[ "$status" -ne 0 ]
	[[ "$output" == *"govulncheck が見つかりません"* ]]
	[[ "$output" == *"自動リトライは行いません"* ]]
}

@test "成果物のディレクトリが無い場合、build-agent2-binaries.sh を先に実行するよう案内して停止する" {
	cd "${REPO_ROOT}"
	stub_govulncheck "${CLEAN_JSON}" "${CLEAN_JSON}"
	run bash scripts/scan-agent2-binaries.sh "${TEST_TMPDIR}/nowhere"

	[ "$status" -ne 0 ]
	[[ "$output" == *"build-agent2-binaries.sh"* ]]
}

@test "どちらかのアーカイブが無い場合は停止する(片方だけの検査で通さない)" {
	cd "${REPO_ROOT}"
	make_archives
	rm "${DIST}/${PREFIX}-windows-amd64.zip"
	stub_govulncheck "${CLEAN_JSON}" "${CLEAN_JSON}"
	run bash scripts/scan-agent2-binaries.sh "${DIST}"

	[ "$status" -ne 0 ]
	[[ "$output" == *"ちょうど1つ必要"* ]]
	[ ! -f "${TEST_TMPDIR}/govulncheck-calls.log" ]
}

@test "同じ種類のアーカイブが複数ある場合は、どれを検査したか曖昧になるので停止する" {
	cd "${REPO_ROOT}"
	make_archives
	cp "${DIST}/${PREFIX}-linux-amd64.tar.gz" "${DIST}/zabbix_agent2-6.0.47-b20260101-linux-amd64.tar.gz"
	stub_govulncheck "${CLEAN_JSON}" "${CLEAN_JSON}"
	run bash scripts/scan-agent2-binaries.sh "${DIST}"

	[ "$status" -ne 0 ]
	[[ "$output" == *"ちょうど1つ必要"* ]]
}

@test "脆弱性が無ければ、Linux版・Windows版の両方を解析してPassする" {
	cd "${REPO_ROOT}"
	make_archives
	stub_govulncheck "${CLEAN_JSON}" "${CLEAN_JSON}"
	run bash scripts/scan-agent2-binaries.sh "${DIST}"

	[ "$status" -eq 0 ]
	[[ "$output" == *"Go vulnerability verdict (linux): Pass"* ]]
	[[ "$output" == *"Go vulnerability verdict (windows): Pass"* ]]
	[[ "$output" == *"Go vulnerability verdict (all binaries): Pass"* ]]
	[ "$(wc -l < "${TEST_TMPDIR}/govulncheck-calls.log")" -eq 2 ]
	grep -q -- "-mode=binary -format json" "${TEST_TMPDIR}/govulncheck-calls.log"
}

@test "Windows版にだけ脆弱性があればFailするが、Linux版の結果も表示する" {
	cd "${REPO_ROOT}"
	make_archives
	stub_govulncheck "${CLEAN_JSON}" "${CALLED_JSON}"
	run bash scripts/scan-agent2-binaries.sh "${DIST}"

	[ "$status" -ne 0 ]
	[[ "$output" == *"Go vulnerability verdict (linux): Pass"* ]]
	[[ "$output" == *"Go vulnerability verdict (windows): Fail"* ]]
	[[ "$output" == *"Go vulnerability verdict (all binaries): Fail"* ]]
	[[ "$output" == *"govulncheck|GO-2026-6603"* ]]
}

@test "Linux版にだけ脆弱性があっても、Windows版まで解析してからFailする" {
	cd "${REPO_ROOT}"
	make_archives
	stub_govulncheck "${CALLED_JSON}" "${CLEAN_JSON}"
	run bash scripts/scan-agent2-binaries.sh "${DIST}"

	[ "$status" -ne 0 ]
	[[ "$output" == *"Go vulnerability verdict (linux): Fail"* ]]
	[[ "$output" == *"Go vulnerability verdict (windows): Pass"* ]]
	[ "$(wc -l < "${TEST_TMPDIR}/govulncheck-calls.log")" -eq 2 ]
}

@test "govulncheck自体が失敗(DB取得失敗等)した場合は、Passにせず停止する" {
	cd "${REPO_ROOT}"
	make_archives
	stub_govulncheck "" "" 3
	run bash scripts/scan-agent2-binaries.sh "${DIST}"

	[ "$status" -ne 0 ]
	[[ "$output" == *"govulncheck の実行に失敗しました"* ]]
	[[ "$output" != *"verdict"*"Pass"* ]]
}
