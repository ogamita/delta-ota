;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.
;;;
;;; ota-server — top-level CLI dispatch.
;;;
;;; The build script saves an executable whose toplevel calls
;;; (ota-server:main) with no arguments; we read argv ourselves
;;; via UIOP:COMMAND-LINE-ARGUMENTS.  When called from the test
;;; harness or the e2e shell scripts, MAIN can also be invoked
;;; programmatically:
;;;
;;;   (ota-server:main "serve" "--config=server/etc/ota.dev.toml")
;;;   (ota-server:main :config "server/etc/ota.dev.toml")  ; legacy
;;;
;;; — i.e. the &rest argv form (string args) and the legacy
;;; &key form both work.  The legacy form is preserved so the
;;; existing e2e harness and any out-of-tree callers do not break.

(defpackage #:ota-server
  (:use #:cl)
  (:export #:main
           #:serve
           #:migrate
           #:run-gc
           #:version-string))

(in-package #:ota-server)

;; ---------------------------------------------------------------------------
;; Version
;; ---------------------------------------------------------------------------

(defun version-string ()
  "Return the version recorded in ota-server.asd."
  (or (asdf:component-version (asdf:find-system "ota-server" nil))
      "unknown"))

;; ---------------------------------------------------------------------------
;; Tiny argv helpers (kept first-party — same flavour as ota-admin)
;; ---------------------------------------------------------------------------

(defun %get-flag (argv name)
  "Look up --NAME=value or --NAME value in ARGV.  Returns the value
string or NIL when absent."
  (let ((eq-prefix (concatenate 'string "--" name "="))
        (bare      (concatenate 'string "--" name)))
    (loop for tail on argv
          for a = (first tail)
          when (alexandria:starts-with-subseq eq-prefix a)
            return (subseq a (length eq-prefix))
          when (string= a bare)
            return (second tail))))

(defun %positional (argv)
  "Return the positional (non-flag) arguments from ARGV."
  (loop for a in argv
        unless (alexandria:starts-with-subseq "--" a)
          collect a))

;; ---------------------------------------------------------------------------
;; Subcommands
;; ---------------------------------------------------------------------------

(defun %resolve (config)
  (ota-server.config:resolve-config config))

(defun serve (&key config)
  "Boot the server.  CONFIG: NIL → defaults+env-vars; pathname/string
→ TOML file (env-vars override); plist → already-resolved (test
harness)."
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
                 :tls-key  (getf cfg :tls-key)
                 ;; v1.4: admin cert-subject identity + per-endpoint
                 ;; rate limits (ADR-0009).  All four knobs are
                 ;; opt-in -- with no TOML changes the server
                 ;; behaves exactly like v1.3 modulo the per-route
                 ;; bucket keying (which inherits the v1.3 defaults
                 ;; for routes without specific caps).
                 :admin-subjects               (getf cfg :tls-admin-subjects)
                 :trust-proxy-subject-header   (getf cfg :tls-trust-proxy-subject-header)
                 :proxy-subject-header-name    (or (getf cfg :tls-proxy-subject-header-name)
                                                   "x-ota-client-cert-subject")
                 :require-mtls                 (getf cfg :tls-require-mtls)
                 :rate-limits-override         (getf cfg :rate-limits-override)))
         (patch-worker-count (or (getf cfg :patcher-worker-count) 2)))
    (ota-server.catalogue:run-migrations db)
    (ensure-directories-exist
     (ota-server.http::app-state-manifests-dir state))
    ;; v1.2: reset any patch_jobs the previous process left in 'running'
    ;; before starting the new pool.  Bsdiff is deterministic and
    ;; INSERT-PATCH dedupes on (from, to, patcher), so re-running a
    ;; partially-completed job is idempotent.
    (let ((reset (ota-server.catalogue:reset-stale-running-jobs db)))
      (when (plusp reset)
        (format t "patch-pool: reset ~D stale running job~:P from a previous run~%"
                reset)
        (force-output)))
    (let ((pool (ota-server.workers:start-patch-pool
                 cas db :size patch-worker-count)))
      (setf (ota-server.http::app-state-pool state) pool))
    (format t "ota-server ~A~%~
               listening on ~A:~A (~A http worker thread~:P, ~A patch worker~:P)~%~
               data_dir=~A~%~
               manifest pubkey=~A~%"
            (version-string)
            (getf cfg :host) (getf cfg :port)
            (or (getf cfg :worker-num) 1)
            patch-worker-count
            root
            (ota-server.manifest:keypair-public-hex kp))
    (force-output)
    (let ((handler
            (ota-server.http:start-server state
                                          :host       (getf cfg :host)
                                          :port       (getf cfg :port)
                                          :worker-num (getf cfg :worker-num))))
      (format t "ota-server: ready.~%")
      (force-output)
      (unwind-protect
           (handler-case
               (loop (sleep 86400))
             (#+sbcl sb-sys:interactive-interrupt #-sbcl t () nil))
        (ota-server.workers:stop-patch-pool
         (ota-server.http::app-state-pool state))
        (ota-server.http:stop-server handler)))
    0))

(defun migrate (&key config)
  "Apply catalogue migrations and exit."
  (let* ((cfg (%resolve config))
         (root (uiop:ensure-directory-pathname (getf cfg :data-dir)))
         (db (ota-server.catalogue:open-catalogue
              (merge-pathnames "db/ota.db" root))))
    (ota-server.catalogue:run-migrations db)
    (ota-server.catalogue:close-catalogue db)
    (format t "ota-server: migrations applied at ~A~%" (merge-pathnames "db/ota.db" root))
    (force-output)
    0))

(defun run-gc (&key config software (min-user-count 0) (min-age-days 30)
                    dry-run (ensure-reachability t) (allow-blob-fallback nil)
                    (max-built-edges 50))
  "Run garbage collection for SOFTWARE and exit.  Mirrors the
HTTP `POST /v1/admin/software/<sw>/gc` handler.

Required: :software.  Optional: :min-user-count (default 0),
:min-age-days (default 30), :dry-run, :ensure-reachability
(default T; v1.6 reachability-aware GC), :allow-blob-fallback
(default NIL; accept full-blob fallback for affected clients
instead of pre-building edges), :max-built-edges (default 50;
ceiling on the patches the plan may pre-build).

Exit codes:
  0  success (drops applied OR dry-run completed)
  2  missing required arg
  3  GC aborted (reachability infeasible without
                 --allow-blob-fallback)"
  (unless software
    (format *error-output* "ota-server gc: --software=NAME required~%")
    (return-from run-gc 2))
  (let* ((cfg (%resolve config))
         (root (uiop:ensure-directory-pathname (getf cfg :data-dir)))
         (cas (ota-server.storage:make-cas root))
         (db  (ota-server.catalogue:open-catalogue
               (merge-pathnames "db/ota.db" root)))
         (kp  (ota-server.manifest:load-or-generate-keypair
               (merge-pathnames "etc/keys/" root)))
         (manifests-dir (merge-pathnames "manifests/" root)))
    (unwind-protect
         (let* ((result (ota-server.workers:gc-software
                         cas db kp manifests-dir
                         :software software
                         :min-user-count min-user-count
                         :min-age-days   min-age-days
                         :dry-run        dry-run
                         :ensure-reachability ensure-reachability
                         :allow-blob-fallback allow-blob-fallback
                         :max-built-edges max-built-edges))
                (reach (getf result :reachability))
                (aborted (getf result :aborted)))
           (cond
             (aborted
              (format *error-output*
                      "ota-server gc: aborted -- ~D edges-to-build exceed max-built-edges=~D; ~
re-run with --allow-blob-fallback to drop anyway~%"
                      (length (getf reach :edges-to-build))
                      max-built-edges)
              (return-from run-gc 3))
             (t
              (format t "ota-server gc: software=~A pruned=~D dry-run=~A ~
min-user-count=~A min-age-days=~A~%"
                      software
                      (length (getf result :pruned))
                      (if (getf result :dry-run) "true" "false")
                      min-user-count min-age-days)
              (when reach
                (let ((fates (getf reach :clients-by-fate)))
                  (format t "  reachability: unaffected=~D graceful=~D blob-fallback=~D unreachable=~D ~
edges-built=~D~%"
                          (or (getf fates :unaffected) 0)
                          (or (getf fates :graceful) 0)
                          (or (getf fates :blob-fallback) 0)
                          (or (getf fates :unreachable) 0)
                          (or (getf reach :edges-built) 0))))
              (dolist (rid (getf result :pruned))
                (format t "  ~A  ~A~%"
                        (if dry-run "would prune" "pruned     ")
                        rid))
              (force-output)
              (ota-server.catalogue:append-audit
               db
               :identity "cli"
               :action "gc"
               :target software
               :detail (format nil "pruned=~D dry_run=~A ensure_reachability=~A"
                               (length (getf result :pruned))
                               (getf result :dry-run)
                               ensure-reachability)))))
      (ota-server.catalogue:close-catalogue db))
    0))

;; ---------------------------------------------------------------------------
;; Usage
;; ---------------------------------------------------------------------------

(defun run-stats (&key config query-name params)
  "Run one named stats query from the catalogue and print the
result as an ASCII table.  Mirrors the HTTP
`GET /v1/admin/stats/<query-name>` so cron / systemd timers
can collect stats without going through the API.

Required: :query-name (a keyword).  Optional: :params, a plist
of :keyword/string-or-integer values matching the catalogue
entry's :params list.  Exit code 0 on success, 2 on missing
:query-name, 3 on unknown query / missing required param."
  (unless query-name
    (format *error-output* "ota-server stats: <query-name> required~%")
    (return-from run-stats 2))
  (let* ((cfg (%resolve config))
         (root (uiop:ensure-directory-pathname (getf cfg :data-dir)))
         (db  (ota-server.catalogue:open-catalogue
               (merge-pathnames "db/ota.db" root))))
    (unwind-protect
         (handler-case
             (multiple-value-bind (cols rows)
                 (ota-server.workers:run-stat-query db query-name :params params)
               (%print-stats-table cols rows)
               (force-output)
               0)
           (ota-server.workers:stats-error (c)
             (format *error-output* "ota-server stats: ~A~%" c)
             3))
      (ota-server.catalogue:close-catalogue db))))

(defun %print-stats-table (cols rows)
  "Render (COLS ROWS) as a left-aligned ASCII table on
*standard-output*.  Computes per-column widths from the data so
the output is friendly to grep / awk pipelines without being
ugly when read by a human."
  (let* ((widths (mapcar (lambda (col)
                           (max (length (symbol-name col))
                                (reduce
                                 #'max
                                 (mapcar (lambda (row)
                                           (length (princ-to-string
                                                    (or (nth (position col cols) row) ""))))
                                         rows)
                                 :initial-value 0)))
                         cols)))
    ;; Header.
    (loop for col in cols for w in widths
          do (format t "~vA  " w (symbol-name col)))
    (terpri)
    (loop for w in widths
          do (format t "~v,,,'-A  " w ""))
    (terpri)
    ;; Body.
    (dolist (row rows)
      (loop for col in cols for w in widths
            for v in row
            do (format t "~vA  " w (or v "")))
      (terpri))
    (format t "~%~D row~:P~%" (length rows))))

(defun %usage (&optional (stream *error-output*))
  (format stream
"ota-server — Ogamita Delta OTA distribution server

Usage:
  ota-server serve   [--config=PATH]    boot the server (default subcommand)
  ota-server migrate [--config=PATH]    apply catalogue migrations and exit
  ota-server gc      [--config=PATH] --software=NAME [--min-user-count=N]
                     [--min-age-days=N] [--dry-run]
                     [--no-ensure-reachability] [--allow-blob-fallback]
                     [--max-built-edges=N]
                                        run garbage collection on SOFTWARE and exit
  ota-server stats   [--config=PATH] <query-name> [--<param>=<value> ...]
                                        run an admin stats query; --help-stats
                                        lists available queries
  ota-server shell                      drop into an SBCL REPL (debug only)
  ota-server version                    print version and exit
  ota-server help                       print this message and exit

Configuration:
  --config=PATH      path to a TOML config file.  When omitted, the server
                     starts from built-in defaults overlaid by environment
                     variables.

Environment variables (override file values):
  OTA_HOST           bind address           (default 127.0.0.1)
  OTA_PORT           TCP port               (default 8443)
  OTA_ROOT           data directory         (default ./build/dev/ota-data)
  OTA_ADMIN_TOKEN    admin bearer token     (required for admin endpoints)
  OTA_TLS_CERT       path to PEM TLS cert   (optional; otherwise plain HTTP)
  OTA_TLS_KEY        path to PEM TLS key    (optional)
")
  (force-output stream))

;; ---------------------------------------------------------------------------
;; Top-level dispatch
;; ---------------------------------------------------------------------------

(defun %dispatch-argv (argv)
  "Process ARGV (a list of strings) and return an integer exit code."
  (let* ((cmd (or (first argv) "serve"))
         (rest (rest argv))
         (config (%get-flag rest "config")))
    (cond
      ((member cmd '("help" "-h" "--help") :test #'string=)
       (%usage)
       2)
      ((member cmd '("version" "-v" "--version") :test #'string=)
       (format t "ota-server ~A~%" (version-string))
       0)
      ((string= cmd "serve")
       (or (serve :config config) 0))
      ((string= cmd "migrate")
       (or (migrate :config config) 0))
      ((string= cmd "gc")
       (let ((software       (%get-flag rest "software"))
             (min-user-count (alexandria:if-let ((v (%get-flag rest "min-user-count")))
                               (parse-integer v) 0))
             (min-age-days   (alexandria:if-let ((v (%get-flag rest "min-age-days")))
                               (parse-integer v) 30))
             (dry-run        (or (member "--dry-run" rest :test #'string=)
                                 (let ((v (%get-flag rest "dry-run")))
                                   (and v (not (string= v "false"))
                                        (not (string= v "0"))))))
             ;; v1.6 reachability knobs.  --no-ensure-reachability
             ;; disables the new layer; default is on.
             (no-ensure      (member "--no-ensure-reachability" rest :test #'string=))
             (allow-blob     (or (member "--allow-blob-fallback" rest :test #'string=)
                                 (let ((v (%get-flag rest "allow-blob-fallback")))
                                   (and v (not (string= v "false"))
                                        (not (string= v "0"))))))
             (max-built      (alexandria:if-let ((v (%get-flag rest "max-built-edges")))
                               (parse-integer v) 50)))
         (or (run-gc :config config
                     :software software
                     :min-user-count min-user-count
                     :min-age-days min-age-days
                     :dry-run (and dry-run t)
                     :ensure-reachability (not no-ensure)
                     :allow-blob-fallback (and allow-blob t)
                     :max-built-edges max-built)
             0)))
      ((string= cmd "stats")
       (cond
         ((member "--help-stats" rest :test #'string=)
          (%list-stats *standard-output*)
          0)
         (t
          (let* ((positional (%positional rest))
                 (qname-str (second positional))
                 (qname (and qname-str
                             (intern (string-upcase
                                      (substitute #\- #\_ qname-str))
                                     :keyword)))
                 (params (%stats-params-from-flags rest)))
            (or (run-stats :config config
                           :query-name qname
                           :params params)
                0)))))
      ((string= cmd "shell")
       #+sbcl (sb-impl::toplevel-init)
       0)
      (t
       (format *error-output* "ota-server: unknown subcommand: ~A~%~%" cmd)
       (%usage)
       2))))

(defun %stats-params-from-flags (argv)
  "Walk ARGV and collect every --KEY=VALUE flag (except --config
and the like) into a plist of :KEY/value.  Used by the stats
subcommand: any flag the user passes that isn't a known
infrastructure flag is treated as a stats query parameter."
  (let ((reserved '("config" "help" "help-stats"))
        (acc '()))
    (dolist (a argv)
      (when (and (>= (length a) 3)
                 (string= "--" a :end2 2))
        (let* ((eq (position #\= a))
               (k  (if eq (subseq a 2 eq) (subseq a 2)))
               (v  (if eq (subseq a (1+ eq)) "")))
          (unless (member k reserved :test #'string=)
            (push v acc)
            (push (intern (string-upcase k) :keyword) acc)))))
    acc))

(defun %list-stats (stream)
  "Print the catalogue of available stats queries to STREAM."
  (let ((rows (ota-server.workers:list-stat-queries)))
    (format stream "Available stats queries:~%~%")
    (dolist (r rows)
      (format stream "  ~A~%" (string-downcase
                               (symbol-name (getf r :name))))
      (format stream "    ~A~%" (getf r :description))
      (let ((ps (getf r :params)))
        (when ps
          (format stream "    params: ~{--~A~^ ~}~%"
                  (mapcar (lambda (p)
                            (substitute #\- #\_
                                        (string-downcase (symbol-name p))))
                          ps))))
      (terpri stream))))

(defun main (&rest argv)
  "Top-level entry point.  Two calling conventions:

  - String args: (main \"serve\" \"--config=...\") or no args (read
    UIOP:COMMAND-LINE-ARGUMENTS).  Returns an integer exit code.

  - Legacy keyword form: (main :config <plist-or-pathname-or-nil>)
    -- preserved so the e2e harness and out-of-tree callers do not
    break.  Calls SERVE directly."
  (cond
    ;; Legacy keyword call: (main :config X).
    ((and argv (keywordp (first argv)))
     (apply #'serve argv))
    ;; CLI call: pass strings, or nothing (read argv).
    (t
     (let ((argv (or argv (uiop:command-line-arguments))))
       (%dispatch-argv argv)))))
