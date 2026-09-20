# Zabbix 6.0 Custom (EOL-Free, SAST/SCA-Clean)

Zabbix 6.0 is nearing its official support end-of-life, and its upstream
container images have stopped receiving updates — known vulnerabilities are
no longer being patched upstream. This project builds Zabbix 6.0 from source,
applies the fixes needed to pass SAST/SCA scanning, and repackages it as a
custom, continuously rebuildable set of container images —
`zabbix-server`, `zabbix-web`, `zabbix-agent2`, and `zabbix-proxy` — staying
config/behavior compatible with the official `zabbix/zabbix-*` images.
MySQL is the only supported backend for the main database; `zabbix-proxy` is
the one exception, since its own local buffer database may use SQLite3, same
as the official image of that name — it never touches the main MySQL
database. Zabbix itself stays on the 6.0.x line; only the base images and
this project's own build/scan/publish tooling are actively maintained.

The Zabbix 6.0 source tree is vendored at `sources/zabbix-6.0.48/` (see
"Adding the Zabbix source" below for provenance and how to update it to a
later 6.0.x point release).

## The build/release tooling layer

This repository's own code (everything except the eventual Zabbix source) is
the automation that takes a Zabbix source tree from build through to a
scanned, published image. It implements six components:

- **VulnerabilityRegistry** (`release_tools/models.py`,
  `release_tools/registry.py`) — the CVE/GHSA triage ledger: register a
  vulnerability, issue a time-boxed waiver when no fix is published yet, and
  track waiver expiry. Persisted to `data/vulnerability-registry.yaml`.
- **ScanRunner** (`release_tools/gate.py`, `scripts/scan-sca.sh`,
  `scripts/scan-sast.sh`) — normalizes Trivy (SCA), Semgrep, and cppcheck
  (SAST) tool output into a common `Finding` shape and evaluates the
  pass/fail gate against the registry's current waiver state.
- **SecretScanner** (`scripts/scan-secrets.sh`, `.pre-commit-config.yaml`) —
  gitleaks, run both pre-commit (git diff) and in CI (git diff + the built
  image's filesystem layers); both must come back clean.
- **BuildPipeline** (`docker/*/Dockerfile`, `scripts/build-images.sh`) —
  builds the 4 in-scope components (server/web/agent2/proxy; no
  java-gateway) on Alpine, amd64 only, MySQL only (proxy's local buffer may
  use SQLite3).
- **CompatibilityTestRunner** (`compose.yml`, `scripts/compat-test.sh`) —
  brings the stack up via `docker compose` and checks official-image
  environment variable/volume compatibility, logging `docker stats
  --no-stream` as a reference observation (not itself a release gate).
- **ImagePublisher** (`release_tools/tagging.py`, `scripts/push-images.sh`) —
  generates the `tamacat/zabbix-<component>:<version>-r<YYYYMMDD>-<arch>`
  tag (never a floating tag such as `latest`), enforces the 4-condition
  publish gate (SCA pass, SAST pass, compatibility pass, secrets clean) plus
  an explicit self-review confirmation before `docker push`, then attempts
  cosign keyless signing and SBOM attestation against the published registry
  digest (CI-only; skipped with a warning outside a GitHub Actions OIDC
  context).

## Adding the Zabbix source

The Dockerfiles and scripts reference `${ZABBIX_SRC_DIR}` (build arg / env
var, default `sources/zabbix-6.0.48`) as the location of the buildable
Zabbix 6.0 source tree, relative to this directory. It is vendored directly
(committed, not a nested git submodule), matching the layout already used by
the sibling `zabbix-5.0-custom` project.

The vendored tree was obtained from Zabbix's official source distribution
and its integrity verified against the official SHA-256 checksum before
extracting:

```bash
curl -sSL -o zabbix-6.0.48.tar.gz \
  https://cdn.zabbix.com/zabbix/sources/stable/6.0/zabbix-6.0.48.tar.gz
curl -sSL -o zabbix-6.0.48.tar.gz.sha256 \
  https://cdn.zabbix.com/zabbix/sources/stable/6.0/zabbix-6.0.48.tar.gz.sha256
sha256sum -c zabbix-6.0.48.tar.gz.sha256   # must print "OK" before extracting
tar -xzf zabbix-6.0.48.tar.gz -C sources/
```

To move to a later 6.0.x point release, repeat the same download-and-verify
steps for the new version, replace `sources/zabbix-6.0.48/` with the new
tree, and update `ZABBIX_VERSION`/`ZABBIX_SRC_DIR` in `.env` and
`.env.example` accordingly (never upgrade past the 6.0.x line — see
`docs/CONTRIBUTING.md`). Override `ZABBIX_SRC_DIR` if you place the source
somewhere else.

## Running the tools

```bash
cp .env.example .env   # fill in DB_SERVER_HOST / MYSQL_PASSWORD / etc.

# Tests (do not require the Zabbix source to be present)
python3 -m pytest tests -q        # release_tools/ unit tests
bats tests/scripts                # scripts/ tests (requires bats-core)

# VulnerabilityRegistry CLI
python3 -m release_tools.cli register-cve --cve-id CVE-2026-00001 \
  --component zabbix-server --severity Critical
python3 -m release_tools.cli generate-tag --component zabbix-server \
  --zabbix-version 6.0.48 --build-date "$(date -u +%Y%m%d)" --arch amd64
```

Once the Zabbix source is present:

```bash
./scripts/build-images.sh      # build + tag all 4 components
./scripts/scan-sca.sh   <tag>  # Trivy SCA scan + gate
./scripts/scan-sast.sh         # Semgrep + cppcheck SAST scan + gate
./scripts/scan-secrets.sh <tag> [<tag> ...]   # gitleaks, git diff + image layers
./scripts/compat-test.sh       # docker compose up + compatibility checklist
./scripts/ci-pipeline.sh       # runs the five commands above in order (build
                                # through the BR3.1 publish-gate check), stopping
                                # at the first failing gate
./scripts/push-images.sh --tag <tag> --sca Pass --sast Pass \
  --compat Pass --secret Clean   # publish gate + self-review + docker push
```

See [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md) for the commit-message
CVE/GHSA traceability convention and the code-style tracks (patches to
upstream Zabbix source vs. this project's own build/CI layer).

## Continuous Integration

[`​.github/workflows/ci-release.yml`](.github/workflows/ci-release.yml) runs on
every push/PR to `main`, on a weekly schedule (Monday 03:00 UTC, for the base
image rebuild/rescan practice above), and on manual dispatch. It re-runs the
unit test suite, `scripts/ci-pipeline.sh`, and — after a required manual
approval on the `production` GitHub environment (this project's self-review
gate) — `scripts/push-images.sh` for each component, then signs the published
digest with cosign (keyless, GitHub OIDC) and attaches its SBOM.

Before the workflow can publish, this repository's own GitHub settings need
two one-time additions: a `production` environment with the repository owner
set as a required reviewer (this is the self-review gate), and
`DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` repository secrets scoped to push
access only.

## Ongoing maintenance

The base image (Alpine) is rebuilt and rescanned periodically, not just once
at first release — this project exists specifically because the official
images stopped receiving these updates, so this practice is required, not
optional. The release gate always checks against the current CVE database
at gate-evaluation time rather than relying on scan results from whenever
the image was originally built.

## License

GPL-2.0, matching upstream Zabbix's own license — see [LICENSE](LICENSE).
