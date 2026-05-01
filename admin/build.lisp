;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.

(require :asdf)

(let ((qlinit (merge-pathnames "quicklisp/setup.lisp"
                               (or (uiop:getenv "QUICKLISP_HOME")
                                   (user-homedir-pathname)))))
  (when (probe-file qlinit)
    (load qlinit)))

(asdf:load-asd (truename "admin/ota-admin.asd"))
(asdf:load-system "ota-admin")

(ensure-directories-exist "admin/build/")

#+sbcl
(sb-ext:save-lisp-and-die "admin/build/ota-admin.core"
                          :compression t
                          :purify t)
