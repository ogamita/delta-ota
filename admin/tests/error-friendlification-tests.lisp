;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.
;;;
;;; Unit tests for ota-admin::%friendlier-message — the helper that
;;; rewrites cl+ssl / dexador / usocket error messages into one-line
;;; user-facing hints.  These are pure-function tests against synthetic
;;; condition objects; no network, no subprocess, no real TLS.

(in-package #:ota-admin.tests)

(def-suite ota-admin-error-friendlification
  :description "ota-admin::%friendlier-message dispatch.")

(in-suite ota-admin-error-friendlification)

(defun synthetic-error (message)
  "Return a SIMPLE-ERROR whose printed representation is MESSAGE."
  (make-condition 'simple-error
                  :format-control "~A"
                  :format-arguments (list message)))

(defun friendlier (message url)
  (ota-admin::%friendlier-message (synthetic-error message) url))

;; Stub classes whose CLASS-NAME mimics what real USOCKET conditions
;; look like.  The dispatch in %friendlier-message reads
;; (symbol-name (class-name (class-of err))), so the package the
;; symbol lives in is irrelevant -- only the symbol's printed name
;; matters.  Defining these locally keeps the tests independent of
;; usocket internals.
(define-condition ns-host-not-found-error          (error) ())
(define-condition ns-try-again-condition           (error) ())
(define-condition connection-refused-error         (error) ())
(define-condition usocket-fake-timeout-error       (error) ())   ; matches USOCKET fallback
(define-condition some-totally-unrelated-error     (error) ())

(defun friendlier-by-class (class url)
  (ota-admin::%friendlier-message (make-condition class) url))

;; ---------------------------------------------------------------------------
;; The motivating case: TLS handshake against a plain-HTTP server.
;; ---------------------------------------------------------------------------

(test tls-vs-http-wrong-version-number
  "An OpenSSL 'wrong version number' error against an https:// URL
gets rewritten with a hint to drop the 's' or configure TLS.  The
suggested URL is the BASE (scheme://host:port), not the request
path -- because that's what OTA_SERVER takes."
  (let ((msg (friendlier
              "A failure in the SSL library occurred on handle … (SSL_get_error: 1). ERR_print_errors(): tls_validate_record_header:wrong version number"
              "https://localhost:8443/v1/admin/software/hello/releases")))
    (is (stringp msg))
    (is (search "TLS handshake failed" msg))
    (is (search "plain HTTP"           msg))
    (is (search "http://localhost:8443" msg)
        "expected the suggested URL with the 's' stripped, got ~S" msg)
    (is (not (search "/v1/admin/software/hello/releases" msg))
        "the suggested OTA_SERVER must NOT include the request path: ~S" msg)))

(test tls-vs-http-error-against-http-url-passes-through
  "The same SSL error against an http:// URL is NOT rewritten — there
is no scheme to suggest swapping to.  Pass through unchanged."
  (is (null
       (friendlier "tls_validate_record_header:wrong version number"
                   "http://localhost:8443"))))

(test tls-validator-string-alone-is-enough
  "Match on either 'wrong version number' OR 'tls_validate_record_header'
so future libssl versions that reword one without the other still trigger."
  (is (stringp (friendlier "tls_validate_record_header:something_else"
                           "https://x.example.com")))
  (is (stringp (friendlier "wrong version number"
                           "https://x.example.com"))))

;; ---------------------------------------------------------------------------
;; Untrusted certificate.
;; ---------------------------------------------------------------------------

(test cert-verify-failed
  (let ((msg (friendlier "certificate verify failed: self-signed certificate"
                         "https://ota.example.com")))
    (is (stringp msg))
    (is (search "certificate verification failed" msg))
    (is (search "ota.example.com" msg))))

(test cert-untrusted-issuer-variants
  "Recognise the common OpenSSL/cl+ssl phrasings."
  (dolist (text '("certificate verify failed"
                  "self signed certificate"
                  "self-signed certificate"
                  "unable to get local issuer certificate"))
    (is (stringp (friendlier text "https://x.example.com"))
        "phrase ~S should match the cert-untrusted branch" text)))

(test cert-error-against-http-url-passes-through
  "Cert errors reported for an http:// URL would be a libssl bug, not
a config problem — don't pretend to know the fix."
  (is (null (friendlier "certificate verify failed"
                        "http://x.example.com"))))

;; ---------------------------------------------------------------------------
;; Connection-level failures.
;; ---------------------------------------------------------------------------

(test connection-refused-variants
  (dolist (text '("Connection refused"
                  "connect: ECONNREFUSED"
                  "Couldn't connect to server"))
    (let ((m (friendlier text "http://127.0.0.1:8443")))
      (is (stringp m) "phrase ~S should match the conn-refused branch" text)
      (is (search "127.0.0.1:8443" m))
      (is (search "connection refused" m)))))

