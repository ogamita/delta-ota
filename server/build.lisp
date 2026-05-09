;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.
;;;
;;; build.lisp — produce server/build/ota-server (standalone executable)
;;;
;;; Run from the repo root with:
;;;   sbcl --non-interactive --no-userinit --no-sysinit --load server/build.lisp

(require :asdf)

;; Load Quicklisp from the first directory that has setup.lisp.
;; The CI dev image installs it at /opt/quicklisp; developer
;; workstations typically have it under $HOME or $QUICKLISP_HOME.
(let* ((candidates (remove nil
                            (list (uiop:getenv "QUICKLISP_HOME")
                                  "/opt"
                                  (namestring (user-homedir-pathname)))))
       (setup (loop for base in candidates
                    for path = (concatenate 'string
                                            (string-right-trim "/" base)
                                            "/quicklisp/setup.lisp")
                    when (probe-file path) return path)))
  (cond (setup
         (format t "build: loading Quicklisp from ~A~%" setup)
         (force-output)
         (load setup))
        (t
         (format t "build: WARNING — Quicklisp setup.lisp not found in ~S~%"
                 candidates)
         (force-output))))

(asdf:load-asd (truename "server/ota-server.asd"))

;; Use Quicklisp's quickload when available so missing deps are fetched;
;; fall back to plain ASDF when Quicklisp is not present (e.g. an air-
;; gapped builder that has the deps pre-installed via another mechanism).
(if (find-package :ql)
    (uiop:symbol-call :ql :quickload "ota-server")
    (asdf:load-system "ota-server"))

(ensure-directories-exist (truename "./") :verbose nil)
(ensure-directories-exist "server/build/")

;; Build a standalone executable, not a bare core image.  The toplevel
;; calls (ota-server:main) -- which itself reads UIOP:COMMAND-LINE-ARGUMENTS
;; -- and exits with its return value (an integer exit code).  Errors
;; print to stderr and exit non-zero; SIGINT exits 130.  The SBCL
;; banner is suppressed because :TOPLEVEL takes over from the default
;; REPL toplevel.
;;
;; :SAVE-RUNTIME-OPTIONS T bakes SBCL's own runtime options into the
;; image so the user does not have to pass --end-runtime-options to
;; separate SBCL flags from application arguments.
#+sbcl
(progn
  (format t "build: dumping server/build/ota-server~%")
  (sb-ext:save-lisp-and-die "server/build/ota-server"
                            :compression t
                            :purify t
                            :executable t
                            :save-runtime-options t
                            :toplevel
                            (lambda ()
                              (handler-case
                                  (uiop:quit (or (apply #'ota-server:main nil) 0))
                                (sb-sys:interactive-interrupt ()
                                  (uiop:quit 130))
                                (error (c)
                                  (format *error-output* "ota-server: ~A~%" c)
                                  (uiop:quit 1))))))
