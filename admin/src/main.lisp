;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.

(defpackage #:ota-admin
  (:use #:cl)
  (:export #:main))

(in-package #:ota-admin)

(defun main (&rest argv)
  (declare (ignore argv))
  (format t "ota-admin: stub. Phase-0 skeleton.~%")
  (force-output))
