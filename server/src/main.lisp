;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.

(defpackage #:ota-server
  (:use #:cl)
  (:export #:main
           #:migrate
           #:run-gc))

(in-package #:ota-server)

(defun main (&key config)
  (declare (ignore config))
  ;; Phase-0 stub: real implementation lands in phase 1.
  (format t "ota-server: stub. config not yet honoured.~%")
  (force-output))

(defun migrate (&key config)
  (declare (ignore config))
  (format t "ota-server migrate: stub.~%")
  (force-output))

(defun run-gc (&key config)
  (declare (ignore config))
  (format t "ota-server gc: stub.~%")
  (force-output))
