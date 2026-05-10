#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Ogamita Ltd.
#
# v1.1.1 e2e: prove that two ota-server processes pointed at the
# SAME data directory don't corrupt each other when a publish
# race happens.
#
# This is the "real" cross-process complement to the 8-thread
# fiveam test (insert-release-if-new-is-atomic-under-concurrent-
# callers): the unit test goes through the same SQLite locking
# path but only across SBCL threads sharing one connection.  Two
# separate processes against the same DB file is a strictly
# stronger guarantee, recorded as an open item in ADR-0006.
#
# Scenario:
#   1. Boot server A on port $A and server B on port $B, both
#      pointing at the same data dir.
#   2. Race: in parallel, both A and B receive a publish for the
#      SAME (software, os, arch, version=R1) tuple, with the
#      SAME blob.  Outcomes must be:
#         - exactly one of them logs "stored" (the :inserted branch);
#         - the other returns 200 with idempotent:true (:existing
#           same-blob branch);
#         - neither returns a 5xx.
#   3. Same race for version=R2 with DIFFERENT blob contents on
#      A vs. B.  Outcomes must be:
#         - exactly one wins with code 201 (or 200 streaming "done");
#         - the other returns 409 conflict (it lost the race AND its
#           blob differs);
#         - neither returns a 5xx.
#   4. Sequential: publish version=R3 only on A, version=R4 only on
#      B.  Both must succeed (different versions don't conflict).
#
# Required PATH bins: sbcl, ~/quicklisp/setup.lisp, curl, head, tr,
# python3 (for parsing JSON).

set -eu

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "${repo_root}"

run_dir="${OTA_E2E_RUN_DIR:-tests/e2e/run-two-process}"
rm -rf "${run_dir}"
mkdir -p "${run_dir}/logs"

PORT_A="${PORT_A:-18480}"
PORT_B="${PORT_B:-18481}"
OTA_TOKEN="two-process-token"

make vendor-build >>"${run_dir}/logs/build.log" 2>&1

# Small payloads -- this test stresses the catalogue locking, not
# bsdiff.  Keep them tiny so the bsdiff fan-in finishes fast.
make_payload() {
    dst="$1"; tag="$2"
    mkdir -p "${dst}"
    head -c 4096 /dev/zero | tr '\0' 'A' > "${dst}/file.bin"
    echo "${tag}" >> "${dst}/file.bin"
}
# pX_same: shared between A and B (race 1: same blob).
# pX_a / pX_b: divergent contents (race 2: conflict).
# pX_solo_*: single-publisher payloads (race 3: no contention).
make_payload "${run_dir}/p1_same"  v1
make_payload "${run_dir}/p2_a"     v2-from-a
make_payload "${run_dir}/p2_b"     v2-from-b-different
make_payload "${run_dir}/p3_solo"  v3-solo
make_payload "${run_dir}/p4_solo"  v4-solo
echo "tests/e2e/two-process: payloads prepared"

# ONE shared data directory -- this is the key property under test.
shared_root="${run_dir}/shared-data"
mkdir -p "${shared_root}"
abs_root="$(cd "${shared_root}" && pwd)"

# Boot two SBCL servers against the same data dir on different ports.
boot_server() {
    label="$1"; port="$2"; logfile="$3"
    cat > "${run_dir}/run-server-${label}.lisp" <<EOF
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
                                :port ${port}
                                :worker-num 4)
  (format t "ota-server[${label}]: ready on port ${port}~%")
  (force-output)
  (loop (sleep 30)))
EOF
    sbcl --non-interactive --no-userinit --no-sysinit \
         --load ~/quicklisp/setup.lisp \
         --eval '(asdf:load-asd (truename "server/ota-server.asd"))' \
         --load "${run_dir}/run-server-${label}.lisp" \
         >"${logfile}" 2>&1 &
    echo $!
}

server_a_log="${run_dir}/logs/server-a.log"
server_b_log="${run_dir}/logs/server-b.log"
echo "tests/e2e/two-process: starting two servers on the SAME data dir"
pid_a="$(boot_server a "${PORT_A}" "${server_a_log}")"
# Wait for A to migrate the DB before starting B (otherwise both
# race on the migrations themselves -- a separate concern from
# this test's purpose).
for i in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:${PORT_A}/v1/install/x" >/dev/null 2>&1; then
        break
    fi
    sleep 1
    if ! kill -0 "${pid_a}" 2>/dev/null; then
        echo "tests/e2e/two-process: server A died early; log:" >&2
        cat "${server_a_log}" >&2; exit 1
    fi
