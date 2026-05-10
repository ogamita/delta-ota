#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Ogamita Ltd.
#
# v1.4 e2e: cert-subject admin identity (ADR-0009) + per-endpoint
# rate limits.
#
#   1. Boot ota-server with TRUST_PROXY_SUBJECT_HEADER on,
#      admin_subjects = ["CN=alice", "CN=bob"], and a tightened
#      admin-mint cap (5/minute) so the rate-limit burst is
#      observable within a single shell test.
#
#   2. POST /v1/admin/software (create) WITHOUT a cert subject
#      header: bearer alone succeeds (require_mtls is off);
#      audit row records identity = "admin".
#
#   3. Repeat WITH a valid cert subject header: succeeds; audit
#      row records identity = "CN=alice".
#
#   4. Repeat WITH a subject NOT on the allowlist: 403.
#
#   5. Burst N mint-token requests; observe the cap kicks in
#      with a 429 response.
#
#   6. Switch require_mtls on at a second server and confirm an
#      admin call without a cert is now 403, even with a valid
#      bearer.

set -eu

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "${repo_root}"

run_dir="${OTA_E2E_RUN_DIR:-tests/e2e/run-admin-identity}"
rm -rf "${run_dir}"
mkdir -p "${run_dir}/logs"

OTA_PORT="${OTA_PORT:-18484}"
OTA_PORT2="${OTA_PORT2:-18485}"
OTA_TOKEN="admin-identity-test-token"

make vendor-build >>"${run_dir}/logs/build.log" 2>&1

server_root="${run_dir}/server-root"
abs_root="$(mkdir -p "${server_root}" && cd "${server_root}" && pwd)"

# Server #1: trust the header, allowlist alice + bob, tight mint cap.
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
                :hostname "localhost"
                :trust-proxy-subject-header t
                :admin-subjects '("CN=alice" "CN=bob")
                :rate-limits-override '(:admin-mint-install-token (5 . 1/60)))))
  (ota-server.catalogue:run-migrations db)
  (ensure-directories-exist (ota-server.http::app-state-manifests-dir state))
  (ota-server.http:start-server state :host "127.0.0.1" :port ${OTA_PORT}
                                      :worker-num 4)
  (format t "ota-server: ready on ${OTA_PORT}~%")
  (force-output)
  (loop (sleep 30)))
EOF

