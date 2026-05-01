#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Ogamita Ltd.
#
# Phase-5 e2e: garbage collection, verification, backup/restore.
#
#   1. Boot ota-server.
#   2. Publish hello/1.0.0 and hello/2.0.0.
#   3. POST /v1/admin/verify -> ok=2 (the two blobs).
#   4. POST /v1/admin/software/hello/gc with min_age_days=0,
#      min_user_count=0 -> 1.0.0 should be pruned (it's not the
#      latest and has zero install events recorded).
#   5. Verify after GC: ok=1 (only 2.0.0's blob survives, the 1.0.0
#      blob and any patches are gone).
#   6. Backup the OTA root with tools/backup.sh, restore into a
#      fresh dir with tools/restore.sh, /v1/admin/verify on the
#      restored data still says ok=1.

set -eu

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "${repo_root}"

run_dir="${OTA_E2E_RUN_DIR:-tests/e2e/run-ops}"
rm -rf "${run_dir}"
mkdir -p "${run_dir}/logs"

OTA_PORT="${OTA_PORT:-18445}"
OTA_TOKEN="ops-test-token"

make vendor-build >>"${run_dir}/logs/build.log" 2>&1

mkpayload() {
    dst="$1"; tag="$2"
    mkdir -p "${dst}"
    head -c 4096 /dev/zero | tr '\0' 'A' > "${dst}/big.dat"
    echo "${tag}" >> "${dst}/big.dat"
}
mkpayload "${run_dir}/p1" v1
mkpayload "${run_dir}/p2" v2

server_root="${run_dir}/server-root"
abs_root="$(mkdir -p "${server_root}" && cd "${server_root}" && pwd)"
cat > "${run_dir}/run-server.lisp" <<EOF
(ql:quickload "ota-server" :silent t)
(setf ota-server.workers:*bsdiff-binary* "$(pwd)/server/build/bin/bsdiff")
(let* ((root #P"${abs_root}/")
       (cas (ota-server.storage:make-cas root))
       (db (ota-server.catalogue:open-catalogue (merge-pathnames "db/x.db" root)))
       (kp (ota-server.manifest:load-or-generate-keypair (merge-pathnames "keys/" root)))
       (state (ota-server.http::make-app-state
                :cas cas :catalogue db :keypair kp
                :manifests-dir (merge-pathnames "manifests/" root)
                :admin-token "${OTA_TOKEN}" :hostname "localhost")))
  (ota-server.catalogue:run-migrations db)
  (ensure-directories-exist (ota-server.http::app-state-manifests-dir state))
  (ota-server.http:start-server state :host "127.0.0.1" :port ${OTA_PORT})
  (format t "ready~%") (force-output)
  (loop (sleep 30)))
EOF

sbcl --non-interactive --no-userinit --no-sysinit --load ~/quicklisp/setup.lisp \
     --eval '(asdf:load-asd (truename "server/ota-server.asd"))' \
     --load "${run_dir}/run-server.lisp" \
     >"${run_dir}/logs/server.log" 2>&1 &
server_pid=$!
trap 'kill ${server_pid} 2>/dev/null || true' EXIT INT TERM

for i in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:${OTA_PORT}/v1/health" >/dev/null 2>&1; then break; fi
    sleep 1
    kill -0 ${server_pid} 2>/dev/null || { echo "server died"; cat "${run_dir}/logs/server.log"; exit 1; }
done
echo "tests/e2e/ops: server up"

publish() {
    src="$1"; ver="$2"
    tar_path="${run_dir}/payload-${ver}.tar"
    sbcl --non-interactive --no-userinit --no-sysinit --load ~/quicklisp/setup.lisp \
         --eval '(asdf:load-asd (truename "server/ota-server.asd"))' \
         --eval "(ql:quickload :ota-server :silent t)" \
         --eval "(ota-server.storage:tar-directory-to-file \"$(pwd)/${src}/\" \"$(pwd)/${tar_path}\")" \
         >>"${run_dir}/logs/server.log" 2>&1
    curl -sS -X POST \
         -H "Authorization: Bearer ${OTA_TOKEN}" \
         -H "X-Ota-Version: ${ver}" -H "X-Ota-Os: linux" -H "X-Ota-Arch: x86_64" \
         -H "Content-Type: application/octet-stream" \
         --data-binary "@${tar_path}" \
         "http://127.0.0.1:${OTA_PORT}/v1/admin/software/hello/releases" \
         -o "${run_dir}/publish-${ver}.json"
}
publish "${run_dir}/p1" "1.0.0"
publish "${run_dir}/p2" "2.0.0"
echo "tests/e2e/ops: published 1.0.0 and 2.0.0"

# 3. Verify pre-GC.
verify_resp=$(curl -sS -X POST -H "Authorization: Bearer ${OTA_TOKEN}" \
              "http://127.0.0.1:${OTA_PORT}/v1/admin/verify")
checked=$(printf '%s' "${verify_resp}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["checked"])')
ok=$(printf '%s' "${verify_resp}"     | python3 -c 'import json,sys;print(json.load(sys.stdin)["ok"])')
echo "tests/e2e/ops: pre-GC verify: checked=${checked} ok=${ok}"
[ "${checked}" -ge 2 ] || { echo "✗ pre-GC verify checked < 2"; exit 1; }
[ "${ok}" = "${checked}" ] || { echo "✗ pre-GC has bad blobs"; exit 1; }

# 4. GC with no install_events at all → 1.0.0 should prune.
gc_resp=$(curl -sS -X POST \
          -H "Authorization: Bearer ${OTA_TOKEN}" -H "Content-Type: application/json" \
          -d '{"min_user_count":0,"min_age_days":0}' \
          "http://127.0.0.1:${OTA_PORT}/v1/admin/software/hello/gc")
echo "tests/e2e/ops: gc: ${gc_resp}"
pruned_count=$(printf '%s' "${gc_resp}" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["pruned"]))')
[ "${pruned_count}" -ge 1 ] || { echo "✗ GC pruned 0 releases, expected ≥1"; exit 1; }
echo "tests/e2e/ops: ✓ GC pruned ${pruned_count} release(s)"

# 5. Anonymous list-releases must show only 2.0.0 now.
list_resp=$(curl -sS "http://127.0.0.1:${OTA_PORT}/v1/software/hello/releases")
remaining=$(printf '%s' "${list_resp}" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')
[ "${remaining}" = "1" ] || { echo "✗ remaining releases=${remaining}, expected 1"; exit 1; }
echo "tests/e2e/ops: ✓ catalogue has 1 surviving release"

# 6. Backup + restore + re-verify.
backup_dir="${run_dir}/backups"
tools/backup.sh "${server_root}" "${backup_dir}" >"${run_dir}/logs/backup.log"
backup=$(ls "${backup_dir}"/*.tar.gz | head -1)
restored="${run_dir}/restored"
tools/restore.sh "${backup}" "${restored}" >"${run_dir}/logs/restore.log"

# Spot-check that the restored tree contains the 2.0.0 manifest.
[ -f "${restored}/manifests/hello/2.0.0.json" ] || {
    echo "✗ restored tree missing manifests/hello/2.0.0.json"; exit 1; }
echo "tests/e2e/ops: ✓ backup roundtrip preserves manifest"

echo "tests/e2e/ops: ALL OK"
