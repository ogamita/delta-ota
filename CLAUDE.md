# -*- mode:markdown; coding:utf-8 -*-

# delta-ota — project instructions for Claude

This repository is **Ogamita Delta OTA** (`delta-ota`): an over-the-air
software-distribution system that ships large packages as binary
deltas (bsdiff / xdelta3).  Owned and distributed by **Ogamita Ltd.**
under **AGPL-3.0-or-later**, with commercial licences available on
request.

The authoritative design documents are:

- [docs/ota-specifications.org](docs/ota-specifications.org) — formal specification.
- [docs/ota-implementation-plan.org](docs/ota-implementation-plan.org) — delivery plan, phased.
- [docs/dependencies.org](docs/dependencies.org) — vendored sources, pinned commits, SHA-256.
- [docs/THIRD_PARTY_LICENSES.org](docs/THIRD_PARTY_LICENSES.org) — aggregated upstream licences (shipped in the client).

Read the spec and the plan before changing anything substantive.

## Architecture in one paragraph

Three artefacts: `ota-server` (SBCL daemon on Linux, HTTP/JSON API,
Woo + sendfile, content-addressed blobs/patches), `ota-admin` (SBCL
CLI for developers), and the client = `libota` (Go, built as
`c-shared` and `c-archive`) + `ota-agent` (Go static binary on
Windows / macOS / Linux).  Patches are bsdiff (default) or xdelta3.
The Go client is cgo-free and ships as a single self-contained
binary per OS.  The server vendors C `bsdiff` / `xdelta3` and builds
its own helper binaries — no system tools at runtime.

## Languages and stacks

| Component        | Language                                  |
|------------------|-------------------------------------------|
| `ota-server`     | Common Lisp (SBCL) + Woo (Clack adapter)  |
| `ota-admin` CLI  | Common Lisp (SBCL)                        |
| `libota` core    | Go (`-buildmode=c-shared` and `c-archive`)|
| `ota-agent` CLI  | Go, statically linked, no cgo             |
| Web install page | Static HTML + minimal JS, served by `ota-server` |
| Catalogue DB     | SQLite by default; PostgreSQL when scaled |

## Repository layout

```
delta-ota/
├── docs/                       specifications, plan, ADRs, dependencies
├── server/                     SBCL project (asdf system "ota-server")
├── admin/                      SBCL CLI (asdf system "ota-admin")
├── client/                     Go module (libota + ota-agent)
├── schemas/                    manifest.schema.json, api.openapi.yaml
├── vendor/                     server-side vendored sources (C, CL)
├── client/internal/vendor/     client-side vendored sources (Go)
├── docker/                     Dockerfiles, docker-compose.yml
├── tools/                      vendor-import.sh, vendor-verify.sh, etc.
├── tests/                      cross-component integration tests
└── ci/                         GitLab CI / GitHub Actions configs
```

## Hard rules

These are non-negotiable.  Violations are caught in CI; do not
"temporarily" relax them.

### Self-containment

- The client binary has **no runtime dependency** on `bsdiff`,
  `bspatch`, `xdelta3`, `tar`, OpenSSL, or any other external tool
  or shared library.  `ldd ota-agent` (Linux) and `otool -L
  ota-agent` (macOS) must show no third-party dynamic dependencies.
- The Go client is **cgo-free**: `CGO_ENABLED=0`, and built with
  `-tags=netgo,osusergo -trimpath`.
- The server invokes vendored `bsdiff` / `xdelta3` binaries by
  **absolute path** baked into config.  It must not consult `$PATH`
  for these tools.

### Vendoring policy

- Every vendored source must be **permissively licensed**: MIT,
  BSD-2/3-Clause, Apache-2.0, or ISC.  GPL / LGPL / AGPL sources
  are **prohibited** in `vendor/` and `client/internal/vendor/`.
  In particular `jmacd/xdelta-gpl` (GPLv2) is *not* used; we
  vendor `jmacd/xdelta` (Apache-2.0).
- Note the apparent contradiction: this *project* is AGPL-3.0, but
  *vendored dependencies* must be permissive.  AGPL is one-way
  compatible with the permissive licences we vendor — they may be
  combined into an AGPL whole.  GPL-vendored code, by contrast,
  would force consumers of `libota` (which we ship under both
  AGPL and commercial terms) into GPL, which is unacceptable.
