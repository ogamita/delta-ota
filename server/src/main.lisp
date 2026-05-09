;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.

(defpackage #:ota-server
  (:use #:cl)
  (:export #:main
           #:migrate
           #:run-gc))

(in-package #:ota-server)

(defun %resolve (config)
  (ota-server.config:resolve-config config))

(defun main (&key config)
  "Boot the server. CONFIG may be:
     - NIL                — defaults overlaid by env-vars (OTA_HOST,
                            OTA_PORT, OTA_ROOT, OTA_ADMIN_TOKEN,
                            OTA_TLS_CERT, OTA_TLS_KEY).
     - a pathname/string  — path to a TOML config; env-vars override
                            file values.
     - a plist            — already-resolved configuration (test
                            harness path)."
  (let* ((cfg (%resolve config))
         (root (uiop:ensure-directory-pathname (getf cfg :data-dir)))
         (cas (ota-server.storage:make-cas root))
         (db (ota-server.catalogue:open-catalogue
              (merge-pathnames "db/ota.db" root)))
         (kp (ota-server.manifest:load-or-generate-keypair
              (merge-pathnames "etc/keys/" root)))
         (state (ota-server.http::make-app-state
                 :cas cas
                 :catalogue db
                 :keypair kp
                 :manifests-dir (merge-pathnames "manifests/" root)
                 :admin-token (getf cfg :admin-token)
                 :hostname (or (getf cfg :hostname) "localhost")
                 :tls-cert (getf cfg :tls-cert)
                 :tls-key  (getf cfg :tls-key))))
    (ota-server.catalogue:run-migrations db)
    (ensure-directories-exist
     (ota-server.http::app-state-manifests-dir state))
    (format t "ota-server: listening on ~A:~A~%  data_dir=~A~%  manifest pubkey=~A~%"
            (getf cfg :host) (getf cfg :port) root
            (ota-server.manifest:keypair-public-hex kp))
    (force-output)
    (let ((handler
            (ota-server.http:start-server state
                                          :host (getf cfg :host)
                                          :port (getf cfg :port))))
      (format t "ota-server: ready.~%")
      (force-output)
      (handler-case
          (loop (sleep 86400))
        (#+sbcl sb-sys:interactive-interrupt #-sbcl t () nil))
      (ota-server.http:stop-server handler))))

(defun migrate (&key config)
  "Apply catalogue migrations and exit. CONFIG is interpreted as in MAIN."
  (let* ((cfg (%resolve config))
         (root (uiop:ensure-directory-pathname (getf cfg :data-dir)))
         (db (ota-server.catalogue:open-catalogue
              (merge-pathnames "db/ota.db" root))))
    (ota-server.catalogue:run-migrations db)
    (ota-server.catalogue:close-catalogue db)
    (format t "ota-server: migrations applied at ~A~%" (merge-pathnames "db/ota.db" root))
    (force-output)))

(defun run-gc (&key config)
  (declare (ignore config))
  (format t "ota-server gc: phase-1 stub.~%")
  (force-output))
