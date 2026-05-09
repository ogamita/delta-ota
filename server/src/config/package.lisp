;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.

(defpackage #:ota-server.config
  (:use #:cl)
  (:export #:resolve-config
           #:load-config-from-file
           #:apply-env-overrides
           #:load-config-from-env
           #:*defaults*
           #:config-error))
