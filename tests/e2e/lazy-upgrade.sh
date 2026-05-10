#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Ogamita Ltd.
#
# v1.6 e2e: lazy upgrade-time patch build.
#
#   1. Boot ota-server, publish 1.2 then 1.3 then -- out-of-order --
#      1.2.1.  Per the fan-in policy, 1.2.1's publish builds patches
#      FROM 1.2 and 1.3 TO 1.2.1 (forward-only).  There is NO patch
#      from 1.2.1 TO 1.3.
#
#   2. GET /v1/software/big/upgrade?from=1.2.1&to=1.3 hits a missing
#      patch -- the server should build on demand and return
#      built_on_demand=true.
#
#   3. Same GET again: now built_on_demand=false (catalogue cached
#      the patch).
#
#   4. GET with from=to errors 400.
#   5. GET with unknown version errors 404.
#
# This is the v1.6 piece that closes the out-of-order-publish gap
# (debug versions inserted into an older release stream).

set -eu

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "${repo_root}"

run_dir="${OTA_E2E_RUN_DIR:-tests/e2e/run-lazy-upgrade}"
rm -rf "${run_dir}"
mkdir -p "${run_dir}/logs"

OTA_PORT="${OTA_PORT:-18488}"
OTA_TOKEN="lazy-upgrade-test-token"

make vendor-build >>"${run_dir}/logs/build.log" 2>&1

make_payload() {
    dst="$1"; tag="$2"
    mkdir -p "${dst}"
    head -c 4096 /dev/zero | tr '\0' 'A' > "${dst}/big.dat"
    echo "${tag}" >> "${dst}/big.dat"
}
make_payload "${run_dir}/p120" v1.2
make_payload "${run_dir}/p130" v1.3
make_payload "${run_dir}/p121" v1.2.1

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
                :admin-token "${OTA_TOKEN}"
                :hostname "localhost")))
  (ota-server.catalogue:run-migrations db)
  (ensure-directories-exist (ota-server.http::app-state-manifests-dir state))
  (ota-server.catalogue:reset-stale-running-jobs db)
  (setf (ota-server.http::app-state-pool state)
        (ota-server.workers:start-patch-pool cas db :size 2))
  (ota-server.http:start-server state :host "127.0.0.1" :port ${OTA_PORT}
                                      :worker-num 4)
  (format t "ota-server: ready on ${OTA_PORT}~%")
  (force-output)
  (loop (sleep 30)))
EOF

server_log="${run_dir}/logs/server.log"
sbcl --non-interactive --no-userinit --no-sysinit \
     --load ~/quicklisp/setup.lisp \
     --eval '(asdf:load-asd (truename "server/ota-server.asd"))' \
     --load "${run_dir}/run-server.lisp" \
     >"${server_log}" 2>&1 &
server_pid=$!
trap 'kill ${server_pid} 2>/dev/null || true' EXIT INT TERM

for i in $(seq 1 30); do
    curl -sf "http://127.0.0.1:${OTA_PORT}/v1/health" >/dev/null 2>&1 && break
    sleep 1
done
curl -sf "http://127.0.0.1:${OTA_PORT}/v1/health" >/dev/null || {
    echo "server failed to start"; cat "${server_log}"; exit 1; }
echo "tests/e2e/lazy-upgrade: server up"

publish() {
    src="$1"; ver="$2"
    tar_path="${run_dir}/payload-${ver}.tar"
    sbcl --non-interactive --no-userinit --no-sysinit \
         --load ~/quicklisp/setup.lisp \
         --eval '(asdf:load-asd (truename "server/ota-server.asd"))' \
         --eval "(ql:quickload :ota-server :silent t)" \
         --eval "(ota-server.storage:tar-directory-to-file \"$(pwd)/${src}/\" \"$(pwd)/${tar_path}\")" \
         >>"${server_log}" 2>&1
    curl -sS -X POST \
         -H "Authorization: Bearer ${OTA_TOKEN}" \
         -H "X-Ota-Version: ${ver}" \
         -H "X-Ota-Os: linux" -H "X-Ota-Arch: x86_64" \
         -H "X-Ota-Os-Versions: 12" \
         --data-binary "@${tar_path}" \
         "http://127.0.0.1:${OTA_PORT}/v1/admin/software/big/releases" \
         -o "${run_dir}/publish-${ver}.json"
    grep -q '"release_id"' "${run_dir}/publish-${ver}.json" \
        || { echo "publish ${ver} failed: $(cat ${run_dir}/publish-${ver}.json)"; exit 1; }
}

