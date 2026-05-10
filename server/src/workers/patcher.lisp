;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.
;;;
;;; Patch builder.
;;;
;;; v1.0–v1.1: each publish ran the bsdiff fan-in synchronously inside
;;; the publish handler thread (BUILD-PATCHES-FOR-RELEASE).
;;;
;;; v1.2: the fan-in is asynchronous — ENQUEUE-PATCHES-FOR-RELEASE
;;; inserts one row per prior release into PATCH_JOBS and the worker
;;; pool (workers/pool.lisp) consumes them.  The publish handler tails
;;; the jobs to emit per-patch progress events on the NDJSON response.
;;;
;;; BUILD-PATCH-FROM-BLOBS is the bsdiff invocation itself, used by
;;; both the legacy synchronous BUILD-PATCHES-FOR-RELEASE (still
;;; available for tests / out-of-tree callers) and by the pool's
;;; per-job worker.  The Postgres-backed queue is the same surface,
;;; just a different driver — see ADR-0007.

(in-package #:ota-server.workers)

(defparameter *bsdiff-binary*
  ;; Resolved at boot; set by the http app via a config value if
  ;; needed.  The default points at the location the dev image / the
  ;; repo Makefile populate.
  (or (uiop:getenv "OTA_BSDIFF")
      "/opt/ota/bin/bsdiff"))

(defun build-patch-from-blobs (cas catalogue
                               &key from-release-id to-release-id
                                    from-blob-sha to-blob-sha)
  "Run vendored bsdiff(1) on the two on-disk blobs, store the resulting
   patch in the patches CAS, and record it in the catalogue.  Returns
   (values patch-sha patch-size).  Idempotent: if a patch with the same
   (from,to,patcher) already exists in the catalogue, it is reused."
  (let* ((from-blob (ota-server.storage:cas-blob-path cas from-blob-sha))
         (to-blob   (ota-server.storage:cas-blob-path cas to-blob-sha))
         (tmp (merge-pathnames
               (format nil "tmp/patch-~A.bsdiff" (random (expt 2 32)))
               (ota-server.storage:cas-root cas))))
    (ensure-directories-exist tmp)
    (unless (probe-file from-blob)
      (error "build-patch: missing source blob ~A" from-blob))
    (unless (probe-file to-blob)
      (error "build-patch: missing target blob ~A" to-blob))
    (uiop:run-program (list (namestring *bsdiff-binary*)
                            (namestring from-blob)
                            (namestring to-blob)
                            (namestring tmp))
                      :output :string :error-output :string)
    (multiple-value-bind (sha size)
        (ota-server.storage:put-patch-from-file cas tmp)
      (ota-server.catalogue:insert-patch
       catalogue
       :sha256 sha
       :from-release-id from-release-id
       :to-release-id   to-release-id
       :patcher "bsdiff"
       :size size)
      (format t "build-patch: ~A -> ~A: ~A bytes (sha ~A)~%"
              from-release-id to-release-id size sha)
      (force-output)
      (values sha size))))

(defun build-patches-for-release (cas catalogue
                                  &key software os arch new-version
                                       new-release-id new-blob-sha
                                       on-progress)
  "Build a patch from every previously published release of the same
   (software, os, arch) to the new release.  Returns a list of plists
   describing the patches built.

Logs per-patch progress (\"publish: bsdiff N/M from VERSION ...\")
to *standard-output* so operators tailing the server log can see
how far through the fan-in pass the publish is.

ON-PROGRESS, when supplied, is a function called once with each of:

  (:event :patches-started :total M)
  (:event :patch-built     :i I :total M
                           :from VERSION :sha SHA :size SIZE)
  (:event :patches-done    :built M)

The publish handler uses ON-PROGRESS to emit NDJSON events on a
streaming HTTP response (since v1.1.1).  Other callers that don't
care can omit the callback and get the same return shape as
before."
  (let* ((all (ota-server.catalogue:list-releases catalogue software))
         (priors (remove-if-not
                  (lambda (rel)
                    (and (string= (getf rel :os) os)
                         (string= (getf rel :arch) arch)
                         (not (string= (getf rel :version) new-version))))
                  all))
         (total (length priors))
         (built '())
         (i 0))
    (when (plusp total)
      (format t "publish: building ~D patch~:[~;es~] for ~A/~A-~A/~A~%"
              total (/= 1 total)
              software os arch new-version)
      (force-output)
      (when on-progress
        (funcall on-progress (list :event :patches-started :total total))))
    (dolist (rel priors)
      (incf i)
      (format t "publish: bsdiff ~D/~D from ~A (~A bytes) ...~%"
              i total (getf rel :version) (getf rel :blob-size))
      (force-output)
      (handler-case
          (multiple-value-bind (sha size)
              (build-patch-from-blobs
               cas catalogue
               :from-release-id (getf rel :release-id)
               :to-release-id   new-release-id
               :from-blob-sha   (getf rel :blob-sha256)
               :to-blob-sha     new-blob-sha)
            (push (list :from (getf rel :version)
                        :sha256 sha :size size :patcher "bsdiff")
                  built)
            (when on-progress
              (funcall on-progress
                       (list :event :patch-built
                             :i i :total total
                             :from (getf rel :version)
                             :sha sha :size size))))
        (error (e)
          (format *error-output*
                  "build-patches: skipping ~A->~A: ~A~%"
                  (getf rel :release-id) new-release-id e))))
    (when (and on-progress (plusp total))
      (funcall on-progress (list :event :patches-done :built (length built))))
    (nreverse built)))

(defun enqueue-patches-for-release (catalogue
                                    &key software os arch new-version
                                         new-release-id new-blob-sha
                                         (patcher "bsdiff"))
  "Enqueue one PATCH_JOBS row per prior release of (software, os, arch)
to NEW-RELEASE-ID.  Returns the list of plists describing each enqueued
job's catalogue row (ordered oldest prior first).  Does NOT run bsdiff
itself — the worker pool consumes the queue.  Idempotent: a re-publish
silently no-ops on the UNIQUE (from, to, patcher) constraint, so the
returned list of :existing rows can be tailed exactly the same way as
:enqueued ones."
  (let* ((all (ota-server.catalogue:list-releases catalogue software))
         (priors (remove-if-not
                  (lambda (rel)
                    (and (string= (getf rel :os) os)
                         (string= (getf rel :arch) arch)
                         (not (string= (getf rel :version) new-version))))
                  all))
         (enqueued '()))
    (dolist (rel priors)
      (multiple-value-bind (status job-id)
          (ota-server.catalogue:enqueue-patch-job
           catalogue
           :from-release-id (getf rel :release-id)
           :to-release-id   new-release-id
           :software        software
           :os              os
           :arch            arch
           :from-version    (getf rel :version)
           :from-blob-sha256 (getf rel :blob-sha256)
           :to-blob-sha256   new-blob-sha
           :patcher         patcher)
        (push (list :id job-id
                    :status status
                    :from-release-id (getf rel :release-id)
                    :from-version (getf rel :version)
                    :from-blob-size (getf rel :blob-size))
              enqueued)))
    (nreverse enqueued)))
