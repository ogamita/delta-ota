#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Ogamita Ltd.
#
# Phase-1+2 e2e harness:
#   1. Build payload v1, v2 (a small mutation), v3 (another mutation).
#   2. Boot ota-server (SBCL+Woo).
#   3. Publish v1, v2 (server builds v1->v2 patch), v3 (builds v1->v3 and v2->v3).
#   4. Install v1 with ota-agent.
#   5. Upgrade to v2 via patch (verify via download size).
#   6. Upgrade to v3 via patch (verify result hash matches manifest).
#   7. Verify each installed tree byte-matches its source via deterministic tar.
#
# Requires sbcl + Quicklisp + go on PATH. Builds the vendored bsdiff helper too.

set -eu

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "${repo_root}"

run_dir="${OTA_E2E_RUN_DIR:-tests/e2e/run}"
rm -rf "${run_dir}"
mkdir -p "${run_dir}/logs"

OTA_PORT="${OTA_PORT:-18443}"
OTA_TOKEN="e2e-token"

# 0. ensure vendored bsdiff helper is built (server uses it).
make vendor-build >>"${run_dir}/logs/build.log" 2>&1

# 1. payloads
make_payload() {
    dst="$1"; tag="$2"
    mkdir -p "${dst}/sub"
    # Mostly identical bytes so bsdiff produces a small patch.
    head -c 4096 /dev/zero | tr '\0' 'A' > "${dst}/big.dat"
    echo "${tag}" >> "${dst}/big.dat"
    echo "alpha"   > "${dst}/a.txt"
    echo "beta"    > "${dst}/b.txt"
    echo "gamma-${tag}" > "${dst}/sub/c.txt"
}
make_payload "${run_dir}/p1" v1
make_payload "${run_dir}/p2" v2
make_payload "${run_dir}/p3" v3
echo "tests/e2e: payloads prepared"

# 2. boot server
server_root="${run_dir}/server-root"
server_log="${run_dir}/logs/server.log"
mkdir -p "${server_root}"
abs_root="$(cd "${server_root}" && pwd)"

cat > "${run_dir}/run-server.lisp" <<EOF
(ql:quickload "ota-server" :silent t)
(setf ota-server.workers:*bsdiff-binary*
      "$(pwd)/server/build/bin/bsdiff")
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
  ;; v1.2: reset stale running jobs from any prior run, then start the
  ;; async patch-build worker pool.  Wiring it here exercises the new
  ;; architecture; without it the publish handler falls back to the
  ;; legacy synchronous fan-in (which is also still tested).
  (ota-server.catalogue:reset-stale-running-jobs db)
  (setf (ota-server.http::app-state-pool state)
        (ota-server.workers:start-patch-pool cas db :size 2))
  (ota-server.http:start-server state :host "127.0.0.1" :port ${OTA_PORT})
  (format t "ota-server: ready on port ${OTA_PORT}~%")
  (force-output)
  (loop (sleep 30)))
EOF

echo "tests/e2e: starting server (port ${OTA_PORT})"
sbcl --non-interactive --no-userinit --no-sysinit \
     --load ~/quicklisp/setup.lisp \
     --eval '(asdf:load-asd (truename "server/ota-server.asd"))' \
     --load "${run_dir}/run-server.lisp" \
     >"${server_log}" 2>&1 &
server_pid=$!
trap 'kill ${server_pid} 2>/dev/null || true' EXIT INT TERM

for i in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:${OTA_PORT}/v1/health" >/dev/null 2>&1; then
        echo "tests/e2e: server up after ${i}s"
        break
    fi
    sleep 1
    if ! kill -0 ${server_pid} 2>/dev/null; then
        echo "tests/e2e: server died early; log:"; cat "${server_log}"; exit 1
    fi
done
curl -sf "http://127.0.0.1:${OTA_PORT}/v1/health" >/dev/null || {
    echo "tests/e2e: server failed to come up"; cat "${server_log}"; exit 1; }

# Helper: tar a payload via the server's deterministic tar writer,
# then publish it.
publish_payload() {
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
         -H "X-Ota-Os-Versions: 12,13" \
         -H "Content-Type: application/octet-stream" \
         --data-binary "@${tar_path}" \
         "http://127.0.0.1:${OTA_PORT}/v1/admin/software/hello/releases" \
         -o "${run_dir}/publish-${ver}.json"
    echo "tests/e2e: publish ${ver}: $(cat "${run_dir}/publish-${ver}.json")"
}