# Server #2: same config but require_mtls on.
abs_root2="${abs_root}-strict"
mkdir -p "${abs_root2}"
cat > "${run_dir}/run-server-strict.lisp" <<EOF
(ql:quickload "ota-server" :silent t)
(setf ota-server.workers:*bsdiff-binary* "$(pwd)/server/build/bin/bsdiff")
(let* ((root #P"${abs_root2}/")
       (cas (ota-server.storage:make-cas root))
       (db (ota-server.catalogue:open-catalogue (merge-pathnames "db/x.db" root)))
       (kp (ota-server.manifest:load-or-generate-keypair (merge-pathnames "keys/" root)))
       (state (ota-server.http::make-app-state
                :cas cas :catalogue db :keypair kp
                :manifests-dir (merge-pathnames "manifests/" root)
                :admin-token "${OTA_TOKEN}"
                :hostname "localhost"
                :trust-proxy-subject-header t
                :admin-subjects '("CN=alice")
                :require-mtls t)))
  (ota-server.catalogue:run-migrations db)
  (ensure-directories-exist (ota-server.http::app-state-manifests-dir state))
  (ota-server.http:start-server state :host "127.0.0.1" :port ${OTA_PORT2}
                                      :worker-num 4)
  (format t "ota-server: ready on ${OTA_PORT2}~%")
  (force-output)
  (loop (sleep 30)))
EOF

start_server () {
    script="$1"; port="$2"; log="${run_dir}/logs/server-${port}.log"
    sbcl --non-interactive --no-userinit --no-sysinit \
         --load ~/quicklisp/setup.lisp \
         --eval '(asdf:load-asd (truename "server/ota-server.asd"))' \
         --load "${script}" \
         >"${log}" 2>&1 &
    echo $!
}

server_pid=$(start_server "${run_dir}/run-server.lisp" "${OTA_PORT}")
server_pid2=$(start_server "${run_dir}/run-server-strict.lisp" "${OTA_PORT2}")
trap 'kill ${server_pid} ${server_pid2} 2>/dev/null || true' EXIT INT TERM

wait_for () {
    p="$1"
    for i in $(seq 1 30); do
        if curl -sf "http://127.0.0.1:${p}/v1/health" >/dev/null 2>&1; then
            echo "tests/e2e/admin-identity: server ${p} up after ${i}s"
            return 0
        fi
        sleep 1
    done
    echo "tests/e2e/admin-identity: server ${p} never came up"; exit 1
}
wait_for "${OTA_PORT}"
wait_for "${OTA_PORT2}"

admin_post () {
    port="$1"; path="$2"; cert_subject="$3"; body="$4"
    extra=""
    if [ -n "${cert_subject}" ]; then
        extra="-H X-Ota-Client-Cert-Subject:${cert_subject}"
    fi
    curl -sS -o /dev/null -w '%{http_code}' \
        -X POST \
        -H "Authorization: Bearer ${OTA_TOKEN}" \
        -H "Content-Type: application/json" \
        ${extra} \
        --data-binary "${body}" \
        "http://127.0.0.1:${port}${path}"
}

# === (2) Create software without cert subject -- bearer alone OK ===
echo "tests/e2e/admin-identity: (2) admin call with no cert subject..."
status=$(admin_post "${OTA_PORT}" "/v1/admin/software" "" '{"name":"alpha","display_name":"Alpha"}')
if [ "${status}" != "201" ]; then
    echo "  ✗ expected 201, got ${status}"; exit 1
fi
echo "  ✓ 201 (bearer alone accepted when require_mtls is off)"

# === (3) Create software WITH valid cert subject -- audit records subject ===
echo "tests/e2e/admin-identity: (3) admin call with valid cert subject..."
status=$(admin_post "${OTA_PORT}" "/v1/admin/software" "CN=alice" '{"name":"beta","display_name":"Beta"}')
if [ "${status}" != "201" ]; then
    echo "  ✗ expected 201, got ${status}"; exit 1
fi
# Pull the audit log and verify identity column.
audit=$(curl -sS -H "Authorization: Bearer ${OTA_TOKEN}" \
             "http://127.0.0.1:${OTA_PORT}/v1/admin/audit")
if ! echo "${audit}" | grep -q '"identity":"CN=alice"'; then
    echo "  ✗ audit log doesn't record identity=CN=alice:"
    echo "${audit}"
    exit 1
fi
if ! echo "${audit}" | grep -q '"identity":"admin"'; then
    echo "  ✗ audit log should also have the earlier identity=admin row:"
    echo "${audit}"
    exit 1
fi
echo "  ✓ 201, audit log carries identity=CN=alice"

# === (4) Subject NOT on allowlist -> 403 ===
echo "tests/e2e/admin-identity: (4) admin call with disallowed subject..."
status=$(admin_post "${OTA_PORT}" "/v1/admin/software" "CN=eve" '{"name":"gamma"}')
if [ "${status}" != "403" ]; then
    echo "  ✗ expected 403, got ${status}"; exit 1
fi
echo "  ✓ 403 (disallowed subject correctly rejected)"

# === (5) Burst mint-token until rate-limited.  Cap was set to 5
#         tokens for :admin-mint-install-token; the 6th must 429.
echo "tests/e2e/admin-identity: (5) burst until rate-limit kicks in..."
got_429="no"
for i in 1 2 3 4 5 6 7; do
    status=$(admin_post "${OTA_PORT}" "/v1/admin/install-tokens" "CN=alice" '{"classifications":["public"]}')
    echo "  request ${i}: HTTP ${status}"
    if [ "${status}" = "429" ]; then got_429="yes"; break; fi
done
if [ "${got_429}" != "yes" ]; then
    echo "  ✗ never saw 429 across 7 mints (cap was 5/min) -- limiter broken?"
    exit 1
fi
echo "  ✓ admin-mint-install-token bucket hit its tightened cap"

# === (6) Strict server: require_mtls on, no cert -> 403 ===
echo "tests/e2e/admin-identity: (6) require_mtls server rejects no-cert..."
status=$(admin_post "${OTA_PORT2}" "/v1/admin/software" "" '{"name":"strict-test"}')
if [ "${status}" != "403" ]; then
    echo "  ✗ expected 403 from strict server, got ${status}"; exit 1
fi
echo "  ✓ require_mtls enforced even with valid bearer"

# === Strict server WITH cert subject -> still works
echo "tests/e2e/admin-identity: (6b) require_mtls server accepts valid cert..."
status=$(admin_post "${OTA_PORT2}" "/v1/admin/software" "CN=alice" '{"name":"strict-ok"}')
if [ "${status}" != "201" ]; then
    echo "  ✗ expected 201, got ${status}"; exit 1
fi
echo "  ✓ valid bearer + valid cert accepted"

echo "PASS: tests/e2e/admin-identity — cert-subject identity + per-endpoint rate limits"
