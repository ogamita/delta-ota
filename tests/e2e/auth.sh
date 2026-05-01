#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Ogamita Ltd.
#
# Phase-4 e2e: classification-based filtering + install-token exchange.
#
#   1. Boot ota-server.
#   2. Publish hello/1.0.0 with classifications=public.
#   3. Publish hello/2.0.0-beta with classifications=beta.
#   4. Anonymous client: latest → 1.0.0 (the beta is filtered out).
#   5. Mint an install token with classifications=[public,beta] via admin.
#   6. Agent installs using --install-token: latest → 2.0.0-beta.
#   7. Audit log records publish-release + mint-install-token.

set -eu

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "${repo_root}"

run_dir="${OTA_E2E_RUN_DIR:-tests/e2e/run-auth}"
rm -rf "${run_dir}"
mkdir -p "${run_dir}/logs"

OTA_PORT="${OTA_PORT:-18444}"
OTA_TOKEN="auth-test-token"

make vendor-build >>"${run_dir}/logs/build.log" 2>&1

mkpayload() {
    dst="$1"; tag="$2"
    mkdir -p "${dst}"
    head -c 4096 /dev/zero | tr '\0' 'A' > "${dst}/big.dat"
    echo "${tag}" >> "${dst}/big.dat"
    echo "tag-${tag}" > "${dst}/info.txt"
}
mkpayload "${run_dir}/p1" public
mkpayload "${run_dir}/p2" beta

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
  (with-open-file (out (merge-pathnames "pubkey.hex" root)
                       :direction :output :if-exists :supersede)
    (write-string (ota-server.manifest:keypair-public-hex kp) out))
  (ota-server.http:start-server state :host "127.0.0.1" :port ${OTA_PORT})
  (format t "ota-server: ready on port ${OTA_PORT}~%") (force-output)
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
echo "tests/e2e/auth: server up"

publish_with_classifications() {
    src="$1"; ver="$2"; cls="$3"
    tar_path="${run_dir}/payload-${ver}.tar"
    sbcl --non-interactive --no-userinit --no-sysinit --load ~/quicklisp/setup.lisp \
         --eval '(asdf:load-asd (truename "server/ota-server.asd"))' \
         --eval "(ql:quickload :ota-server :silent t)" \
         --eval "(ota-server.storage:tar-directory-to-file \"$(pwd)/${src}/\" \"$(pwd)/${tar_path}\")" \
         >>"${run_dir}/logs/server.log" 2>&1
    curl -sS -X POST \
         -H "Authorization: Bearer ${OTA_TOKEN}" \
         -H "X-Ota-Version: ${ver}" -H "X-Ota-Os: linux" -H "X-Ota-Arch: x86_64" \
         -H "X-Ota-Classifications: ${cls}" \
         -H "Content-Type: application/octet-stream" \
         --data-binary "@${tar_path}" \
         "http://127.0.0.1:${OTA_PORT}/v1/admin/software/hello/releases" \
         -o "${run_dir}/publish-${ver}.json"
    echo "tests/e2e/auth: publish ${ver}: $(cat "${run_dir}/publish-${ver}.json")"
}

# Note: the v2 publish would also try to build a v1->v2 patch; that's
# fine for this test, just slower.
publish_with_classifications "${run_dir}/p1" "1.0.0"      "public"
publish_with_classifications "${run_dir}/p2" "2.0.0-beta" "beta"

# 4. Anonymous: latest must be 1.0.0
anon_latest=$(curl -sf "http://127.0.0.1:${OTA_PORT}/v1/software/hello/releases/latest" \
              | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')
if [ "${anon_latest}" != "1.0.0" ]; then
    echo "tests/e2e/auth: ✗ anonymous latest expected 1.0.0, got ${anon_latest}"; exit 1
fi
echo "tests/e2e/auth: ✓ anonymous client sees only public (1.0.0)"

# 5. Mint install token with [public, beta] classifications.
mint_resp=$(curl -sS -X POST \
            -H "Authorization: Bearer ${OTA_TOKEN}" \
            -H "Content-Type: application/json" \
            -d '{"classifications":["public","beta"],"ttl_seconds":120}' \
            "http://127.0.0.1:${OTA_PORT}/v1/admin/install-tokens")
echo "tests/e2e/auth: mint: ${mint_resp}"
install_token=$(printf '%s' "${mint_resp}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["install_token"])')

# 6. Agent install with the token.
mkdir -p "${run_dir}/bin"
(cd client && CGO_ENABLED=0 go build -trimpath -tags=netgo,osusergo \
     -o "../${run_dir}/bin/ota-agent" ./agent)
ota_home="${run_dir}/agent-home"
mkdir -p "${ota_home}"
OTA_HOME="${ota_home}" \
OTA_TRUSTED_PUBKEYS="$(cat "${server_root}/pubkey.hex")" \
"${run_dir}/bin/ota-agent" install hello \
     --server "http://127.0.0.1:${OTA_PORT}" --latest \
     --install-token "${install_token}" --hwinfo "e2e-runner"

state_current=$(python3 -c 'import json,sys; print(json.load(open("'${ota_home}'/hello/state.json"))["current"])')
if [ "${state_current}" != "2.0.0-beta" ]; then
    echo "tests/e2e/auth: ✗ authenticated agent expected 2.0.0-beta, got ${state_current}"; exit 1
fi
echo "tests/e2e/auth: ✓ authenticated agent sees beta (2.0.0-beta)"

# 7. Audit log non-empty.
audit=$(curl -sS -H "Authorization: Bearer ${OTA_TOKEN}" \
        "http://127.0.0.1:${OTA_PORT}/v1/admin/audit")
audit_count=$(printf '%s' "${audit}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
if [ "${audit_count}" -lt 3 ]; then
    echo "tests/e2e/auth: ✗ audit log has ${audit_count} rows, expected >= 3"; exit 1
fi
echo "tests/e2e/auth: ✓ audit log has ${audit_count} rows"

echo "tests/e2e/auth: ALL OK"
