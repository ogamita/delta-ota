#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Ogamita Ltd.
#
# v1.3 e2e: HTTP Range support on /v1/blobs/<sha>.
#
#   1. Boot ota-server.
#   2. Publish a 4 MiB blob (big enough that --max-time can cut it).
#   3. Issue a GET with --max-time so curl drops mid-download; verify
#      we got *some* bytes but not the whole file.
#   4. Re-issue with `Range: bytes=N-` (curl --continue-at) to resume;
#      concatenate against step 3's partial file and verify the
#      complete SHA-256 matches the published blob's sha.
#   5. Issue an out-of-range request and verify a 416 reply.
#   6. Issue a normal full GET and verify Accept-Ranges: bytes is
#      advertised on a non-partial response.
#
# This exercises the *server's* Range path with a real HTTP client.
# The client-side resume logic (.part survival, trailing-zero scan,
# prefix re-hash) is covered by the Go unit tests; an interrupted
# ota-agent install would require a packet-level fault injector to
# test reliably from a shell script, which isn't worth the build-bot
# complexity.

set -eu

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "${repo_root}"

run_dir="${OTA_E2E_RUN_DIR:-tests/e2e/run-resume}"
rm -rf "${run_dir}"
mkdir -p "${run_dir}/logs"

OTA_PORT="${OTA_PORT:-18482}"
OTA_TOKEN="resume-test-token"

make vendor-build >>"${run_dir}/logs/build.log" 2>&1

# 4 MiB payload of pseudo-random bytes — `head -c` from /dev/urandom
# is portable and gives us something the trailing-zero scanner won't
# muddle through.
payload="${run_dir}/payload.bin"
head -c $((4 * 1024 * 1024)) /dev/urandom > "${payload}"
expected_sha=$(shasum -a 256 "${payload}" | awk '{print $1}')

# A throwaway tar that *contains* the payload, since the publish
# endpoint expects a release blob (not a raw file).  The blob the
# server stores is the sha of the tar, not of the inner payload —
# we'll compute the published sha from the publish response.
tar_path="${run_dir}/payload.tar"

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
    if curl -sf "http://127.0.0.1:${OTA_PORT}/v1/health" >/dev/null 2>&1; then
        echo "tests/e2e/resume: server up after ${i}s"
        break
    fi
    sleep 1
    if ! kill -0 ${server_pid} 2>/dev/null; then
        echo "tests/e2e/resume: server died early; log:"; cat "${server_log}"; exit 1
    fi
done

# Bundle the payload as a release tarball using the server's
# deterministic tar writer, so the tar bytes are stable across
# runs (the `make_payload` files in run.sh use the same trick).
sbcl --non-interactive --no-userinit --no-sysinit \
     --load ~/quicklisp/setup.lisp \
     --eval '(asdf:load-asd (truename "server/ota-server.asd"))' \
     --eval "(ql:quickload :ota-server :silent t)" \
     --eval "(let ((d (merge-pathnames #P\"src/\" #P\"$(pwd)/${run_dir}/\"))) \
               (ensure-directories-exist d) \
               (uiop:copy-file #P\"$(pwd)/${payload}\" \
                               (merge-pathnames \"big.bin\" d)) \
               (ota-server.storage:tar-directory-to-file d #P\"$(pwd)/${tar_path}\"))" \
     >>"${server_log}" 2>&1

publish_resp="${run_dir}/publish.json"
curl -sS -X POST \
     -H "Authorization: Bearer ${OTA_TOKEN}" \
     -H "X-Ota-Version: 1.0.0" \
     -H "X-Ota-Os: linux" -H "X-Ota-Arch: x86_64" \
     -H "X-Ota-Os-Versions: 1" \
     -H "Content-Type: application/octet-stream" \
     --data-binary "@${tar_path}" \
     "http://127.0.0.1:${OTA_PORT}/v1/admin/software/big/releases" \
     -o "${publish_resp}"
echo "tests/e2e/resume: publish: $(cat "${publish_resp}")"

blob_sha=$(grep -o '"blob_sha256":"[a-f0-9]*"' "${publish_resp}" | cut -d'"' -f4)
blob_size=$(grep -o '"blob_size":[0-9]*' "${publish_resp}" | cut -d: -f2)
echo "tests/e2e/resume: blob sha=${blob_sha} size=${blob_size}"

