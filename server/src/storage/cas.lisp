;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.
;;;
;;; Content-addressed blob/patch storage backed by the local
;;; filesystem.  Phase-1 default; the S3 backend lands in phase 5
;;; behind the same interface.

(in-package #:ota-server.storage)

(defstruct (cas (:constructor %make-cas))
  (root nil :type pathname :read-only t))

(defun make-cas (root-pathname)
  "Create a CAS rooted at ROOT-PATHNAME (created if missing)."
  (let ((root (uiop:ensure-directory-pathname root-pathname)))
    (ensure-directories-exist root)
    (ensure-directories-exist (merge-pathnames "blobs/" root))
    (ensure-directories-exist (merge-pathnames "patches/" root))
    (ensure-directories-exist (merge-pathnames "manifests/" root))
    (ensure-directories-exist (merge-pathnames "tmp/" root))
    (%make-cas :root root)))

(defun cas-blob-path (cas sha256-hex)
  "Return the on-disk pathname for the blob with the given hex SHA-256."
  (declare (type cas cas) (type string sha256-hex))
  (assert (= (length sha256-hex) 64))
  (let ((prefix (subseq sha256-hex 0 2)))
    (merge-pathnames (format nil "blobs/~A/~A" prefix sha256-hex)
                     (cas-root cas))))

(defun cas-patch-path (cas sha256-hex)
  (declare (type cas cas) (type string sha256-hex))
  (assert (= (length sha256-hex) 64))
  (let ((prefix (subseq sha256-hex 0 2)))
    (merge-pathnames (format nil "patches/~A/~A" prefix sha256-hex)
                     (cas-root cas))))

(defun has-patch (cas sha256-hex)
  (and (probe-file (cas-patch-path cas sha256-hex)) t))

(defun put-patch-from-file (cas src-pathname)
  "Move SRC-PATHNAME into the patches CAS, returning (values sha size)."
  (let* ((sha (sha256-hex-of-file src-pathname))
         (dst (cas-patch-path cas sha)))
    (ensure-directories-exist dst)
    (cond ((probe-file dst) (delete-file src-pathname))
          (t (sb-posix:rename (namestring src-pathname) (namestring dst))))
    (values sha (with-open-file (in dst :direction :input
                                        :element-type '(unsigned-byte 8))
                  (file-length in)))))

(defun has-blob (cas sha256-hex)
  (and (probe-file (cas-blob-path cas sha256-hex)) t))

(defun blob-size (cas sha256-hex)
  (with-open-file (s (cas-blob-path cas sha256-hex)
                     :direction :input
                     :element-type '(unsigned-byte 8))
    (file-length s)))

(defun sha256-hex-of-bytes (bytes)
  (declare (type (simple-array (unsigned-byte 8) (*)) bytes))
  (ironclad:byte-array-to-hex-string
   (ironclad:digest-sequence :sha256 bytes)))

(defun sha256-hex-of-file (pathname)
  "Stream the file through SHA-256 and return the hex digest."
  (let ((digester (ironclad:make-digest :sha256))
        (buf (make-array 65536 :element-type '(unsigned-byte 8))))
    (with-open-file (in pathname
                        :direction :input
                        :element-type '(unsigned-byte 8))
      (loop for n = (read-sequence buf in)
            while (plusp n)
            do (ironclad:update-digest digester buf :start 0 :end n)))
    (ironclad:byte-array-to-hex-string
     (ironclad:produce-digest digester))))

(defun put-blob-from-file (cas src-pathname)
  "Move SRC-PATHNAME into the CAS, returning (values sha256-hex size).
   The blob is hashed on its way in, then renamed to its content-
   addressed location.  If the blob already exists, the source is
   simply deleted."
  (let* ((sha (sha256-hex-of-file src-pathname))
         (dst (cas-blob-path cas sha)))
    (ensure-directories-exist dst)
    ;; CL's rename-file mangles pathnames without an extension; use
    ;; the POSIX syscall directly. We are SBCL-pinned per ADR-0001.
    (cond ((probe-file dst)
           (delete-file src-pathname))
          (t
           (sb-posix:rename (namestring src-pathname) (namestring dst))))
    (values sha (blob-size cas sha))))