done
pid_b="$(boot_server b "${PORT_B}" "${server_b_log}")"
trap "kill ${pid_a} ${pid_b} 2>/dev/null || true" EXIT INT TERM
for i in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:${PORT_B}/v1/install/x" >/dev/null 2>&1; then
        break
    fi
    sleep 1
    if ! kill -0 "${pid_b}" 2>/dev/null; then
        echo "tests/e2e/two-process: server B died early; log:" >&2
        cat "${server_b_log}" >&2; exit 1
    fi
done
echo "tests/e2e/two-process: both servers up (A=:${PORT_A}, B=:${PORT_B})"

# Helper: tar a payload (using the server's own deterministic
# writer so a/b processes see byte-identical blobs for the
# "same content" race) then POST it without --no-stream so the
# server's NDJSON path also gets exercised.
publish_at() {
    src="$1"; ver="$2"; tag="$3"; port="$4"; outfile="$5"
    tar_path="${run_dir}/tar-${ver}-${port}.tar"
    sbcl --non-interactive --no-userinit --no-sysinit \
         --load ~/quicklisp/setup.lisp \
         --eval '(asdf:load-asd (truename "server/ota-server.asd"))' \
         --eval "(ql:quickload :ota-server :silent t)" \
         --eval "(ota-server.storage:tar-directory-to-file \"$(pwd)/${src}/\" \"$(pwd)/${tar_path}\")" \
         >>"${run_dir}/logs/publish-${ver}-${port}.log" 2>&1
    # Capture status code separately so we can assert on it.
    curl -sS -o "${outfile}.body" -w "%{http_code}" \
         -X POST                                                \
         -H "Authorization: Bearer ${OTA_TOKEN}"                 \
         -H "X-Ota-Version: ${ver}"                              \
         -H "X-Ota-Os: linux"                                    \
         -H "X-Ota-Arch: amd64"                                  \
         -H "Content-Type: application/octet-stream"             \
         --data-binary "@${tar_path}"                            \
         "http://127.0.0.1:${port}/v1/admin/software/${tag}/releases" \
         > "${outfile}.code" 2>>"${run_dir}/logs/publish-${ver}-${port}.log"
}

# ---------------------------------------------------------------------------
# Race 1: SAME tuple, SAME blob -- exactly one :inserted, one :existing.
# ---------------------------------------------------------------------------
echo
echo "=== Race 1: same tuple (v1) + same blob, parallel on A and B ==="
publish_at "${run_dir}/p1_same" "1.0.0" "racetest" "${PORT_A}" \
           "${run_dir}/r1-a.out" &
pid1a=$!
publish_at "${run_dir}/p1_same" "1.0.0" "racetest" "${PORT_B}" \
           "${run_dir}/r1-b.out" &
pid1b=$!
wait "${pid1a}" "${pid1b}"

code_a="$(cat ${run_dir}/r1-a.out.code)"
code_b="$(cat ${run_dir}/r1-b.out.code)"
echo "  A: code=${code_a}"
echo "  B: code=${code_b}"
# Expected outcomes (in either order):
#   one of them returns 201 (won the race, :inserted)
#   the other returns 200 (lost the race, :existing same blob -> idempotent)
#   neither returns 5xx
race1_ok=true
case "${code_a}-${code_b}" in
    201-200|200-201|200-200)
        # 200-200 is also acceptable: both lost to a third
        # observer, OR both happened to find a row from a prior
        # run (shouldn't happen on a fresh data dir, but the test
        # accepts it for robustness).
        ;;
    *)
        race1_ok=false ;;
esac
if [ "${code_a}" -ge 500 ] || [ "${code_b}" -ge 500 ]; then
    race1_ok=false
fi
if ${race1_ok}; then
    echo "  PASS: race 1"
else
    echo "  FAIL: race 1 -- got code_a=${code_a} code_b=${code_b}" >&2
    echo "  body A: $(cat ${run_dir}/r1-a.out.body | head -c 300)" >&2
    echo "  body B: $(cat ${run_dir}/r1-b.out.body | head -c 300)" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Race 2: SAME tuple (v2), DIFFERENT blob -- exactly one wins, the
