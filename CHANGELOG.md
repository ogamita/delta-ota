# Changelog

All notable changes to delta-ota are recorded here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versions follow [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html),
and the public contracts (HTTP/JSON API, manifest schema, libota
C ABI) follow these compatibility commitments:

- **Wire format** (`schema_version: 1`): stable for the lifetime of
  major version 1. Field additions are non-breaking; renames /
  removals / type changes are a major-version event.
- **Manifest schema**: bumped only on incompatible field changes;
  new fields are non-breaking.
- **libota C ABI**: stable for the lifetime of a major version.
  Adding new exported functions is non-breaking.
- **`state.json`**: forward-compatible — new fields are ignored by
  older agents.

## [Unreleased]

Nothing yet.

## [1.0.0] - 2026-05-01

The 1.0 cut. Public contracts (HTTP/JSON API, manifest schema,
libota C ABI, state.json layout) frozen for the v1.x line.

### Added
- **Server** (Common Lisp / SBCL + Woo on Linux):
  - HTTP/JSON API with kernel-level `sendfile(2)` on plain HTTP.
  - Catalogue (SQLite by default; PG sub-phase to come).
  - Content-addressed blob and patch storage (FS by default; S3
    sub-phase to come).
  - Ed25519-signed manifests with deterministic ordered-object JSON
    encoding for byte-stable signing.
  - Deterministic POSIX-ustar release blobs.
  - Synchronous bsdiff patch worker (BSDIFF40 + bzip2) building a
    patch from every prior release of the same `(software, os,
    arch)` triple at publish time.
  - Reverse-patch builder: `POST /v1/admin/software/{sw}/patches/reverse`.
  - Garbage collection: `POST /v1/admin/software/{sw}/gc` with
    `dry_run`, `min_user_count`, `min_age_days`.
  - Storage verification: `POST /v1/admin/verify` re-hashes every
    artefact and reports mismatches.
  - Manifest re-sign on key rotation.
  - Install-token mint + per-client bearer exchange:
    `POST /v1/admin/install-tokens` (single) and
    `POST /v1/admin/install-tokens/batch` (up to 10 000 per call).
    `POST /v1/exchange-token` (client side).
  - Classification-based visibility filtering on every catalogue
    read.
  - Audit log of every admin write: `GET /v1/admin/audit`.
  - Recovery anchors: `GET /v1/software/{sw}/anchors` returns every
    uncollectable release plus the latest visible one.
  - Rate limits: in-memory token-bucket per identity (600-token
    capacity, 10 tokens/sec refill); returns 429 + `Retry-After`.
  - Optional TLS via `OTA_TLS_CERT` / `OTA_TLS_KEY`.
  - HTML install page at `GET /v1/install/{sw}`.
- **Client** (Go, cgo-free, single static binary per OS):
  - `ota-agent install / upgrade / revert / doctor / watch`.
  - `doctor --recover=<version>` for multi-step rollback to any
    server-curated anchor.
  - `watch --interval=24h --once` polling daemon for cron / systemd
    / launchd / Windows Task Scheduler.
  - `libota` exported as a C-ABI shared library (`-buildmode=c-shared`)
    and static archive (`-buildmode=c-archive`); five entry points
    (`ota_install / ota_upgrade / ota_revert / ota_version /
    ota_last_error`) plus generated `libota.h`.
  - Platform abstraction with symlink-or-shim `current` link
    (Windows non-admin/non-developer-mode falls back to `current.path`).
  - In-process bspatch (vendored `gabstv-go-bsdiff`).
  - Safe tar extractor (rejects `..`, NUL, absolute paths, Windows
    reserved names).
  - Atomic switch-over with absolute-target symlinks.
- **Admin CLI** (`ota-admin`):
  - `publish <dir>`: tars the source with the deterministic writer
    and uploads.
  - `mint-tokens --csv users.csv [--classifications=...] [--ttl=7d]`:
    bulk install-token issuance; emits a TSV ready for mail merge.
- **Tooling**:
  - `tools/backup.sh` / `tools/restore.sh` for full-root tarball
    backup with SHA-256 sidecar.
  - `tools/vendor-import.sh` / `tools/vendor-verify.sh` for
    permissive-only vendoring.
  - `tools/check-licence-headers.sh` for SPDX enforcement.
  - `tools/check-self-contained.sh` to assert no third-party dynamic
    deps in the client binary.
- **Documentation**:
  - Specifications, implementation plan, datasheet, user manual,
    operator runbook, performance notes, dependencies list,
    third-party licences. All buildable as PDFs via `make docs-pdf`.
  - Five ADRs (stack split; Woo not Hunchentoot; vendoring policy;
    bsdiff-only / no xdelta3; threat-model walkthrough).
  - Marketing HTML page under `marketing/`.
- **CI**:
  - GitLab pipeline: prepare → verify (vendor-verify, licence-headers,
    go-vet, go-test, go-fuzz) → build (server, libota cgo,
    client × 3 OSes × 2 arches) → test (unit + e2e: install, auth,
    ops, recovery) → package (multi-arch server image) → publish.
  - GitHub Actions mirror with native macOS + Windows test runners.
- **Vendored** (all permissive licences): `mendsley/bsdiff`,
  `gabstv/go-bsdiff`, `dsnet/compress`, `sharplispers/archive`.
  No GPL.

### Deferred to post-1.0 sub-phases
- Mandatory mTLS for admin endpoints (cert-subject identity).
- PostgreSQL catalogue backend (cl-sqlite → cl-dbi swap).
- S3-compatible blob storage backend.

## Pre-1.0 history

Phases 0–6 of the delivery plan landed before this changelog
opened. The high-level milestones, reconstructable from
`git log` and `docs/ota-implementation-plan.org`:

- **Phase 0** — repo scaffolding, contracts (manifest JSON Schema +
  OpenAPI), vendor tooling, three vendored components imported,
  CI green.
- **Phase 1** — end-to-end install on Linux: SBCL+Woo server,
  deterministic POSIX-ustar tar, Ed25519 signed manifests, Go
  client (cgo-free) with safe extractor + atomic flip.
- **Phase 2** — binary-delta upgrades (bsdiff via the gabstv-go-
  bsdiff library on both server and client; format-compatible).
- **Phase 3** — cross-platform client: platform abstraction
  (symlink with `current.path` shim fallback for non-admin
  Windows), `libota` built as `c-shared` for Linux/macOS/Windows.
- **Phase 4** — install-token + per-client bearer exchange,
  classification-based visibility filtering, audit log, opt-in TLS.
- **Phase 5** — operations: garbage collection, content
  verification, manifest re-sign on key rotation, backup/restore
  scripts, full operator runbook (`docs/operations.org`).
- **Phase 6** — recovery: anchors endpoint, `ota-agent doctor` and
  `--recover=<version>` for multi-step rollback to known-good
  releases.

## Versioning policy

A v1.0.0 tag is cut when:

1. Phase 7 hardening lands (this changelog opens for it).
2. The HTTP/JSON API + manifest schema + libota C ABI are
   declared frozen for the v1.x line.
3. The container image is published as `:1.0.0` in addition to
   the existing `:latest` tag.
4. CHANGELOG.md gets a `## [1.0.0] - YYYY-MM-DD` heading and the
   `Unreleased` section is moved under it.

Patch releases (1.0.x) are bug fixes and security patches with no
contract changes. Minor releases (1.x.0) add functionality
without breaking existing clients. A 2.0.0 only happens for an
incompatible change to one of the public contracts.
