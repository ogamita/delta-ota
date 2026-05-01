#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Ogamita Ltd.
#
# Restore an OTA root from a backup tarball produced by
# tools/backup.sh. The destination must not exist (or be empty) so
# that we never accidentally clobber a live deployment.
#
# Usage:
#   tools/restore.sh <backup.tar.gz> <ota-root>

set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <backup.tar.gz> <ota-root>" >&2
    exit 2
fi

src="$1"
dst="$2"

[ -f "${src}" ] || { echo "no such backup: ${src}" >&2; exit 1; }
if [ -e "${dst}" ] && [ "$(ls -A "${dst}" 2>/dev/null | head -1)" ]; then
    echo "refusing to restore into non-empty ${dst}" >&2
    exit 1
fi

mkdir -p "${dst}"
tar -C "${dst}" -xzf "${src}"

echo "restore: untarred ${src} into ${dst}"
echo "  blobs:    $(ls "${dst}/blobs"    2>/dev/null | wc -l) prefix dirs"
echo "  patches:  $(ls "${dst}/patches"  2>/dev/null | wc -l) prefix dirs"
echo "  manifests:$(ls "${dst}/manifests" 2>/dev/null | wc -l) software dirs"
echo
echo "Verify integrity with:"
echo "  curl -X POST -H 'Authorization: Bearer \$OTA_ADMIN_TOKEN' \\"
echo "       \$OTA_URL/v1/admin/verify"