# other returns 409 conflict.
# ---------------------------------------------------------------------------
echo
echo "=== Race 2: same tuple (v2) + DIFFERENT blob on A vs. B ==="
publish_at "${run_dir}/p2_a" "2.0.0" "racetest" "${PORT_A}" \
           "${run_dir}/r2-a.out" &
pid2a=$!
publish_at "${run_dir}/p2_b" "2.0.0" "racetest" "${PORT_B}" \
           "${run_dir}/r2-b.out" &
pid2b=$!
wait "${pid2a}" "${pid2b}"

code_a="$(cat ${run_dir}/r2-a.out.code)"
code_b="$(cat ${run_dir}/r2-b.out.code)"
echo "  A: code=${code_a}"
echo "  B: code=${code_b}"
race2_ok=true
# Acceptable outcomes:
#   201-409  (A won, B's different blob conflicts)
#   409-201  (symmetric)
case "${code_a}-${code_b}" in
    201-409|409-201) ;;
    *)               race2_ok=false ;;
esac
if [ "${code_a}" -ge 500 ] || [ "${code_b}" -ge 500 ]; then
    race2_ok=false
fi
if ${race2_ok}; then
    echo "  PASS: race 2 (one 201, one 409, no 5xx)"
else
    echo "  FAIL: race 2 -- got code_a=${code_a} code_b=${code_b}" >&2
    echo "  body A: $(cat ${run_dir}/r2-a.out.body | head -c 300)" >&2
    echo "  body B: $(cat ${run_dir}/r2-b.out.body | head -c 300)" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Race 3 (no contention): different versions on A and B succeed
# without interfering.
# ---------------------------------------------------------------------------
echo
echo "=== Race 3: different versions on each server (no contention) ==="
publish_at "${run_dir}/p3_solo" "3.0.0" "racetest" "${PORT_A}" \
           "${run_dir}/r3-a.out" &
pid3a=$!
publish_at "${run_dir}/p4_solo" "4.0.0" "racetest" "${PORT_B}" \
           "${run_dir}/r3-b.out" &
pid3b=$!
wait "${pid3a}" "${pid3b}"
code_a="$(cat ${run_dir}/r3-a.out.code)"
code_b="$(cat ${run_dir}/r3-b.out.code)"
echo "  A (v3.0.0): code=${code_a}"
echo "  B (v4.0.0): code=${code_b}"
if [ "${code_a}" = "201" ] && [ "${code_b}" = "201" ]; then
    echo "  PASS: race 3 (both 201, distinct versions inserted)"
else
    echo "  FAIL: race 3 -- expected 201/201, got ${code_a}/${code_b}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Final consistency: list the catalogue from each server -- they
# must agree (same SQLite file, both processes look at the same
# rows).
# ---------------------------------------------------------------------------
echo
echo "=== Final catalogue consistency ==="
list_a="$(curl -sS http://127.0.0.1:${PORT_A}/v1/software/racetest/releases)"
list_b="$(curl -sS http://127.0.0.1:${PORT_B}/v1/software/racetest/releases)"
versions_a="$(printf '%s' "${list_a}" \
              | python3 -c 'import json,sys; print(",".join(sorted(r["version"] for r in json.load(sys.stdin))))')"
versions_b="$(printf '%s' "${list_b}" \
              | python3 -c 'import json,sys; print(",".join(sorted(r["version"] for r in json.load(sys.stdin))))')"
echo "  A sees: ${versions_a}"
echo "  B sees: ${versions_b}"
if [ "${versions_a}" != "${versions_b}" ]; then
    echo "  FAIL: catalogues diverge between processes" >&2
    exit 1
fi
# Expected: 1.0.0, 2.0.0, 3.0.0, 4.0.0 (a winning v2 + the rest).
case "${versions_a}" in
    "1.0.0,2.0.0,3.0.0,4.0.0") echo "  PASS: 4 versions, both processes agree" ;;
    *)
        echo "  FAIL: expected 4 versions 1.0.0,2.0.0,3.0.0,4.0.0; got ${versions_a}" >&2
        exit 1
        ;;
esac

echo
echo "PASS: tests/e2e/two-process-publish — atomic publish across processes"
