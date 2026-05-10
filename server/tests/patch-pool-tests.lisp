;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.
;;;
;;; v1.2: tests for the persistent patch_jobs queue + the async
;;; worker pool that consumes it.
;;;
;;; The catalogue-side tests exercise the SQL surface directly with no
;;; threading involved.  The pool tests substitute a tiny shell script
;;; for `bsdiff(1)` so we can run real work without depending on the
;;; vendored binary, then assert the pool drained the queue.

(in-package #:ota-server.tests)

(def-suite ota-server-patch-pool
  :description "v1.2 persistent patch_jobs queue + async worker pool."
  :in ota-server-suite)

(in-suite ota-server-patch-pool)

;; ---------------------------------------------------------------------------
;; Catalogue-side: queue surface in isolation.
;; ---------------------------------------------------------------------------

(defun fresh-pool-catalogue ()
  "Open a fresh catalogue + run migrations.  Returns (values cat root)."
  (let* ((root (make-tmp-dir))
         (db (ota-server.catalogue:open-catalogue
              (merge-pathnames "db/ota.db" root))))
    (ota-server.catalogue:run-migrations db)
    (values db root)))

(defun fake-job-args (i)
  "Return a plist of unique-by-I :enqueue-patch-job arguments."
  (list :from-release-id (format nil "sw/linux-x86_64/1.0.~D" i)
        :to-release-id   "sw/linux-x86_64/2.0.0"
        :software        "sw"
        :os              "linux"
        :arch            "x86_64"
        :from-version    (format nil "1.0.~D" i)
        :from-blob-sha256 (make-string 64 :initial-element #\a)
        :to-blob-sha256   (make-string 64 :initial-element #\b)))

(test enqueue-patch-job-is-idempotent
  "Two identical enqueues return :enqueued then :existing, with the
same row id both times."
  (multiple-value-bind (cat root) (fresh-pool-catalogue)
    (unwind-protect
         (let ((args (fake-job-args 0)))
           (multiple-value-bind (s1 id1)
               (apply #'ota-server.catalogue:enqueue-patch-job cat args)
             (multiple-value-bind (s2 id2)
                 (apply #'ota-server.catalogue:enqueue-patch-job cat args)
               (is (eq :enqueued s1))
               (is (eq :existing s2))
               (is (integerp id1))
               (is (= id1 id2)
                   "second enqueue should return the same row id, got ~S vs ~S"
                   id1 id2)))
           (is (= 1 (ota-server.catalogue:count-patch-jobs cat :status "pending"))))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test claim-next-returns-oldest-pending
  "claim-next-patch-job marks the oldest pending row running, returns
its plist, and a second claim picks up the next-oldest."
  (multiple-value-bind (cat root) (fresh-pool-catalogue)
    (unwind-protect
         (progn
           (apply #'ota-server.catalogue:enqueue-patch-job cat (fake-job-args 0))
           (apply #'ota-server.catalogue:enqueue-patch-job cat (fake-job-args 1))
           (let ((j1 (ota-server.catalogue:claim-next-patch-job cat))
                 (j2 (ota-server.catalogue:claim-next-patch-job cat))
                 (j3 (ota-server.catalogue:claim-next-patch-job cat)))
             (is (not (null j1)))
             (is (string= "running" (getf j1 :status)))
             (is (= 1 (getf j1 :attempts)))
             (is (string= "1.0.0" (getf j1 :from-version))
                 "first claim should be the oldest enqueued (1.0.0)")
             (is (not (null j2)))
             (is (string= "1.0.1" (getf j2 :from-version)))
             (is (null j3) "third claim against an empty queue must be NIL")))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test complete-and-fail-update-status
  "complete-patch-job and fail-patch-job set the documented columns."
  (multiple-value-bind (cat root) (fresh-pool-catalogue)
    (unwind-protect
         (let* ((dummy "deadbeef"))
           (apply #'ota-server.catalogue:enqueue-patch-job cat (fake-job-args 0))
           (apply #'ota-server.catalogue:enqueue-patch-job cat (fake-job-args 1))
           (let* ((j1 (ota-server.catalogue:claim-next-patch-job cat))
                  (j2 (ota-server.catalogue:claim-next-patch-job cat)))
             (ota-server.catalogue:complete-patch-job
              cat (getf j1 :id) :sha256 dummy :size 42)
             (ota-server.catalogue:fail-patch-job
              cat (getf j2 :id) "boom")
             (let ((rows (ota-server.catalogue:list-patch-jobs-for-release
                          cat "sw/linux-x86_64/2.0.0")))
               (is (= 2 (length rows)))
               (let ((done   (find "done"   rows :key (lambda (r) (getf r :status))
                                                 :test #'string=))
                     (failed (find "failed" rows :key (lambda (r) (getf r :status))
                                                 :test #'string=)))
                 (is (string= dummy (getf done :patch-sha256)))
                 (is (= 42 (getf done :patch-size)))
                 (is (string= "boom" (getf failed :error)))
                 (is (not (null (getf done :completed-at))))
                 (is (not (null (getf failed :completed-at))))))))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test reset-stale-running-jobs-recovers
  "A row left in 'running' (because the previous server died mid-bsdiff)
is reset to 'pending' by reset-stale-running-jobs and re-claimed by a
subsequent worker."
  (multiple-value-bind (cat root) (fresh-pool-catalogue)
    (unwind-protect
         (progn
           (apply #'ota-server.catalogue:enqueue-patch-job cat (fake-job-args 0))
           (let ((j (ota-server.catalogue:claim-next-patch-job cat)))
             (declare (ignore j))
             (is (= 1 (ota-server.catalogue:count-patch-jobs cat :status "running")))
             (is (= 0 (ota-server.catalogue:count-patch-jobs cat :status "pending"))))
           ;; Server dies here.  On restart:
           (let ((reset (ota-server.catalogue:reset-stale-running-jobs cat)))
             (is (= 1 reset))
             (is (= 0 (ota-server.catalogue:count-patch-jobs cat :status "running")))
             (is (= 1 (ota-server.catalogue:count-patch-jobs cat :status "pending"))))
           ;; The new pool re-picks the row up.
           (let ((j2 (ota-server.catalogue:claim-next-patch-job cat)))
             (is (not (null j2)))
             (is (= 2 (getf j2 :attempts))
                 "attempts should have incremented across the recovery")))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

;; ---------------------------------------------------------------------------
;; End-to-end pool: real worker threads, fake bsdiff binary.
;; ---------------------------------------------------------------------------

(defun write-fake-bsdiff (root)
  "Write a tiny shell script under ROOT that mimics bsdiff(1)'s
calling convention (`bsdiff FROM TO OUT`).  The output bytes embed
the source-blob path so two distinct (from, to) pairs produce
distinct patch contents — necessary because the real `patches`
table is content-addressed by SHA, so identical patch bytes from
different jobs would collapse onto a single row.  Returns the
script's pathname."
  (let ((p (merge-pathnames "fake-bsdiff" root)))
    (with-open-file (out p :direction :output
                           :if-exists :supersede
                           :element-type 'character)
      (format out "#!/bin/sh~%printf 'PATCH:%s->%s' \"$1\" \"$2\" > \"$3\"~%"))
    #+sbcl (sb-posix:chmod p #o755)
    p))

(defun seed-blob (cas content-byte size)
  "Put a SIZE-byte blob whose every byte is CONTENT-BYTE under CAS,
returning its sha256."
  (let* ((tmp (merge-pathnames (format nil "seed-~A.bin" content-byte)
                               (ota-server.storage:cas-root cas)))
         (buf (make-array size :element-type '(unsigned-byte 8)
                               :initial-element content-byte)))
    (ensure-directories-exist tmp)
    (with-open-file (out tmp :direction :output
                             :if-exists :supersede
                             :element-type '(unsigned-byte 8))
      (write-sequence buf out))
    (multiple-value-bind (sha size)
        (ota-server.storage:put-blob-from-file cas tmp)
      (declare (ignore size))
      sha)))

(test pool-drains-queue-end-to-end
  "Boot a 2-worker pool against a fake-bsdiff, enqueue 3 jobs, wait
for them to all reach 'done', verify the resulting patch rows landed
in the patches table."
  (multiple-value-bind (cat root) (fresh-pool-catalogue)
    (let* ((cas    (ota-server.storage:make-cas root))
           (script (write-fake-bsdiff root))
           (to-sha   (seed-blob cas 65 64))
           ;; Distinct from-blobs so the fake bsdiff produces distinct
           ;; patch SHAs (the patches table PK is the patch sha256).
           ;; Vary BOTH the byte value AND the size to be extra-sure
           ;; the inputs are unique.
           (from-shas (loop for b from 70 below 73
                            for sz from 64 by 8
                            collect (seed-blob cas b sz)))
           (target-rid "sw/linux-x86_64/2.0.0")
           pool)
      (unwind-protect
           (let ((ota-server.workers:*bsdiff-binary* (namestring script)))
             ;; Three priors → three jobs.
             (loop for i from 0 below 3
                   for sha in from-shas do
               (ota-server.catalogue:enqueue-patch-job
                cat
                :from-release-id (format nil "sw/linux-x86_64/1.0.~D" i)
                :to-release-id   target-rid
                :software "sw" :os "linux" :arch "x86_64"
                :from-version (format nil "1.0.~D" i)
                :from-blob-sha256 sha
                :to-blob-sha256   to-sha))
             (setf pool (ota-server.workers:start-patch-pool cas cat :size 2))
             (ota-server.workers:notify-patch-pool pool)
             ;; Wait up to 5 s for the queue to drain.
             (let ((deadline (+ (get-internal-real-time)
                                (* 5 internal-time-units-per-second))))
               (loop while (and (plusp (ota-server.catalogue:count-patch-jobs
                                        cat :to-release-id target-rid
                                            :status "pending"))
                                (< (get-internal-real-time) deadline))
                     do (sleep 0.05))
               (loop while (and (plusp (ota-server.catalogue:count-patch-jobs
                                        cat :to-release-id target-rid
                                            :status "running"))
                                (< (get-internal-real-time) deadline))
                     do (sleep 0.05)))
             (is (= 3 (ota-server.catalogue:count-patch-jobs
                       cat :to-release-id target-rid :status "done")))
             (is (zerop (ota-server.catalogue:count-patch-jobs
                         cat :to-release-id target-rid :status "failed")))
             (let ((rows (ota-server.catalogue:list-patches-to
                          cat target-rid))
                   (jobs (ota-server.catalogue:list-patch-jobs-for-release
                          cat target-rid)))
               (is (= 3 (length rows))
                   "every successful job should leave a patches row, got ~D; jobs=~S patches=~S"
                   (length rows) jobs rows)))
        (ota-server.workers:stop-patch-pool pool)
        (ota-server.catalogue:close-catalogue cat)
        (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore)))))

(test pool-stops-cleanly-on-empty-queue
  "Starting then immediately stopping a pool with no work in the
queue must return promptly (within ~3 s) and not leave threads alive."
  (multiple-value-bind (cat root) (fresh-pool-catalogue)
    (let ((cas (ota-server.storage:make-cas root))
          pool)
      (unwind-protect
           (let* ((t0 (get-internal-real-time))
                  (_  (setf pool (ota-server.workers:start-patch-pool
                                  cas cat :size 2)))
                  (_2 (ota-server.workers:stop-patch-pool pool))
                  (elapsed-secs (/ (- (get-internal-real-time) t0)
                                   internal-time-units-per-second)))
             (declare (ignore _ _2))
             (is (< elapsed-secs 3)
                 "start+stop with no work should finish in <3s, took ~A"
                 elapsed-secs)
             (dolist (th (ota-server.workers::patch-pool-threads pool))
               (is (not (bordeaux-threads:thread-alive-p th))
                   "worker thread ~A should have exited" th)))
        (ota-server.catalogue:close-catalogue cat)
        (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore)))))