if [ -z "${blob_sha}" ] || [ "${blob_size}" -lt $((1024 * 1024)) ]; then
    echo "tests/e2e/resume: ✗ blob too small (${blob_size}); test won't be representative"
    exit 1
fi

blob_url="http://127.0.0.1:${OTA_PORT}/v1/blobs/${blob_sha}"

# --- (3) Interrupted GET: --limit-rate + --max-time guarantees a cut
# regardless of how fast localhost actually is.  100 KB/s × 0.5 s
# bounds the bytes received to ~50 KB on a 4 MiB blob.
part="${run_dir}/blob.part"
echo "tests/e2e/resume: starting interrupted GET (limit-rate 100K, max-time 0.5s)..."
set +e
curl -s --limit-rate 100K --max-time 0.5 -o "${part}" "${blob_url}"
curl_exit=$?
set -e
part_size=$(wc -c < "${part}" | tr -d ' ')
echo "tests/e2e/resume: interrupted at ${part_size} bytes (curl exit=${curl_exit})"
if [ "${part_size}" -eq 0 ]; then
    echo "tests/e2e/resume: ✗ got zero bytes — the test isn't actually exercising resume"
    exit 1
fi
if [ "${part_size}" -ge "${blob_size}" ]; then
    echo "tests/e2e/resume: ✗ download somehow finished within max-time; raise blob size"
    exit 1
fi

# --- (4) Resume with Range: bytes=N-
echo "tests/e2e/resume: resuming with Range: bytes=${part_size}-"
resume_part="${run_dir}/blob.resume"
http_status=$(curl -sS -o "${resume_part}" -w '%{http_code}' \
                   -H "Range: bytes=${part_size}-" "${blob_url}")
if [ "${http_status}" != "206" ]; then
    echo "tests/e2e/resume: ✗ resume returned HTTP ${http_status}, want 206"
    exit 1
fi

# Concatenate the two halves and check sha against the published blob.
final="${run_dir}/blob.full"
cat "${part}" "${resume_part}" > "${final}"
final_size=$(wc -c < "${final}" | tr -d ' ')
final_sha=$(shasum -a 256 "${final}" | awk '{print $1}')
if [ "${final_size}" != "${blob_size}" ]; then
    echo "tests/e2e/resume: ✗ resumed file is ${final_size} bytes, want ${blob_size}"
    exit 1
fi
if [ "${final_sha}" != "${blob_sha}" ]; then
    echo "tests/e2e/resume: ✗ sha mismatch:"
    echo "  resumed = ${final_sha}"
    echo "  blob    = ${blob_sha}"
    exit 1
fi
echo "tests/e2e/resume: ✓ resumed file matches blob_sha"

# --- (5) Out-of-range -> 416 with Content-Range: bytes */SIZE
echo "tests/e2e/resume: out-of-range request..."
oor_status=$(curl -sS -o /dev/null -w '%{http_code}' \
                  -H "Range: bytes=99999999-" "${blob_url}")
if [ "${oor_status}" != "416" ]; then
    echo "tests/e2e/resume: ✗ out-of-range returned HTTP ${oor_status}, want 416"
    exit 1
fi
echo "tests/e2e/resume: ✓ out-of-range correctly returned 416"

# --- (6) Full GET advertises Accept-Ranges.  We use -D to dump
# headers separately rather than -I (HEAD) — Woo's routing only
# matches GET on /v1/blobs/<sha>, and we want a real GET anyway.
echo "tests/e2e/resume: full GET advertises Accept-Ranges..."
hdr_file="${run_dir}/headers.txt"
curl -sS -D "${hdr_file}" -o /dev/null "${blob_url}"
ar=$(grep -i '^accept-ranges:' "${hdr_file}" | tr -d '\r' | awk '{print $2}')
if [ "${ar}" != "bytes" ]; then
    echo "tests/e2e/resume: ✗ Accept-Ranges = '${ar}', want 'bytes'"
    echo "  headers seen:"
    cat "${hdr_file}"
    exit 1
fi
echo "tests/e2e/resume: ✓ Accept-Ranges: bytes advertised on full responses"

echo "PASS: tests/e2e/resume-download — server Range support exercised end-to-end"
