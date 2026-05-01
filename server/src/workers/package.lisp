;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.

(defpackage #:ota-server.workers
  (:use #:cl)
  (:export #:build-patch-from-blobs
           #:build-patches-for-release
           #:*bsdiff-binary*))

(in-package #:ota-server.workers)
