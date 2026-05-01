#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Ogamita Ltd.
#
# vendor-import.sh — fetch a third-party source tree, extract under
# vendor/<name>/ or client/internal/vendor/<name>/, copy LICENSE,
# and write VENDORED.md with provenance metadata.
#
# Usage:
#   tools/vendor-import.sh <name> <upstream-tarball-url> <commit-or-tag> \
#                          <license-spdx> <target-dir> [subdir-in-tarball]
#
# Example:
#   tools/vendor-import.sh mendsley-bsdiff \
#       https://github.com/mendsley/bsdiff/archive/<commit>.tar.gz \
#       <commit> BSD-2-Clause vendor
#
# Idempotent: re-running with the same inputs produces an identical
# tree. Uses only curl, tar, sha256sum, sed -- runnable on any
# developer workstation without admin rights.

set -eu

if [ "$#" -lt 5 ]; then
    cat >&2 <<EOF
usage: $0 <name> <tarball-url> <commit> <spdx-id> <target-dir> [subdir]

  name        directory name under target-dir
  tarball-url URL of a .tar.gz tarball pinned to <commit>
  commit      upstream commit hash or tag (recorded in VENDORED.md)
  spdx-id     SPDX licence identifier (must be permissive)
  target-dir  vendor | client/internal/vendor
  subdir      optional path inside the tarball to import (defaults to root)
EOF
    exit 2
fi

name="$1"
url="$2"
commit="$3"
spdx="$4"
target="$5"
subdir="${6:-}"

case "${spdx}" in
    MIT|BSD-2-Clause|BSD-3-Clause|Apache-2.0|ISC) ;;
    *)
        echo "vendor-import: refusing non-permissive licence '${spdx}'" >&2
        echo "  permitted: MIT, BSD-2-Clause, BSD-3-Clause, Apache-2.0, ISC" >&2
        exit 1
        ;;
esac

case "${target}" in
    vendor|client/internal/vendor) ;;
    *)
        echo "vendor-import: target-dir must be 'vendor' or 'client/internal/vendor'" >&2
        exit 1
        ;;
esac

dest="${target}/${name}"

# Repo root: caller invokes us from anywhere, but paths are repo-root-relative.
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "${repo_root}"

mkdir -p "${dest}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

echo "vendor-import: fetching ${url}"
curl -fsSL "${url}" -o "${tmp}/source.tar.gz"

# Record the upstream tarball hash so we can detect upstream tampering.
upstream_sha="$(sha256sum "${tmp}/source.tar.gz" | awk '{print $1}')"

mkdir -p "${tmp}/extracted"
tar -xzf "${tmp}/source.tar.gz" -C "${tmp}/extracted"

# GitHub-style tarballs unwrap into a single top-level directory.
top="$(find "${tmp}/extracted" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
src="${top}"
[ -n "${subdir}" ] && src="${top}/${subdir}"

if [ ! -d "${src}" ]; then
    echo "vendor-import: source path '${src}' not found in tarball" >&2
    exit 1
fi

# Wipe the destination tree (preserving VENDORED.md history would lie).
rm -rf "${dest}"
mkdir -p "${dest}"

# Copy the imported tree.
(cd "${src}" && tar -cf - .) | (cd "${dest}" && tar -xf -)

# Locate the upstream LICENSE.
license_src=""
for cand in LICENSE LICENSE.txt LICENSE.md COPYING COPYING.txt; do
    if [ -f "${top}/${cand}" ]; then
        license_src="${top}/${cand}"
        break
    fi
done

if [ -n "${license_src}" ]; then
    cp "${license_src}" "${dest}/LICENSE"
else
    echo "vendor-import: WARNING — no LICENSE file found in upstream tarball" >&2
    echo "vendor-import: write ${dest}/LICENSE manually before committing" >&2
fi

# Compute SHA-256 of the imported tree.
# Portable across macOS / Linux / Alpine: byte-wise sort, with the
# per-file hash list re-sorted after xargs to absorb any batching
# that might reorder output. LC_ALL=C ensures locale-independent.
tree_sha="$(cd "${dest}" && \
    LC_ALL=C find . -type f ! -name VENDORED.md -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 sha256sum \
    | LC_ALL=C sort \
    | sha256sum | awk '{print $1}')"

today="$(date -u +%Y-%m-%d)"

cat > "${dest}/VENDORED.md" <<EOF
# Vendored: ${name}

|                  |                                                 |
|------------------|-------------------------------------------------|
| Upstream URL     | ${url}                                          |
| Upstream commit  | \`${commit}\`                                   |
| Upstream subdir  | ${subdir:-(repo root)}                          |
| Licence          | ${spdx} (see ./LICENSE)                         |
| Imported on      | ${today}                                        |
| Tarball SHA-256  | \`${upstream_sha}\`                             |
| Tree SHA-256     | \`${tree_sha}\`                                 |

This directory contains a verbatim copy of upstream source. Do not
edit files here directly. To apply local changes, record a \`.patch\`
file in this directory and apply it from the build, or open an
upstream PR.

Re-imports must update both \`docs/dependencies.org\` and the
\`Tree SHA-256\` above.
EOF

echo "vendor-import: ${name} -> ${dest}"
echo "  tree sha256: ${tree_sha}"
echo
echo "Now update docs/dependencies.org with this row:"
echo "  ${name} | ${commit} | ${spdx} | ${today} | ${tree_sha}"
