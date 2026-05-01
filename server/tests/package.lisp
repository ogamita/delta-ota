;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.

(defpackage #:ota-server.tests
  (:use #:cl #:fiveam)
  (:export #:run-all))

(in-package #:ota-server.tests)

(def-suite ota-server-suite
  :description "Phase-0 placeholder suite for ota-server.")

(in-suite ota-server-suite)

(test smoke
  "Trivial smoke test so the suite can run before phase 1 implements anything."
  (is (= 2 (+ 1 1))))

(defun run-all ()
  (let ((result (run! 'ota-server-suite)))
    (unless result
      (uiop:quit 1))))
