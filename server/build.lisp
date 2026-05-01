;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.
;;;
;;; build.lisp — produce server/build/ota-server.core
;;;
;;; Run from the repo root with:
;;;   sbcl --non-interactive --no-userinit --no-sysinit --load server/build.lisp

(require :asdf)

;; Use Quicklisp if it's set up on the developer machine.
(let ((qlinit (merge-pathnames "quicklisp/setup.lisp"
                               (or (uiop:getenv "QUICKLISP_HOME")
                                   (user-homedir-pathname)))))
  (when (probe-file qlinit)
    (load qlinit)))

;; Phase 0 builds an empty core just to prove the pipeline.
(asdf:load-asd (truename "server/ota-server.asd"))
(asdf:load-system "ota-server")

(ensure-directories-exist (truename "./") :verbose nil)
(ensure-directories-exist "server/build/")

#+sbcl
(progn
  (format t "build: dumping server/build/ota-server.core~%")
  (sb-ext:save-lisp-and-die "server/build/ota-server.core"
                            :compression t
                            :purify t))
