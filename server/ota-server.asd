;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.

(defsystem "ota-server"
  :description "Ogamita Delta OTA — distribution server."
  :author "Ogamita Ltd. <support@ogamita.com>"
  :license "AGPL-3.0-or-later"
  :version "1.7.0"
  :homepage "https://gitlab.com/ogamita/delta-ota"
  :source-control (:git "https://gitlab.com/ogamita/delta-ota.git")
  :bug-tracker "https://gitlab.com/ogamita/delta-ota/-/issues"
  :depends-on ("alexandria"
               "uiop"
               "bordeaux-threads"
               "ironclad"
               "com.inuoe.jzon"
               "clop"
               "sqlite"
               "clack"
               "woo"
               "cl-ppcre"
               ;; v1.7: outbound HTTP for the notification webhook.
               "dexador")
  :pathname "src/"
  :components ((:module "config"
                :components ((:file "package")
                             (:file "loader" :depends-on ("package"))))
               (:module "storage"
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
                             (:file "patcher"       :depends-on ("package"))
                             (:file "pool"          :depends-on ("package" "patcher"))
                             (:file "reachability"  :depends-on ("package" "patcher"))
                             (:file "operations"    :depends-on ("package" "reachability"))
                             (:file "stats"         :depends-on ("package"))
                             (:file "notifications" :depends-on ("package")))
                :depends-on ("storage" "catalogue" "manifest"))
               (:module "http"
                :components ((:file "package")
                             (:file "server" :depends-on ("package")))
                :depends-on ("storage" "manifest" "catalogue" "workers"))
               (:module "admin"
                :components ((:file "package")))
               (:file "main" :depends-on ("http" "config")))
  :in-order-to ((test-op (test-op "ota-server/tests"))))

(defsystem "ota-server/tests"
  :description "Ogamita Delta OTA — server test suite."
  :license "AGPL-3.0-or-later"
  :depends-on ("ota-server" "fiveam" "dexador")
  :pathname "tests/"
  :components ((:file "package")
               (:file "smoke"             :depends-on ("package"))
               (:file "config-tests"      :depends-on ("smoke"))
               (:file "cli-smoke"         :depends-on ("smoke"))
               (:file "concurrency-tests" :depends-on ("smoke"))
               (:file "patch-pool-tests"  :depends-on ("smoke"))
               (:file "range-tests"       :depends-on ("smoke"))
               (:file "admin-identity-tests" :depends-on ("smoke"))
               (:file "client-state-tests"   :depends-on ("smoke"))
               (:file "reachability-tests"   :depends-on ("smoke"))
               (:file "notifications-tests"  :depends-on ("smoke")))
  :perform (test-op (op c)
             (uiop:symbol-call :ota-server.tests :run-all)))
