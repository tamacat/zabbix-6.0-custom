"""CIの結果を、GitHub Actionsの実行ページに出すMarkdown(Job Summary)にまとめる。

目的: 週次の定期実行のたびに、(1) 前回のビルドから何が変わったか、(2) 脆弱性チェックがどこまで
通ったか、を数千行のログを開かずに分かるようにする。ここは表示専用で、ゲートの判定
(scan-gate / publish-gate)には一切影響しない。記録に失敗してもゲートの結果は変わらない。

入力:
  - 記録ファイル(JSON Lines)。`scan-gate --summary-file` と scripts/ci-pipeline.sh が1行ずつ追記する。
      {"kind": "scan", "tool": "trivy", "target": "<イメージ>", "verdict": "Pass",
       "counts": {"Critical": 0, "High": 1, "Medium": 2, "Low": 5},
       "baseline_known": 0, "waived": 3, "blocking": 0, "waived_ids": ["CVE-..."]}
      {"kind": "step", "name": "シークレットスキャン", "result": "Clean"}
  - 今回と前回のSBOM(Trivy `--format cyclonedx`)のディレクトリ。ファイル名は
    `<イメージ名>_<タグ>.cyclonedx.json`(`/` と `:` は `_` に置き換え済み)。
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

from .gate import _GATED_SEVERITIES as GATED_SEVERITIES
from .models import SEVERITIES, Finding

SBOM_SUFFIX = ".cyclonedx.json"
# 変更一覧に載せる最大行数(イメージごと)。超えた分は件数だけ示す。
MAX_LISTED_CHANGES = 40
# waiverで通した指摘として列挙する最大件数。
MAX_LISTED_WAIVED = 20

_OK = "✅"
_NG = "❌"
_WARN = "⚠️"


# --- 記録(producer側)--------------------------------------------------------


def build_scan_record(
    tool: str,
    target: str,
    verdict: str,
    all_findings: Iterable[Finding],
    remaining: Iterable[Finding],
    blocking: Iterable[Finding],
) -> Dict[str, Any]:
    """scan-gate が判定に使った値から、サマリー用の1件の記録を作る。

    all_findings: ツールの出力を正規化した全件(baseline適用前)。
    remaining:    baseline適用後(baselineが無ければ all_findings と同じ)。
    blocking:     remaining のうち、ゲート対象で、有効なwaiverが無いもの。
    """
    all_list = list(all_findings)
    remaining_list = list(remaining)
    blocking_ids = {f.finding_id for f in blocking}

    counts = {severity: 0 for severity in SEVERITIES}
    for finding in all_list:
        counts[finding.severity] += 1

    gated_total = sum(1 for f in all_list if f.severity in GATED_SEVERITIES)
    gated_remaining = [f for f in remaining_list if f.severity in GATED_SEVERITIES]
    waived = [f for f in gated_remaining if f.finding_id not in blocking_ids]
    return {
        "kind": "scan",
        "tool": tool,
        "target": target,
        "verdict": verdict,
        "counts": counts,
        "baseline_known": gated_total - len(gated_remaining),
        "waived": len(waived),
        "blocking": len(blocking_ids),
        "waived_ids": sorted({f.cve_id for f in waived if f.cve_id}),
    }


def append_record(path: str | Path, record: Dict[str, Any]) -> None:
    """記録ファイルへ1行追記する(親ディレクトリが無ければ作る)。"""
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    with target.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")


def load_records(path: str | Path | None) -> List[Dict[str, Any]]:
    """記録ファイルを読む。無い・壊れた行は黙って飛ばす(表示専用のため)。"""
    if not path:
        return []
    source = Path(path)
    if not source.is_file():
        return []
    records: List[Dict[str, Any]] = []
    for line in source.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            records.append(value)
    return records


# --- SBOM(前回との差分)------------------------------------------------------


def _image_key_and_tag(filename: str) -> Tuple[str, str]:
    stem = filename[: -len(SBOM_SUFFIX)] if filename.endswith(SBOM_SUFFIX) else filename
    if "_" in stem:
        key, tag = stem.rsplit("_", 1)
        return key, tag
    return stem, ""


def load_sbom_dir(directory: str | Path | None) -> Dict[str, Dict[str, Any]]:
    """SBOMのディレクトリを読み、イメージごとの {tag, os, packages} を返す。

    packages は {パッケージ識別子: (表示名, バージョン)}。識別子はpurlからバージョンを除いたもの
    (無ければ type:name)なので、同じパッケージの版が変わっても同じキーになる。
    """
    result: Dict[str, Dict[str, Any]] = {}
    if not directory:
        return result
    base = Path(directory)
    if not base.is_dir():
        return result
    for path in sorted(base.glob(f"*{SBOM_SUFFIX}")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        key, tag = _image_key_and_tag(path.name)
        packages: Dict[str, Tuple[str, str]] = {}
        os_text = ""
        for component in data.get("components", []) or []:
            ctype = component.get("type", "")
            name = component.get("name", "")
            version = component.get("version", "")
            if ctype == "operating-system":
                os_text = f"{name} {version}".strip()
                continue
            if ctype == "file" or not name or not version:
                continue
            purl = component.get("purl") or ""
            ident = purl.split("@", 1)[0] if purl else f"{ctype}:{name}"
            packages[ident] = (name, version)
        result[key] = {"tag": tag, "os": os_text, "packages": packages}
    return result


def diff_packages(
    old: Dict[str, Tuple[str, str]], new: Dict[str, Tuple[str, str]]
) -> Tuple[List[Tuple[str, str]], List[Tuple[str, str]], List[Tuple[str, str, str]]]:
    """(追加, 削除, 更新) を返す。追加・削除は (名前, 版)、更新は (名前, 旧版, 新版)。"""
    added = sorted((n, v) for ident, (n, v) in new.items() if ident not in old)
    removed = sorted((n, v) for ident, (n, v) in old.items() if ident not in new)
    changed = sorted(
        (new[ident][0], old[ident][1], new[ident][1])
        for ident in new
        if ident in old and old[ident][1] != new[ident][1]
    )
    return added, removed, changed


# --- Trivy DBの鮮度 -----------------------------------------------------------


def trivy_db_updated_at() -> Optional[str]:
    """`trivy version --format json` から、脆弱性DBの更新時刻を取る。取れなければ None。"""
    try:
        proc = subprocess.run(
            ["trivy", "version", "--format", "json"],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        info = json.loads(proc.stdout or "{}")
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
        return None
    db = info.get("VulnerabilityDB") or {}
    return db.get("UpdatedAt") or db.get("DownloadedAt")


# --- Markdown -------------------------------------------------------------------


def _mark(verdict: str) -> str:
    return _OK if verdict in ("Pass", "Clean") else _NG


def _scan_overall(scans: List[Dict[str, Any]], steps: List[Dict[str, Any]]) -> Tuple[str, str]:
    failed = [s for s in scans if s.get("verdict") != "Pass"]
    failed_steps = [s for s in steps if s.get("result") not in ("Pass", "Clean", "Skipped")]
    if failed or failed_steps:
        names = [f"{s.get('tool')} ({s.get('target')})" for s in failed] + [str(s.get("name")) for s in failed_steps]
        return _NG, "ゲートがFailしました: " + ", ".join(names)
    gate = [s for s in steps if s.get("name") == "公開前提条件"]
    if gate and gate[-1].get("result") == "Pass":
        return _OK, "検証ゲートはすべてPassしました"
    if not scans and not steps:
        return _WARN, "記録がありません(検証が始まる前に止まった可能性があります)"
    return _WARN, "検証が最後まで終わっていません(途中で止まった可能性があります。ログを確認してください)"


def _count_cells(counts: Dict[str, int]) -> str:
    return " | ".join(str(counts.get(severity, 0)) for severity in SEVERITIES)


def _render_scans(scans: List[Dict[str, Any]]) -> List[str]:
    lines: List[str] = []
    sca = [s for s in scans if s.get("tool") in ("trivy", "govulncheck")]
    sast = [s for s in scans if s.get("tool") in ("semgrep", "cppcheck")]

    if sca:
        lines += [
            "### SCA(Trivy・govulncheck)",
            "",
            "| 対象 | ツール | Critical | High | Medium | Low | waiver済(件数) | 未対応 | 判定 |",
            "|---|---|---:|---:|---:|---:|---:|---:|:---:|",
        ]
        for s in sca:
            lines.append(
                f"| `{s.get('target')}` | {s.get('tool')} | {_count_cells(s.get('counts', {}))} "
                f"| {s.get('waived', 0)} | {s.get('blocking', 0)} | {_mark(s.get('verdict', ''))} |"
            )
        lines += [
            "",
            "Critical/High/Mediumがゲート対象です(Lowは対象外)。govulncheckは「バイナリが実際に呼ぶ脆弱性」だけを数えます。",
            "",
        ]
    if sast:
        lines += [
            "### SAST(Semgrep・cppcheck)",
            "",
            "| ツール | 対象 | Critical | High | Medium | Low | 既知(baseline) | waiver済(件数) | 新規 | 判定 |",
            "|---|---|---:|---:|---:|---:|---:|---:|---:|:---:|",
        ]
        for s in sast:
            lines.append(
                f"| {s.get('tool')} | {s.get('target')} | {_count_cells(s.get('counts', {}))} "
                f"| {s.get('baseline_known', 0)} | {s.get('waived', 0)} | {s.get('blocking', 0)} "
                f"| {_mark(s.get('verdict', ''))} |"
            )
        lines += ["", "「新規」はbaseline(承認済みの既知の指摘)を超えた分で、これだけがゲート対象です。", ""]

    waived_ids = sorted({cve for s in scans for cve in s.get("waived_ids", [])})
    if waived_ids:
        shown = ", ".join(waived_ids[:MAX_LISTED_WAIVED])
        more = f" ほか{len(waived_ids) - MAX_LISTED_WAIVED}件" if len(waived_ids) > MAX_LISTED_WAIVED else ""
        lines += [f"waiverを使って通したCVE({len(waived_ids)}種類): {shown}{more}", ""]
    return lines


def _render_steps(steps: List[Dict[str, Any]]) -> List[str]:
    if not steps:
        return []
    lines = ["### その他のゲート", "", "| 項目 | 結果 |", "|---|:---:|"]
    for step in steps:
        result = str(step.get("result", ""))
        lines.append(f"| {step.get('name')} | {_mark(result)} {result} |")
    lines.append("")
    return lines


def _render_changes(new: Dict[str, Dict[str, Any]], prev: Dict[str, Dict[str, Any]]) -> List[str]:
    lines = ["## 前回ビルドからの変更(SBOM比較)", ""]
    if not new:
        return lines + ["今回のSBOMがありません(SBOM生成より前に止まった可能性があります)。", ""]
    if not prev:
        return lines + ["前回のSBOMが見つからないため、比較できません(初回、または保存期間切れ)。", ""]

    any_change = False
    body: List[str] = []
    unchanged: List[str] = []
    for key in sorted(new):
        cur = new[key]
        old = prev.get(key)
        if old is None:
            body += [f"- `{key}`: 前回のSBOMに無いイメージです(新規)。", ""]
            any_change = True
            continue
        added, removed, changed = diff_packages(old["packages"], cur["packages"])
        os_changed = old["os"] != cur["os"]
        if not (added or removed or changed or os_changed):
            unchanged.append(f"- `{key}`: 変更なし(`{old['tag']}` → `{cur['tag']}`)")
            continue
        any_change = True
        parts = []
        if changed:
            parts.append(f"更新{len(changed)}")
        if added:
            parts.append(f"追加{len(added)}")
        if removed:
            parts.append(f"削除{len(removed)}")
        # <summary> の中ではMarkdownが効かないので、<code> で書く。
        summary = f"<code>{key}</code>: " + (" / ".join(parts) if parts else "パッケージの変更なし")
        if os_changed:
            summary += f" / OS {old['os'] or '?'} → {cur['os'] or '?'}"
        body += ["<details>", f"<summary>{summary}(<code>{old['tag']}</code> → <code>{cur['tag']}</code>)</summary>", ""]
        rows: List[str] = []
        rows += [f"| 更新 | `{n}` | {o} → {v} |" for n, o, v in changed]
        rows += [f"| 追加 | `{n}` | {v} |" for n, v in added]
        rows += [f"| 削除 | `{n}` | {v} |" for n, v in removed]
        body += ["| 区分 | パッケージ | バージョン |", "|---|---|---|"]
        body += rows[:MAX_LISTED_CHANGES]
        if len(rows) > MAX_LISTED_CHANGES:
            body.append(f"| … | ほか{len(rows) - MAX_LISTED_CHANGES}件 | |")
        body += ["", "</details>", ""]

    if not any_change:
        lines.append("パッケージの更新はありません(ベースイメージ・依存とも前回と同じです)。")
        lines.append("")
    lines += body
    if unchanged:
        lines += unchanged + [""]
    return lines


def render_summary(
    records: List[Dict[str, Any]],
    new_sbom: Dict[str, Dict[str, Any]],
    prev_sbom: Dict[str, Dict[str, Any]],
    meta: Dict[str, str],
) -> str:
    scans = [r for r in records if r.get("kind") == "scan"]
    steps = [r for r in records if r.get("kind") == "step"]
    icon, headline = _scan_overall(scans, steps)

    title = f"# {icon} 脆弱性チェックと前回からの変更"
    if meta.get("zabbix_version"):
        title += f" — Zabbix {meta['zabbix_version']}"
    out: List[str] = [title, "", headline, ""]

    info: List[Tuple[str, str]] = []
    if meta.get("event"):
        info.append(("実行のきっかけ", meta["event"]))
    if meta.get("build_date"):
        info.append(("ビルド日", meta["build_date"]))
    if meta.get("alpine_version"):
        os_texts = sorted({v["os"] for v in new_sbom.values() if v.get("os")})
        suffix = f"(イメージ内: {', '.join(os_texts)})" if os_texts else ""
        info.append(("Alpine", f"{meta['alpine_version']}{suffix}"))
    if meta.get("trivy_db"):
        info.append(("Trivy脆弱性DBの更新", meta["trivy_db"]))
    if info:
        out += ["| 項目 | 内容 |", "|---|---|"] + [f"| {k} | {v} |" for k, v in info] + [""]

    out += _render_changes(new_sbom, prev_sbom)
    out += ["## 脆弱性チェックの結果", ""]
    if not scans and not steps:
        out += ["記録がありません。", ""]
    out += _render_scans(scans)
    out += _render_steps(steps)
    out += [
        "---",
        "このジョブは検証だけを行います。Docker Hubへの公開は、`production` 環境の承認後に `Publish` ジョブが行います"
        "(承認するまでRunは waiting のままです)。",
        "",
    ]
    return "\n".join(out)


def main_render(
    records_path: Optional[str],
    sbom_dir: Optional[str],
    prev_sbom_dir: Optional[str],
    meta: Dict[str, str],
    query_trivy_db: bool,
    stream=None,
) -> int:
    """`ci-summary` サブコマンドの本体。常に0を返す(表示専用なので、CIを落とさない)。"""
    stream = stream or sys.stdout
    if query_trivy_db and not meta.get("trivy_db"):
        updated = trivy_db_updated_at()
        if updated:
            meta = {**meta, "trivy_db": updated}
    try:
        text = render_summary(
            load_records(records_path),
            load_sbom_dir(sbom_dir),
            load_sbom_dir(prev_sbom_dir),
            meta,
        )
    except Exception as exc:  # 表示専用: どんな不具合でもCIのゲートを巻き込まない
        text = f"# {_WARN} サマリーを作れませんでした\n\n`{type(exc).__name__}: {exc}`\n"
    stream.write(text)
    return 0
