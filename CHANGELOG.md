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

Pre-1.0 baseline. Phase-7 hardening and 1.0 cut prep:

### Added
- Fuzz tests for the three client-side attack-surface entry
  points: `manifest.Parse`, `tarx.Extract`, `patch.Apply`,
  plus `manifest.Verify` and `tarx.safeName`. Run with
  `go test -fuzz=Fuzz... -fuzztime=Ns ./internal/...`.
- ADR-0005: threat-model walkthrough — 20 threats from the spec,
  each marked Closed / Mitigated / Accepted with the disposition
  reasoning.
- `docs/perf.org` — performance assumptions, the strace recipe to
  verify `sendfile` actually fires for blob downloads, sizing
  reference, known costs (patch-builder RAM, TLS user-space copy,
  disk-space growth model).

### Changed
- nothing breaking.

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
