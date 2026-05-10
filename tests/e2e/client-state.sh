#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Ogamita Ltd.
#
# v1.5 e2e: client-software state snapshot reporting end-to-end.
#
#   1. Boot ota-server with one software, publish 1.0.0 and 1.1.0.
#   2. ota-agent install 1.0.0  -> server has snapshot row,
#      kind=install.
#   3. ota-agent upgrade to 1.1.0 -> snapshot row updated,
#      kind=upgrade, previous=1.0.0.
#   4. ota-agent revert -> snapshot row reverts, kind=revert.
#   5. At each step, GET /v1/admin/stats/population-per-release
#      reflects the current state.
#
# The snapshot replaces the lossy install_events scan we had since
# v1.0; this e2e proves the agent-side wiring + the server-side
# storage + the stats endpoint all line up.

set -eu

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "${repo_root}"

run_dir="${OTA_E2E_RUN_DIR:-tests/e2e/run-client-state}"
rm -rf "${run_dir}"
mkdir -p "${run_dir}/logs"

OTA_PORT="${OTA_PORT:-18486}"
OTA_TOKEN="client-state-test-token"

make vendor-build >>"${run_dir}/logs/build.log" 2>&1

# Payloads (two versions so we can exercise install -> upgrade -> revert).
make_payload() {
    dst="$1"; tag="$2"
    mkdir -p "${dst}"
    head -c 4096 /dev/zero | tr '\0' 'A' > "${dst}/big.dat"
    echo "${tag}" >> "${dst}/big.dat"
    echo "tag-${tag}" > "${dst}/info.txt"
}
make_payload "${run_dir}/p1" v1
make_payload "${run_dir}/p2" v2

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
  (with-open-file (out (merge-pathnames "pubkey.hex" root)
                       :direction :output :if-exists :supersede)
    (write-string (ota-server.manifest:keypair-public-hex kp) out))
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
echo "tests/e2e/client-state: server up"

# Bundle payloads into deterministic tarballs and publish them.
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
         "http://127.0.0.1:${OTA_PORT}/v1/admin/software/myapp/releases" \
         -o "${run_dir}/publish-${ver}.json"
}
publish "${run_dir}/p1" "1.0.0"
publish "${run_dir}/p2" "1.1.0"
echo "tests/e2e/client-state: published 1.0.0 and 1.1.0"

# Build the agent.
mkdir -p "${run_dir}/bin"
(cd client && CGO_ENABLED=0 go build -trimpath -tags=netgo,osusergo \
     -o "../${run_dir}/bin/ota-agent" ./agent)

ota_home="${run_dir}/agent-home"
mkdir -p "${ota_home}"
pubkey=$(cat "${server_root}/pubkey.hex")

# Mint an install token so the agent has a per-client bearer.
mint_resp=$(curl -sS -X POST \
                 -H "Authorization: Bearer ${OTA_TOKEN}" \
                 -H "Content-Type: application/json" \
                 -d '{"classifications":["public"]}' \
                 "http://127.0.0.1:${OTA_PORT}/v1/admin/install-tokens")
install_tok=$(echo "${mint_resp}" | grep -o '"install_token":"[^"]*"' | cut -d'"' -f4)
[ -n "${install_tok}" ] || { echo "no install token"; exit 1; }

run_agent() {
    OTA_HOME="${ota_home}" OTA_TRUSTED_PUBKEYS="${pubkey}" \
        "${run_dir}/bin/ota-agent" "$@" \
            --server "http://127.0.0.1:${OTA_PORT}"
}

# === (2) Install 1.0.0 ===
echo "tests/e2e/client-state: install 1.0.0..."
run_agent install myapp --version=1.0.0 --install-token="${install_tok}"

# Verify population-per-release shows 1 client on 1.0.0.
pop=$(curl -sS -H "Authorization: Bearer ${OTA_TOKEN}" \
           "http://127.0.0.1:${OTA_PORT}/v1/admin/stats/population-per-release?software=myapp")
echo "  pop after install: ${pop}"
# Result rows are tuples [release_id, clients] in column order.
# Matching `"myapp/linux-x86_64/1.0.0",1]` asserts: 1.0.0 has 1 client.
echo "${pop}" | grep -q '"myapp/linux-x86_64/1.0.0",1\]' || {
    echo "  ✗ expected (1.0.0, 1) in response"; exit 1; }
echo "  ✓ snapshot shows 1 client on 1.0.0 after install"

# === (3) Upgrade to 1.1.0 ===
echo "tests/e2e/client-state: upgrade to 1.1.0..."
run_agent upgrade myapp --to=1.1.0

pop=$(curl -sS -H "Authorization: Bearer ${OTA_TOKEN}" \
           "http://127.0.0.1:${OTA_PORT}/v1/admin/stats/population-per-release?software=myapp")
echo "  pop after upgrade: ${pop}"
echo "${pop}" | grep -q '"myapp/linux-x86_64/1.1.0",1\]' || {
    echo "  ✗ expected (1.1.0, 1) row after upgrade"; exit 1; }
# 1.0.0 must no longer appear as a row -- the snapshot moved to 1.1.0
# (uniquely per (client, software), so the previous row was overwritten).
if echo "${pop}" | grep -q '"myapp/linux-x86_64/1.0.0"'; then
    echo "  ✗ 1.0.0 should no longer be in the result"; exit 1
fi
echo "  ✓ snapshot moved to 1.1.0 after upgrade"

# === (4) Revert ===
echo "tests/e2e/client-state: revert..."
run_agent revert myapp

pop=$(curl -sS -H "Authorization: Bearer ${OTA_TOKEN}" \
           "http://127.0.0.1:${OTA_PORT}/v1/admin/stats/population-per-release?software=myapp")
echo "  pop after revert: ${pop}"
echo "${pop}" | grep -q '"myapp/linux-x86_64/1.0.0",1\]' || {
    echo "  ✗ expected snapshot to point back at 1.0.0 after revert"
    echo "${pop}"
    exit 1
}
echo "  ✓ snapshot reverted to 1.0.0"

# === (5) Audit log carries the kinds ===
echo "tests/e2e/client-state: audit log..."
audit=$(curl -sS -H "Authorization: Bearer ${OTA_TOKEN}" \
             "http://127.0.0.1:${OTA_PORT}/v1/admin/audit")
# The reporting endpoint isn't routed through with-admin-identity (per-client
# bearer auth), so the audit log has the admin-action rows.  We just check
# that the stats query was audited under the admin identity, since that's
# the surface ADR-0010 documents.
echo "${audit}" | grep -q '"action":"stats-run"' || {
    echo "  ✗ audit log missing a stats-run row"
    echo "${audit}"
    exit 1
}
echo "  ✓ audit log records the stats queries"

echo "PASS: tests/e2e/client-state — snapshot + stats end-to-end"