(test dns-failure-variants
  (dolist (text '("Name or service not known"
                  "nodename nor servname provided"
                  "No such host is known"))
    (let ((m (friendlier text "http://no-such-host.invalid:8443")))
      (is (stringp m) "phrase ~S should match the DNS-failure branch" text)
      (is (search "could not resolve" m))
      (is (search "no-such-host.invalid" m)))))

;; ---------------------------------------------------------------------------
;; Pass-through.
;; ---------------------------------------------------------------------------

(test unknown-error-passes-through
  "Errors we don't recognise return NIL so the original condition gets
re-signaled verbatim."
  (is (null (friendlier "418 I'm a teapot"             "https://x.example.com")))
  (is (null (friendlier "totally unrelated complaint"  "http://127.0.0.1:8443"))))

;; ---------------------------------------------------------------------------
;; Internal helpers.
;; ---------------------------------------------------------------------------

(test scheme-detector
  (is (eq :https (ota-admin::%http-scheme-of "https://x.example.com/path")))
  (is (eq :http  (ota-admin::%http-scheme-of "http://x.example.com:8443")))
  (is (null (ota-admin::%http-scheme-of "ftp://x.example.com")))
  (is (null (ota-admin::%http-scheme-of "x.example.com"))))

;; ---------------------------------------------------------------------------
;; Class-name dispatch (the case the substring matcher misses, where
;; the condition's printed form is just "Condition USOCKET:FOO was
;; signalled" with no diagnostic text).
;; ---------------------------------------------------------------------------

(test class-dispatch-dns-not-found
  "A condition whose class-name contains NS-HOST-NOT-FOUND triggers the
DNS branch even when the printed message has nothing useful."
  (let ((m (friendlier-by-class 'ns-host-not-found-error
                                "http://no-such-host.invalid:8443")))
    (is (stringp m))
    (is (search "could not resolve" m))))

(test class-dispatch-dns-try-again
  (let ((m (friendlier-by-class 'ns-try-again-condition
                                "http://flaky.example.com")))
    (is (stringp m))
    (is (search "could not resolve" m))))

(test class-dispatch-connection-refused
  (let ((m (friendlier-by-class 'connection-refused-error
                                "http://127.0.0.1:1")))
    (is (stringp m))
    (is (search "connection refused" m))))

(test class-dispatch-usocket-fallback
  "Any condition whose qualified class name contains USOCKET (real or
test-stub) gets a 'could not reach' fallback rather than the bare
class name."
  (let ((m (friendlier-by-class 'usocket-fake-timeout-error
                                "https://127.0.0.1:1")))
    (is (stringp m))
    (is (search "could not reach" m))
    (is (search "127.0.0.1:1" m))
    ;; The qualified class name is included in parens for debuggability.
    (is (search "USOCKET-FAKE-TIMEOUT-ERROR" m))))

