;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.

(defpackage #:ota-server.catalogue
  (:use #:cl)
  (:export #:open-catalogue
           #:close-catalogue
           #:run-migrations
           #:ensure-software
           #:list-software
           #:get-software
           #:insert-release
           #:list-releases
           #:get-release
           #:get-latest-release
           #:record-install-event
           #:insert-patch
           #:list-patches-to
           ;; phase-4 auth
           #:mint-install-token
           #:claim-install-token
           #:create-client
           #:get-client-by-token
           #:touch-client
           #:append-audit
           #:list-audit))

(in-package #:ota-server.catalogue)
