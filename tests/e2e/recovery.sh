#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Ogamita Ltd.
#
# Phase-6 e2e: anchors endpoint + ota-agent doctor --recover.
#
#   1. Boot ota-server.
#   2. Publish hello/1.0.0, hello/1.1.0, hello/1.2.0.
#   3. Mark 1.0.0 as uncollectable -> it is now an anchor.
#   4. GET /v1/software/hello/anchors lists 1.0.0 (uncollectable)
#      and 1.2.0 (latest); 1.1.0 is NOT an anchor.
#   5. Install 1.2.0, verify state.
#   6. ota-agent doctor hello prints local distributions and remote
#      anchors.
#   7. ota-agent doctor hello --recover=1.0.0 installs the older
#      version (multi-step rollback).

set -eu

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "${repo_root}"

run_dir="${OTA_E2E_RUN_DIR:-tests/e2e/run-recovery}"
rm -rf "${run_dir}"
mkdir -p "${run_dir}/logs"

OTA_PORT="${OTA_PORT:-18446}"
OTA_TOKEN="recovery-test-token"

make vendor-build >>"${run_dir}/logs/build.log" 2>&1

mkpayload() {
    dst="$1"; tag="$2"
    mkdir -p "${dst}"
    head -c 4096 /dev/zero | tr '\0' 'A' > "${dst}/big.dat"
    echo "${tag}" >> "${dst}/big.dat"
    echo "tag-${tag}" > "${dst}/info.txt"
}
mkpayload "${run_dir}/p1" v1
mkpayload "${run_dir}/p2" v2
mkpayload "${run_dir}/p3" v3

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
echo "tests/e2e/recovery: server up"

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
publish "${run_dir}/p2" "1.1.0"
publish "${run_dir}/p3" "1.2.0"

# 3. Mark 1.0.0 as uncollectable.
curl -sS -X POST -H "Authorization: Bearer ${OTA_TOKEN}" \
     "http://127.0.0.1:${OTA_PORT}/v1/admin/software/hello/releases/1.0.0/uncollectable" \
     >"${run_dir}/uncollectable-resp.json"
echo "tests/e2e/recovery: marked 1.0.0 uncollectable: $(cat "${run_dir}/uncollectable-resp.json")"

# 4. Anchors endpoint.
anchors=$(curl -sS "http://127.0.0.1:${OTA_PORT}/v1/software/hello/anchors")
echo "tests/e2e/recovery: anchors: ${anchors}"
versions=$(printf '%s' "${anchors}" | python3 -c \
    'import json,sys; print(",".join(sorted(a["version"] for a in json.load(sys.stdin))))')
case "${versions}" in
    "1.0.0,1.2.0") echo "tests/e2e/recovery: ✓ anchors are {1.0.0, 1.2.0}" ;;
    *) echo "tests/e2e/recovery: ✗ unexpected anchors: ${versions}"; exit 1 ;;
esac

# 5. Install latest (1.2.0).
mkdir -p "${run_dir}/bin"
(cd client && CGO_ENABLED=0 go build -trimpath -tags=netgo,osusergo \
     -o "../${run_dir}/bin/ota-agent" ./agent)
ota_home="${run_dir}/agent-home"
mkdir -p "${ota_home}"
OTA_HOME="${ota_home}" \
OTA_TRUSTED_PUBKEYS="$(cat "${server_root}/pubkey.hex")" \
"${run_dir}/bin/ota-agent" install hello \
     --server "http://127.0.0.1:${OTA_PORT}" --version=1.2.0
state_v=$(python3 -c 'import json,sys;print(json.load(open("'${ota_home}'/hello/state.json"))["current"])')
[ "${state_v}" = "1.2.0" ] || { echo "✗ expected 1.2.0, got ${state_v}"; exit 1; }
echo "tests/e2e/recovery: ✓ installed 1.2.0"

# 6. doctor (read-only).
OTA_HOME="${ota_home}" \
"${run_dir}/bin/ota-agent" doctor hello \
     --server "http://127.0.0.1:${OTA_PORT}" \
     >"${run_dir}/doctor.txt"
grep -q "1.0.0" "${run_dir}/doctor.txt" || {
    echo "✗ doctor output missing 1.0.0 anchor"; cat "${run_dir}/doctor.txt"; exit 1; }
echo "tests/e2e/recovery: ✓ doctor lists anchors"

# 7. doctor --recover=1.0.0 (multi-step rollback).
OTA_HOME="${ota_home}" \
OTA_TRUSTED_PUBKEYS="$(cat "${server_root}/pubkey.hex")" \
"${run_dir}/bin/ota-agent" doctor hello \
     --server "http://127.0.0.1:${OTA_PORT}" --recover=1.0.0
state_v=$(python3 -c 'import json,sys;print(json.load(open("'${ota_home}'/hello/state.json"))["current"])')
[ "${state_v}" = "1.0.0" ] || { echo "✗ expected 1.0.0 after recover, got ${state_v}"; exit 1; }
echo "tests/e2e/recovery: ✓ recovered to 1.0.0"

echo "tests/e2e/recovery: ALL OK"
