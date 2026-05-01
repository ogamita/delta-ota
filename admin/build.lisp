;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.

(require :asdf)

(let* ((candidates (remove nil
                            (list (uiop:getenv "QUICKLISP_HOME")
                                  "/opt"
                                  (namestring (user-homedir-pathname)))))
       (setup (loop for base in candidates
                    for path = (concatenate 'string
                                            (string-right-trim "/" base)
                                            "/quicklisp/setup.lisp")
                    when (probe-file path) return path)))
  (when setup
    (format t "build: loading Quicklisp from ~A~%" setup)
    (force-output)
    (load setup)))

(asdf:load-asd (truename "admin/ota-admin.asd"))

(if (find-package :ql)
    (uiop:symbol-call :ql :quickload "ota-admin")
    (asdf:load-system "ota-admin"))

(ensure-directories-exist "admin/build/")

#+sbcl
(sb-ext:save-lisp-and-die "admin/build/ota-admin.core"
                          :compression t
                          :purify t)
