#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Ogamita Ltd.
#
# v1.7 e2e: opt-in client emails + notification webhook fan-out.
#
#   1. Boot a tiny Python webhook receiver that records every POST
#      it receives.
#   2. Boot ota-server with [notifications].webhook_url pointing at it.
#   3. Install software 1.0.0 with the agent; set-email; verify
#      the email shows up via show-email.
#   4. Publish 2.0.0.  The publish handler enqueues a notification
#      for our client (current=1.0.0, target=2.0.0).  Wait for the
#      pool to dispatch; verify the webhook receiver got a POST
#      with the expected JSON shape.
#   5. POST /v1/admin/software/<sw>/announce manually; verify the
#      receiver gets a second POST with reason=announce.
#   6. unset-email; show-email now returns empty.

set -eu

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "${repo_root}"

run_dir="${OTA_E2E_RUN_DIR:-tests/e2e/run-notifications}"
rm -rf "${run_dir}"
mkdir -p "${run_dir}/logs"

OTA_PORT="${OTA_PORT:-18489}"
WEBHOOK_PORT="${WEBHOOK_PORT:-19089}"
OTA_TOKEN="notif-test-token"

make vendor-build >>"${run_dir}/logs/build.log" 2>&1

# === (1) Webhook receiver: records every POST to a file
recv_log="${run_dir}/webhook.jsonl"
: > "${recv_log}"
cat > "${run_dir}/webhook.py" <<EOF
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG = os.environ["RECV_LOG"]

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(n)
        with open(LOG, "ab") as f:
            f.write(body)
            f.write(b"\n")
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")
    def log_message(self, *a): pass

HTTPServer(("127.0.0.1", int(os.environ["WEBHOOK_PORT"])), H).serve_forever()
EOF
RECV_LOG="${recv_log}" WEBHOOK_PORT="${WEBHOOK_PORT}" \
    python3 "${run_dir}/webhook.py" >"${run_dir}/logs/webhook.log" 2>&1 &
recv_pid=$!

# Payloads.
make_payload() {
    dst="$1"; tag="$2"
    mkdir -p "${dst}"
    head -c 4096 /dev/zero | tr '\0' 'A' > "${dst}/big.dat"
    echo "${tag}" >> "${dst}/big.dat"
}
make_payload "${run_dir}/p1" v1
make_payload "${run_dir}/p2" v2

# === (2) Server with webhook configured
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
  (ota-server.catalogue:reset-stale-running-notifications db)
  (setf (ota-server.http::app-state-notification-pool state)
        (ota-server.workers:start-notification-pool
         db
         :webhook-url "http://127.0.0.1:${WEBHOOK_PORT}/notify"
         :webhook-timeout 5
         :size 2
         :max-attempts 3))
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
trap 'kill ${server_pid} ${recv_pid} 2>/dev/null || true' EXIT INT TERM

for i in $(seq 1 30); do
    curl -sf "http://127.0.0.1:${OTA_PORT}/v1/health" >/dev/null 2>&1 && break
    sleep 1
done
curl -sf "http://127.0.0.1:${OTA_PORT}/v1/health" >/dev/null || {
    echo "server failed"; cat "${server_log}"; exit 1; }
echo "tests/e2e/notifications: server + webhook receiver up"

