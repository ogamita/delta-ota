#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Ogamita Ltd.
#
# v1.0.4 e2e: prove that the multi-worker server keeps reads
# responsive while a slow handler is in flight.
#
# Scenario: spawn the server with worker_num >= 4, kick off a
# publish for a moderately large blob (the bsdiff pass holds
# ONE worker thread for several seconds), and concurrently fire
# many GET /v1/install/<sw> requests from a herd of background
# curls.  Every reader must complete inside a tight deadline,
# proving the publish handler did not wedge the event loop.
#
# Required PATH bins: sbcl, ~/quicklisp/setup.lisp, curl, head, tr.

set -eu

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "${repo_root}"

run_dir="${OTA_E2E_RUN_DIR:-tests/e2e/run-parallel}"
rm -rf "${run_dir}"
mkdir -p "${run_dir}/logs"

OTA_PORT="${OTA_PORT:-18460}"
OTA_TOKEN="parallel-token"
N_READERS="${N_READERS:-50}"            # concurrent GET clients
READ_DEADLINE_SEC="${READ_DEADLINE_SEC:-3}"   # per-request curl timeout
TOTAL_DEADLINE_SEC="${TOTAL_DEADLINE_SEC:-30}"

make vendor-build >>"${run_dir}/logs/build.log" 2>&1

# A largish payload so bsdiff has real work on the second publish
# (the in-flight publish is the one we expect to hold a worker thread).
make_payload() {
    dst="$1"; tag="$2"
    mkdir -p "${dst}"
    head -c $((4 * 1024 * 1024)) /dev/zero | tr '\0' 'A' > "${dst}/big.dat"
    echo "${tag}" >> "${dst}/big.dat"
}
make_payload "${run_dir}/p1" v1
make_payload "${run_dir}/p2" v2
echo "tests/e2e/parallel: payloads prepared (4 MiB each)"

# Boot the server with worker_num=4 so a single in-flight publish
# leaves >= 3 worker threads available for the GET herd.  This is
# the key v1.0.4 property under test.
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
  (ota-server.http:start-server state
                                :host "127.0.0.1"
                                :port ${OTA_PORT}
                                :worker-num 4)
  (format t "ota-server: ready on port ${OTA_PORT} (worker-num=4)~%")
  (force-output)
  (loop (sleep 30)))
EOF

echo "tests/e2e/parallel: starting server (port ${OTA_PORT}, worker-num=4)"
sbcl --non-interactive --no-userinit --no-sysinit \
     --load ~/quicklisp/setup.lisp \
     --eval '(asdf:load-asd (truename "server/ota-server.asd"))' \
     --load "${run_dir}/run-server.lisp" \
     >"${server_log}" 2>&1 &
server_pid=$!
trap 'kill ${server_pid} 2>/dev/null || true' EXIT INT TERM

for i in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:${OTA_PORT}/v1/install/x" >/dev/null 2>&1; then
        echo "tests/e2e/parallel: server up after ${i}s"
        break
    fi
    sleep 1
    if ! kill -0 ${server_pid} 2>/dev/null; then
        echo "tests/e2e/parallel: server died early; log:"; cat "${server_log}"; exit 1
    fi
done

# Helper: tar a payload then upload it as a release.  The first
# publish only inserts; the second triggers a bsdiff build (slow,
# this is the synchronous handler we want to NOT block other reqs).
publish_payload() {
    src="$1"; ver="$2"; tag="$3"
    tar_path="${run_dir}/payload-${ver}.tar"
    sbcl --non-interactive --no-userinit --no-sysinit \
         --load ~/quicklisp/setup.lisp \
         --eval '(asdf:load-asd (truename "server/ota-server.asd"))' \
         --eval "(ql:quickload :ota-server :silent t)" \
         --eval "(ota-server.storage:tar-directory-to-file \"$(pwd)/${src}/\" \"$(pwd)/${tar_path}\")" \
         >>"${server_log}" 2>&1
    curl -sS -X POST                                                \
         -H "Authorization: Bearer ${OTA_TOKEN}"                     \
         -H "X-Ota-Version: ${ver}"                                  \
         -H "X-Ota-Os: linux"                                        \
         -H "X-Ota-Arch: amd64"                                      \
         -H "X-Ota-Os-Versions:"                                     \
         -H "Content-Type: application/octet-stream"                 \
         --data-binary "@${tar_path}"                                \
         "http://127.0.0.1:${OTA_PORT}/v1/admin/software/${tag}/releases" \
         >>"${run_dir}/logs/publish-${ver}.log" 2>&1
}