(test typename-includes-package-prefix
  "Sanity check: %condition-typename emits 'PKG:NAME' so substring
matchers can distinguish real-USOCKET-prefix from coincidental
short names."
  (let ((tn (ota-admin::%condition-typename
             (make-condition 'connection-refused-error))))
    ;; The defcondition above lives in :ota-admin.tests, so the
    ;; qualified name should contain that package prefix.
    (is (search "OTA-ADMIN.TESTS" tn))
    (is (search "CONNECTION-REFUSED-ERROR" tn))))

(test class-dispatch-unknown-passes-through
  "A non-USOCKET, non-recognised condition class returns NIL so the
original error propagates verbatim."
  (is (null (friendlier-by-class 'some-totally-unrelated-error
                                 "http://x.example.com"))))

;; ---------------------------------------------------------------------------
;; Read-timeout (SBCL io-timeout) — a publish whose bsdiff outlasted
;; the client's read deadline.  This is the v1.0.4 motivating case
;; for *default-read-timeout* being bumped from 10s to 600s.
;; ---------------------------------------------------------------------------

(test io-timeout-message-is-rewritten
  "The raw SBCL message 'I/O timeout while doing input on ...'
gets rewritten with a hint pointing at OTA_ADMIN_READ_TIMEOUT."
  (let ((m (friendlier
            "I/O timeout while doing input on #<SB-SYS:FD-STREAM ...>"
            "http://127.0.0.1:8443/v1/admin/software/x/releases")))
    (is (stringp m))
    (is (search "I/O timeout"               m))
    (is (search "OTA_ADMIN_READ_TIMEOUT"    m))
    (is (search "still processing"          m))
    ;; The hint MUST mention the URL so the operator knows which
    ;; server they were talking to.
    (is (search "127.0.0.1:8443"            m))))

(define-condition fake-io-timeout-error (error) ())
(define-condition fake-deadline-timeout-error (error) ())

(test io-timeout-class-dispatch
  "Even when the printed message is opaque (the underlying condition
class name contains IO-TIMEOUT or DEADLINE-TIMEOUT), we still
recognise it."
  (dolist (class '(fake-io-timeout-error fake-deadline-timeout-error))
    (let ((m (friendlier-by-class class
                                  "http://127.0.0.1:8443/v1/admin/x")))
      (is (stringp m) "class ~A: expected friendly text" class)
      (is (search "OTA_ADMIN_READ_TIMEOUT" m)))))

;; ---------------------------------------------------------------------------
;; Timeout-resolution helper.
;; ---------------------------------------------------------------------------

(test resolve-timeout-from-env
  "%resolve-timeout reads an integer second-count from the env, with
sane behaviour for unset / empty / 0 / non-integer values."
  (let ((env (make-hash-table :test 'equal))
        (orig-getenv (symbol-function 'uiop:getenv)))
    ;; Drive uiop:getenv from the hash table for the duration of
    ;; the test.  Keep it scoped: setf-fdefinition is reverted on
    ;; the way out via UNWIND-PROTECT.
    (unwind-protect
         (progn
           (setf (symbol-function 'uiop:getenv)
                 (lambda (name) (gethash name env)))
           ;; Unset → fallback.
           (is (= 600 (ota-admin::%resolve-timeout
                       "OTA_ADMIN_READ_TIMEOUT" 600)))
           ;; Empty string → fallback.
           (setf (gethash "OTA_ADMIN_READ_TIMEOUT" env) "")
           (is (= 600 (ota-admin::%resolve-timeout
                       "OTA_ADMIN_READ_TIMEOUT" 600)))
           ;; "0" → NIL (no deadline).
           (setf (gethash "OTA_ADMIN_READ_TIMEOUT" env) "0")
           (is (null (ota-admin::%resolve-timeout
                      "OTA_ADMIN_READ_TIMEOUT" 600)))
           ;; "120" → 120.
           (setf (gethash "OTA_ADMIN_READ_TIMEOUT" env) "120")
           (is (= 120 (ota-admin::%resolve-timeout
                       "OTA_ADMIN_READ_TIMEOUT" 600)))
           ;; junk → fallback.
           (setf (gethash "OTA_ADMIN_READ_TIMEOUT" env) "not-a-number")
           (is (= 600 (ota-admin::%resolve-timeout
                       "OTA_ADMIN_READ_TIMEOUT" 600))))
      (setf (symbol-function 'uiop:getenv) orig-getenv))))

(test default-read-timeout-is-not-the-dexador-default
  "+DEFAULT-READ-TIMEOUT-SECONDS+ must be much larger than dexador's
own default (10s) — that's the whole point of this layer."
  (is (> ota-admin::+default-read-timeout-seconds+ 60)
      "expected > 60s, got ~A" ota-admin::+default-read-timeout-seconds+))

(test scheme-swap
  (is (string= "http://x.example.com/y"
               (ota-admin::%swap-scheme "https://x.example.com/y" "http")))
  (is (string= "https://x.example.com:8443"
               (ota-admin::%swap-scheme "http://x.example.com:8443" "https")))
  (is (string= "no-scheme"
               (ota-admin::%swap-scheme "no-scheme" "http"))))

(test base-url
  "Strip the path so suggested OTA_SERVER values are clean."
  (is (string= "https://x.example.com:8443"
               (ota-admin::%base-url "https://x.example.com:8443/v1/admin/software/x/releases")))
  (is (string= "http://x.example.com"
               (ota-admin::%base-url "http://x.example.com/")))
  ;; No path at all -- pass through.
  (is (string= "http://x.example.com:8443"
               (ota-admin::%base-url "http://x.example.com:8443")))
  ;; Bare hostname (no scheme) -- pass through; the cond above
  ;; wouldn't normally invoke %BASE-URL on a non-http URL, but this
  ;; protects against future callers.
  (is (string= "x.example.com"
               (ota-admin::%base-url "x.example.com"))))