# Publish 1.0.0.
publish() {
    src="$1"; ver="$2"
    tar_path="${run_dir}/p-${ver}.tar"
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

# Build agent.
mkdir -p "${run_dir}/bin"
(cd client && CGO_ENABLED=0 go build -trimpath -tags=netgo,osusergo \
     -o "../${run_dir}/bin/ota-agent" ./agent)
ota_home="${run_dir}/agent-home"
mkdir -p "${ota_home}"
pubkey=$(cat "${server_root}/pubkey.hex")

mint=$(curl -sS -X POST -H "Authorization: Bearer ${OTA_TOKEN}" \
            -H "Content-Type: application/json" \
            -d '{"classifications":["public"]}' \
            "http://127.0.0.1:${OTA_PORT}/v1/admin/install-tokens")
install_tok=$(echo "${mint}" | grep -o '"install_token":"[^"]*"' | cut -d'"' -f4)

# Install 1.0.0.
OTA_HOME="${ota_home}" OTA_TRUSTED_PUBKEYS="${pubkey}" \
    "${run_dir}/bin/ota-agent" install myapp --version=1.0.0 \
        --install-token="${install_tok}" \
        --server "http://127.0.0.1:${OTA_PORT}"
echo "tests/e2e/notifications: 1.0.0 installed"

# === (3) set-email + show-email
OTA_HOME="${ota_home}" "${run_dir}/bin/ota-agent" set-email myapp alice@example.com \
    >"${run_dir}/setemail.txt"
grep -q "registered alice@example.com for myapp" "${run_dir}/setemail.txt" \
    || { echo "set-email output wrong: $(cat ${run_dir}/setemail.txt)"; exit 1; }
echo "tests/e2e/notifications: ✓ set-email registered alice@example.com"

show_out=$(OTA_HOME="${ota_home}" "${run_dir}/bin/ota-agent" show-email myapp)
echo "${show_out}" | grep -q "alice@example.com" \
    || { echo "show-email missing alice: ${show_out}"; exit 1; }
echo "tests/e2e/notifications: ✓ show-email lists alice@example.com"

# === (4) Publish 2.0.0 -> fan-out -> webhook receiver gets one POST
echo "tests/e2e/notifications: publishing 2.0.0 to trigger fan-out..."
publish "${run_dir}/p2" "2.0.0"

# Wait up to 10s for the webhook to fire.
for i in $(seq 1 20); do
    if [ -s "${recv_log}" ]; then break; fi
    sleep 0.5
done
[ -s "${recv_log}" ] || { echo "webhook never fired"; cat "${server_log}" | tail -30; exit 1; }
first_line=$(head -n1 "${recv_log}")
echo "  webhook got: ${first_line}"
echo "${first_line}" | grep -q '"reason":"publish"' \
    || { echo "✗ wrong reason"; exit 1; }
echo "${first_line}" | grep -q '"emails":\["alice@example.com"\]' \
    || { echo "✗ emails missing alice"; exit 1; }
echo "${first_line}" | grep -q '"software":"myapp"' \
    || { echo "✗ software missing"; exit 1; }
echo "${first_line}" | grep -q '"version":"2.0.0"' \
    || { echo "✗ version wrong"; exit 1; }
echo "tests/e2e/notifications: ✓ publish-time fan-out fired correctly"

# === (5) Admin announce -> second POST
echo "tests/e2e/notifications: admin announce..."
curl -sS -X POST \
     -H "Authorization: Bearer ${OTA_TOKEN}" \
     -H "Content-Type: application/json" \
     -d '{"release_id":"myapp/linux-x86_64/2.0.0","reason":"announce"}' \
     "http://127.0.0.1:${OTA_PORT}/v1/admin/software/myapp/announce" \
     -o "${run_dir}/announce.json"
grep -q '"enqueued"' "${run_dir}/announce.json" \
    || { echo "announce response wrong: $(cat ${run_dir}/announce.json)"; exit 1; }
# Wait for the announce row to be dispatched.  The publish row used
# the same (client, software, release, reason='publish') tuple, so
# (..., reason='announce') is a fresh row.  Total dispatched: 2.
for i in $(seq 1 20); do
    n=$(wc -l < "${recv_log}" | tr -d ' ')
    [ "${n}" -ge 2 ] && break
    sleep 0.5
done
n=$(wc -l < "${recv_log}" | tr -d ' ')
[ "${n}" -ge 2 ] || { echo "✗ expected ≥2 webhook hits, got ${n}"; exit 1; }
grep -q '"reason":"announce"' "${recv_log}" \
    || { echo "✗ no announce row in receiver log"; cat "${recv_log}"; exit 1; }
echo "tests/e2e/notifications: ✓ admin announce dispatched"

# === (6) unset-email
echo "tests/e2e/notifications: unset-email..."
OTA_HOME="${ota_home}" "${run_dir}/bin/ota-agent" unset-email myapp >/dev/null
show_after=$(OTA_HOME="${ota_home}" "${run_dir}/bin/ota-agent" show-email myapp)
echo "${show_after}" | grep -q "no emails registered" \
    || { echo "✗ unset-email didn't clear: ${show_after}"; exit 1; }
echo "tests/e2e/notifications: ✓ unset-email cleared registrations"

echo "PASS: tests/e2e/notifications — publish + announce fan-out via webhook"