- Each vendored subdir carries the verbatim upstream `LICENSE` and
  a `VENDORED.md` (upstream URL, commit hash, SHA-256 of the tree,
  import date, any local patches).
- `tools/vendor-verify.sh` re-hashes every vendored subtree and
  fails CI on any mismatch.  Never edit vendored code in place; if
  a patch is needed, record it as a `.patch` file alongside
  `VENDORED.md` and apply it in the build.

### Determinism

- The release blob (`.tar`) must be byte-identical for two builds
  of the same source: entries sorted lexicographically, `mtime=0`,
  `uid=gid=0`, names empty, modes normalised to 0644 / 0755 (set by
  the build manifest, not by source `fs` bits), no xattrs, no
  compression at the blob layer.  Patch quality depends on this.
- Patches and blobs are content-addressed by SHA-256.  Identity is
  the hash; never trust filenames as identity.

### Atomicity on the client

- `current` only ever flips when the new distribution is fully
  validated on disk.  Failure at any step leaves the previously
  working release intact.
- The client never modifies `current` while the application is
  running over it — staging happens in a sibling directory and the
  flip is an atomic symlink/junction swap.

### Cryptography

- TLS 1.3 throughout; mTLS optional but recommended.
- Manifests are signed Ed25519; clients verify against a pinned
  public key bundle.
- All artefact integrity checks use SHA-256.  No MD5, no SHA-1.

## Hosting and CI

- **Primary remote**: `gitlab.com:ogamita/delta-ota` (origin).
  GitLab CI is the canonical pipeline (`.gitlab-ci.yml`).
- **Mirror**: `github.com:ogamita/delta-ota`, kept in sync by a
  GitLab push mirror.  GitHub Actions runs a *subset* of CI as a
  smoke test (`.github/workflows/ci.yml`); the GitLab pipeline is
  authoritative.
- Container images are built and pushed to the GitLab container
  registry: `registry.gitlab.com/ogamita/delta-ota/...`.

## Docker

A development image and a production image of `ota-server` are
maintained under `docker/`:

- `docker/Dockerfile.server` — multi-stage build of `ota-server`
  with vendored `bsdiff` / `xdelta3` helpers; runs as a non-root
  user; exposes 8443.
- `docker/Dockerfile.dev` — base image used by CI for SBCL+Go
  toolchain.
- `docker/docker-compose.yml` — server + Postgres + MinIO (S3
  compatible), wired together for local end-to-end tests.

A deployment is either:

1. a single dedicated host (a customer's own server in their own
   data centre), or
2. a Kubernetes deployment in a cloud, with PostgreSQL as the
   catalogue and S3 / S3-compatible storage for blobs and patches.

The same image supports both; the storage and database backends
are switched in `ota.toml`.

## When working on this code

- Read [docs/ota-specifications.org](docs/ota-specifications.org)
  and [docs/ota-implementation-plan.org](docs/ota-implementation-plan.org)
  before non-trivial changes.  If a change contradicts the spec,
  update the spec first (with reasoning) — do not let the code and
  the spec drift apart.
- Phases in the plan are *vertical slices*; do not break the
  end-to-end pipeline to land work earlier.
- Tests that assert determinism (tar byte-identity, patch
  reconstruction → manifest hash) are canaries.  Do not weaken or
  skip them to make a change land.
- Prefer `org-mode` for documentation in `docs/` (matches the rest
  of the documents).  Markdown is acceptable at the repo root
  (`README.md`, `CLAUDE.md`, `LICENSE`).
- Commit messages: imperative mood, body explains *why*, footer
  carries `Signed-off-by:` (DCO).  Reference `docs/...:section` when
  a commit implements a specific specification clause.
- **Never peruse backup files** (`*~`, `*.~N~`).  See parent CLAUDE.md.
- **Avoid absolute pathnames** in committed files.  See parent
  CLAUDE.md.

## Licence

The project is **AGPL-3.0-or-later**.  Commercial licences for
proprietary distribution are available from Ogamita Ltd. — see
[README.md](README.md).

When adding new files, prepend an SPDX header:

```
// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Ogamita Ltd.
```

(Use the comment syntax appropriate to the file: `;;` for Lisp,
`#` for shell / Makefiles, `//` for Go, `<!--` for HTML, etc.)
