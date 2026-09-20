#!/usr/bin/env python3
"""release_tools CLI — VulnerabilityRegistry操作、スキャンゲート判定、
タグ生成、公開ゲート判定、公開直前セルフレビュー確認を提供するコマンドライン
インターフェース。`scripts/*.sh` から `python3 -m release_tools.cli <subcommand>`
として呼び出されることを想定する。

すべてのサブコマンドは、成功時exit 0、ドメインルール違反または入力不備時
exit 1で終了し、エラーメッセージは標準エラー出力に書き出す(construction.md
「Error Handling」— 呼び出し元シェルスクリプトの `set -euo pipefail` と
組み合わせて、失敗をパイプライン全体へ確実に伝播させる)。
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import date
from pathlib import Path
from typing import Optional

from . import gate as gate_mod
from .models import COMPONENT_NAMES
from .registry import VulnerabilityRegistry, VulnerabilityRegistryError
from .tagging import generate_tag, require_self_review_confirmation

DEFAULT_REGISTRY_PATH = "data/vulnerability-registry.yaml"


def _load_registry(path: str) -> VulnerabilityRegistry:
    return VulnerabilityRegistry(Path(path))


def _parse_date(value: str) -> date:
    return date.fromisoformat(value)


# --- サブコマンド実装 ---------------------------------------------------------


def cmd_register_cve(args: argparse.Namespace) -> int:
    registry = _load_registry(args.registry)
    try:
        vuln = registry.register_cve(
            cve_id=args.cve_id,
            component_name=args.component,
            severity=args.severity,
            fix_reference=args.fix_reference,
        )
    except (ValueError, VulnerabilityRegistryError) as exc:
        print(f"register-cve失敗: {exc}", file=sys.stderr)
        return 1
    registry.save()
    print(json.dumps(vuln.to_dict(), ensure_ascii=False))
    return 0


def cmd_waive(args: argparse.Namespace) -> int:
    registry = _load_registry(args.registry)
    try:
        waiver = registry.issue_waiver(
            waiver_id=args.waiver_id,
            cve_id=args.cve_id,
            reason=args.reason,
            issued_at=_parse_date(args.issued_at),
            expires_at=_parse_date(args.expires_at),
        )
    except (ValueError, VulnerabilityRegistryError) as exc:
        print(f"waive失敗: {exc}", file=sys.stderr)
        return 1
    registry.save()
    print(json.dumps(waiver.to_dict(), ensure_ascii=False))
    return 0


def cmd_update_status(args: argparse.Namespace) -> int:
    registry = _load_registry(args.registry)
    today = _parse_date(args.today) if args.today else None
    try:
        vuln = registry.update_status(args.cve_id, args.status, today=today)
    except (ValueError, VulnerabilityRegistryError) as exc:
        print(f"update-status失敗: {exc}", file=sys.stderr)
        return 1
    registry.save()
    print(json.dumps(vuln.to_dict(), ensure_ascii=False))
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    registry = _load_registry(args.registry)
    vulns = registry.list_vulnerabilities(status=args.status, component_name=args.component)
    print(json.dumps([v.to_dict() for v in vulns], ensure_ascii=False, indent=2))
    return 0


def cmd_generate_tag(args: argparse.Namespace) -> int:
    try:
        tag = generate_tag(
            component=args.component,
            zabbix_version=args.zabbix_version,
            build_date=args.build_date,
            arch=args.arch,
        )
    except ValueError as exc:
        print(f"generate-tag失敗: {exc}", file=sys.stderr)
        return 1
    print(tag)
    return 0


def cmd_scan_gate(args: argparse.Namespace) -> int:
    registry = _load_registry(args.registry)
    today = _parse_date(args.today) if args.today else None
    raw = Path(args.input).read_text(encoding="utf-8")
    try:
        if args.tool == "trivy":
            findings = gate_mod.normalize_trivy_findings(json.loads(raw))
        elif args.tool == "semgrep":
            findings = gate_mod.normalize_semgrep_findings(json.loads(raw))
        elif args.tool == "cppcheck":
            findings = gate_mod.normalize_cppcheck_findings(raw)
        else:  # argparseのchoicesで到達しないが、fail fastのため明示する
            raise ValueError(f"未対応のtoolです: {args.tool}")
    except (json.JSONDecodeError, ValueError) as exc:
        print(f"scan-gate失敗: 入力の解析に失敗しました: {exc}", file=sys.stderr)
        return 1

    verdict = gate_mod.scan_gate(findings, registry, today=today)
    registry.save()  # BR2.2/BR2.3によるwaiver/vulnerability状態の変化を永続化する
    print(verdict)
    return 0 if verdict == "Pass" else 1


def cmd_publish_gate(args: argparse.Namespace) -> int:
    ok = gate_mod.publish_gate(args.sca, args.sast, args.compat, args.secret)
    print("Pass" if ok else "Fail")
    return 0 if ok else 1


def cmd_confirm_publish(args: argparse.Namespace) -> int:
    confirmed: Optional[bool]
    if args.yes:
        confirmed = True
    elif args.no:
        confirmed = False
    else:
        confirmed = None
    ok = require_self_review_confirmation(confirmed=confirmed)
    print("confirmed" if ok else "not-confirmed")
    return 0 if ok else 1


# --- argparse組み立て ---------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="release_tools", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("register-cve", help="Vulnerabilityを棚卸し台帳へ新規登録する")
    p.add_argument("--cve-id", required=True)
    p.add_argument("--component", required=True, choices=COMPONENT_NAMES)
    p.add_argument("--severity", required=True, choices=("Critical", "High", "Medium", "Low"))
    p.add_argument("--fix-reference", default=None)
    p.add_argument("--registry", default=DEFAULT_REGISTRY_PATH)
    p.set_defaults(func=cmd_register_cve)

    p = sub.add_parser("waive", help="期限付きwaiverを発行しVulnerability.statusをWaivedへ更新する")
    p.add_argument("--cve-id", required=True)
    p.add_argument("--waiver-id", required=True)
    p.add_argument("--reason", required=True)
    p.add_argument("--issued-at", required=True, help="YYYY-MM-DD")
    p.add_argument("--expires-at", required=True, help="YYYY-MM-DD")
    p.add_argument("--registry", default=DEFAULT_REGISTRY_PATH)
    p.set_defaults(func=cmd_waive)

    p = sub.add_parser("update-status", help="Vulnerability.statusを更新する(BR1.2を強制)")
    p.add_argument("--cve-id", required=True)
    p.add_argument("--status", required=True, choices=("Open", "InProgress", "Fixed", "Waived"))
    p.add_argument("--today", default=None, help="YYYY-MM-DD(テスト・再現用、既定は本日)")
    p.add_argument("--registry", default=DEFAULT_REGISTRY_PATH)
    p.set_defaults(func=cmd_update_status)

    p = sub.add_parser("list", help="棚卸し済みVulnerabilityを一覧表示する")
    p.add_argument("--status", default=None, choices=("Open", "InProgress", "Fixed", "Waived"))
    p.add_argument("--component", default=None, choices=COMPONENT_NAMES)
    p.add_argument("--registry", default=DEFAULT_REGISTRY_PATH)
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("generate-tag", help="BR4.1に従い公開タグを生成する")
    p.add_argument("--component", required=True, choices=COMPONENT_NAMES)
    p.add_argument("--zabbix-version", required=True)
    p.add_argument("--build-date", required=True, help="YYYYMMDD")
    p.add_argument("--arch", default="amd64")
    p.set_defaults(func=cmd_generate_tag)

    p = sub.add_parser("scan-gate", help="スキャン結果を正規化しBR2.1のゲート判定を行う")
    p.add_argument("--tool", required=True, choices=("trivy", "semgrep", "cppcheck"))
    p.add_argument("--input", required=True, help="ツール出力ファイルのパス")
    p.add_argument("--today", default=None, help="YYYY-MM-DD(テスト・再現用、既定は本日)")
    p.add_argument("--registry", default=DEFAULT_REGISTRY_PATH)
    p.set_defaults(func=cmd_scan_gate)

    p = sub.add_parser("publish-gate", help="BR3.1の4条件を判定する")
    p.add_argument("--sca", required=True, choices=("Pass", "Fail"))
    p.add_argument("--sast", required=True, choices=("Pass", "Fail"))
    p.add_argument("--compat", required=True, choices=("Pass", "Fail"))
    p.add_argument("--secret", required=True, choices=("Clean", "Blocked"))
    p.set_defaults(func=cmd_publish_gate)

    p = sub.add_parser("confirm-publish", help="BR3.2の公開直前セルフレビュー承認を行う")
    group = p.add_mutually_exclusive_group()
    group.add_argument("--yes", action="store_true", help="非対話で承認済みとして扱う")
    group.add_argument("--no", action="store_true", help="非対話で未承認として扱う")
    p.set_defaults(func=cmd_confirm_publish)

    return parser


def main(argv: Optional[list[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
