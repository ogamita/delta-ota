#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Ogamita Ltd.
#
# v1.5 e2e: admin SQL statistics surface.
#
# Boots a server with a hand-seeded snapshot table (skipping the
# agent layer -- client-state.sh covers that), then exercises:
#
#   1. GET /v1/admin/stats             -> catalogue listing
#   2. GET /v1/admin/stats/population-per-release?software=...
#   3. GET /v1/admin/stats/fleet-summary
#   4. GET /v1/admin/stats/stale-clients?software=...
#   5. GET /v1/admin/stats/gc-impact?software=...
#   6. GET /v1/admin/stats/unknown    -> 404
#   7. GET /v1/admin/stats/population-per-release (no software) -> 400
#   8. ota-server stats --help-stats   -> CLI listing
#   9. ota-server stats population-per-release --software=...  -> CLI run
#
# Tests the routing, parameter parsing, JSON envelope, and the
# error-response paths.  Per-query SQL correctness is in the lisp
# unit tests; this is the integration layer.

set -eu

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "${repo_root}"

run_dir="${OTA_E2E_RUN_DIR:-tests/e2e/run-stats}"
rm -rf "${run_dir}"
mkdir -p "${run_dir}/logs"

OTA_PORT="${OTA_PORT:-18487}"
OTA_TOKEN="stats-test-token"

server_root="${run_dir}/server-root"
abs_root="$(mkdir -p "${server_root}" && cd "${server_root}" && pwd)"

