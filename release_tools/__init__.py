"""release_tools — Zabbix 6.0 EOL-Free Custom Build のビルド/リリースツール層。

このパッケージは Zabbix 本体のソースコードを一切含まない。含むのは、
脆弱性棚卸し(VulnerabilityRegistry)・スキャンゲート判定(ScanRunner)・
タグ生成と公開ゲート(ImagePublisher)という、このプロジェクト自身が
新規に書くビルド/CI層のロジックのみである。

各エンティティ(Vulnerability, Waiver等)の型・制約はこのパッケージ内の
`models.py` を、対応するビジネスルール(BR1.x, BR2.x等)は各モジュールの
docstringおよび `docs/CONTRIBUTING.md` を参照。
"""

__version__ = "0.1.0"
