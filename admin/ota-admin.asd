;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.

(defsystem "ota-admin"
  :description "Ogamita Delta OTA — administrator CLI."
  :author "Ogamita Ltd. <support@ogamita.com>"
  :license "AGPL-3.0-or-later"
  :version "1.4.1"
  :homepage "https://gitlab.com/ogamita/delta-ota"
  :depends-on ("alexandria" "uiop" "dexador" "com.inuoe.jzon" "ota-server")
  :pathname "src/"
  :components ((:file "main"))
  :in-order-to ((test-op (test-op "ota-admin/tests"))))

(defsystem "ota-admin/tests"
  :license "AGPL-3.0-or-later"
  :depends-on ("ota-admin" "fiveam")
  :pathname "tests/"
  :components ((:file "package")
               (:file "cli-smoke" :depends-on ("package"))
               (:file "error-friendlification-tests" :depends-on ("package"))
               (:file "ndjson-consumer-tests" :depends-on ("package")))
  :perform (test-op (op c)
             (uiop:symbol-call :ota-admin.tests :run-all)))
