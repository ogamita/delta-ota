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
           #:insert-release-if-new
           #:list-releases
           #:get-release
           #:get-release-by-tuple
           #:get-latest-release
           #:highest-semver-release
           #:parse-semver
           #:semver<
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
           #:list-audit
           ;; phase-5 ops
           #:count-users-at-release
           #:delete-release
           #:delete-patches-touching
           #:list-patches-by-from-or-to
           #:count-releases-using-blob
           ;; phase-6
           #:mark-uncollectable
           ;; v1.2 — async patch-build worker pool
           #:enqueue-patch-job
           #:claim-next-patch-job
           #:complete-patch-job
           #:fail-patch-job
           #:list-patch-jobs-for-release
           #:count-patch-jobs
           #:reset-stale-running-jobs))

(in-package #:ota-server.catalogue)
