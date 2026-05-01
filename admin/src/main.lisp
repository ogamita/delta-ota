;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.

(defpackage #:ota-admin
  (:use #:cl)
  (:export #:main #:publish))

(in-package #:ota-admin)

(defun publish (&key dir software version os arch
                     (server "http://127.0.0.1:8080")
                     (token (uiop:getenv "OTA_ADMIN_TOKEN"))
                     (os-versions ""))
  "Tar DIR with the deterministic tar writer, then upload it as a new
   release of SOFTWARE/VERSION on SERVER.  Requires the server's
   admin TOKEN."
  (unless token
    (error "ota-admin publish: OTA_ADMIN_TOKEN env var or :token argument required"))
  (let ((tar-path (merge-pathnames (format nil "~A-~A-publish.tar"
                                           software version)
                                   (uiop:temporary-directory))))
    (ota-server.storage:tar-directory-to-file dir tar-path)
    (let ((bytes (with-open-file (in tar-path
                                     :direction :input
                                     :element-type '(unsigned-byte 8))
                   (let* ((n (file-length in))
                          (buf (make-array n :element-type '(unsigned-byte 8))))
                     (read-sequence buf in)
                     buf))))
      (multiple-value-bind (resp code)
          (dexador:post (format nil "~A/v1/admin/software/~A/releases"
                                server software)
                        :headers (list (cons "Authorization"
                                             (format nil "Bearer ~A" token))
                                       (cons "X-Ota-Version" version)
                                       (cons "X-Ota-Os" os)
                                       (cons "X-Ota-Arch" arch)
                                       (cons "X-Ota-Os-Versions" os-versions)
                                       (cons "Content-Type" "application/octet-stream"))
                        :content bytes)
        (delete-file tar-path)
        (format t "publish: code=~A body=~A~%" code resp)
        (force-output)
        (unless (= code 201)
          (uiop:quit 1))
        resp))))

(defun usage ()
  (format *error-output*
"ota-admin — Ogamita Delta OTA admin CLI

Usage:
  ota-admin publish <dir> --software=NAME --version=X --os=OS --arch=ARCH
                          [--os-versions=12,13] [--server=URL]

Environment:
  OTA_ADMIN_TOKEN   bearer token for admin auth (required)
  OTA_SERVER        default --server URL
")
  (uiop:quit 2))

(defun get-flag (argv name)
  (loop for a in argv
        when (alexandria:starts-with-subseq (concatenate 'string "--" name "=") a)
          return (subseq a (+ 3 (length name)))
        when (string= a (concatenate 'string "--" name))
          return (let ((rest (cdr (member a argv :test #'string=))))
                   (and rest (first rest)))))

(defun positional-args (argv)
  (loop for a in argv
        unless (alexandria:starts-with-subseq "--" a)
          collect a))

(defun main (&rest argv)
  (let ((argv (or argv (uiop:command-line-arguments))))
    (cond ((or (null argv) (string= (first argv) "help")) (usage))
          ((string= (first argv) "publish")
           (let ((rest (rest argv)))
             (publish :dir (or (first (positional-args rest))
                               (progn (format *error-output* "publish: missing <dir>~%") (uiop:quit 2)))
                      :software    (or (get-flag rest "software")
                                       (progn (format *error-output* "missing --software~%") (uiop:quit 2)))
                      :version     (or (get-flag rest "version")
                                       (progn (format *error-output* "missing --version~%") (uiop:quit 2)))
                      :os          (or (get-flag rest "os")
                                       (progn (format *error-output* "missing --os~%") (uiop:quit 2)))
                      :arch        (or (get-flag rest "arch")
                                       (progn (format *error-output* "missing --arch~%") (uiop:quit 2)))
                      :os-versions (or (get-flag rest "os-versions") "")
                      :server      (or (get-flag rest "server")
                                       (uiop:getenv "OTA_SERVER")
                                       "http://127.0.0.1:8080"))))
          (t (usage)))))
