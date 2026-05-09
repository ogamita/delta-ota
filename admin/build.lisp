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

(pushnew (truename #P"server/") ql:*local-project-directories*)
(asdf:load-asd (truename "admin/ota-admin.asd"))

(if (find-package :ql)
    (uiop:symbol-call :ql :quickload "ota-admin")
    (asdf:load-system "ota-admin"))

(ensure-directories-exist "admin/build/")

;; Build a standalone executable, not a bare core image. The toplevel
;; calls (ota-admin:main) -- which itself reads UIOP:COMMAND-LINE-ARGUMENTS
;; -- then exits cleanly. Errors print to stderr and exit non-zero.
;; The SBCL banner is suppressed because :TOPLEVEL takes over from the
;; default REPL toplevel.
#+sbcl
(sb-ext:save-lisp-and-die "admin/build/ota-admin"
                          :compression t
                          :purify t
                          :executable t
                          :save-runtime-options t
                          :toplevel
                          (lambda ()
                            (handler-case
                                (progn
                                  (apply #'ota-admin:main nil)
                                  (uiop:quit 0))
                              (sb-sys:interactive-interrupt ()
                                (uiop:quit 130))
                              (error (c)
                                (format *error-output* "ota-admin: ~A~%" c)
                                (uiop:quit 1)))))
