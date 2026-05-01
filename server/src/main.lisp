;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.

(defpackage #:ota-server
  (:use #:cl)
  (:export #:main
           #:migrate
           #:run-gc
           #:*default-config*))

(in-package #:ota-server)

(defparameter *default-config*
  (list :host "127.0.0.1"
        :port 8080
        :data-dir "./build/dev/ota-data"
        :admin-token "dev-token"))

(defun env-or-default (env-name fallback)
  (or (uiop:getenv env-name) fallback))

(defun env-port (env-name fallback)
  (let ((s (uiop:getenv env-name)))
    (if s (parse-integer s) fallback)))

(defun load-config-from-env ()
  (list :host (env-or-default "OTA_HOST" "0.0.0.0")
        :port (env-port "OTA_PORT" 8080)
        :data-dir (env-or-default "OTA_ROOT" "./build/dev/ota-data")
        :admin-token (env-or-default "OTA_ADMIN_TOKEN" "dev-token")))

(defun main (&key config)
  "Boot the server. CONFIG is a plist; otherwise environment vars are
   consulted (OTA_HOST, OTA_PORT, OTA_ROOT, OTA_ADMIN_TOKEN)."
  (let* ((cfg (or config (load-config-from-env)))
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
                 :hostname (or (getf cfg :hostname) "localhost"))))
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
      ;; Block forever: SBCL's clackup with woo runs in the same thread
      ;; if :worker-num is unspecified; otherwise we wait on the
      ;; handler.  For now, sleep until interrupted.
      (handler-case
          (loop (sleep 86400))
        (#+sbcl sb-sys:interactive-interrupt #-sbcl t () nil))
      (ota-server.http:stop-server handler))))

(defun migrate (&key config)
  (let* ((cfg (or config (load-config-from-env)))
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
