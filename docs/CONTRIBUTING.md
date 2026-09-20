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

The release gate requires zero known Critical/High/Medium vulnerabilities,
except for items covered by an explicit, time-boxed waiver recorded in the
VulnerabilityRegistry (`data/vulnerability-registry.yaml`, managed via
`python3 -m release_tools.cli waive`). A waiver is re-evaluated when it
expires — it is never a way to silently disable a gate, and an unfixed
vulnerability without a released fix is never grounds to block a release
indefinitely.

Secrets are scanned twice: once pre-commit (git diff) and once in CI (git
diff plus the built image's filesystem layers). Both must be clean.
