;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.

(defpackage #:ota-server.storage
  (:use #:cl)
  (:export #:make-cas
           #:cas-root
           #:cas-blob-path
           #:cas-patch-path
           #:put-blob-from-file
           #:put-patch-from-file
           #:has-blob
           #:has-patch
           #:blob-size
           #:sha256-hex-of-file
           #:sha256-hex-of-bytes
           ;; tar
           #:tar-entry
           #:make-tar-entry
           #:walk-files
           #:write-deterministic-tar
           #:tar-directory-to-file))

(in-package #:ota-server.storage)
