;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.
;;;
;;; v1.4: admin identity (cert-subject) + per-endpoint rate limits.
;;;
;;; The interesting cases live in ADMIN-IDENTITY (which the macro
;;; WITH-ADMIN-IDENTITY composes into every admin handler) and in
;;; APP-EFFECTIVE-RATE-LIMITS + RATE-ALLOW-P (per-route caps).
;;; These tests pin the decision matrix:
;;;
;;;   bearer? cert?     mtls? subj-allowed?   -> result
;;;   ------- --------- ----- --------------- --------
;;;   absent  any       any   any             -> 401
;;;   wrong   any       any   any             -> 401
;;;   ok      absent    no    -               -> ok "admin"
;;;   ok      absent    yes   -               -> 403 "client cert required"
;;;   ok      present   any   yes             -> ok subject
;;;   ok      present   any   no              -> 403 "subject not authorised"
;;;   ok      empty-hdr any   any             -> treated as absent
;;;
;;; The header is read only when TRUST-PROXY-SUBJECT-HEADER is T;
;;; otherwise a forged subject from a misconfigured deployment is
;;; silently ignored (so the v1.3 codepath is reachable even when
;;; the operator hasn't yet flipped the knob).

(in-package #:ota-server.tests)

(def-suite ota-server-admin-identity
  :description "v1.4 admin cert-subject identity + per-endpoint rate limits."
  :in ota-server-suite)

(in-suite ota-server-admin-identity)

;; ---------------------------------------------------------------------------
;; Test fixtures
;; ---------------------------------------------------------------------------

(defun make-test-state (&key (admin-token "T")
                             (trust-proxy-subject-header nil)
                             (admin-subjects nil)
                             (require-mtls nil)
                             (proxy-subject-header-name "x-ota-client-cert-subject")
                             (rate-limits-override nil)
                             (rate-capacity 600)
                             (rate-refill-per-sec 10))
  "Minimal app-state for testing the auth + rate-limit logic in
isolation -- no CAS, no catalogue, no Woo.  Fills the slots
ADMIN-IDENTITY and RATE-ALLOW-P actually read."
  (ota-server.http::make-app-state
   :admin-token admin-token
   :trust-proxy-subject-header trust-proxy-subject-header
   :proxy-subject-header-name proxy-subject-header-name
   :admin-subjects admin-subjects
   :require-mtls require-mtls
   :rate-limits-override rate-limits-override
   :rate-capacity rate-capacity
   :rate-refill-per-sec rate-refill-per-sec))

(defun env-with-headers (alist)
  "Build a minimal Clack env containing only the request headers
(case-insensitive, matching Woo's lowercased intake)."
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k . v) in alist do
      (setf (gethash (string-downcase k) h) v))
    (list :headers h :remote-addr "10.0.0.1")))

;; ---------------------------------------------------------------------------
;; ADMIN-IDENTITY decision matrix
;; ---------------------------------------------------------------------------

(test admin-identity-401-when-no-bearer
  "No Authorization header -> 401, regardless of cert state."
  (let ((app (make-test-state)))
    (multiple-value-bind (status code)
        (ota-server.http::admin-identity (env-with-headers nil) app)
      (is (eq :reject status))
      (is (= 401 code)))))