# Out-of-order publish: 1.2 then 1.3 (which builds 1.2->1.3),
# then 1.2.1 which DOES NOT cause a 1.2.1->1.3 patch (fan-in is
# forward-only: 1.2.1's publish builds 1.2->1.2.1 and 1.3->1.2.1).
publish "${run_dir}/p120" "1.2"
publish "${run_dir}/p130" "1.3"
publish "${run_dir}/p121" "1.2.1"
echo "tests/e2e/lazy-upgrade: published 1.2 -> 1.3 -> 1.2.1 (out of order)"

# Sanity check: confirm the catalogue doesn't have a 1.2.1->1.3 patch.
patches=$(curl -sS -H "Authorization: Bearer ${OTA_TOKEN}" \
               "http://127.0.0.1:${OTA_PORT}/v1/software/big/releases/1.3/manifest")
if echo "${patches}" | grep -q '"from":"1.2.1"'; then
    echo "  ✗ catalogue UNEXPECTEDLY has a 1.2.1->1.3 patch already; test premise broken"
    exit 1
fi
echo "  ✓ confirmed: no 1.2.1->1.3 patch exists yet"

# === (2) First request: build on demand
echo "tests/e2e/lazy-upgrade: (2) lazy build 1.2.1 -> 1.3..."
r=$(curl -sS "http://127.0.0.1:${OTA_PORT}/v1/software/big/upgrade?from=1.2.1&to=1.3")
echo "  response: ${r}"
echo "${r}" | grep -q '"built_on_demand":true' \
    || { echo "  ✗ expected built_on_demand=true on first call"; exit 1; }
echo "${r}" | grep -q '"from":"1.2.1"' \
    || { echo "  ✗ response missing from=1.2.1"; exit 1; }
echo "${r}" | grep -q '"to":"1.3"' \
    || { echo "  ✗ response missing to=1.3"; exit 1; }
echo "  ✓ patch built on demand"

# === (3) Second request: served from cache
echo "tests/e2e/lazy-upgrade: (3) repeat -> served from cache..."
r=$(curl -sS "http://127.0.0.1:${OTA_PORT}/v1/software/big/upgrade?from=1.2.1&to=1.3")
echo "  response: ${r}"
echo "${r}" | grep -q '"built_on_demand":false' \
    || { echo "  ✗ expected built_on_demand=false on second call"; exit 1; }
echo "  ✓ second call hit the cache"

# === (4) Same release from=to -> 400
echo "tests/e2e/lazy-upgrade: (4) from=to -> 400..."
code=$(curl -sS -o /dev/null -w '%{http_code}' \
            "http://127.0.0.1:${OTA_PORT}/v1/software/big/upgrade?from=1.3&to=1.3")
[ "${code}" = "400" ] || { echo "  ✗ expected 400, got ${code}"; exit 1; }
echo "  ✓ 400 on from=to"

# === (5) Unknown version -> 404
echo "tests/e2e/lazy-upgrade: (5) unknown version -> 404..."
code=$(curl -sS -o /dev/null -w '%{http_code}' \
            "http://127.0.0.1:${OTA_PORT}/v1/software/big/upgrade?from=1.2.1&to=9.9.9")
[ "${code}" = "404" ] || { echo "  ✗ expected 404, got ${code}"; exit 1; }
echo "  ✓ 404 on unknown to version"

# === (6) Downloading the lazily-built patch works
echo "tests/e2e/lazy-upgrade: (6) download the built patch..."
sha=$(echo "${r}" | grep -o '"sha256":"[^"]*"' | cut -d'"' -f4)
patch_file="${run_dir}/lazy.patch"
http_status=$(curl -sS -o "${patch_file}" -w '%{http_code}' \
                   "http://127.0.0.1:${OTA_PORT}/v1/patches/${sha}")
[ "${http_status}" = "200" ] || { echo "  ✗ download returned ${http_status}"; exit 1; }
[ -s "${patch_file}" ] || { echo "  ✗ patch file is empty"; exit 1; }
echo "  ✓ patch is downloadable"

echo "PASS: tests/e2e/lazy-upgrade — out-of-order publish gap closed"
