;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.
;;;
;;; v1.5: tests for client_software_state snapshot + the rewritten
;;; count-users-at-release + patch_jobs orphan cleanup + the admin
;;; stats catalogue.
;;;
;;; The catalogue-side surface is exercised in isolation here.
;;; The HTTP layer (PUT /v1/clients/me/software, GET /v1/admin/stats/...)
;;; is exercised via the e2e shell scripts so we test the dispatcher,
;;; bearer-auth, and JSON-shape integration too.

(in-package #:ota-server.tests)

(def-suite ota-server-client-state
  :description "v1.5 client_software_state + stats catalogue."
  :in ota-server-suite)

(in-suite ota-server-client-state)

(defun fresh-state-catalogue ()
  "Open a fresh catalogue with all migrations applied."
  (let* ((root (make-tmp-dir))
         (db (ota-server.catalogue:open-catalogue
              (merge-pathnames "db/ota.db" root))))
    (ota-server.catalogue:run-migrations db)
    (values db root)))

;; ---------------------------------------------------------------------------
;; record-client-software-state + get-client-software-state
;; ---------------------------------------------------------------------------

(test record-and-get-roundtrip
  "Recording a state row and reading it back via
get-client-software-state preserves every field."
  (multiple-value-bind (cat root) (fresh-state-catalogue)
    (unwind-protect
         (progn
           (ota-server.catalogue:record-client-software-state
            cat :client-id "c-alpha" :software "myapp"
                :current-release-id "myapp/linux-x86_64/1.0.0"
                :previous-release-id nil :kind "install")
           (let ((s (ota-server.catalogue:get-client-software-state
                     cat "c-alpha" "myapp")))
             (is (not (null s)))
             (is (string= "myapp/linux-x86_64/1.0.0"
                          (getf s :current-release-id)))
             (is (null (getf s :previous-release-id)))
             (is (string= "install" (getf s :last-kind)))))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test re-put-is-idempotent-update
  "A second record-client-software-state for the same (client, sw)
overwrites the previous row; primary key prevents duplicates."
  (multiple-value-bind (cat root) (fresh-state-catalogue)
    (unwind-protect
         (progn
           (ota-server.catalogue:record-client-software-state
            cat :client-id "c-alpha" :software "myapp"
                :current-release-id "myapp/linux-x86_64/1.0.0"
                :kind "install")
           (ota-server.catalogue:record-client-software-state
            cat :client-id "c-alpha" :software "myapp"
                :current-release-id "myapp/linux-x86_64/1.1.0"
                :previous-release-id "myapp/linux-x86_64/1.0.0"
                :kind "upgrade")
           (let ((s (ota-server.catalogue:get-client-software-state
                     cat "c-alpha" "myapp")))
             (is (string= "myapp/linux-x86_64/1.1.0"
                          (getf s :current-release-id)))
             (is (string= "myapp/linux-x86_64/1.0.0"
                          (getf s :previous-release-id)))
             (is (string= "upgrade" (getf s :last-kind)))))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test uninstall-records-null-current
  "Uninstall keeps the row for stats but clears current_release_id."
  (multiple-value-bind (cat root) (fresh-state-catalogue)
    (unwind-protect
         (progn
           (ota-server.catalogue:record-client-software-state
            cat :client-id "c-alpha" :software "myapp"
                :current-release-id "myapp/linux-x86_64/1.0.0"
                :kind "install")
           (ota-server.catalogue:record-client-software-state
            cat :client-id "c-alpha" :software "myapp"
                :current-release-id nil
                :previous-release-id "myapp/linux-x86_64/1.0.0"
                :kind "uninstall")
           (let ((s (ota-server.catalogue:get-client-software-state
                     cat "c-alpha" "myapp")))
             (is (not (null s)))
             (is (null (getf s :current-release-id)))
             (is (string= "uninstall" (getf s :last-kind)))))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

;; ---------------------------------------------------------------------------
;; count-users-at-release (rewritten in v1.5 to read the snapshot)
;; ---------------------------------------------------------------------------

(test count-users-exact-from-snapshot
  "count-users-at-release returns exactly the number of snapshot
rows pointing at the given release.  No event-log scan; no
DISTINCT; no recency window when window-days is NIL."
  (multiple-value-bind (cat root) (fresh-state-catalogue)
    (unwind-protect
         (progn
           (loop for i from 1 to 7 do
             (ota-server.catalogue:record-client-software-state
              cat :client-id (format nil "c-~D" i)
                  :software "myapp"
                  :current-release-id "myapp/linux-x86_64/1.0.0"
                  :kind "install"))
           (loop for i from 8 to 10 do
             (ota-server.catalogue:record-client-software-state
              cat :client-id (format nil "c-~D" i)
                  :software "myapp"
                  :current-release-id "myapp/linux-x86_64/1.1.0"
                  :kind "install"))
           (is (= 7 (ota-server.catalogue:count-users-at-release
                     cat "myapp" "myapp/linux-x86_64/1.0.0")))
           (is (= 3 (ota-server.catalogue:count-users-at-release
                     cat "myapp" "myapp/linux-x86_64/1.1.0")))
           (is (= 0 (ota-server.catalogue:count-users-at-release
                     cat "myapp" "myapp/linux-x86_64/2.0.0"))))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test count-users-excludes-uninstalled
  "A row with current_release_id IS NULL (uninstall) must not
count toward the release the client previously had installed."
  (multiple-value-bind (cat root) (fresh-state-catalogue)
    (unwind-protect
         (progn
           (ota-server.catalogue:record-client-software-state
            cat :client-id "c-1" :software "myapp"
                :current-release-id "myapp/linux-x86_64/1.0.0"
                :kind "install")
           (ota-server.catalogue:record-client-software-state
            cat :client-id "c-2" :software "myapp"
                :current-release-id nil :kind "uninstall")
           (is (= 1 (ota-server.catalogue:count-users-at-release
                     cat "myapp" "myapp/linux-x86_64/1.0.0"))))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test count-users-recency-window
  "With WINDOW-DAYS, rows older than the cutoff are excluded.
Useful for the GC's 'still active' semantics."
  (multiple-value-bind (cat root) (fresh-state-catalogue)
    (unwind-protect
         (let ((fresh (ota-server.catalogue::universal-to-iso8601
                       (get-universal-time)))
               (ancient (ota-server.catalogue::universal-to-iso8601
                         (- (get-universal-time) (* 200 86400)))))
           (ota-server.catalogue:record-client-software-state
            cat :client-id "c-1" :software "myapp"
                :current-release-id "myapp/linux-x86_64/1.0.0"
                :kind "install" :at fresh)
           (ota-server.catalogue:record-client-software-state
            cat :client-id "c-2" :software "myapp"
                :current-release-id "myapp/linux-x86_64/1.0.0"
                :kind "install" :at ancient)
           (is (= 2 (ota-server.catalogue:count-users-at-release
                     cat "myapp" "myapp/linux-x86_64/1.0.0"))
               "no recency cutoff -> both count")
           (is (= 1 (ota-server.catalogue:count-users-at-release
                     cat "myapp" "myapp/linux-x86_64/1.0.0" :window-days 30))
               "30-day cutoff excludes the 200-day-old row"))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

;; ---------------------------------------------------------------------------
;; patch_jobs orphan cleanup (delete-patch-jobs-touching)
;; ---------------------------------------------------------------------------

(test delete-patch-jobs-touching-removes-rows
  "delete-patch-jobs-touching drops every row where the release-id
appears as from OR to.  Used by drop-release so patch-job audit
rows die with their endpoint releases."
  (multiple-value-bind (cat root) (fresh-state-catalogue)
    (unwind-protect
         (progn
           ;; Enqueue three jobs all touching `mid`.
           (loop for i from 0 below 3 do
             (ota-server.catalogue:enqueue-patch-job
              cat
              :from-release-id (format nil "sw/linux-x86_64/1.0.~D" i)
              :to-release-id   "sw/linux-x86_64/mid"
              :software "sw" :os "linux" :arch "x86_64"
              :from-version (format nil "1.0.~D" i)
              :from-blob-sha256 (make-string 64 :initial-element #\a)
              :to-blob-sha256   (make-string 64 :initial-element #\b)))
           ;; Plus one job that doesn't touch `mid` at all.
           (ota-server.catalogue:enqueue-patch-job
            cat
            :from-release-id "sw/linux-x86_64/9.0.0"
            :to-release-id   "sw/linux-x86_64/9.1.0"
            :software "sw" :os "linux" :arch "x86_64"
            :from-version "9.0.0"
            :from-blob-sha256 (make-string 64 :initial-element #\c)
            :to-blob-sha256   (make-string 64 :initial-element #\d))
           (is (= 4 (ota-server.catalogue:count-patch-jobs cat)))
           (ota-server.catalogue:delete-patch-jobs-touching
            cat "sw/linux-x86_64/mid")
           (is (= 1 (ota-server.catalogue:count-patch-jobs cat))
               "only the unrelated 9.0.0 -> 9.1.0 row should survive"))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

;; ---------------------------------------------------------------------------
;; Stats catalogue (workers/stats.lisp)
;; ---------------------------------------------------------------------------

(test stats-catalogue-lists-eight-queries
  "list-stat-queries returns the documented set."
  (let ((names (mapcar (lambda (e) (getf e :name))
                       (ota-server.workers:list-stat-queries))))
    (is (= 8 (length names)))
    (dolist (expected '(:population-per-release :fleet-summary :stale-clients
                        :gc-impact :recent-events :upgrade-failure-rate
                        :adoption-curve :recovery-events))
      (is (member expected names)
          "missing expected query ~S in ~S" expected names))))

(test stats-unknown-name-errors
  "run-stat-query against an unknown name signals STATS-ERROR
which the HTTP handler maps to 404."
  (multiple-value-bind (cat root) (fresh-state-catalogue)
    (unwind-protect
         (signals ota-server.workers:stats-error
           (ota-server.workers:run-stat-query cat :nonexistent))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test stats-missing-required-param-errors
  ":population-per-release requires :software; missing it
signals STATS-ERROR (HTTP layer maps to 400)."
  (multiple-value-bind (cat root) (fresh-state-catalogue)
    (unwind-protect
         (signals ota-server.workers:stats-error
           (ota-server.workers:run-stat-query
            cat :population-per-release))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test stats-population-per-release-returns-counts
  "Seed three clients on two releases; the query reports the
correct counts ordered by clients DESC."
  (multiple-value-bind (cat root) (fresh-state-catalogue)
    (unwind-protect
         (progn
           (ota-server.catalogue:record-client-software-state
            cat :client-id "c-1" :software "myapp"
                :current-release-id "myapp/linux-x86_64/1.0.0"
                :kind "install")
           (ota-server.catalogue:record-client-software-state
            cat :client-id "c-2" :software "myapp"
                :current-release-id "myapp/linux-x86_64/1.0.0"
                :kind "install")
           (ota-server.catalogue:record-client-software-state
            cat :client-id "c-3" :software "myapp"
                :current-release-id "myapp/linux-x86_64/1.1.0"
                :kind "install")
           (multiple-value-bind (cols rows)
               (ota-server.workers:run-stat-query
                cat :population-per-release
                :params (list :software "myapp"))
             ;; Column symbols live in the workers package; compare by
             ;; name to avoid package-qualification headaches in tests.
             (is (equal '("RELEASE_ID" "CLIENTS")
                        (mapcar #'symbol-name cols)))
             (is (= 2 (length rows)))
             (is (equal "myapp/linux-x86_64/1.0.0" (first (first rows))))
             (is (= 2 (second (first rows))))
             (is (equal "myapp/linux-x86_64/1.1.0" (first (second rows))))
             (is (= 1 (second (second rows))))))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test stats-fleet-summary-counts-by-software
  "fleet-summary aggregates across all software in one call."
  (multiple-value-bind (cat root) (fresh-state-catalogue)
    (unwind-protect
         (progn
           (ota-server.catalogue:record-client-software-state
            cat :client-id "c-1" :software "alpha"
                :current-release-id "alpha/linux-x86_64/1.0.0"
                :kind "install")
           (ota-server.catalogue:record-client-software-state
            cat :client-id "c-2" :software "alpha"
                :current-release-id "alpha/linux-x86_64/1.0.0"
                :kind "install")
           (ota-server.catalogue:record-client-software-state
            cat :client-id "c-3" :software "beta"
                :current-release-id "beta/linux-x86_64/0.1.0"
                :kind "install")
           (multiple-value-bind (cols rows)
               (ota-server.workers:run-stat-query cat :fleet-summary)
             (declare (ignore cols))
             (is (= 2 (length rows)))
             ;; Sorted by clients DESC; alpha (2) before beta (1).
             (is (equal "alpha" (first (first rows))))
             (is (= 2 (second (first rows))))
             (is (equal "beta" (first (second rows))))
             (is (= 1 (second (second rows))))))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test stats-stale-clients-honours-since-days
  "stale-clients defaults to 30 days; the recent row is excluded
and the ancient row is included."
  (multiple-value-bind (cat root) (fresh-state-catalogue)
    (unwind-protect
         (let ((fresh (ota-server.catalogue::universal-to-iso8601
                       (get-universal-time)))
               (ancient (ota-server.catalogue::universal-to-iso8601
                         (- (get-universal-time) (* 60 86400)))))
           (ota-server.catalogue:record-client-software-state
            cat :client-id "c-fresh" :software "myapp"
                :current-release-id "myapp/linux-x86_64/1.0.0"
                :kind "install" :at fresh)
           (ota-server.catalogue:record-client-software-state
            cat :client-id "c-stale" :software "myapp"
                :current-release-id "myapp/linux-x86_64/1.0.0"
                :kind "install" :at ancient)
           (multiple-value-bind (cols rows)
               (ota-server.workers:run-stat-query
                cat :stale-clients
                :params (list :software "myapp"))
             (declare (ignore cols))
             (is (= 1 (length rows)))
             (is (equal "c-stale" (first (first rows))))))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))
