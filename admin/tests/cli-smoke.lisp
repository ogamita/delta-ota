;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.
;;;
;;; Black-box smoke test: spawn the built ota-admin executable and
;;; check it behaves like a CLI -- prints usage, validates required
;;; flags, exits with the expected codes. If the binary hasn't been
;;; built yet, the suite is skipped with a clear note rather than
;;; failing -- it is a `make build-admin` artefact, not an in-image
;;; test of the source.

(in-package #:ota-admin.tests)

(def-suite ota-admin-cli-smoke
  :description "Black-box checks against the built ota-admin executable.")

(in-suite ota-admin-cli-smoke)

(defun project-root ()
  "Return the absolute path to the repository root (parent of this asd)."
  (asdf:system-relative-pathname "ota-admin" "../"))

(defun ota-admin-binary ()
  (merge-pathnames "admin/build/ota-admin" (project-root)))

(defun run-admin (args)
  "Spawn the ota-admin binary with ARGS (a list of strings).
Return (values stdout stderr exit-code). ARGS is passed verbatim;
no shell expansion."
  (multiple-value-bind (out err code)
      (uiop:run-program (cons (namestring (ota-admin-binary)) args)
                        :output         '(:string :stripped t)
                        :error-output   '(:string :stripped t)
                        :ignore-error-status t)
    (values out err code)))

(defun binary-exists-p ()
  (probe-file (ota-admin-binary)))

(test binary-was-built
  "ota-admin must have been compiled by `make build-admin` before
the rest of this suite is meaningful."
  (if (binary-exists-p)
      (pass "binary present at ~A" (ota-admin-binary))
      (skip "ota-admin not built; run `make build-admin` first")))

(test help-prints-usage-and-exits-2
  "`ota-admin help` (and -h / --help) prints usage to stderr and exits 2."
  (when (binary-exists-p)
    (dolist (form '("help" "-h" "--help"))
      (multiple-value-bind (out err code) (run-admin (list form))
        (declare (ignore out))
        (is (= 2 code) "form ~S: expected exit 2, got ~A" form code)
        (is (search "ota-admin"   err))
        (is (search "publish"     err))
        (is (search "mint-tokens" err))))))

(test version-prints-and-exits-0
  "`ota-admin version` (and -v / --version) prints the version and exits 0."
  (when (binary-exists-p)
    (dolist (form '("version" "-v" "--version"))
      (multiple-value-bind (out err code) (run-admin (list form))
        (declare (ignore err))
        (is (= 0 code) "form ~S: expected exit 0, got ~A" form code)
        (is (search "ota-admin" out)
            "form ~S: stdout missing program name" form)))))

(test no-args-prints-usage
  "Invoking the binary with no arguments also prints usage and exits 2."
  (when (binary-exists-p)
    (multiple-value-bind (out err code) (run-admin '())
      (declare (ignore out))
      (is (= 2 code))
      (is (search "Usage:" err)))))

(test publish-missing-dir-errors
  "`publish` with no positional dir argument exits non-zero with a
clear missing-arg message on stderr."
  (when (binary-exists-p)
    (multiple-value-bind (out err code) (run-admin '("publish"))
      (declare (ignore out))
      (is (not (zerop code)))
      (is (search "missing" err)))))

(test publish-missing-token-errors
  "`publish <dir> --software=... --version=...` without OTA_ADMIN_TOKEN
errors with a clear message about the token."
  (when (binary-exists-p)
    (let ((dir (uiop:temporary-directory)))
      (multiple-value-bind (out err code)
          (run-admin (list "publish" (namestring dir)
                           "--software=hello"
                           "--version=1.0.0"
                           "--os=darwin"
                           "--arch=arm64"))
        (declare (ignore out))
        (is (not (zerop code)))
        (is (or (search "OTA_ADMIN_TOKEN" err)
                (search "token"           err)))))))

(test unknown-subcommand-prints-usage
  "Any unrecognised subcommand falls through to usage."
  (when (binary-exists-p)
    (multiple-value-bind (out err code) (run-admin '("nonsense-command"))
      (declare (ignore out))
      (is (= 2 code))
      (is (search "Usage:" err)))))

(defun run-all ()
  (let ((result (run! 'ota-admin-cli-smoke)))
    (unless result
      (uiop:quit 1))))
