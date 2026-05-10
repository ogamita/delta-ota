;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.

(defpackage #:ota-server.workers
  (:use #:cl)
  (:export #:build-patch-from-blobs
           #:build-patches-for-release
           #:*bsdiff-binary*
           ;; phase-5
           #:gc-software
           #:verify-storage
           #:resign-manifests
           ;; v1.2: async patch-build worker pool
           #:patch-pool
           #:make-patch-pool
           #:start-patch-pool
           #:stop-patch-pool
           #:notify-patch-pool
           #:enqueue-patches-for-release))

(in-package #:ota-server.workers)