# Seed: publish v1 (no patch build, fast).
echo "tests/e2e/parallel: priming with v1"
publish_payload "${run_dir}/p1" "1.0.0" "ogamita-test"

# Now: kick off the slow publish (v2 -> bsdiff against v1) in the
# background, then immediately fire N_READERS concurrent GETs.
echo "tests/e2e/parallel: starting slow publish + ${N_READERS} concurrent reads"
publish_payload "${run_dir}/p2" "2.0.0" "ogamita-test" &
publisher_pid=$!

# Reader herd.  Each reader records exit code + wall time.  All must
# return inside READ_DEADLINE_SEC (curl --max-time) AND the herd as
# a whole must finish before TOTAL_DEADLINE_SEC.  If the server were
# single-threaded, every GET would queue behind the slow publish and
# blow either timeout.
mkdir -p "${run_dir}/reader-results"
herd_start=$(date +%s)
reader_pids=""
for i in $(seq 1 "${N_READERS}"); do
    (
        rc=0
        if ! curl -sS --max-time "${READ_DEADLINE_SEC}" \
                  -o /dev/null -w "%{http_code} %{time_total}\n" \
                  "http://127.0.0.1:${OTA_PORT}/v1/install/ogamita-test" \
                  >"${run_dir}/reader-results/reader-${i}.out" 2>&1; then
            rc=$?
        fi
        echo "${rc}" > "${run_dir}/reader-results/reader-${i}.rc"
    ) &
    reader_pids="${reader_pids} $!"
done
# IMPORTANT: don't use bare `wait` -- the server (sbcl) is also a
# child of this shell and bare wait would block on it forever.
# Wait for each reader explicitly instead.
for pid in ${reader_pids}; do
    wait "${pid}" 2>/dev/null || true
done
herd_end=$(date +%s)
herd_duration=$((herd_end - herd_start))
echo "tests/e2e/parallel: herd completed in ${herd_duration}s"

# Wait for the slow publisher (so we leave the server in a clean state).
wait "${publisher_pid}" 2>/dev/null || true

# Score the results.
fails=0
slowest=0
for rc_file in "${run_dir}"/reader-results/reader-*.rc; do
    rc="$(cat "${rc_file}")"
    if [ "${rc}" != "0" ]; then
        fails=$((fails + 1))
    fi
done

# Find the slowest individual reader (sanity check, even when all OK).
for out in "${run_dir}"/reader-results/reader-*.out; do
    t="$(awk '{print $2}' "${out}" 2>/dev/null | head -1)"
    [ -n "${t}" ] || continue
    # bash arithmetic doesn't do floats; multiply by 1000 -> ms
    ms=$(printf '%s' "${t}" | awk '{printf "%d", $1 * 1000}')
    [ "${ms}" -gt "${slowest}" ] && slowest=${ms}
done

echo "tests/e2e/parallel: failed readers = ${fails} / ${N_READERS}"
echo "tests/e2e/parallel: slowest reader = ${slowest} ms"
echo "tests/e2e/parallel: herd wall time = ${herd_duration}s (deadline ${TOTAL_DEADLINE_SEC}s)"

if [ "${fails}" -gt 0 ]; then
    echo "FAIL: ${fails} reader(s) timed out or errored while a publish was in flight." >&2
    echo "      First failing output:" >&2
    for out in "${run_dir}"/reader-results/reader-*.out; do
        rc_file="${out%.out}.rc"
        if [ "$(cat "${rc_file}")" != "0" ]; then
            echo "      --- ${out} ---" >&2
            cat "${out}" >&2
            break
        fi
    done
    exit 1
fi

if [ "${herd_duration}" -gt "${TOTAL_DEADLINE_SEC}" ]; then
    echo "FAIL: herd took ${herd_duration}s, exceeding ${TOTAL_DEADLINE_SEC}s deadline." >&2
    exit 1
fi

echo "PASS: tests/e2e/parallel — ${N_READERS} concurrent reads stayed responsive while a publish was in flight."
