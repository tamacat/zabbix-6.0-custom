# Contributing Guide

This document covers how to change this project's own build/release tooling
layer (`release_tools/`, `docker/`, `scripts/`, `tests/`). Patches to the
actual Zabbix source (once added under `sources/`) follow a different track
and its own upstream-derived conventions — see "Code style" below.

## Commit message convention (CVE/GHSA traceability)

BR4.2 — every commit or patch file that fixes a specific vulnerability must
make the corresponding CVE/GHSA ID identifiable. Include at least one line in
the commit message body or footer in this format:

```
Fixes: CVE-YYYY-NNNNN
```

If only a GHSA ID has been assigned, use the same format with the GHSA ID:

```
Fixes: GHSA-xxxx-xxxx-xxxx
```

This convention applies both to patches against the upstream Zabbix source
(Track A) and to changes to this project's own build/CI layer (Track B).
General Track B changes that don't correspond to a specific CVE/GHSA (routine
Dockerfile or script maintenance, for example) are not required to follow
this convention.

## Testing policy (summary)

- A confirmed vulnerability (CVE) fix: **test-first** — write a regression
  test that reproduces the vulnerability and fails before applying the fix.
- Any other general change (Dockerfiles, build/CI scripts, etc.):
  **test-after** — implement first, then write and run the test.
- Python tooling layer: `python3 -m pytest tests -q`
- Shell script layer: `bats tests/scripts` (requires bats-core)

Every triaged vulnerability must have at least one regression test or
scanner detect-then-resolve check, executed in CI — a numeric coverage
target is not used as a substitute.

## Code style

- **Track A (patches to the upstream Zabbix source)**: follow the existing
  upstream Zabbix coding style and per-language conventions as-is. Do not
  introduce new formatters or linters, and do not restructure existing
  upstream directories or file paths — this keeps future upstream syncs
  (rebase/merge) possible.
- **Track B (this project's own build/CI layer)**:
  - Dockerfile: hadolint
  - Shell scripts: shellcheck; always start with `set -euo pipefail`
  - Python: standard PEP 8 (no additional formatter is enforced yet)

`.pre-commit-config.yaml` registers gitleaks (secret scanning, pre-commit
side), hadolint, and shellcheck. Run `pre-commit install` before committing.

## Security scanning

Two independent tool families are used, each for a different kind of check:

- **SCA / image scanning** (Trivy): known-vulnerability lookups against
  dependencies and the base image.
- **SAST** (Semgrep for PHP/JS, cppcheck for C): semantic static analysis of
  the patched source itself.

### How the SAST gate treats upstream code

The vendored Zabbix source contains many findings that upstream never fixed
and this project does not touch. Failing on all of them would make the gate
impossible to pass, so SAST is gated on **new** findings only:

- `data/sast-baseline/{semgrep,cppcheck}.json` records the known findings as
  counts per tool / rule / file / message (no line numbers, so upstream line
  shifts do not matter). Anything beyond those counts fails the gate. cppcheck
  findings carry no CVE/GHSA ID, so they can never be waived: a finding beyond
  the baseline always fails, and a false positive is handled by fixing the
  configuration or by an inline `// cppcheck-suppress <id>` in the source.
- **Scope**: on push/PR only the files changed since the unmodified upstream
  import are analysed (`data/upstream-import-ref` names that commit, and CI
  checks out full history for it). Scheduled and manually dispatched runs use
  `--scope full`, which analyses the whole tree. Third-party code under
  `vendor/` is out of scope for SAST; it is covered by SCA.
- **Updating the baseline** is a deliberate, reviewed act, never a way to get
  a red build green: run `./scripts/scan-sast.sh --update-baseline`, read the
  `git diff data/sast-baseline/`, and commit only if every added entry is an
  upstream finding you accept. A patch of ours that introduces a finding must
  be fixed, not baselined. When moving to a later 6.0.x point release, replace
  the tree, update `data/upstream-import-ref` to the import commit, and
  regenerate the baseline.

The release gate requires zero known Critical/High/Medium vulnerabilities,
except for items covered by an explicit, time-boxed waiver recorded in the
VulnerabilityRegistry (`data/vulnerability-registry.yaml`, managed via
`python3 -m release_tools.cli waive`). A waiver is re-evaluated when it
expires — it is never a way to silently disable a gate, and an unfixed
vulnerability without a released fix is never grounds to block a release
indefinitely.

Secrets are scanned twice: once pre-commit (git diff) and once in CI (git
diff plus the built image's filesystem layers). Both must be clean.
