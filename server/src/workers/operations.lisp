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
                         (window-days 180) dry-run)
  "Garbage-collect expendable releases for SOFTWARE.

   A release is pruned when ALL of these hold:
     - it is not marked uncollectable;
     - it is not the latest published release;
     - count-users-at-release(...) <= MIN-USER-COUNT in the recency
       WINDOW-DAYS;
     - it has been published longer than MIN-AGE-DAYS.

   Pruning drops the release row, every patch touching it (whether
   from or to), the manifest .json/.sig pair, and the blob — but
   only if no surviving release still references the blob's sha.

   Returns a plist:
     (:pruned (release-id ...) :kept-blobs (sha ...) :dry-run BOOL)"
  (let* ((releases (ota-server.catalogue:list-releases catalogue software))
         (latest   (first releases))   ; list-releases is published_at DESC
         (now-univ (get-universal-time))
         (min-age-secs (* min-age-days 86400))
         (pruned '())
         (kept-blobs '()))
    (dolist (rel releases)
      (let* ((rid (getf rel :release-id))
             (vers (getf rel :version))
             (uncollectable (getf rel :uncollectable))
             (published (getf rel :published-at))
             (age (- now-univ (parse-iso8601 published)))
             (users (ota-server.catalogue:count-users-at-release
                     catalogue software rid :window-days window-days)))
        (cond
          (uncollectable          nil)        ; keep
          ((eq rel latest)        nil)        ; keep latest
          ((< age min-age-secs)   nil)        ; too young
          ((> users min-user-count) nil)      ; still in use
          (t
           (push rid pruned)
           (unless dry-run
             (drop-release cas catalogue keypair manifests-dir
                           rel kept-blobs))))))
    (list :pruned (nreverse pruned)
          :kept-blobs kept-blobs
          :dry-run (if dry-run t nil))))

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
