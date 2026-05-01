;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.

(defpackage #:ota-server.http
  (:use #:cl)
  (:export #:make-app
           #:start-server
           #:stop-server))

(in-package #:ota-server.http)
