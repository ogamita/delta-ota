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

## [1.0.4] - 2026-05-09

### Fixed
- **`publish` is now idempotent on `(software, os, arch, version)`
  — duplicate publishes no longer crash the server with `500
  UNIQUE constraint failed: releases.…`.** The handler now looks
  up the tuple before inserting and decides:
  - same blob hash → `200 {"idempotent": true, …}` with the
    existing release-id and the count of patches already on disk;
  - different blob hash → `409 Conflict` with a clear message
    naming both blob hashes and telling the operator to bump the
    version or delete the existing release first;
  - new tuple → `201` as before.

  This is what makes a client-side I/O timeout a safe retry: the
  re-run will either succeed-as-200 (if the first attempt actually
  landed) or proceed normally.

### Added
- **Server prints its version + worker count on startup.** The
  banner now reads `ota-server X.Y.Z\nlistening on H:P (N worker
  thread{s})\n…` — operators can immediately verify which build
  is running and that multi-thread mode is engaged. If you see
  "(1 worker thread)" your `[server].worker_num` is mis-set.
- **`OTA_WORKER_NUM` env-var override** for symmetry with the
  other `OTA_*` vars (overrides `[server].worker_num` from the
  TOML file).
- **Per-patch progress logging during publish.** The patch worker
  now logs `publish: building N patches for SW/OS-ARCH/VER` plus
  `publish: bsdiff i/N from VERSION (BYTES bytes) ...` for each
  prior release. An operator tailing the server log can see how
  far through the fan-in pass a publish is. (Real-time progress
  in the HTTP response would require a chunked-transfer
  rewrite — deferred to a later phase.)
- **New `ota-server.catalogue:get-release-by-tuple`** plus 3
  unit tests + a worker-num-env-override test (server suite is
  now 116 checks, was 109).

### Fixed
- **`ota-admin publish` no longer times out client-side while the
  server is still processing.** Dexador's default
  `*default-read-timeout*` is **10 seconds** — far too short for a
  publish whose synchronous bsdiff pass against prior releases
  routinely takes longer. The client closed its socket, the
  server kept working, and the 201 arrived at a half-closed
  connection. `ota-admin` now passes a generous read-timeout
  (default 600 s) and connect-timeout (default 30 s) to every
  HTTP call, both tunable via env-vars `OTA_ADMIN_READ_TIMEOUT`
  and `OTA_ADMIN_CONNECT_TIMEOUT` (seconds, integer; `0` disables
  the deadline). Surfaces SBCL's `IO-TIMEOUT` condition with a
  pointed message about bumping the timeout and re-running (the
  publish handler is idempotent on `(software, os, arch,
  version)` so a re-run after a client-side timeout is safe).
- **Multi-worker HTTP serving — long publishes no longer wedge
  the server.** Woo had been booted in single-threaded mode, so
  the synchronous bsdiff patch build inside the publish handler
  blocked every concurrent request for the duration of the
  build. A second `ota-admin` invocation (or any `ota-agent`
  read) hitting the server during that window timed out with
  `I/O timeout while doing input on …`. The server now starts
  Woo with `:worker-num` (default 4, configurable via
  `[server].worker_num`); each worker runs its own libev loop
  and shares the listening socket via `accept(2)`, so a slow
  handler on one thread never starves the others. Verified
  end-to-end by `tests/e2e/parallel.sh` (`make e2e-parallel`):
  50 concurrent reads against an `/v1/install/<sw>` endpoint
  while a multi-megabyte publish + bsdiff is in flight, all
  reads complete inside a 3 s per-request deadline.

### Changed
- **Catalogue is now thread-safe.** `OPEN-CATALOGUE` returns a
  struct wrapping the cl-sqlite handle plus a
  `bordeaux-threads:make-recursive-lock`; every catalogue
  function holds the lock while inside the C library. SQLite is
  also opened in WAL mode with a 10 s `busy_timeout` and
  `synchronous=NORMAL`, so concurrent readers + one writer do
  not block each other through the journal. The public catalogue
  API is unchanged — callers pass the same value, only the
  internal representation changed.
- New `[server].worker_num` TOML key (default 4) — added to all
  three sample configs (`ota.dev.toml`, `ota.docker.toml`,
  `ota.toml.sample`) and documented in `docs/operations.org`
  alongside a new "Concurrency model" section with sizing
  guidance.

### Added
- **`tests/e2e/parallel.sh`** — proves the multi-worker server
  keeps reads responsive while a slow publish is in flight.
  Wired into `make e2e` as `e2e-parallel`.
- **10 new server unit tests** in
  `server/tests/concurrency-tests.lisp`: catalogue struct shape,
  WAL/busy-timeout settings, parallel reader+writer race against
  a real catalogue, recursive-lock nested-call check, `worker-num`
  default and TOML override. Server suite is now 109 checks
  (was 99), all green.
