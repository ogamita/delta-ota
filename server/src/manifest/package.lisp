;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.

(defpackage #:ota-server.manifest
  (:use #:cl)
  (:export #:build-manifest-plist
           #:manifest-to-json-bytes
           #:sign-bytes
           #:verify-bytes
           #:load-or-generate-keypair
           #:keypair
           #:keypair-public
           #:keypair-private
           #:keypair-public-hex
           #:keypair-private-hex
           #:hex-to-bytes
           #:bytes-to-hex))

(in-package #:ota-server.manifest)