publish_payload "${run_dir}/p1" "1.0.0"
publish_payload "${run_dir}/p2" "1.1.0"
publish_payload "${run_dir}/p3" "1.2.0"

# 4. build agent and install v1
echo "tests/e2e: building ota-agent..."
mkdir -p "${run_dir}/bin"
(cd client && CGO_ENABLED=0 go build -trimpath -tags=netgo,osusergo \
     -o "../${run_dir}/bin/ota-agent" ./agent)
ota_home="${run_dir}/agent-home"
mkdir -p "${ota_home}"

echo "tests/e2e: install v1..."
OTA_HOME="${ota_home}" \
OTA_TRUSTED_PUBKEYS="$(cat "${server_root}/pubkey.hex")" \
"${run_dir}/bin/ota-agent" install hello \
     --server "http://127.0.0.1:${OTA_PORT}" --version=1.0.0

# 5. upgrade to v2 (should pull a patch)
echo "tests/e2e: upgrade to v2 (patch path)..."
OTA_HOME="${ota_home}" \
OTA_TRUSTED_PUBKEYS="$(cat "${server_root}/pubkey.hex")" \
"${run_dir}/bin/ota-agent" upgrade hello \
     --server "http://127.0.0.1:${OTA_PORT}" --to=1.1.0

# Confirm a patch file landed in the agent's patches dir.
patches_dir="${ota_home}/hello/patches"
if [ -z "$(ls -A "${patches_dir}" 2>/dev/null || true)" ]; then
    echo "tests/e2e: ✗ no patch file in ${patches_dir}"; exit 1
fi
echo "tests/e2e: ✓ patch was used: $(ls "${patches_dir}")"

# 6. upgrade to v3 (also via patch)
echo "tests/e2e: upgrade to v3 (patch path)..."
OTA_HOME="${ota_home}" \
OTA_TRUSTED_PUBKEYS="$(cat "${server_root}/pubkey.hex")" \
"${run_dir}/bin/ota-agent" upgrade hello \
     --server "http://127.0.0.1:${OTA_PORT}" --to=1.2.0

# 7. verify final installed tree matches v3 source
installed="${ota_home}/hello/current"
[ -e "${installed}" ] || { echo "missing ${installed}"; exit 1; }

src_tar="${run_dir}/v3-src.tar"
inst_tar="${run_dir}/v3-inst.tar"
sbcl --non-interactive --no-userinit --no-sysinit \
     --load ~/quicklisp/setup.lisp \
     --eval '(asdf:load-asd (truename "server/ota-server.asd"))' \
     --eval "(ql:quickload :ota-server :silent t)" \
     --eval "(ota-server.storage:tar-directory-to-file \"$(pwd)/${run_dir}/p3/\" \"$(pwd)/${src_tar}\")" \
     --eval "(ota-server.storage:tar-directory-to-file \"$(pwd)/${installed}/\" \"$(pwd)/${inst_tar}\")" \
     >>"${server_log}" 2>&1

if cmp -s "${src_tar}" "${inst_tar}"; then
    echo "tests/e2e: ✓ installed v3 tree matches source byte-for-byte"
else
    echo "tests/e2e: ✗ installed v3 tree DIFFERS from source"
    sha256sum "${src_tar}" "${inst_tar}" 2>/dev/null || shasum -a 256 "${src_tar}" "${inst_tar}"
    exit 1
fi

# Patch size sanity: v1->v2 patch should be <50% of the v2 blob.
publish_v2_blob_size=$(grep -o '"blob_size":[0-9]*' "${run_dir}/publish-1.1.0.json" | cut -d: -f2)
patch_file=$(ls -t "${patches_dir}" | head -1)
patch_size=$(wc -c < "${patches_dir}/${patch_file}")
echo "tests/e2e: v1->v2 patch=${patch_size} bytes vs blob=${publish_v2_blob_size} bytes"
if [ "${patch_size}" -ge $((publish_v2_blob_size / 2)) ]; then
    echo "tests/e2e: ✗ patch is too large (>= 50% of blob)"
    exit 1
fi
echo "tests/e2e: ✓ patch is < 50% of blob size"

echo "tests/e2e: ALL OK"
