;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.
;;;
;;; Unit tests for ota-server.config — the TOML loader, env-var
;;; overlay, and resolve-config dispatch added in v1.0.2.

(in-package #:ota-server.tests)

(def-suite ota-server-config-suite
  :description "TOML loader + env overlay + resolve-config dispatch."
  :in ota-server-suite)

(in-suite ota-server-config-suite)

;; ---------------------------------------------------------------------------
;; Helpers
;; ---------------------------------------------------------------------------

(defun write-toml-tmp (text)
  "Write TEXT to a fresh tmp file and return its pathname."
  (let* ((dir (make-tmp-dir))
         (path (merge-pathnames "config.toml" dir)))
    (with-open-file (out path :direction :output :if-exists :supersede)
      (write-string text out))
    path))

(defun env-stub (alist)
  "Return a closure suitable as :getenv that looks names up in ALIST.
Names absent from ALIST resolve to NIL (i.e. unset)."
  (lambda (name)
    (cdr (assoc name alist :test #'string=))))

(defun load-toml-as-plist (text)
  "Convenience: parse TEXT as TOML and return the resolved plist (no env)."
  (ota-server.config:apply-env-overrides
   (ota-server.config:load-config-from-file (write-toml-tmp text))
   :getenv (env-stub nil)))

;; ---------------------------------------------------------------------------
;; TOML → plist
;; ---------------------------------------------------------------------------

(test toml-empty-yields-defaults
  "An empty TOML file populates every key from *DEFAULTS*."
  (let ((cfg (load-toml-as-plist "")))
    (is (equal "127.0.0.1" (getf cfg :host)))
    (is (equal 8443        (getf cfg :port)))
    (is (equal "localhost" (getf cfg :hostname)))
    (is (equal "info"      (getf cfg :log-level)))
    (is (equal "fs"        (getf cfg :storage-backend)))
    (is (equal "bsdiff"    (getf cfg :patcher-default)))
    (is (equal 900         (getf cfg :install-token-ttl-seconds)))
    (is (null              (getf cfg :tls-cert)))))

(test toml-listen-host-port
  "[server].listen 'host:port' splits into :host and :port."
  (let ((cfg (load-toml-as-plist "[server]
listen = \"10.0.0.5:9000\"
")))
    (is (equal "10.0.0.5" (getf cfg :host)))
    (is (equal 9000       (getf cfg :port)))))

(test toml-listen-bare-port
  "[server].listen ':port' uses the default host."
  (let ((cfg (load-toml-as-plist "[server]
listen = \":7777\"
")))
    (is (equal "127.0.0.1" (getf cfg :host)))
    (is (equal 7777        (getf cfg :port)))))

(test toml-listen-no-colon
  "A listen value without a colon is taken as host; port stays default."
  (let ((cfg (load-toml-as-plist "[server]
listen = \"otahost\"
")))
    (is (equal "otahost" (getf cfg :host)))
    (is (equal 8443      (getf cfg :port)))))

(test toml-listen-non-string-errors
  "[server].listen must be a string."
  (signals ota-server.config:config-error
    (load-toml-as-plist "[server]
listen = 8080
")))

(test toml-server-section
  "Hostname / data_dir / log_level land in the right plist keys."
  (let ((cfg (load-toml-as-plist "[server]
hostname  = \"ota.example.com\"
data_dir  = \"/srv/ota\"
log_level = \"debug\"
")))
    (is (equal "ota.example.com" (getf cfg :hostname)))
    (is (equal "/srv/ota"        (getf cfg :data-dir)))
    (is (equal "debug"           (getf cfg :log-level)))))

(test toml-tls-section
  "[tls] cert/key/client_ca/require_mtls are mapped."
  (let ((cfg (load-toml-as-plist "[tls]
cert         = \"/e/cert.pem\"
key          = \"/e/key.pem\"
client_ca    = \"/e/ca.pem\"
require_mtls = true
")))
    (is (equal "/e/cert.pem" (getf cfg :tls-cert)))
    (is (equal "/e/key.pem"  (getf cfg :tls-key)))
    (is (equal "/e/ca.pem"   (getf cfg :tls-client-ca)))
    (is (eq    t             (getf cfg :tls-require-mtls)))))

(test toml-storage-and-catalogue
  "[storage] and [catalogue] map to their plist keys."
  (let ((cfg (load-toml-as-plist "[storage]
backend = \"fs\"
[catalogue]
db = \"sqlite:/tmp/x.db\"
")))
    (is (equal "fs"               (getf cfg :storage-backend)))
    (is (equal "sqlite:/tmp/x.db" (getf cfg :catalogue-db)))))

(test toml-patcher-section
  "[patcher] populates default / worker_count / bsdiff_path / bspatch_path."
  (let ((cfg (load-toml-as-plist "[patcher]
default      = \"bsdiff\"
worker_count = 4
bsdiff_path  = \"/opt/ota/bin/bsdiff\"
bspatch_path = \"/opt/ota/bin/bspatch\"
")))
    (is (equal "bsdiff"             (getf cfg :patcher-default)))
    (is (equal 4                    (getf cfg :patcher-worker-count)))
    (is (equal "/opt/ota/bin/bsdiff"  (getf cfg :patcher-bsdiff-path)))
    (is (equal "/opt/ota/bin/bspatch" (getf cfg :patcher-bspatch-path)))))

(test toml-gc-and-install-token
  "[gc] and [install_token] map correctly."
  (let ((cfg (load-toml-as-plist "[gc]
default_threshold = 5
schedule          = \"0 3 * * *\"
[install_token]
ttl_seconds = 600
")))
    (is (equal 5            (getf cfg :gc-default-threshold)))
    (is (equal "0 3 * * *"  (getf cfg :gc-schedule)))
    (is (equal 600          (getf cfg :install-token-ttl-seconds)))))

(test toml-shipped-samples-parse
  "Every TOML file we ship must parse without error."
  (dolist (relpath '("server/etc/ota.dev.toml"
                     "server/etc/ota.docker.toml"
                     "server/etc/ota.toml.sample"))
    (let ((path (asdf:system-relative-pathname "ota-server"
                                               (concatenate 'string "../" relpath))))
      (when (probe-file path)
        (finishes (ota-server.config:load-config-from-file path))))))

;; ---------------------------------------------------------------------------
;; Errors
;; ---------------------------------------------------------------------------

(test missing-file-errors
  "Pointing at a non-existent path signals CONFIG-ERROR."
  (signals ota-server.config:config-error
    (ota-server.config:load-config-from-file "/no/such/path/ota.toml")))

(test malformed-toml-errors
  "Garbage TOML signals CONFIG-ERROR (not the underlying parser error)."
  (signals ota-server.config:config-error
    (ota-server.config:load-config-from-file
     (write-toml-tmp "this is not valid toml = = ="))))

;; ---------------------------------------------------------------------------
;; Env-var overlay
;; ---------------------------------------------------------------------------

(test env-overrides-host-and-port
  "OTA_HOST / OTA_PORT win over file values."
  (let* ((file (ota-server.config:load-config-from-file
                (write-toml-tmp "[server]
listen = \"10.0.0.5:9000\"
")))
         (cfg (ota-server.config:apply-env-overrides
               file
               :getenv (env-stub '(("OTA_HOST" . "1.2.3.4")
                                   ("OTA_PORT" . "5555"))))))
    (is (equal "1.2.3.4" (getf cfg :host)))
    (is (equal 5555      (getf cfg :port)))))

(test env-overrides-data-dir
  "OTA_ROOT wins over [server].data_dir."
  (let* ((file (ota-server.config:load-config-from-file
                (write-toml-tmp "[server]
data_dir = \"/file/dir\"
")))
         (cfg (ota-server.config:apply-env-overrides
               file
               :getenv (env-stub '(("OTA_ROOT" . "/env/dir"))))))
    (is (equal "/env/dir" (getf cfg :data-dir)))))

(test env-sets-admin-token
  "OTA_ADMIN_TOKEN sets :admin-token (no TOML key for it today)."
  (let ((cfg (ota-server.config:apply-env-overrides
              nil
              :getenv (env-stub '(("OTA_ADMIN_TOKEN" . "secret"))))))
    (is (equal "secret" (getf cfg :admin-token)))))

(test env-tls-overrides
  "OTA_TLS_CERT / OTA_TLS_KEY override [tls].cert / .key."
  (let* ((file (ota-server.config:load-config-from-file
                (write-toml-tmp "[tls]
cert = \"/file/cert\"
key  = \"/file/key\"
")))
         (cfg (ota-server.config:apply-env-overrides
               file
               :getenv (env-stub '(("OTA_TLS_CERT" . "/env/cert")
                                   ("OTA_TLS_KEY"  . "/env/key"))))))
    (is (equal "/env/cert" (getf cfg :tls-cert)))
    (is (equal "/env/key"  (getf cfg :tls-key)))))

(test env-empty-string-is-noop
  "An env-var set to the empty string is treated as unset."
  (let* ((file (ota-server.config:load-config-from-file
                (write-toml-tmp "[server]
listen = \"10.0.0.5:9000\"
")))
         (cfg (ota-server.config:apply-env-overrides
               file
               :getenv (env-stub '(("OTA_HOST" . ""))))))
    (is (equal "10.0.0.5" (getf cfg :host)))))

(test env-port-non-integer-errors
  "OTA_PORT must parse as an integer."
  (signals error
    (ota-server.config:apply-env-overrides
     nil
     :getenv (env-stub '(("OTA_PORT" . "not-a-number"))))))

(test env-only-defaults-from-load-from-env
  "load-config-from-env returns *DEFAULTS* with env applied."
  (let ((cfg (ota-server.config:load-config-from-env
              :getenv (env-stub '(("OTA_PORT" . "1234"))))))
    (is (equal 1234        (getf cfg :port)))
    (is (equal "127.0.0.1" (getf cfg :host)))))

;; ---------------------------------------------------------------------------
;; resolve-config dispatch
;; ---------------------------------------------------------------------------

(test resolve-nil-uses-env-only
  "resolve-config NIL → defaults overlaid by env."
  (let ((cfg (ota-server.config:resolve-config
              nil
              :getenv (env-stub '(("OTA_HOST" . "9.9.9.9"))))))
    (is (equal "9.9.9.9"   (getf cfg :host)))
    (is (equal 8443        (getf cfg :port)))))

(test resolve-string-path-loads-file
  "resolve-config with a string path loads TOML then applies env."
  (let* ((path (write-toml-tmp "[server]
hostname = \"from-file\"
"))
         (cfg (ota-server.config:resolve-config
               (namestring path)
               :getenv (env-stub nil))))
    (is (equal "from-file" (getf cfg :hostname)))))

(test resolve-pathname-loads-file
  "resolve-config also accepts a PATHNAME."
  (let* ((path (write-toml-tmp "[server]
hostname = \"from-pathname\"
"))
         (cfg (ota-server.config:resolve-config
               path
               :getenv (env-stub nil))))
    (is (equal "from-pathname" (getf cfg :hostname)))))

(test resolve-plist-returned-as-is
  "resolve-config with a pre-built plist returns it unchanged."
  (let ((cfg (ota-server.config:resolve-config
              (list :host "z" :port 1 :data-dir "/d" :admin-token "t"))))
    (is (equal "z" (getf cfg :host)))
    (is (equal 1   (getf cfg :port)))))

(test resolve-bad-type-errors
  "Anything other than nil/path/plist signals CONFIG-ERROR."
  (signals ota-server.config:config-error
    (ota-server.config:resolve-config 42))
  (signals ota-server.config:config-error
    (ota-server.config:resolve-config #\x))
  ;; Odd-length list (not a valid plist) → reject.
  (signals ota-server.config:config-error
    (ota-server.config:resolve-config '(:host)))
  ;; Even-length but non-keyword keys → reject.
  (signals ota-server.config:config-error
    (ota-server.config:resolve-config '("host" "x" "port" 1))))

;; ---------------------------------------------------------------------------
;; admin_token from TOML (v1.1.1: closes the gap that operations.org
;; documented but the loader never delivered -- prior to this, the
;; key was silently ignored and only OTA_ADMIN_TOKEN worked).
;; ---------------------------------------------------------------------------

(test toml-admin-token
  "[server].admin_token populates :admin-token in the resolved plist."
  (let ((cfg (load-toml-as-plist "[server]
admin_token = \"production-secret-XYZ\"
")))
    (is (equal "production-secret-XYZ" (getf cfg :admin-token)))))

(test toml-admin-token-default-when-absent
  "When [server].admin_token is missing, :admin-token falls through
to *DEFAULTS*'s value (the dev-token)."
  (let ((cfg (load-toml-as-plist "")))
    (is (equal "dev-token" (getf cfg :admin-token)))))

(test env-admin-token-overrides-toml-value
  "The OTA_ADMIN_TOKEN env-var wins over [server].admin_token in TOML
(env always trumps file, per the documented precedence)."
  (let* ((file (ota-server.config:load-config-from-file
                (write-toml-tmp "[server]
admin_token = \"from-file\"
")))
         (cfg (ota-server.config:apply-env-overrides
               file
               :getenv (env-stub '(("OTA_ADMIN_TOKEN" . "from-env"))))))
    (is (equal "from-env" (getf cfg :admin-token)))))

(test resolve-precedence-file-then-env
  "When a file AND env-vars are present, env-vars win."
  (let* ((path (write-toml-tmp "[server]
listen = \"10.0.0.5:9000\"
hostname = \"file-host\"
"))
         (cfg (ota-server.config:resolve-config
               path
               :getenv (env-stub '(("OTA_HOST" . "env-host")
                                   ("OTA_PORT" . "1111"))))))
    (is (equal "env-host"  (getf cfg :host)))
    (is (equal 1111        (getf cfg :port)))
    (is (equal "file-host" (getf cfg :hostname)))))
