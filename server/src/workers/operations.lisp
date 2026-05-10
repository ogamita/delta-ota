;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.
;;;
;;; Phase-5 operational workers: garbage collection, content
;;; verification, manifest re-signing on key rotation.

(in-package #:ota-server.workers)

;; ---------------------------------------------------------------------
;; Garbage collection.
;; ---------------------------------------------------------------------

(defun gc-software (cas catalogue keypair manifests-dir
                    &key software (min-user-count 0) (min-age-days 30)
                         (window-days 180) dry-run
                         (ensure-reachability t) (allow-blob-fallback nil)
                         (max-built-edges 50) (fallback-ratio 0.7))
  "Garbage-collect expendable releases for SOFTWARE.

A release is on the candidate-drop list when ALL of these hold:
  - it is not marked uncollectable;
  - it is not the highest-semver visible release;
  - count-users-at-release(...) ≤ MIN-USER-COUNT in the recency
    WINDOW-DAYS;
  - it has been published longer than MIN-AGE-DAYS.

v1.6 (reachability layer): with ENSURE-REACHABILITY = T (default),
the GC first computes a plan partitioning every active client by
how the simulated drop set affects them, and pre-builds the
minimum set of `from -> target` patches needed to keep
blob-fallback clients on a delta path.  When the plan needs more
than MAX-BUILT-EDGES new patches, the GC refuses to proceed
unless ALLOW-BLOB-FALLBACK is T -- in that case affected clients
will fall back to a full-blob download on their next upgrade.

Returns a plist:
  :pruned          list of release-ids actually dropped
  :kept-blobs      list of blob shas kept (still referenced)
  :dry-run         BOOLEAN
  :reachability    plist :clients-by-fate :edges-built :edges-to-build
                          :blocked-clients (when ENSURE-REACHABILITY)"
  (let* ((releases (ota-server.catalogue:list-releases catalogue software))
         (latest-rid
           (let ((r (ota-server.catalogue:highest-semver-release releases)))
             (and r (getf r :release-id))))
         (now-univ (get-universal-time))
         (min-age-secs (* min-age-days 86400))
         (candidates '()))
    (dolist (rel releases)
      (let* ((rid (getf rel :release-id))
             (uncollectable (getf rel :uncollectable))
             (published (getf rel :published-at))
             (age (- now-univ (parse-iso8601 published)))
             (users (ota-server.catalogue:count-users-at-release
                     catalogue software rid :window-days window-days)))
        (when (and (not uncollectable)
                   (not (and latest-rid (string= rid latest-rid)))
                   (>= age min-age-secs)
                   (<= users min-user-count))
          (push rel candidates))))
    (setf candidates (nreverse candidates))
    (let ((drop-set (mapcar (lambda (r) (getf r :release-id)) candidates))
          (reachability-info nil))
      (when ensure-reachability
        (let* ((client-positions
                 (remove-if-not
                  (lambda (s)
                    (and (string= (getf s :software) software)
                         (getf s :current-release-id)))
                  (ota-server.catalogue:list-client-software-states
                   catalogue :software software)))
               (plan (ota-server.workers:compute-reachability-plan
                      catalogue
                      :software software
                      :drop-set drop-set
                      :client-positions client-positions
                      :fallback-ratio fallback-ratio)))
          (cond
            ;; Refuse if the plan needs too many builds and the
            ;; operator didn't authorise blob fallback.
            ((and (not (ota-server.workers:reachability-plan-feasible-p
                        plan max-built-edges))
                  (not allow-blob-fallback))
             (return-from gc-software
               (list :pruned nil
                     :kept-blobs nil
                     :dry-run t
                     :reachability
                     (append plan
                             (list :feasible-p nil
                                   :edges-built 0
                                   :error "edges-to-build exceeds max_built_edges"))
                     :aborted t)))
            ((and (not dry-run)
                  (not allow-blob-fallback))
             ;; Build the missing edges before any drop happens.
             (let ((built (ota-server.workers:execute-reachability-builds
                           cas catalogue plan)))
               (setf reachability-info
                     (append plan (list :feasible-p t
                                        :edges-built built)))))
            (t
             ;; Dry-run OR allow-blob-fallback: don't build, just
             ;; report what the plan would have done.
             (setf reachability-info
                   (append plan (list :feasible-p
                                      (ota-server.workers:reachability-plan-feasible-p
                                       plan max-built-edges)
                                      :edges-built 0)))))))
      (let ((pruned '()) (kept-blobs '()))
        (dolist (rel candidates)
          (push (getf rel :release-id) pruned)
          (unless dry-run
            (drop-release cas catalogue keypair manifests-dir
                          rel kept-blobs)))
        (list :pruned (nreverse pruned)
              :kept-blobs kept-blobs
              :dry-run (if dry-run t nil)
              :reachability reachability-info)))))

(defun parse-iso8601 (s)
  "Parse YYYY-MM-DDTHH:MM:SSZ into universal-time. Tolerant: any
   parse failure → 0 (treated as 'very old')."
  (handler-case
      (let* ((year  (parse-integer s :start 0  :end 4))
             (month (parse-integer s :start 5  :end 7))
             (day   (parse-integer s :start 8  :end 10))
             (hour  (parse-integer s :start 11 :end 13))
             (min   (parse-integer s :start 14 :end 16))
             (sec   (parse-integer s :start 17 :end 19)))
        (encode-universal-time sec min hour day month year 0))
    (error () 0)))

(defun drop-release (cas catalogue keypair manifests-dir rel kept-blobs)
  "Drop one release and its dependent artefacts. KEPT-BLOBS is a
   list mutated in place (not strictly — the caller's binding is
   shared)."
  (declare (ignore keypair))
  (let* ((rid     (getf rel :release-id))
         (sw      (getf rel :software))
         (vers    (getf rel :version))
         (blob-sha (getf rel :blob-sha256)))
    ;; 1. Patches touching this release (and their files).
    (dolist (p (ota-server.catalogue:list-patches-by-from-or-to catalogue rid))
      (let ((path (ota-server.storage:cas-patch-path cas (getf p :sha256))))
        (when (probe-file path) (delete-file path))))
    (ota-server.catalogue:delete-patches-touching catalogue rid)
    ;; 1b. v1.5: patch_jobs audit rows touching this release.  Without
    ;; this, the snapshot table would have dangling references to a
    ;; release_id that no longer exists in `releases`.  Pinned
    ;; releases are protected because drop-release is never called
    ;; on them (uncollectable check in gc-software).
    (ota-server.catalogue:delete-patch-jobs-touching catalogue rid)
    ;; 2. Manifest .json and .sig.
    (let ((mj (merge-pathnames (format nil "~A/~A.json" sw vers) manifests-dir))
          (ms (merge-pathnames (format nil "~A/~A.sig"  sw vers) manifests-dir)))
      (when (probe-file mj) (delete-file mj))
      (when (probe-file ms) (delete-file ms)))
    ;; 3. Release row.
    (ota-server.catalogue:delete-release catalogue sw vers)
    ;; 4. Blob — only if no other release still references it.
    (let ((refcount (ota-server.catalogue:count-releases-using-blob catalogue blob-sha)))
      (cond ((zerop refcount)
             (let ((bp (ota-server.storage:cas-blob-path cas blob-sha)))
               (when (probe-file bp) (delete-file bp))))
            (t
             (push blob-sha kept-blobs))))
    (ota-server.catalogue:append-audit
     catalogue
     :identity "gc" :action "prune-release" :target rid
     :detail (format nil "users-window=ok"))
    rid))

;; ---------------------------------------------------------------------
;; Content verification: walk the CAS, re-hash, report mismatches.
;; ---------------------------------------------------------------------

(defun verify-storage (cas)
  "Walk every blob and patch on disk, recompute SHA-256, compare
   against the path's expected hash. Returns
     (:checked N :ok N :bad ((path got expected) ...))"
  (let ((checked 0) (ok 0) (bad '()))
    (labels ((walk (subdir)
               (let ((root (merge-pathnames subdir
                                            (ota-server.storage:cas-root cas))))
                 (when (probe-file root)
                   (uiop:collect-sub*directories
                    (uiop:ensure-directory-pathname root)
                    (constantly t) (constantly t)
                    (lambda (d)
                      (dolist (f (uiop:directory-files d))
                        (let* ((expected (file-namestring f))
                               (actual (ota-server.storage:sha256-hex-of-file f)))
                          (incf checked)
                          (cond ((string= expected actual)
                                 (incf ok))
                                (t
                                 (push (list (namestring f) actual expected) bad)))))))))))
      (walk "blobs/")
      (walk "patches/")
      (list :checked checked :ok ok :bad (nreverse bad)))))

;; ---------------------------------------------------------------------
;; Manifest re-sign on key rotation.
;; ---------------------------------------------------------------------

(defun resign-manifests (manifests-dir new-keypair)
  "Re-sign every <sw>/<v>.json under MANIFESTS-DIR with NEW-KEYPAIR,
   replacing the .sig file. Returns the list of re-signed paths."
  (let ((resigned '()))
    (uiop:collect-sub*directories
     (uiop:ensure-directory-pathname manifests-dir)
     (constantly t) (constantly t)
     (lambda (d)
       (dolist (f (uiop:directory-files d))
         (when (string= (pathname-type f) "json")
           (let* ((bytes (read-file-bytes f))
                  (sig (ota-server.manifest:sign-bytes
                        bytes
                        (ota-server.manifest:keypair-private new-keypair)
                        (ota-server.manifest:keypair-public  new-keypair)))
                  (sig-path (make-pathname :type "sig" :defaults f)))
             (with-open-file (out sig-path :direction :output
                                           :if-exists :supersede
                                           :element-type '(unsigned-byte 8))
               (write-sequence sig out))
             (push (namestring f) resigned))))))
    (nreverse resigned)))

(defun read-file-bytes (path)
  (with-open-file (in path :direction :input :element-type '(unsigned-byte 8))
    (let* ((n (file-length in))
           (buf (make-array n :element-type '(unsigned-byte 8))))
      (read-sequence buf in)
      buf)))
