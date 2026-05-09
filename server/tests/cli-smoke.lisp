;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.
;;;
;;; Black-box smoke test against the built ota-server executable.
;;; Subprocess-invokes the binary and checks its CLI surface:
;;;   - help / -h / --help       → usage on stderr, exit 2
;;;   - version / -v / --version → "ota-server X.Y.Z" on stdout, exit 0
;;;   - (no args)                → defaults to serve (skipped here -- it
;;;                                 doesn't terminate; covered by e2e)
;;;   - unknown subcommand       → usage + exit 2
;;;   - migrate --config=<tmp>   → runs and creates the SQLite DB
;;;
;;; Skipped cleanly if the binary hasn't been built (`make build-server`).

(in-package #:ota-server.tests)

(def-suite ota-server-cli-smoke
  :description "Black-box checks against the built ota-server executable."
  :in ota-server-suite)

(in-suite ota-server-cli-smoke)

(defun %project-root ()
  (asdf:system-relative-pathname "ota-server" "../"))

(defun %ota-server-binary ()
  (merge-pathnames "server/build/ota-server" (%project-root)))

(defun %binary-exists-p ()
  (probe-file (%ota-server-binary)))

(defun %run-server (args &key environment)
  "Spawn the ota-server binary with ARGS (a list of strings).
ENVIRONMENT, if non-NIL, is a list of \"NAME=VALUE\" overlays passed
through `env -i NAME=VALUE … binary args…` so the test environment
is reproducible."
  (let* ((bin (namestring (%ota-server-binary)))
         (cmd (cond (environment
                     (append (list "env" "-i") environment (list bin) args))
                    (t (cons bin args)))))
    (multiple-value-bind (out err code)
        (uiop:run-program cmd
                          :output         '(:string :stripped t)
                          :error-output   '(:string :stripped t)
                          :ignore-error-status t)
      (values out err code))))

(test cli-binary-was-built
  (if (%binary-exists-p)
      (pass "binary present at ~A" (%ota-server-binary))
      (skip "ota-server not built; run `make build-server` first")))

(test cli-help-prints-usage-and-exits-2
  "`ota-server help` (and -h / --help) print usage to stderr and exit 2."
  (when (%binary-exists-p)
    (dolist (form '("help" "-h" "--help"))
      (multiple-value-bind (out err code) (%run-server (list form))
        (declare (ignore out))
        (is (= 2 code) "form ~S: expected exit 2, got ~A" form code)
        (is (search "ota-server" err)
            "form ~S: usage missing 'ota-server'" form)
        (is (search "Usage:"     err)
            "form ~S: usage missing 'Usage:'"     form)
        (is (search "serve"      err))
        (is (search "migrate"    err))))))

(test cli-version-prints-and-exits-0
  "`ota-server version` (and -v / --version) print the version and exit 0."
  (when (%binary-exists-p)
    (dolist (form '("version" "-v" "--version"))
      (multiple-value-bind (out err code) (%run-server (list form))
        (declare (ignore err))
        (is (= 0 code) "form ~S: expected exit 0, got ~A" form code)
        (is (search "ota-server" out)
            "form ~S: stdout missing program name" form)))))

(test cli-unknown-subcommand-prints-usage
  "An unrecognised subcommand prints usage to stderr and exits 2."
  (when (%binary-exists-p)
    (multiple-value-bind (out err code) (%run-server '("nonsense-command"))
      (declare (ignore out))
      (is (= 2 code))
      (is (search "unknown subcommand" err))
      (is (search "Usage:" err)))))

(test cli-migrate-creates-db
  "`migrate --config=PATH` runs migrations and exits 0; the SQLite DB
appears under the configured data_dir."
  (when (%binary-exists-p)
    (let* ((root (uiop:ensure-directory-pathname
                  (merge-pathnames
                   (format nil "ota-cli-migrate-~A/" (random 1000000))
                   (uiop:temporary-directory))))
           (cfg-path (merge-pathnames "ota.toml" root)))
      (ensure-directories-exist root)
      (unwind-protect
          (progn
            (with-open-file (out cfg-path :direction :output
                                           :if-exists :supersede)
              (format out "[server]~%data_dir = \"~A\"~%" (namestring root)))
            (multiple-value-bind (stdout stderr code)
                (%run-server (list "migrate"
                                   (concatenate 'string
                                                "--config="
                                                (namestring cfg-path))))
              (declare (ignore stderr))
              (is (= 0 code) "migrate exit=~A stdout=~A" code stdout)
              (is (probe-file (merge-pathnames "db/ota.db" root))
                  "migrate did not create db/ota.db under ~A" root)))
        (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore)))))

(test cli-migrate-bad-config-errors-non-zero
  "Pointing --config at a non-existent file exits non-zero with a
clear error message."
  (when (%binary-exists-p)
    (multiple-value-bind (out err code)
        (%run-server '("migrate" "--config=/no/such/path/ota.toml"))
      (declare (ignore out))
      (is (not (zerop code)) "expected non-zero exit, got ~A" code)
      (is (or (search "config file not found" err)
              (search "ota-server"             err))))))
