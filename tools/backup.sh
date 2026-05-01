#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Ogamita Ltd.
#
# Backup the entire OTA root: catalogue DB, blobs, patches, signed
# manifests, signing keys, and config.  The tarball is gzipped and
# named with the UTC timestamp.
#
# Usage:
#   tools/backup.sh <ota-root> <output-dir>
#
# Example:
#   tools/backup.sh /var/lib/ota /var/backups/ota

set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <ota-root> <output-dir>" >&2
    exit 2
fi

ota_root="$1"
out_dir="$2"

[ -d "${ota_root}" ] || { echo "no such ota-root: ${ota_root}" >&2; exit 1; }
mkdir -p "${out_dir}"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
out="${out_dir}/ota-backup-${stamp}.tar.gz"

# Quiesce the DB by relying on SQLite's WAL: we copy the file while
# the server is running.  For PostgreSQL deployments, run pg_dump
# separately and add the dump to the tarball.
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

cp -R "${ota_root}/db"        "${tmp_dir}/db"
cp -R "${ota_root}/blobs"     "${tmp_dir}/blobs"     2>/dev/null || mkdir -p "${tmp_dir}/blobs"
cp -R "${ota_root}/patches"   "${tmp_dir}/patches"   2>/dev/null || mkdir -p "${tmp_dir}/patches"
cp -R "${ota_root}/manifests" "${tmp_dir}/manifests" 2>/dev/null || mkdir -p "${tmp_dir}/manifests"
cp -R "${ota_root}/etc"       "${tmp_dir}/etc"       2>/dev/null || mkdir -p "${tmp_dir}/etc"

tar -C "${tmp_dir}" -czf "${out}" .
sha256sum "${out}" > "${out}.sha256" 2>/dev/null || shasum -a 256 "${out}" > "${out}.sha256"

echo "backup: ${out}"
echo "  sha256: $(cat "${out}.sha256" | awk '{print $1}')"
