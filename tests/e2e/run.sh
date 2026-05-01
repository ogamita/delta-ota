#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Ogamita Ltd.
#
# Phase-1 e2e harness:
#   1. Build a small payload directory.
#   2. Boot ota-server (SBCL+Woo) on a free port.
#   3. Build ota-admin and use it to publish the payload.
#   4. Build ota-agent and use it to install on the same machine.
#   5. Verify the installed tree matches the source tree byte-for-byte
#      after canonicalisation (deterministic tar).
#
# Requires sbcl + Quicklisp + go on PATH. CI uses the dev image.

set -eu

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "${repo_root}"

run_dir="${OTA_E2E_RUN_DIR:-tests/e2e/run}"
rm -rf "${run_dir}"
mkdir -p "${run_dir}/logs"

OTA_PORT="${OTA_PORT:-18443}"
OTA_TOKEN="e2e-token"

# 1. payload
payload_src="${run_dir}/payload-src"
mkdir -p "${payload_src}/sub"
echo "alpha"   > "${payload_src}/a.txt"
echo "beta"    > "${payload_src}/b.txt"
echo "gamma"   > "${payload_src}/sub/c.txt"
echo "tests/e2e: payload prepared at ${payload_src}"

# 2. boot server
server_root="${run_dir}/server-root"
server_log="${run_dir}/logs/server.log"
mkdir -p "${server_root}"

cat > "${run_dir}/run-server.lisp" <<EOF
(ql:quickload "ota-server" :silent t)
(let* ((root #P"$(pwd)/${server_root}/")
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
  (ota-server.http:start-server state :host "127.0.0.1" :port ${OTA_PORT})
  (format t "ota-server: ready on port ${OTA_PORT}~%")
  (force-output)
  (loop (sleep 30)))
EOF

echo "tests/e2e: starting server (port ${OTA_PORT}, log ${server_log})"
sbcl --non-interactive --no-userinit --no-sysinit \
     --load ~/quicklisp/setup.lisp \
     --eval '(asdf:load-asd (truename "server/ota-server.asd"))' \
     --load "${run_dir}/run-server.lisp" \
     >"${server_log}" 2>&1 &
server_pid=$!
trap 'kill ${server_pid} 2>/dev/null || true' EXIT INT TERM

# Wait for the server to come up.
for i in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:${OTA_PORT}/v1/health" >/dev/null 2>&1; then
        echo "tests/e2e: server up after ${i}s"
        break
    fi
    sleep 1
    if ! kill -0 ${server_pid} 2>/dev/null; then
        echo "tests/e2e: server died early; log:"
        cat "${server_log}"
        exit 1
    fi
done

if ! curl -sf "http://127.0.0.1:${OTA_PORT}/v1/health" >/dev/null 2>&1; then
    echo "tests/e2e: server failed to come up"
    cat "${server_log}"
    exit 1
fi

# 3. publish via admin (curl multipart-less upload — phase-1 simple form).
echo "tests/e2e: publishing payload..."
# Build a deterministic tar of the payload using the server's own tar
# writer, so the publish payload is exactly what the server will store.
tar_path="${run_dir}/payload.tar"
sbcl --non-interactive --no-userinit --no-sysinit \
     --load ~/quicklisp/setup.lisp \
     --eval '(asdf:load-asd (truename "server/ota-server.asd"))' \
     --eval "(ql:quickload :ota-server :silent t)" \
     --eval "(ota-server.storage:tar-directory-to-file \"$(pwd)/${payload_src}/\" \"$(pwd)/${tar_path}\")" \
     >>"${server_log}" 2>&1

curl -sS -X POST \
     -H "Authorization: Bearer ${OTA_TOKEN}" \
     -H "X-Ota-Version: 1.0.0" \
     -H "X-Ota-Os: linux" \
     -H "X-Ota-Arch: x86_64" \
     -H "X-Ota-Os-Versions: 12,13" \
     -H "Content-Type: application/octet-stream" \
     --data-binary "@${tar_path}" \
     "http://127.0.0.1:${OTA_PORT}/v1/admin/software/hello/releases" \
     -o "${run_dir}/publish-resp.json"
echo "tests/e2e: publish response: $(cat "${run_dir}/publish-resp.json")"

# 4. build agent and install
echo "tests/e2e: building ota-agent..."
mkdir -p "${run_dir}/bin"
(cd client && CGO_ENABLED=0 go build -trimpath -tags=netgo,osusergo \
     -o "../${run_dir}/bin/ota-agent" ./agent)

ota_home="${run_dir}/agent-home"
mkdir -p "${ota_home}"

echo "tests/e2e: installing via agent..."
OTA_HOME="${ota_home}" \
OTA_TRUSTED_PUBKEYS="$(cat "${server_root}/pubkey.hex")" \
"${run_dir}/bin/ota-agent" install hello \
     --server "http://127.0.0.1:${OTA_PORT}" --latest

# 5. verify the installed tree byte-matches the source via deterministic tar.
echo "tests/e2e: verifying installed tree..."
installed="${ota_home}/hello/current"
[ -e "${installed}" ] || { echo "missing ${installed}"; exit 1; }

src_tar="${run_dir}/src.tar"
inst_tar="${run_dir}/inst.tar"
sbcl --non-interactive --no-userinit --no-sysinit \
     --load ~/quicklisp/setup.lisp \
     --eval '(asdf:load-asd (truename "server/ota-server.asd"))' \
     --eval "(ql:quickload :ota-server :silent t)" \
     --eval "(ota-server.storage:tar-directory-to-file \"$(pwd)/${payload_src}/\" \"$(pwd)/${src_tar}\")" \
     --eval "(ota-server.storage:tar-directory-to-file \"$(pwd)/${installed}/\" \"$(pwd)/${inst_tar}\")" \
     >>"${server_log}" 2>&1

if cmp -s "${src_tar}" "${inst_tar}"; then
    echo "tests/e2e: ✓ installed tree matches source byte-for-byte"
else
    echo "tests/e2e: ✗ installed tree DIFFERS from source"
    sha256sum "${src_tar}" "${inst_tar}" 2>/dev/null || shasum -a 256 "${src_tar}" "${inst_tar}"
    exit 1
fi

echo "tests/e2e: ALL OK"
