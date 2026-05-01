;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.
;;;
;;; build.lisp — produce server/build/ota-server.core
;;;
;;; Run from the repo root with:
;;;   sbcl --non-interactive --no-userinit --no-sysinit --load server/build.lisp

(require :asdf)

;; Load Quicklisp if available (dev workstation or our CI dev image at
;; /opt/quicklisp). The setup.lisp registers Quicklisp with ASDF, which
;; means missing dependencies are downloaded on first ql:quickload.
(let ((qlinit (merge-pathnames "quicklisp/setup.lisp"
                               (or (uiop:getenv "QUICKLISP_HOME")
                                   (user-homedir-pathname)))))
  (when (probe-file qlinit)
    (load qlinit)))

(asdf:load-asd (truename "server/ota-server.asd"))

;; Use Quicklisp's quickload when available so missing deps are fetched;
;; fall back to plain ASDF when Quicklisp is not present (e.g. an air-
;; gapped builder that has the deps pre-installed via another mechanism).
(if (find-package :ql)
    (uiop:symbol-call :ql :quickload "ota-server")
    (asdf:load-system "ota-server"))

(ensure-directories-exist (truename "./") :verbose nil)
(ensure-directories-exist "server/build/")

#+sbcl
(progn
  (format t "build: dumping server/build/ota-server.core~%")
  (sb-ext:save-lisp-and-die "server/build/ota-server.core"
                            :compression t
                            :purify t))
