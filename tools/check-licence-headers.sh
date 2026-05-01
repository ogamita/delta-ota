#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Ogamita Ltd.
#
# check-licence-headers.sh — every first-party source file must carry
# an SPDX-License-Identifier header. Vendored sources are exempt.

set -eu

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "${repo_root}"

# Files that must carry an SPDX header (first-party source).
patterns="
*.go
*.lisp
*.asd
*.sh
Makefile
*.yml
*.yaml
Dockerfile*
"

# Directories that are exempt (vendored, generated, third-party).
exempt_re='^\(vendor/\|client/internal/vendor/\|docs/THIRD_PARTY_LICENSES\|docs/ota-specifications.org.draft1\|LICENSE\)'

failures=0

# shellcheck disable=SC2086
files="$(git ls-files ${patterns} 2>/dev/null || true)"

for f in ${files}; do
    case "${f}" in
        vendor/*|client/internal/vendor/*) continue ;;
    esac
    if echo "${f}" | grep -q "${exempt_re}"; then
        continue
    fi
    # Skip files that exist in the index but not on disk (e.g. a
    # deletion that has not been committed yet).
    [ -f "${f}" ] || continue
    if ! head -n 5 "${f}" | grep -q 'SPDX-License-Identifier'; then
        echo "missing SPDX header: ${f}" >&2
        failures=$((failures + 1))
    fi
done

if [ "${failures}" -ne 0 ]; then
    echo "check-licence-headers: ${failures} file(s) without SPDX header" >&2
    exit 1
fi

echo "check-licence-headers: OK"