(test admin-identity-401-when-wrong-bearer
  "Wrong bearer -> 401, even if the cert subject is allowed."
  (let ((app (make-test-state :trust-proxy-subject-header t
                              :admin-subjects '("CN=alice"))))
    (multiple-value-bind (status code)
        (ota-server.http::admin-identity
         (env-with-headers '(("Authorization" . "Bearer WRONG")
                             ("X-Ota-Client-Cert-Subject" . "CN=alice")))
         app)
      (is (eq :reject status))
      (is (= 401 code)))))

(test admin-identity-ok-bearer-only-when-not-mtls
  "Bearer alone is sufficient when require-mtls is off and there's
no allowlist -- preserves v1.3 behaviour exactly."
  (let ((app (make-test-state)))
    (multiple-value-bind (status identity)
        (ota-server.http::admin-identity
         (env-with-headers '(("Authorization" . "Bearer T")))
         app)
      (is (eq :ok status))
      (is (string= "admin" identity)))))

(test admin-identity-403-when-mtls-required-no-cert
  "require-mtls + correct bearer + no cert -> 403."
  (let ((app (make-test-state :require-mtls t
                              :trust-proxy-subject-header t)))
    (multiple-value-bind (status code msg)
        (ota-server.http::admin-identity
         (env-with-headers '(("Authorization" . "Bearer T")))
         app)
      (is (eq :reject status))
      (is (= 403 code))
      (is (search "cert" msg)))))

(test admin-identity-ignores-header-when-trust-knob-off
  "Without TRUST-PROXY-SUBJECT-HEADER, a header from a forged
upstream is ignored entirely.  With require-mtls on, this should
end up 403 even though the request carries a 'cert' -- because
we are configured not to trust it."
  (let ((app (make-test-state :require-mtls t
                              :trust-proxy-subject-header nil)))
    (multiple-value-bind (status code)
        (ota-server.http::admin-identity
         (env-with-headers '(("Authorization" . "Bearer T")
                             ("X-Ota-Client-Cert-Subject" . "CN=evil")))
         app)
      (is (eq :reject status))
      (is (= 403 code)))))

(test admin-identity-uses-subject-when-trusted-and-allowed
  "Trusted header + subject on the allowlist -> :ok with subject
as the audit-log identity (instead of generic 'admin')."
  (let ((app (make-test-state :trust-proxy-subject-header t
                              :admin-subjects '("CN=alice" "CN=bob"))))
    (multiple-value-bind (status identity)
        (ota-server.http::admin-identity
         (env-with-headers '(("Authorization" . "Bearer T")
                             ("X-Ota-Client-Cert-Subject" . "CN=alice")))
         app)
      (is (eq :ok status))
      (is (string= "CN=alice" identity)
          "audit identity should be the subject, got ~S" identity))))

(test admin-identity-403-when-subject-not-allowed
  "Trusted header but subject not on allowlist -> 403.  Defense
in depth: leaked bearer alone isn't enough."
  (let ((app (make-test-state :trust-proxy-subject-header t
                              :admin-subjects '("CN=alice"))))
    (multiple-value-bind (status code msg)
        (ota-server.http::admin-identity
         (env-with-headers '(("Authorization" . "Bearer T")
                             ("X-Ota-Client-Cert-Subject" . "CN=eve")))
         app)
      (is (eq :reject status))
      (is (= 403 code))
      (is (search "subject" msg)))))

(test admin-identity-empty-allowlist-records-subject-but-doesnt-gate
  "Empty allowlist + trusted subject -> :ok with subject recorded.
Useful when an operator wants the audit-log identity without yet
turning on strict allowlist enforcement."
  (let ((app (make-test-state :trust-proxy-subject-header t
                              :admin-subjects nil)))
    (multiple-value-bind (status identity)
        (ota-server.http::admin-identity
         (env-with-headers '(("Authorization" . "Bearer T")
                             ("X-Ota-Client-Cert-Subject" . "CN=alice")))
         app)
      (is (eq :ok status))
      (is (string= "CN=alice" identity)))))

(test admin-identity-custom-header-name-honoured
  "Operators with nginx emitting X-Client-DN can point our header
knob there instead of using our canonical name."
  (let ((app (make-test-state :trust-proxy-subject-header t
                              :proxy-subject-header-name "x-client-dn"
                              :admin-subjects '("CN=alice"))))
    (multiple-value-bind (status identity)
        (ota-server.http::admin-identity
         (env-with-headers '(("Authorization" . "Bearer T")
                             ("X-Client-DN" . "CN=alice")))
         app)
      (is (eq :ok status))
      (is (string= "CN=alice" identity)))))

;; ---------------------------------------------------------------------------
;; Per-endpoint rate limits
;; ---------------------------------------------------------------------------

(test rate-limits-default-budget-for-unlisted-route
  "A route NOT in *admin-rate-limits* and not overridden uses the
per-app default capacity.  We exhaust by consuming `capacity`
tokens; the next call is denied."
  (let* ((app (make-test-state :rate-capacity 5 :rate-refill-per-sec 0))
         (key (cons "id" :latest-release)))
    (loop for i from 1 to 5 do
      (is (ota-server.http::rate-allow-p app key :latest-release)
          "request ~D of 5 should pass" i))
    (is (not (ota-server.http::rate-allow-p app key :latest-release))
        "request 6 should be rate-limited")))

(test rate-limits-admin-route-uses-tight-builtin-cap
  "Without operator override, :admin-publish-release gets the
built-in 10-token cap -- exhausting it does NOT consume the
generic per-app budget."
  (let* ((app (make-test-state :rate-capacity 600 :rate-refill-per-sec 0))
         (publish-key (cons "id" :admin-publish-release))
         (read-key    (cons "id" :latest-release)))
    ;; Use up the admin route's tighter bucket.
    (loop for i from 1 to 10 do
      (is (ota-server.http::rate-allow-p app publish-key :admin-publish-release)))
    (is (not (ota-server.http::rate-allow-p app publish-key :admin-publish-release))
        "11th publish should be rate-limited")
    ;; Generic read path is unaffected.
    (is (ota-server.http::rate-allow-p app read-key :latest-release)
        "read path's separate bucket must NOT be consumed by admin throttling")))

(test rate-limits-operator-override-wins
  "[rate_limits].admin-publish-release = '3/0.5' caps that route
at 3 tokens / refilling at 0.5/sec, overriding the built-in
10-token default."
  (let* ((app (make-test-state
               :rate-limits-override (list :admin-publish-release (cons 3 1/2))))
         (key (cons "id" :admin-publish-release)))
    (loop for i from 1 to 3 do
      (is (ota-server.http::rate-allow-p app key :admin-publish-release)))
    (is (not (ota-server.http::rate-allow-p app key :admin-publish-release))
        "4th call must be denied under the override")))

(test rate-limits-keyed-on-identity-and-route-together
  "Two identities hitting the same admin endpoint must not share
the same bucket -- otherwise one operator's burst would starve
another."
  (let* ((app (make-test-state))
         (alice (cons "alice" :admin-publish-release))
         (bob   (cons "bob"   :admin-publish-release)))
    (loop for i from 1 to 10 do
      (is (ota-server.http::rate-allow-p app alice :admin-publish-release)))
    (is (not (ota-server.http::rate-allow-p app alice :admin-publish-release)))
    ;; Bob's bucket is independent.
    (is (ota-server.http::rate-allow-p app bob :admin-publish-release)
        "second identity should have its own bucket")))

(test rate-limit-key-includes-route
  "Sanity check that RATE-LIMIT-KEY is route-aware so the
dispatcher's call site produces distinct buckets per endpoint."
  (let ((env   (env-with-headers nil))
        (id    (list :kind :admin :client-id "admin")))
    (let ((k1 (ota-server.http::rate-limit-key env id :admin-publish-release))
          (k2 (ota-server.http::rate-limit-key env id :latest-release)))
      (is (not (equal k1 k2))
          "two routes must produce distinct bucket keys, got ~S vs ~S" k1 k2))))
