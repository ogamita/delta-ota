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
               "com.inuoe.jzon"
               "sqlite"
               "clack"
               "woo"
               "cl-ppcre")
  :pathname "src/"
  :components ((:module "storage"
                :components ((:file "package")
                             (:file "cas" :depends-on ("package"))
                             (:file "tar" :depends-on ("package"))))
               (:module "manifest"
                :components ((:file "package")
                             (:file "manifest" :depends-on ("package"))))
               (:module "catalogue"
                :components ((:file "package")
                             (:file "db" :depends-on ("package"))))
               (:module "workers"
                :components ((:file "package")
                             (:file "patcher"    :depends-on ("package"))
                             (:file "operations" :depends-on ("package")))
                :depends-on ("storage" "catalogue" "manifest"))
               (:module "http"
                :components ((:file "package")
                             (:file "server" :depends-on ("package")))
                :depends-on ("storage" "manifest" "catalogue" "workers"))
               (:module "admin"
                :components ((:file "package")))
               (:file "main" :depends-on ("http")))
  :in-order-to ((test-op (test-op "ota-server/tests"))))

(defsystem "ota-server/tests"
  :description "Ogamita Delta OTA — server test suite."
  :license "AGPL-3.0-or-later"
  :depends-on ("ota-server" "fiveam")
  :pathname "tests/"
  :components ((:file "package")
               (:file "smoke" :depends-on ("package")))
  :perform (test-op (op c)
             (uiop:symbol-call :ota-server.tests :run-all)))
