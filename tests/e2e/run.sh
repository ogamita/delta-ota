#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Ogamita Ltd.
#
# Phase-0 e2e harness skeleton. Real implementation lands in phase 1.

set -eu

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "${repo_root}"

echo "tests/e2e: phase-0 skeleton — nothing to test yet"
echo "tests/e2e: when phase 1 lands, this script will:"
echo "  1. start ota-server in a temporary OTA_ROOT"
echo "  2. publish examples/hello as software=hello version=1.0.0"
echo "  3. install it via ota-agent into a clean OTA_HOME"
echo "  4. assert the installed tree's tar matches the published blob hash"
echo "  5. kill the server mid-download and assert resume works"

exit 0
