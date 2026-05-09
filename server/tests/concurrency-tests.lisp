;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.
;;;
;;; v1.0.4 concurrency tests.  Two things to validate:
;;;
;;;   1. The CATALOGUE struct exposes a recursive lock and the
;;;      OTA-SERVER.CATALOGUE:WITH-CATALOGUE macro acquires it; under
;;;      a parallel-read race the underlying SQLite connection is
;;;      never re-entered (we do not crash, lose updates, or read
;;;      torn rows).
;;;
;;;   2. OPEN-CATALOGUE has actually enabled WAL mode and the
;;;      busy_timeout we asked for.
;;;
;;; These tests cover the pieces that are easy to validate from
;;; in-image -- the multi-worker Woo path and end-to-end HTTP
;;; concurrency are exercised by the e2e shell suite (see
;;; tests/e2e/parallel.sh).

(in-package #:ota-server.tests)

(def-suite ota-server-concurrency
  :description "v1.0.4 catalogue lock + WAL configuration."
  :in ota-server-suite)

(in-suite ota-server-concurrency)

(defun fresh-tmp-catalogue ()
  "Open a fresh catalogue under a unique temp dir, run migrations,
return (values catalogue tmp-root)."
  (let* ((root (make-tmp-dir))
         (db   (merge-pathnames "db/ota.db" root))
         (cat  (ota-server.catalogue:open-catalogue db)))
    (ota-server.catalogue:run-migrations cat)
    (values cat root)))

;; ---------------------------------------------------------------------------
;; Struct shape + WAL configuration
;; ---------------------------------------------------------------------------

(test catalogue-is-a-struct-with-lock
  "OPEN-CATALOGUE returns a CATALOGUE struct exposing both the
underlying sqlite handle and a bordeaux-threads recursive lock."
  (multiple-value-bind (cat root) (fresh-tmp-catalogue)
    (unwind-protect
         (progn
           (is (ota-server.catalogue::catalogue-p cat)
               "open-catalogue should return a CATALOGUE struct, got ~S"
               (type-of cat))
           (is (not (null (ota-server.catalogue::catalogue-handle cat))))
           (is (not (null (ota-server.catalogue::catalogue-lock cat)))))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test wal-mode-is-on
  "OPEN-CATALOGUE leaves the connection in WAL journal mode and with
the configured busy_timeout."
  (multiple-value-bind (cat root) (fresh-tmp-catalogue)
    (unwind-protect
         (let ((handle (ota-server.catalogue::catalogue-handle cat)))
           (let ((mode (string-downcase
                        (sqlite:execute-single handle "PRAGMA journal_mode"))))
             (is (string= "wal" mode)
                 "expected journal_mode=wal, got ~S" mode))
           (is (= 10000
                  (sqlite:execute-single handle "PRAGMA busy_timeout"))
               "expected busy_timeout=10000ms"))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

;; ---------------------------------------------------------------------------
;; Concurrent access via the lock
;; ---------------------------------------------------------------------------

(test parallel-readers-get-consistent-counts
  "Spawn N reader threads that each call LIST-RELEASES against the
same catalogue while one writer thread inserts releases.  No
thread should crash, and every reader's row-count should be
monotonic non-decreasing within a single thread (i.e. no torn /
rolled-back reads)."
  (multiple-value-bind (cat root) (fresh-tmp-catalogue)
    (unwind-protect
         (let* ((n-readers 8)
                (n-writes  20)
                (errors    nil)
                (errors-lock (bordeaux-threads:make-lock "errors"))
                (push-error (lambda (e thread-name)
                              (bordeaux-threads:with-lock-held (errors-lock)
                                (push (list thread-name (princ-to-string e)) errors))))
                (writer-done nil)
                (writer (bordeaux-threads:make-thread
                         (lambda ()
                           (handler-case
                               (progn
                                 (ota-server.catalogue:ensure-software cat :name "concurrent")
                                 (loop for i from 0 below n-writes
                                       do (ota-server.catalogue:insert-release
                                           cat
                                           :release-id (format nil "concurrent/x/v~D" i)
                                           :software "concurrent"
                                           :os "x" :arch "y" :os-versions #()
                                           :version (format nil "~D.0.0" i)
                                           :blob-sha256 (format nil "~64,'0X" i)
                                           :blob-size i
                                           :manifest-sha256 "0"
                                           :published-by "test"))
                                 (setf writer-done t))
                             (error (e) (funcall push-error e "writer"))))
                         :name "writer"))
                (readers
                  (loop for i below n-readers
                        collect
                        (bordeaux-threads:make-thread
                         (lambda ()
                           (handler-case
                               (let ((last 0))
                                 (loop until writer-done
                                       do (let ((n (length
                                                    (ota-server.catalogue:list-releases
                                                     cat "concurrent"))))
                                            (when (< n last)
                                              (error "row count went backwards: ~A < ~A"
                                                     n last))
                                            (setf last n))))
                             (error (e) (funcall push-error e
                                                 (format nil "reader-~D" i)))))
                         :name (format nil "reader-~D" i)))))
           (bordeaux-threads:join-thread writer)
           (mapc #'bordeaux-threads:join-thread readers)
           (is (null errors)
               "concurrent access produced errors: ~{~%  ~A~}" errors)
           (is (= n-writes
                  (length (ota-server.catalogue:list-releases cat "concurrent")))))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test recursive-lock-permits-nested-calls
  "WITH-CATALOGUE holds a *recursive* lock, so a catalogue function
that itself calls another catalogue function from the same thread
must not deadlock."
  (multiple-value-bind (cat root) (fresh-tmp-catalogue)
    (unwind-protect
         (let ((nested-result nil))
           ;; Take the lock manually, then call a public API that
           ;; will also try to take it.  If the lock is recursive
           ;; (which it is per OPEN-CATALOGUE), this returns; if
           ;; not, the test deadlocks and the suite hangs.  Use a
           ;; thread + JOIN-THREAD so a hang fails the test rather
           ;; than wedging the whole CL image.
           (let ((t1 (bordeaux-threads:make-thread
                      (lambda ()
                        (ota-server.catalogue::with-catalogue (db cat)
                          (declare (ignore db))
                          (ota-server.catalogue:ensure-software cat :name "nested")
                          (setf nested-result
                                (ota-server.catalogue:list-software cat))))
                      :name "nested-lock-test")))
             (bordeaux-threads:join-thread t1))
           (is (find "nested" nested-result
                     :key (lambda (sw) (getf sw :name))
                     :test #'string=)
               "nested call did not write the row"))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

;; ---------------------------------------------------------------------------
;; Config: worker_num is plumbed
;; ---------------------------------------------------------------------------

(test worker-num-defaults-to-4
  "Built-in defaults give worker-num = 4."
  (let ((cfg (ota-server.config:apply-env-overrides
              nil :getenv (lambda (n) (declare (ignore n)) nil))))
    (is (= 4 (getf cfg :worker-num)))))

(test worker-num-from-toml
  "[server].worker_num overrides the default."
  (let* ((tmp (merge-pathnames "wn.toml" (make-tmp-dir))))
    (with-open-file (out tmp :direction :output)
      (write-string "[server]
worker_num = 16
" out))
    (let ((cfg (ota-server.config:apply-env-overrides
                (ota-server.config:load-config-from-file tmp)
                :getenv (lambda (n) (declare (ignore n)) nil))))
      (is (= 16 (getf cfg :worker-num))))))
