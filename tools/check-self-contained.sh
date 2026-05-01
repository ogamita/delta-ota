#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Ogamita Ltd.
#
# check-self-contained.sh — assert that a built client binary has no
# third-party dynamic dependencies.
#
# Usage: tools/check-self-contained.sh path/to/ota-agent

set -eu

bin="${1:?usage: $0 <binary>}"

if [ ! -f "${bin}" ]; then
    echo "check-self-contained: ${bin} does not exist" >&2
    exit 1
fi

uname_s="$(uname -s)"
case "${uname_s}" in
    Linux)
        # ldd prints "not a dynamic executable" for fully static binaries.
        if ldd "${bin}" 2>&1 | grep -qE 'not a dynamic executable|statically linked'; then
            echo "check-self-contained: ${bin}: static OK"
            exit 0
        fi
        # Otherwise: a few stdlib libs (linux-vdso, ld-linux, libc, libpthread)
        # are tolerated but anything else is a regression.
        bad="$(ldd "${bin}" 2>&1 | awk '{print $1}' \
            | grep -vE '^(linux-vdso|ld-linux|libc|libpthread|libdl|libm|librt)\.' \
            | grep -vE '^/' || true)"
        if [ -n "${bad}" ]; then
            echo "check-self-contained: ${bin}: unexpected dynamic deps:" >&2
            echo "${bad}" >&2
            exit 1
        fi
        echo "check-self-contained: ${bin}: only stdlib dynamic deps OK"
        ;;
    Darwin)
        bad="$(otool -L "${bin}" | tail -n +2 | awk '{print $1}' \
            | grep -vE '^/usr/lib/(libSystem|libc\+\+|libobjc)' || true)"
        if [ -n "${bad}" ]; then
            echo "check-self-contained: ${bin}: unexpected dynamic deps:" >&2
            echo "${bad}" >&2
            exit 1
        fi
        echo "check-self-contained: ${bin}: only macOS stdlib OK"
        ;;
    *)
        echo "check-self-contained: skip on ${uname_s}" >&2
        ;;
esac