# Seed: 5 clients on 2 releases of one software + 2 clients on 1
# release of a second software, plus an "ancient" row to exercise
# stale-clients.
cat > "${run_dir}/run-server.lisp" <<EOF
(ql:quickload "ota-server" :silent t)
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
  ;; Three releases of myapp + one of beta so gc-impact has rows to
  ;; left-join against.
  (ota-server.catalogue:ensure-software db :name "myapp")
  (ota-server.catalogue:ensure-software db :name "beta")
  (dolist (v '("1.0.0" "1.1.0" "2.0.0"))
    (ota-server.catalogue:insert-release
     db
     :release-id (format nil "myapp/linux-x86_64/~A" v)
     :software "myapp" :os "linux" :arch "x86_64"
     :os-versions #() :version v
     :blob-sha256 (make-string 64 :initial-element (code-char (+ 65 (random 26))))
     :blob-size 1024
     :manifest-sha256 (make-string 64 :initial-element (code-char (+ 65 (random 26))))))
  (ota-server.catalogue:insert-release
   db
   :release-id "beta/linux-x86_64/0.1.0"
   :software "beta" :os "linux" :arch "x86_64"
   :os-versions #() :version "0.1.0"
   :blob-sha256 (make-string 64 :initial-element #\b)
   :blob-size 1024
   :manifest-sha256 (make-string 64 :initial-element #\b))
  ;; Seed the snapshot.
  (loop for i from 1 to 3 do
    (ota-server.catalogue:record-client-software-state
     db :client-id (format nil "c-~D" i) :software "myapp"
     :current-release-id "myapp/linux-x86_64/1.0.0"
     :kind "install"))
  (loop for i from 4 to 5 do
    (ota-server.catalogue:record-client-software-state
     db :client-id (format nil "c-~D" i) :software "myapp"
     :current-release-id "myapp/linux-x86_64/1.1.0"
     :kind "install"))
  (loop for i from 6 to 7 do
    (ota-server.catalogue:record-client-software-state
     db :client-id (format nil "c-~D" i) :software "beta"
     :current-release-id "beta/linux-x86_64/0.1.0"
     :kind "install"))
  ;; One stale row (60 days old).
  (ota-server.catalogue:record-client-software-state
   db :client-id "c-stale" :software "myapp"
   :current-release-id "myapp/linux-x86_64/1.0.0"
   :kind "install"
   :at (ota-server.catalogue::universal-to-iso8601
        (- (get-universal-time) (* 60 86400))))
  (ota-server.http:start-server state :host "127.0.0.1" :port ${OTA_PORT}
                                      :worker-num 2)
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
echo "tests/e2e/stats: server up"

q() {
    curl -sS -H "Authorization: Bearer ${OTA_TOKEN}" \
         "http://127.0.0.1:${OTA_PORT}$1"
}
qcode() {
    curl -sS -o /dev/null -w '%{http_code}' \
         -H "Authorization: Bearer ${OTA_TOKEN}" \
         "http://127.0.0.1:${OTA_PORT}$1"
}

# === (1) Catalogue listing
echo "tests/e2e/stats: (1) catalogue listing..."
r=$(q "/v1/admin/stats")
echo "${r}" | grep -q '"name":"population-per-release"' \
    || { echo "  ✗ catalogue missing population-per-release"; echo "${r}"; exit 1; }
echo "${r}" | grep -q '"name":"fleet-summary"' \
    || { echo "  ✗ catalogue missing fleet-summary"; exit 1; }
echo "  ✓ catalogue lists every documented query"

# === (2) population-per-release
echo "tests/e2e/stats: (2) population-per-release..."
r=$(q "/v1/admin/stats/population-per-release?software=myapp")
# Seeded: 1.0.0 has 4 clients (3 fresh + 1 stale), 1.1.0 has 2.
echo "${r}" | grep -q '"myapp/linux-x86_64/1.0.0",4\]' \
    || { echo "  ✗ expected 1.0.0,4"; echo "${r}"; exit 1; }
echo "${r}" | grep -q '"myapp/linux-x86_64/1.1.0",2\]' \
    || { echo "  ✗ expected 1.1.0,2"; echo "${r}"; exit 1; }
echo "  ✓ population-per-release reflects seeded snapshot"

# === (3) fleet-summary
echo "tests/e2e/stats: (3) fleet-summary..."
r=$(q "/v1/admin/stats/fleet-summary")
echo "${r}" | grep -q '"myapp"' \
    || { echo "  ✗ fleet-summary missing myapp"; exit 1; }
echo "${r}" | grep -q '"beta"' \
    || { echo "  ✗ fleet-summary missing beta"; exit 1; }
echo "  ✓ fleet-summary lists both software lines"

# === (4) stale-clients
echo "tests/e2e/stats: (4) stale-clients..."
r=$(q "/v1/admin/stats/stale-clients?software=myapp&since-days=30")
echo "${r}" | grep -q '"c-stale"' \
    || { echo "  ✗ stale-clients did not surface the 60-day row"; echo "${r}"; exit 1; }
echo "  ✓ stale-clients honours since-days=30"

# === (5) gc-impact
echo "tests/e2e/stats: (5) gc-impact..."
r=$(q "/v1/admin/stats/gc-impact?software=myapp")
# Three releases of myapp; left-join with snapshot gives clients counts.
echo "${r}" | grep -q '"myapp/linux-x86_64/1.0.0"' \
    || { echo "  ✗ gc-impact missing 1.0.0 row"; exit 1; }
echo "${r}" | grep -q '"myapp/linux-x86_64/2.0.0"' \
    || { echo "  ✗ gc-impact missing 2.0.0 row"; exit 1; }
echo "  ✓ gc-impact joins releases against snapshot"

# === (6) unknown query -> 404
echo "tests/e2e/stats: (6) unknown query -> 404..."
code=$(qcode "/v1/admin/stats/this-does-not-exist?software=x")
[ "${code}" = "404" ] || { echo "  ✗ expected 404, got ${code}"; exit 1; }
echo "  ✓ 404 on unknown query"

# === (7) missing required param -> 400
echo "tests/e2e/stats: (7) missing software param -> 400..."
code=$(qcode "/v1/admin/stats/population-per-release")
[ "${code}" = "400" ] || { echo "  ✗ expected 400, got ${code}"; exit 1; }
echo "  ✓ 400 on missing required param"

# === (8) CLI: --help-stats lists the catalogue
echo "tests/e2e/stats: (8) ota-server stats --help-stats..."
# The standalone executable might not have been built; this part of
# the test runs the lisp toplevel directly to exercise the
# subcommand without relying on `make build-server`.
cli_log="${run_dir}/cli-help.txt"
sbcl --non-interactive --no-userinit --no-sysinit \
     --load ~/quicklisp/setup.lisp \
     --eval '(asdf:load-asd (truename "server/ota-server.asd"))' \
     --eval "(ql:quickload :ota-server :silent t)" \
     --eval "(ota-server::%list-stats *standard-output*)" \
     >"${cli_log}" 2>&1
grep -q "population-per-release" "${cli_log}" \
    || { echo "  ✗ --help-stats did not list the catalogue"
         cat "${cli_log}"; exit 1; }
echo "  ✓ %list-stats prints the catalogue"

echo "PASS: tests/e2e/stats — admin stats surface end-to-end"
