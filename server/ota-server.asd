;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.

(defsystem "ota-server"
  :description "Ogamita Delta OTA — distribution server."
  :author "Ogamita Ltd. <support@ogamita.com>"
  :license "AGPL-3.0-or-later"
  :version "0.1.0"
  :homepage "https://gitlab.com/ogamita/delta-ota"
  :source-control (:git "https://gitlab.com/ogamita/delta-ota.git")
  :bug-tracker "https://gitlab.com/ogamita/delta-ota/-/issues"
  :depends-on ("alexandria"
               "uiop"
               "ironclad"
               "jzon"
               "cl-dbi"
               "cl-sqlite"
               "cl-postgres"
               "clack"
               "woo"
               "cl+ssl")
  :pathname "src/"
  :components ((:module "catalogue"
                :components ((:file "package")))
               (:module "storage"
                :components ((:file "package")))
               (:module "manifest"
                :components ((:file "package")))
               (:module "http"
                :components ((:file "package")))
               (:module "workers"
                :components ((:file "package")))
               (:module "admin"
                :components ((:file "package")))
               (:file "main"))
  :in-order-to ((test-op (test-op "ota-server/tests"))))

(defsystem "ota-server/tests"
  :description "Ogamita Delta OTA — server test suite."
  :license "AGPL-3.0-or-later"
  :depends-on ("ota-server" "fiveam")
  :pathname "tests/"
  :components ((:file "package"))
  :perform (test-op (op c)
             (uiop:symbol-call :ota-server.tests :run-all)))