- **Friendly error messages for HTTP/TLS misconfiguration in
  `ota-admin`.** Previously, the most common operator
  bring-up mistakes (`https://` against a plain-HTTP server,
  hostname typo, server not running) surfaced as raw cl+ssl /
  USOCKET stack-trace fragments — `tls_validate_record_header:
  wrong version number` or `Condition USOCKET:NS-HOST-NOT-FOUND-
  ERROR was signalled.`. `ota-admin` now intercepts these and
  prints a one-line actionable message that names the URL and
  suggests the fix (e.g. *"TLS handshake failed against
  https://… — the server appears to be serving plain HTTP, not
  HTTPS. Try OTA_SERVER=http://… (no 's')."*).
- The matcher dispatches on both the printed message and the
  condition's package-qualified class name, so library-internal
  conditions whose default print form lacks diagnostic text
  (`USOCKET:INVALID-ARGUMENT-ERROR`, `USOCKET:NS-HOST-NOT-FOUND-
  ERROR`, etc.) are still recognised. Unknown errors propagate
  unchanged.
- 33 new unit tests in
  `admin/tests/error-friendlification-tests.lisp` cover every
  pattern + every dispatch path (substring, class-name,
  USOCKET-prefix fallback, pass-through). Suite is now 87 admin
  checks (was 27).

### Changed
- **Documentation: `OTA_ADMIN_TOKEN` is now described as the
  shared secret it actually is.** New top-level "Authentication"
  section in [docs/operations.org](docs/operations.org) covers
  the resolution order on the server side (built-in `dev-token`
  default → TOML file *not* mapped today, flagged as a known gap
  → `OTA_ADMIN_TOKEN` env-var override), where to set the token
  for each deployment style (`make run-server`, Docker, tarball
  + systemd `EnvironmentFile`, Kubernetes Secret), where
  `ota-admin` reads it from, and how to generate / rotate it.
  The two install procedures' misleading `# set admin_token`
  sudoedit comments are gone — replaced with the real env-var
  setup. README.md gains a one-line note on the dev-stack
  default.

## [1.0.3] - 2026-05-09

Operator-UX release. **All three executables — `ota-server`,
`ota-admin`, `ota-agent` — now ship as standalone binaries with
their own subcommand dispatch and CLI parsing.** No more
`sbcl --core …` invocations or wrapper scripts to remember.

The container image no longer needs the `sbcl` package; the
`ota-server` binary bundles the SBCL runtime and parses
`serve | migrate | gc | shell | version | help` itself, with
`--config=PATH` and the documented `OTA_*` environment variables.

No public-contract changes (HTTP/JSON API, manifest schema, libota
C ABI, state.json all unchanged from 1.0.0).

### Added
- **`ota-server` builds as a standalone executable.**
  `server/build.lisp` now uses `:executable t` + `:toplevel`
  + `:save-runtime-options t`, producing `server/build/ota-server`
  (Mach-O / ELF). The toplevel calls `ota-server:main` on
  `uiop:command-line-arguments`, handles `SIGINT` (exit 130), and
  prints a one-line stderr message + exit 1 on any uncaught error.
- **Subcommand dispatch in `ota-server`**: `serve` (default),
  `migrate`, `gc`, `shell`, `version` / `-v` / `--version`,
  `help` / `-h` / `--help`. Each of `serve`/`migrate`/`gc`
  accepts `--config=PATH` (or `--config PATH`).
- **`version` subcommand on `ota-admin`** for symmetry with the
  other two binaries: `ota-admin version` prints the asd version
  and exits 0; `-v` and `--version` are accepted aliases.
- **CLI smoke suite for `ota-server`** (`server/tests/cli-smoke.lisp`)
  — black-box subprocess tests against the built binary: every
  alias of `help`/`version`, unknown subcommand handling, the
  `migrate` subcommand actually creating the SQLite DB, and the
  `--config=` error path. 6 tests / 29 checks; wired into
  `asdf:test-system "ota-server"`. Skipped cleanly if the binary
  is absent.
- **CLI smoke suite for `ota-admin` extended** with the new
  `version` subcommand (every alias). Suite is now 27 checks
  (was 13).
- `make lisp-test` now depends on `make build-server`, so the new
  CLI smoke tests have a binary to spawn under `make test-unit`.
- `MAIN`'s legacy `(:config <plist-or-path>)` calling convention
  is preserved alongside the new `(:rest argv)` form, so the e2e
  harness and any out-of-tree callers do not break.

### Changed
- **`make run-server`** now invokes `server/build/ota-server serve
  --config=server/etc/ota.dev.toml` directly (no more
  `sbcl --core … --eval …`). Builds the binary on demand if absent.
- **`docker/entrypoint.sh`** is now a thin shim: it materialises
  the default config from the baked-in sample if none is mounted,
  then `exec`'s `/opt/ota/ota-server` with whatever args the
  container received (defaults to `serve --config=$OTA_CONFIG`).
  Removed the per-subcommand `sbcl --core` blocks.
- **Docker image** drops the `sbcl` and `ca-certificates` apt
  packages on the runtime side and ships the ota-server binary
  directly under `/opt/ota/ota-server`. (`ca-certificates` is
  retained because the server does outbound HTTPS in a few
  admin paths.)
- **systemd unit** invokes `/opt/ota/ota-server serve
  --config=/etc/ota/ota.toml` directly; the previous
  `/opt/ota/libexec/ota-entrypoint serve` reference is gone.
- **dist-server tarball layout**: drops `libexec/ota-entrypoint`
  and `ota-server.core`; ships the standalone `ota-server`
  executable at the root and the systemd unit unchanged.

### Notes
- `ota-agent` is and was already a standalone Go binary with full
  subcommand dispatch (`install | upgrade | revert | doctor |
  watch | … | version`). The 1.0.3 work brings the SBCL binaries
  to feature parity with it.

## [1.0.2] - 2026-05-09

Bugfix release. The `MAIN` function's `:config` argument was
documented as a TOML file path (operations runbook, entrypoint
script, `make run-server`, systemd unit) but the implementation
treated it as a pre-built plist — `(getf "/etc/ota/ota.toml"
:data-dir)` crashed at boot. The TOML configuration files
(`ota.dev.toml`, `ota.docker.toml`, `ota.toml.sample`) were never
read by anything; only the `OTA_*` environment variables actually
configured the server.

No public-contract changes (HTTP/JSON API, manifest schema, libota
C ABI, state.json all unchanged from 1.0.0).

### Added
- `ota-server.config` package — TOML 1.0 loader (via `clop`)
  covering every section documented in
  [operations.org](docs/operations.org): `[server]`, `[tls]`,
  `[storage]`, `[catalogue]`, `[patcher]`, `[gc]`,
  `[install_token]`. Resolution order: built-in defaults → TOML
  file → `OTA_*` env-var overrides.
- 26 unit tests in `server/tests/config-tests.lisp` covering all
  invocation paths: empty TOML, every documented section,
  `listen` host/port splitting (with and without colon), shipped
  sample files, malformed TOML, missing file, env-var overrides
  for every documented variable, the precedence rule (env beats
  file beats defaults), and the dispatch table for
  `resolve-config` (nil / pathname / string / plist / bad type).
  The full suite is now 70 checks; all pass.
- `clop` added to the Quicklisp dependency list (Server),
  prebaked into `docker/Dockerfile.dev` and the GitHub Actions
  `dist-server` workflow.

### Fixed
- `ota-server:main` and `ota-server:migrate` now dispatch on the
  `:config` argument's type via `ota-server.config:resolve-config`
  — pathnames and strings load TOML; plists are passed through
  for the e2e harness; `nil` falls back to env-vars + defaults.
- `make run-server`, the systemd unit, and the Docker entrypoint
  all now boot successfully against their respective TOML files.

### Notes
- The TOML schema documented in the operations runbook is parsed
  in full and stored in the resolved plist, but `MAIN` only
  consumes the subset it consumed in 1.0.0 (`:host`, `:port`,
  `:data-dir`, `:hostname`, `:admin-token`, `:tls-cert`,
  `:tls-key`). Wiring the additional keys (worker count, GC
  schedule, install-token TTL, mTLS) into the running server is
  a v1.1 sub-phase.

## [1.0.1] - 2026-05-09

Operations release. No changes to the public contracts (HTTP/JSON
API, manifest schema, libota C ABI, state.json).

### Added
- **Single-host install tarball** for evaluation, debugging, and
  air-gapped deployments: `make dist-server` produces
  `build/dist/delta-ota-server-X.Y.Z.tar.gz`, containing the SBCL
  core, vendored `bsdiff`/`bspatch` helpers, sample config, systemd
  unit, and a thin entrypoint wrapper shared with the Docker image.
  The tarball is built by CI on `master` and tags but is *not*
  attached to GitLab/GitHub Releases — production deployments
  continue to use the published container image.
- `server/etc/ota.toml.sample` — sample configuration for the host
  install (localhost-by-default, sqlite, fs storage).
- `server/etc/ota-server.service` — systemd unit for the host
  install, with the same hardening posture as the container.
- GitLab CI `dist-server` job (stage `package`, 30-day artefact).
- GitHub Actions `dist-server` workflow job mirroring the GitLab
  one (workflow artefact only, on tag).

### Changed
- `docs/operations.org` quick-start split into "container image
  (canonical)" and "single-host tarball (debug / test /
  evaluation)" — the previous quick-start documented an install
  procedure for an artefact that was never built.

### Fixed
- `admin/build.lisp` now registers `server/` with Quicklisp's
  local-projects so the admin core can resolve the `ota-server`
  ASDF system without manual setup.

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
