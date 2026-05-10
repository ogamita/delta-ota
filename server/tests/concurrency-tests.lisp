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

(test worker-num-env-overrides-toml
  "OTA_WORKER_NUM env-var beats both defaults and the TOML file."
  (let ((cfg (ota-server.config:apply-env-overrides
              (list :worker-num 4)
              :getenv (lambda (n)
                        (when (string= n "OTA_WORKER_NUM") "32")))))
    (is (= 32 (getf cfg :worker-num)))))

;; ---------------------------------------------------------------------------
;; Idempotent publish: the catalogue lookup that feeds it.
;; ---------------------------------------------------------------------------

(test get-release-by-tuple-roundtrips
  "INSERT-RELEASE then GET-RELEASE-BY-TUPLE returns the same row."
  (multiple-value-bind (cat root) (fresh-tmp-catalogue)
    (unwind-protect
         (progn
           (ota-server.catalogue:ensure-software cat :name "idem")
           (ota-server.catalogue:insert-release
            cat
            :release-id "idem/linux-amd64/1.0.0"
            :software "idem"
            :os "linux" :arch "amd64" :os-versions #("12")
            :version "1.0.0"
            :blob-sha256 "deadbeef" :blob-size 42
            :manifest-sha256 "feedface"
            :published-by "test")
           (let ((r (ota-server.catalogue:get-release-by-tuple
                     cat "idem" "linux" "amd64" "1.0.0")))
             (is (not (null r)))
             (is (string= "deadbeef" (getf r :blob-sha256)))
             (is (= 42 (getf r :blob-size)))))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test get-release-by-tuple-discriminates-arch
  "Two releases with the same software/version but different arch are
distinct rows; the lookup returns the right one for each."
  (multiple-value-bind (cat root) (fresh-tmp-catalogue)
    (unwind-protect
         (progn
           (ota-server.catalogue:ensure-software cat :name "multiarch")
           (dolist (arch '("amd64" "arm64"))
             (ota-server.catalogue:insert-release
              cat
              :release-id (format nil "multiarch/linux-~A/1.0.0" arch)
              :software "multiarch"
              :os "linux" :arch arch :os-versions #()
              :version "1.0.0"
              :blob-sha256 (concatenate 'string "blob-" arch)
              :blob-size 1
              :manifest-sha256 "x"
              :published-by "test"))
           (is (string= "blob-amd64"
                        (getf (ota-server.catalogue:get-release-by-tuple
                               cat "multiarch" "linux" "amd64" "1.0.0")
                              :blob-sha256)))
           (is (string= "blob-arm64"
                        (getf (ota-server.catalogue:get-release-by-tuple
                               cat "multiarch" "linux" "arm64" "1.0.0")
                              :blob-sha256))))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test get-release-by-tuple-misses-cleanly
  "An unknown tuple returns NIL (not an error)."
  (multiple-value-bind (cat root) (fresh-tmp-catalogue)
    (unwind-protect
         (is (null (ota-server.catalogue:get-release-by-tuple
                    cat "no-such" "no" "no" "0.0.0")))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

;; ---------------------------------------------------------------------------
;; Semver-aware "latest" -- v1.1.0 fix.  The v1.0.x sort by
;; published_at DESC silently downgraded clients when an older
;; version was re-published after a newer one was already out.
;; ---------------------------------------------------------------------------

(test parse-semver-shapes
  "PARSE-SEMVER returns (NUMS . PRERELEASE-OR-NIL) for valid input
and NIL for non-semver."
  (is (equal '((1 2 3))           (ota-server.catalogue:parse-semver "1.2.3")))
  (is (equal '((1 2 3) . "rc1")   (ota-server.catalogue:parse-semver "1.2.3-rc1")))
  (is (equal '((10 0 4))          (ota-server.catalogue:parse-semver "10.0.4")))
  (is (equal '((1 0))             (ota-server.catalogue:parse-semver "1.0")))
  (is (null (ota-server.catalogue:parse-semver "alpha")))
  (is (null (ota-server.catalogue:parse-semver "1.x.0")))
  (is (null (ota-server.catalogue:parse-semver "")))
  (is (null (ota-server.catalogue:parse-semver nil))))

(test semver-compare
  "SEMVER< orders versions per the spec's numeric rule."
  (let ((v (lambda (s) (ota-server.catalogue:parse-semver s))))
    (is (ota-server.catalogue:semver< (funcall v "1.0.0") (funcall v "1.0.1")))
    (is (ota-server.catalogue:semver< (funcall v "1.0.9") (funcall v "1.0.10")))
    (is (ota-server.catalogue:semver< (funcall v "1.9.9") (funcall v "2.0.0")))
    (is (not (ota-server.catalogue:semver< (funcall v "1.0.1") (funcall v "1.0.0"))))
    (is (not (ota-server.catalogue:semver< (funcall v "1.0.0") (funcall v "1.0.0"))))
    ;; prerelease < release
    (is (ota-server.catalogue:semver< (funcall v "1.0.0-rc1") (funcall v "1.0.0")))
    (is (not (ota-server.catalogue:semver< (funcall v "1.0.0") (funcall v "1.0.0-rc1"))))
    ;; missing tail = 0
    (is (not (ota-server.catalogue:semver< (funcall v "1.0") (funcall v "1.0.0"))))
    (is (not (ota-server.catalogue:semver< (funcall v "1.0.0") (funcall v "1.0"))))))

(test get-latest-release-prefers-highest-semver-not-most-recent
  "v1.1.0 fix: when releases are published OUT of version order,
GET-LATEST-RELEASE returns the highest-semver one, NOT the
most-recently-published one (which v1.0.x did and which silently
downgraded clients)."
  (multiple-value-bind (cat root) (fresh-tmp-catalogue)
    (unwind-protect
         (progn
           (ota-server.catalogue:ensure-software cat :name "lat")
           ;; Insert OLDEST -> NEWEST published_at order, but the
           ;; semver order is 1.0.0 < 1.0.1 < 1.0.2 < 1.0.3 < 1.0.4.
           ;; The v1.0.x bug: "latest" would be 1.0.0 (last inserted,
           ;; newest published_at).  v1.1.0 fix: "latest" is 1.0.4
           ;; (highest semver), regardless of insert order.
           (dolist (v '("1.0.4" "1.0.2" "1.0.3" "1.0.1" "1.0.0"))
             (ota-server.catalogue:insert-release
              cat
              :release-id (format nil "lat/x-y/~A" v)
              :software "lat"
              :os "x" :arch "y" :os-versions #()
              :version v
              :blob-sha256 (format nil "~64,'0X" (sxhash v))
              :blob-size 1
              :manifest-sha256 "0"
              :published-by "test"))
           (let ((latest (ota-server.catalogue:get-latest-release cat "lat")))
             (is (string= "1.0.4" (getf latest :version))
                 "expected 1.0.4 (highest semver), got ~S" (getf latest :version))))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test get-latest-release-falls-back-to-published-at-for-non-semver
  "If NO release has a parseable semver, GET-LATEST-RELEASE falls
back to v1.0.x published_at-DESC behaviour (the only sensible
ordering when versions look like 'alpha', 'beta-build', ...)."
  (multiple-value-bind (cat root) (fresh-tmp-catalogue)
    (unwind-protect
         (progn
           (ota-server.catalogue:ensure-software cat :name "ns")
           (dolist (v '("alpha" "beta" "gamma"))
             (ota-server.catalogue:insert-release
              cat
              :release-id (format nil "ns/x-y/~A" v)
              :software "ns"
              :os "x" :arch "y" :os-versions #()
              :version v
              :blob-sha256 (format nil "~64,'0X" (sxhash v))
              :blob-size 1
              :manifest-sha256 "0"
              :published-by "test"))
           ;; No semver parses -> we fall back to LIST-RELEASES's
           ;; first row (sorted published_at DESC).  Since v1.1.0
           ;; INSERT-RELEASE makes published_at *strictly* monotonic
           ;; per software, the last-inserted (gamma) is unambiguously
           ;; the newest -- the test no longer needs the "any of
           ;; three" relaxation that worked around the same-second tie.
           (let ((latest (ota-server.catalogue:get-latest-release cat "ns")))
             (is (string= "gamma" (getf latest :version))
                 "fallback returned ~S; expected gamma (last inserted)"
                 (getf latest :version))))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test published-at-is-strictly-monotonic-per-software
  "Two back-to-back inserts in the same wall-clock second must NOT
tie on published_at.  v1.1.0: INSERT-RELEASE computes published_at
catalogue-side as max(MAX(prior published_at) + 1s, now), so any
ORDER BY published_at DESC consumer (notably the v1.0.x
get-latest-release fallback for non-semver versions) is
deterministic without the publisher having to sleep."
  (multiple-value-bind (cat root) (fresh-tmp-catalogue)
    (unwind-protect
         (progn
           (ota-server.catalogue:ensure-software cat :name "mono")
           ;; Five tight inserts; we're betting these all happen
           ;; inside one wall-clock second on every reasonable host.
           (dotimes (i 5)
             (ota-server.catalogue:insert-release
              cat
              :release-id (format nil "mono/x-y/r~D" i)
              :software "mono"
              :os "x" :arch "y" :os-versions #()
              :version (format nil "~D" i)
              :blob-sha256 (format nil "~64,'0X" i)
              :blob-size 1
              :manifest-sha256 "0"
              :published-by "test"))
           (let* ((rels (ota-server.catalogue:list-releases cat "mono"))
                  (timestamps (mapcar (lambda (r) (getf r :published-at)) rels)))
             ;; LIST-RELEASES returns published_at DESC, so the list
             ;; should be strictly decreasing.
             (loop for (a b) on timestamps
                   while b
                   do (is (string> a b)
                          "published_at not strictly monotonic: ~S then ~S"
                          a b))
             ;; And: every timestamp is unique.
             (is (= (length timestamps) (length (remove-duplicates timestamps :test #'string=)))
                 "duplicate published_at: ~S" timestamps)))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

;; ---------------------------------------------------------------------------
;; v1.1.1 publish progress: build-patches-for-release ON-PROGRESS
;; callback contract.  Server's publish handler renders the same
;; events as NDJSON over HTTP; here we just check the events arrive
;; in order with the expected shape.
;; ---------------------------------------------------------------------------

(test build-patches-for-release-emits-progress-events
  "When :ON-PROGRESS is supplied, BUILD-PATCHES-FOR-RELEASE calls it
exactly:
  - once with :event :patches-started + :total = N at the start;
  - once with :event :patch-built per successful patch (with
    :i 1..N, :total N, :from VERSION, :sha SHA, :size SIZE);
  - once with :event :patches-done + :built = M at the end.

The test fakes priors via INSERT-RELEASE rows with a non-zero
blob and stubs *bsdiff-binary* with a no-op script so the bsdiff
subprocess succeeds without doing real work."
  (multiple-value-bind (cat root) (fresh-tmp-catalogue)
    (unwind-protect
         (let* ((cas (ota-server.storage:make-cas root))
                (events '()))
           (ota-server.catalogue:ensure-software cat :name "p")
           ;; Insert two priors with their blobs on disk so the
           ;; bsdiff subprocess has something to chew on.  Each
           ;; blob is a few KB of arbitrary bytes.
           (dolist (v '("0.1.0" "0.2.0"))
             (let* ((tmp (merge-pathnames (format nil "tmp/blob-~A.bin" v) root)))
               (ensure-directories-exist tmp)
               (with-open-file (out tmp :direction :output
                                        :if-exists :supersede
                                        :element-type '(unsigned-byte 8))
                 (write-sequence
                  (make-array 4096 :element-type '(unsigned-byte 8)
                              :initial-contents
                              (loop for i below 4096
                                    collect (mod (+ i (length v)) 256)))
                  out))
               (multiple-value-bind (sha size)
                   (ota-server.storage:put-blob-from-file cas tmp)
                 (declare (ignore size))
                 (ota-server.catalogue:insert-release
                  cat
                  :release-id (format nil "p/x-y/~A" v)
                  :software "p" :os "x" :arch "y" :os-versions #()
                  :version v
                  :blob-sha256 sha :blob-size 4096
                  :manifest-sha256 "0" :published-by "test"))))
           ;; Stage the new release's blob too.
           (let* ((to-tmp (merge-pathnames "tmp/blob-1.0.0.bin" root)))
             (with-open-file (out to-tmp :direction :output
                                         :if-exists :supersede
                                         :element-type '(unsigned-byte 8))
               (write-sequence
                (make-array 4096 :element-type '(unsigned-byte 8)
                            :initial-element 42)
                out))
             (multiple-value-bind (to-sha to-size)
                 (ota-server.storage:put-blob-from-file cas to-tmp)
               (declare (ignore to-size))
               (ota-server.workers:build-patches-for-release
                cas cat
                :software "p" :os "x" :arch "y"
                :new-version "1.0.0"
                :new-release-id "p/x-y/1.0.0"
                :new-blob-sha to-sha
                :on-progress (lambda (e) (push e events)))))
           (let ((events (nreverse events)))
             ;; First event is :patches-started total=2.
             (let ((start (first events)))
               (is (eq :patches-started (getf start :event)))
               (is (= 2 (getf start :total))))
             ;; Last event is :patches-done with :built >= 0.
             (let ((end (car (last events))))
               (is (eq :patches-done (getf end :event)))
               (is (numberp (getf end :built))))
             ;; Middle events are all :patch-built with i from 1 upward.
             (let* ((middle (subseq events 1 (1- (length events))))
                    (patch-builts (remove-if-not
                                   (lambda (e) (eq :patch-built (getf e :event)))
                                   middle))
                    (i-values (mapcar (lambda (e) (getf e :i)) patch-builts)))
               (is (equal '(1 2) (sort (copy-list i-values) #'<)))
               (dolist (e patch-builts)
                 (is (= 2 (getf e :total)))
                 (is (stringp (getf e :from)))
                 (is (stringp (getf e :sha)))
                 (is (numberp (getf e :size)))))))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test build-patches-for-release-no-progress-when-no-priors
  "With zero priors, BUILD-PATCHES-FOR-RELEASE skips the
:patches-started and :patches-done events entirely (no work to
report on).  Backward-compatible with callers that don't pass
:ON-PROGRESS."
  (multiple-value-bind (cat root) (fresh-tmp-catalogue)
    (unwind-protect
         (let ((cas (ota-server.storage:make-cas root))
               (events '()))
           (ota-server.catalogue:ensure-software cat :name "lone")
           (let* ((to-tmp (merge-pathnames "tmp/blob-only.bin" root)))
             (ensure-directories-exist to-tmp)
             (with-open-file (out to-tmp :direction :output
                                         :if-exists :supersede
                                         :element-type '(unsigned-byte 8))
               (write-sequence (make-array 256 :element-type '(unsigned-byte 8)
                                               :initial-element 7)
                               out))
             (multiple-value-bind (to-sha to-size)
                 (ota-server.storage:put-blob-from-file cas to-tmp)
               (declare (ignore to-size))
               (ota-server.workers:build-patches-for-release
                cas cat
                :software "lone" :os "x" :arch "y"
                :new-version "1.0.0"
                :new-release-id "lone/x-y/1.0.0"
                :new-blob-sha to-sha
                :on-progress (lambda (e) (push e events)))))
           (is (null events) "expected no progress events; got ~S" events))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

;; ---------------------------------------------------------------------------
;; INSERT-RELEASE-IF-NEW (v1.1.1) -- atomic lookup-then-insert that
;; closes the multi-process publish race.  See ADR-0006.
;; ---------------------------------------------------------------------------

(defun %make-release-args (version &optional (sha nil))
  "Common kwargs for INSERT-RELEASE-IF-NEW under software=irn."
  (list :release-id      (format nil "irn/x-y/~A" version)
        :software        "irn"
        :os              "x"
        :arch            "y"
        :os-versions     #()
        :version         version
        :blob-sha256     (or sha (format nil "~64,'0X" (sxhash version)))
        :blob-size       1
        :manifest-sha256 "0"
        :published-by    "test"))

(test insert-release-if-new-returns-inserted-on-first-call
  "First call for a (sw, os, arch, version) tuple returns
:inserted + NIL, and the row is queryable afterwards via
GET-RELEASE-BY-TUPLE."
  (multiple-value-bind (cat root) (fresh-tmp-catalogue)
    (unwind-protect
         (progn
           (ota-server.catalogue:ensure-software cat :name "irn")
           (multiple-value-bind (status existing)
               (apply #'ota-server.catalogue:insert-release-if-new
                      cat (%make-release-args "1.0.0" "deadbeef"))
             (is (eq :inserted status))
             (is (null existing)))
           (let ((r (ota-server.catalogue:get-release-by-tuple
                     cat "irn" "x" "y" "1.0.0")))
             (is (string= "deadbeef" (getf r :blob-sha256)))))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test insert-release-if-new-returns-existing-on-duplicate-tuple
  "Second call for the SAME tuple returns :existing + the previously-
stored row (not the newly-supplied args).  This is what the publish
handler dispatches its `200 idempotent` / `409 conflict` decision
on -- the existing row's blob-sha256 is the source of truth."
  (multiple-value-bind (cat root) (fresh-tmp-catalogue)
    (unwind-protect
         (progn
           (ota-server.catalogue:ensure-software cat :name "irn")
           (apply #'ota-server.catalogue:insert-release-if-new
                  cat (%make-release-args "1.0.0" "first-blob"))
           ;; Second call with a DIFFERENT blob-sha256 still gets
           ;; back the FIRST blob in :existing -- this is what
           ;; lets the handler distinguish idempotent re-publish
           ;; (sha matches) from conflict (sha differs).
           (multiple-value-bind (status existing)
               (apply #'ota-server.catalogue:insert-release-if-new
                      cat (%make-release-args "1.0.0" "second-blob"))
             (is (eq :existing status))
             (is (string= "first-blob" (getf existing :blob-sha256))
                 ":existing must return the row already in the DB, ~
                  not the just-attempted one")))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test insert-release-if-new-is-atomic-under-concurrent-callers
  "N parallel threads racing on the same tuple: exactly ONE returns
:inserted, the rest return :existing.  This is the v1.1.1 fix --
prior to BEGIN IMMEDIATE wrapping the lookup+insert, the loser of
the race hit a SQLITE_CONSTRAINT 500 because both callers passed
the bare GET-RELEASE-BY-TUPLE check before either INSERT landed."
  (multiple-value-bind (cat root) (fresh-tmp-catalogue)
    (unwind-protect
         (let* ((n-threads 8)
                (results-lock (bordeaux-threads:make-lock "results"))
                (statuses '())
                (errors '())
                (start-barrier (bordeaux-threads:make-condition-variable))
                (start-mutex (bordeaux-threads:make-lock "start"))
                (ready 0)
                (go nil)
                (threads
                  (loop for i below n-threads
                        collect
                        (bordeaux-threads:make-thread
                         (lambda ()
                           ;; Wait for the conductor to release us all
                           ;; together so the contention is real.
                           (bordeaux-threads:with-lock-held (start-mutex)
                             (incf ready)
                             (loop until go
                                   do (bordeaux-threads:condition-wait
                                       start-barrier start-mutex)))
                           (handler-case
                               (multiple-value-bind (status existing)
                                   (apply #'ota-server.catalogue:insert-release-if-new
                                          cat (%make-release-args "1.0.0"
                                                                  (format nil "~64,'0X" i)))
                                 (declare (ignore existing))
                                 (bordeaux-threads:with-lock-held (results-lock)
                                   (push status statuses)))
                             (error (e)
                               (bordeaux-threads:with-lock-held (results-lock)
                                 (push (princ-to-string e) errors)))))))))
           (ota-server.catalogue:ensure-software cat :name "irn")
           ;; Wait for every worker to be parked on the barrier.
           (loop until (bordeaux-threads:with-lock-held (start-mutex)
                         (= ready n-threads))
                 do (sleep 0.01))
           (bordeaux-threads:with-lock-held (start-mutex)
             (setf go t)
             (bordeaux-threads:condition-notify start-barrier)
             ;; condition-notify wakes one; broadcast wakes all.
             #+sbcl (loop repeat n-threads
                          do (bordeaux-threads:condition-notify start-barrier)))
           (mapc #'bordeaux-threads:join-thread threads)
           (is (null errors)
               "no thread should hit SQLITE_CONSTRAINT or any other ~
                error; got: ~{~%  ~A~}" errors)
           (is (= n-threads (length statuses))
               "expected ~A status results, got ~A" n-threads (length statuses))
           (is (= 1 (count :inserted statuses))
               "exactly one thread must win and return :inserted; ~
                got ~A :inserted out of ~A" (count :inserted statuses)
                                            (length statuses))
           (is (= (1- n-threads) (count :existing statuses))
               "all losers must return :existing; got ~A :existing out of ~A"
               (count :existing statuses) (length statuses)))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test get-latest-release-mixed-ignores-non-semver
  "When SOME versions are semver and some are not, the non-semver
ones are ignored and the highest-semver wins.  This matches the
operator intuition that 'real' releases should always be reachable
as `latest` even if a debug build like 'wip' is also in the
catalogue."
  (multiple-value-bind (cat root) (fresh-tmp-catalogue)
    (unwind-protect
         (progn
           (ota-server.catalogue:ensure-software cat :name "mix")
           (dolist (v '("1.0.0" "wip" "1.2.0" "alpha-build" "1.1.0"))
             (ota-server.catalogue:insert-release
              cat
              :release-id (format nil "mix/x-y/~A" v)
              :software "mix"
              :os "x" :arch "y" :os-versions #()
              :version v
              :blob-sha256 (format nil "~64,'0X" (sxhash v))
              :blob-size 1
              :manifest-sha256 "0"
              :published-by "test"))
           (let ((latest (ota-server.catalogue:get-latest-release cat "mix")))
             (is (string= "1.2.0" (getf latest :version)))))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))
