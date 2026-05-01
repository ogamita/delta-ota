#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Ogamita Ltd.
#
# vendor-verify.sh — recompute the SHA-256 of every vendored subtree
# and compare against the value recorded in its VENDORED.md.
# Fails the build on any mismatch.

set -eu

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "${repo_root}"

failures=0
checked=0

for vd in vendor client/internal/vendor; do
    [ -d "${vd}" ] || continue
    for dir in "${vd}"/*/; do
        [ -d "${dir}" ] || continue
        name="$(basename "${dir}")"
        meta="${dir}VENDORED.md"

        if [ ! -f "${meta}" ]; then
            echo "vendor-verify: ${dir}: missing VENDORED.md" >&2
            failures=$((failures + 1))
            continue
        fi

        recorded="$(awk -F'`' '/Tree SHA-256/ {print $2; exit}' "${meta}")"
        if [ -z "${recorded}" ]; then
            echo "vendor-verify: ${dir}: no Tree SHA-256 in VENDORED.md" >&2
            failures=$((failures + 1))
            continue
        fi

        actual="$(cd "${dir}" && find . -type f ! -name VENDORED.md -print0 \
            | sort -z \
            | xargs -0 sha256sum \
            | sha256sum | awk '{print $1}')"

        if [ "${recorded}" != "${actual}" ]; then
            echo "vendor-verify: ${dir}: HASH MISMATCH" >&2
            echo "    recorded: ${recorded}" >&2
            echo "    actual:   ${actual}" >&2
            failures=$((failures + 1))
        else
            echo "vendor-verify: ${name}: OK"
        fi
        checked=$((checked + 1))
    done
done

if [ "${checked}" -eq 0 ]; then
    echo "vendor-verify: no vendored components found (yet)"
    exit 0
fi

if [ "${failures}" -ne 0 ]; then
    echo "vendor-verify: ${failures} failure(s) out of ${checked}" >&2
    exit 1
fi

echo "vendor-verify: ${checked} component(s) OK"
