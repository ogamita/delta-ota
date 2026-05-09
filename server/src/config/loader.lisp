;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.
;;;
;;; Server configuration loader.
;;;
;;; Resolution order, lowest precedence first:
;;;   1. Built-in defaults (*DEFAULTS*).
;;;   2. TOML file (when MAIN's :config is a path).
;;;   3. Environment variables (always applied last; override both).
;;;
;;; A pre-built plist passed to MAIN as :config bypasses all three —
;;; it is treated as already fully resolved (used by tests and the
;;; e2e harness).

(in-package #:ota-server.config)

(define-condition config-error (simple-error) ())

(defparameter *defaults*
  (list :host                       "127.0.0.1"
        :port                       8443
        :hostname                   "localhost"
        :data-dir                   "./build/dev/ota-data"
        :log-level                  "info"
        :admin-token                "dev-token"
        :tls-cert                   nil
        :tls-key                    nil
        :tls-client-ca              nil
        :tls-require-mtls           nil
        :storage-backend            "fs"
        :catalogue-db               nil
        :patcher-default            "bsdiff"
        :patcher-worker-count       2
        :patcher-bsdiff-path        nil
        :patcher-bspatch-path       nil
        :gc-default-threshold       0
        :gc-schedule                nil
        :install-token-ttl-seconds  900))

;; ---------------------------------------------------------------------------
;; TOML parsing
;; ---------------------------------------------------------------------------

(defun %toml-section (toml name)
  "Return the alist of section NAME from CLOP's parse output, or NIL."
  (cdr (assoc name toml :test #'string=)))

(defun %toml-get (section key &optional default)
  "Return SECTION's value for KEY (string), or DEFAULT when absent."
  (let ((cell (assoc key section :test #'string=)))
    (if cell (cdr cell) default)))

(defun %split-listen (listen default-host default-port)
  "Split a TOML \"host:port\" listen string. Return (values host port).
Either component may fall back to the supplied default."
  (cond
    ((null listen) (values default-host default-port))
    ((not (stringp listen))
     (error 'config-error
            :format-control "[server].listen must be a string, got ~S"
            :format-arguments (list listen)))
    (t
     (let ((colon (position #\: listen :from-end t)))
       (cond
         ((null colon) (values listen default-port))
         ((zerop colon) (values default-host
                                (parse-integer (subseq listen 1))))
         (t (values (subseq listen 0 colon)
                    (parse-integer (subseq listen (1+ colon))))))))))

(defun %parse-toml-string (text)
  (handler-case (clop:parse text)
    (error (c)
      (error 'config-error
             :format-control "TOML parse error: ~A"
             :format-arguments (list c)))))

(defun load-config-from-file (path)
  "Read TOML at PATH and return a plist matching the documented schema.
Keys absent from the file fall back to *DEFAULTS*. Env-vars are NOT
applied here — call APPLY-ENV-OVERRIDES on the result."
  (let* ((path (pathname path)))
    (unless (probe-file path)
      (error 'config-error
             :format-control "config file not found: ~A"
             :format-arguments (list path)))
    (let* ((text     (alexandria:read-file-into-string path))
           (toml     (%parse-toml-string text))
           (server   (%toml-section toml "server"))
           (tls      (%toml-section toml "tls"))
           (storage  (%toml-section toml "storage"))
           (cat      (%toml-section toml "catalogue"))
           (patcher  (%toml-section toml "patcher"))
           (gc       (%toml-section toml "gc"))
           (token    (%toml-section toml "install_token"))
           (defaults *defaults*))
      (multiple-value-bind (host port)
          (%split-listen (%toml-get server "listen")
                         (getf defaults :host)
                         (getf defaults :port))
        (list
         :host                      host
         :port                      port
         :hostname                  (%toml-get server  "hostname"
                                               (getf defaults :hostname))
         :data-dir                  (%toml-get server  "data_dir"
                                               (getf defaults :data-dir))
         :log-level                 (%toml-get server  "log_level"
                                               (getf defaults :log-level))
         :admin-token               (getf defaults :admin-token)
         :tls-cert                  (%toml-get tls     "cert")
         :tls-key                   (%toml-get tls     "key")
         :tls-client-ca             (%toml-get tls     "client_ca")
         :tls-require-mtls          (%toml-get tls     "require_mtls"
                                               (getf defaults :tls-require-mtls))
         :storage-backend           (%toml-get storage "backend"
                                               (getf defaults :storage-backend))
         :catalogue-db              (%toml-get cat     "db")
         :patcher-default           (%toml-get patcher "default"
                                               (getf defaults :patcher-default))
         :patcher-worker-count      (%toml-get patcher "worker_count"
                                               (getf defaults :patcher-worker-count))
         :patcher-bsdiff-path       (%toml-get patcher "bsdiff_path")
         :patcher-bspatch-path      (%toml-get patcher "bspatch_path")
         :gc-default-threshold      (%toml-get gc      "default_threshold"
                                               (getf defaults :gc-default-threshold))
         :gc-schedule               (%toml-get gc      "schedule")
         :install-token-ttl-seconds (%toml-get token   "ttl_seconds"
                                               (getf defaults :install-token-ttl-seconds)))))))

;; ---------------------------------------------------------------------------
;; Environment-variable overrides
;; ---------------------------------------------------------------------------

(defun %nonempty (v)
  (and v (stringp v) (plusp (length v)) v))

(defun apply-env-overrides (base &key (getenv #'uiop:getenv))
  "Overlay documented env-vars on BASE plist. BASE NIL means start from
*DEFAULTS*. Env-vars take precedence over both file and defaults.

GETENV is the function used to look up environment variables; it
defaults to UIOP:GETENV. Tests pass their own closure to inject
canned values without mutating the real environment."
  (let* ((cfg (copy-list (or base *defaults*))))
    (alexandria:when-let ((v (%nonempty (funcall getenv "OTA_HOST"))))
      (setf (getf cfg :host) v))
    (alexandria:when-let ((v (%nonempty (funcall getenv "OTA_PORT"))))
      (setf (getf cfg :port) (parse-integer v)))
    (alexandria:when-let ((v (%nonempty (funcall getenv "OTA_ROOT"))))
      (setf (getf cfg :data-dir) v))
    (alexandria:when-let ((v (%nonempty (funcall getenv "OTA_ADMIN_TOKEN"))))
      (setf (getf cfg :admin-token) v))
    (alexandria:when-let ((v (%nonempty (funcall getenv "OTA_TLS_CERT"))))
      (setf (getf cfg :tls-cert) v))
    (alexandria:when-let ((v (%nonempty (funcall getenv "OTA_TLS_KEY"))))
      (setf (getf cfg :tls-key) v))
    cfg))

(defun load-config-from-env (&key (getenv #'uiop:getenv))
  "Convenience: defaults + env-overrides, no file involved."
  (apply-env-overrides nil :getenv getenv))

;; ---------------------------------------------------------------------------
;; Top-level dispatch
;; ---------------------------------------------------------------------------

(defun %plist-p (x)
  (and (listp x)
       (evenp (length x))
       (loop for k in x by #'cddr always (keywordp k))))

(defun resolve-config (config &key (getenv #'uiop:getenv))
  "Resolve MAIN's :config argument into a fully-populated plist.
CONFIG may be:
  - NIL                 → defaults + env-vars
  - a pathname/string   → defaults + TOML file + env-vars
  - a plist             → returned as-is (for tests / e2e harness)
Anything else signals CONFIG-ERROR.

GETENV is forwarded to APPLY-ENV-OVERRIDES (test injection point)."
  (cond
    ((null config)
     (apply-env-overrides nil :getenv getenv))
    ((or (pathnamep config) (stringp config))
     (apply-env-overrides (load-config-from-file config) :getenv getenv))
    ((%plist-p config)
     config)
    (t
     (error 'config-error
            :format-control "main: :config must be a pathname, string, plist, or nil; got ~S"
            :format-arguments (list config)))))
