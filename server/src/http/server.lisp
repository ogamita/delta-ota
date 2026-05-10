;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.
;;;
;;; HTTP/JSON API for the OTA server.  Phase 1: no TLS, no
;;; classifications/channels filtering, single hardcoded admin token.

(in-package #:ota-server.http)

(defstruct app-state
  cas
  catalogue
  keypair
  manifests-dir
  admin-token
  hostname
  ;; phase-4
  (default-client-classifications #("public") :type vector)
  tls-cert
  tls-key
  ;; phase-7-followup: in-memory token-bucket rate limit per identity.
  ;; KEY = client_id|"admin"|"anon-<ip>", VALUE = (cons tokens last-refill).
  (rate-buckets (make-hash-table :test 'equal :synchronized t))
  (rate-capacity 600)              ; tokens
  (rate-refill-per-sec 10)         ; tokens/sec
  ;; v1.2: async patch-build worker pool (workers/pool.lisp).  NIL when
  ;; the legacy synchronous fan-in is wanted (some tests, the e2e
  ;; harness if not yet updated).
  pool)

(defparameter *app* nil)

(defun obj (&rest pairs)
  "Build an ORDERED-OBJECT (see ota-server.manifest) from key-value
   pairs.  Used for every JSON response so that field order is
   deterministic and stable across SBCL hash-table internals."
  (apply #'ota-server.manifest::ordered pairs))

(defun encode-json-string (value)
  (let ((s (make-string-output-stream)))
    (ota-server.manifest::write-json-value value s)
    (get-output-stream-string s)))

(defun json-response (code value &key (extra-headers nil))
  (list code
        (append (list :content-type "application/json; charset=utf-8")
                extra-headers)
        (list (encode-json-string value))))

(defun text-response (code text &key (content-type "text/plain"))
  (list code (list :content-type content-type) (list text)))

(defun error-response (code msg &optional detail)
  (json-response code (obj "error" msg "detail" (or detail ""))))

;; ---------------------------------------------------------------------------
;; NDJSON streaming responses (since v1.1.1).
;;
;; Used by the publish handler when the client opts in via
;; `Accept: application/x-ndjson`.  We hand back a function-shaped
;; clack response (the "lambda-responder" pattern); Woo wraps the
;; socket in a streaming writer and we emit one JSON object per line
;; as work progresses.  The final event is always {"event":"done", …}
;; with the same payload the legacy 201 carries, so simple clients
;; can read just the last line.
;; ---------------------------------------------------------------------------

(defun client-accepts-ndjson-p (env)
  "Return T when the request's Accept header contains
\"application/x-ndjson\".  Match is case-insensitive and substring
(operators commonly send '*/*' or 'application/json' as the primary
preference)."
  (let* ((headers (or (env-get env :headers) (make-hash-table)))
         (accept  (and (hash-table-p headers)
                       (gethash "accept" headers))))
    (and accept
         (search "application/x-ndjson" accept :test #'char-equal))))

(defun %lispy-key-to-json (sym)
  "Convert a Lisp keyword (e.g. :RELEASE-ID) into the project's
JSON-key convention (release_id) -- downcased, hyphens to
underscores.  Matches the OBJ helper used everywhere else in
the HTTP layer."
  (substitute #\_ #\- (string-downcase (symbol-name sym))))

(defun %emit-ndjson-event (writer plist)
  "Render PLIST as a single JSON line (UTF-8) and write it to WRITER.

Keys are converted via %LISPY-KEY-TO-JSON (downcase + hyphens
→ underscores), so :RELEASE-ID becomes the JSON key
\"release_id\" -- consistent with every other server response
shape and with what ota-admin reads for hash-table lookups.

Keyword values like :PATCH-BUILT become lowercased strings
(\"patch-built\") -- they're enum-y, not keys, so we keep the
hyphen for readability."
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k v) on plist by #'cddr
          do (setf (gethash (%lispy-key-to-json k) h)
                   (cond
                     ((keywordp v)        (string-downcase (symbol-name v)))
                     ((eq v t)            t)
                     ((eq v nil)          nil)
                     ((vectorp v)         v)
                     ((listp v)           (coerce v 'vector))
                     (t                   v))))
    (funcall writer
             (concatenate 'string
                          (com.inuoe.jzon:stringify h :pretty nil)
                          (string #\Newline)))))

(defun streaming-ndjson-response (event-builder)
  "Return a clack lambda-responder that opens a 200 chunked NDJSON
stream and runs EVENT-BUILDER with a one-arg `(emit plist)` function.
EVENT-BUILDER must call EMIT for each event including the final
{:event :done …}; its return value is ignored.  The response is
closed automatically when EVENT-BUILDER returns or signals."
  (lambda (responder)
    (let ((writer (funcall responder
                           (list 200
                                 (list :content-type "application/x-ndjson"
                                       :cache-control "no-cache")))))
      (unwind-protect
           (handler-case
               (funcall event-builder
                        (lambda (plist) (%emit-ndjson-event writer plist)))
             (error (c)
               ;; Mid-stream failure: surface it as a final event.
               (handler-case
                   (%emit-ndjson-event
                    writer
                    (list :event :error
                          :message (princ-to-string c)))
                 (error () nil))))
        (funcall writer "" :close t)))))

(defun parse-path (path-info)
  "Split PATH-INFO into segments, dropping empty leading/trailing."
  (let ((parts (uiop:split-string path-info :separator "/")))
    (remove-if (lambda (s) (zerop (length s))) parts)))

(defun match-route (method segments)
  "Return a keyword naming the matched route, plus path-parameter
   bindings as a plist; or NIL if nothing matched."
  (cond
    ((and (eq method :get) (equal segments '("v1" "health")))
     :health)
    ((and (eq method :get) (= 3 (length segments))
          (equal (first segments) "v1") (equal (second segments) "install"))
     (values :install-page (list :software (third segments))))
    ((and (eq method :get) (equal segments '("v1" "software")))
     :list-software)
    ((and (eq method :get) (= 3 (length segments))
          (equal (first segments) "v1") (equal (second segments) "software"))
     (values :get-software (list :software (third segments))))
    ((and (eq method :get) (= 4 (length segments))
          (equal (first segments) "v1") (equal (second segments) "software")
          (equal (fourth segments) "releases"))
     (values :list-releases (list :software (third segments))))
    ((and (eq method :get) (= 5 (length segments))
          (equal (first segments) "v1") (equal (second segments) "software")
          (equal (fourth segments) "releases") (equal (fifth segments) "latest"))
     (values :latest-release (list :software (third segments))))
    ((and (eq method :get) (= 5 (length segments))
          (equal (first segments) "v1") (equal (second segments) "software")
          (equal (fourth segments) "releases"))
     (values :get-release (list :software (third segments) :version (fifth segments))))
    ((and (eq method :get) (= 6 (length segments))
          (equal (first segments) "v1") (equal (second segments) "software")
          (equal (fourth segments) "releases") (equal (sixth segments) "manifest"))
     (values :get-manifest (list :software (third segments) :version (fifth segments))))
    ((and (eq method :get) (= 3 (length segments))
          (equal (first segments) "v1") (equal (second segments) "blobs"))
     (values :get-blob (list :sha256 (third segments))))
    ((and (eq method :get) (= 3 (length segments))
          (equal (first segments) "v1") (equal (second segments) "patches"))
     (values :get-patch (list :sha256 (third segments))))
    ((and (eq method :post) (equal segments '("v1" "admin" "software")))
     :admin-create-software)
    ((and (eq method :post) (= 5 (length segments))
          (equal (first segments) "v1") (equal (second segments) "admin")
          (equal (third segments) "software")
          (equal (fifth segments) "releases"))
     (values :admin-publish-release (list :software (fourth segments))))
    ((and (eq method :post) (equal segments '("v1" "events" "install")))
     :events-install)
    ((and (eq method :post) (equal segments '("v1" "exchange-token")))
     :exchange-token)
    ((and (eq method :post) (equal segments '("v1" "admin" "install-tokens")))
     :admin-mint-install-token)
    ((and (eq method :post) (equal segments '("v1" "admin" "install-tokens" "batch")))
     :admin-mint-install-tokens-batch)
    ((and (eq method :get) (equal segments '("v1" "admin" "audit")))
     :admin-list-audit)
    ((and (eq method :post) (= 5 (length segments))
          (equal (first segments) "v1") (equal (second segments) "admin")
          (equal (third segments) "software") (equal (fifth segments) "gc"))
     (values :admin-gc (list :software (fourth segments))))
    ((and (eq method :post) (equal segments '("v1" "admin" "verify")))
     :admin-verify)
    ((and (eq method :get) (= 4 (length segments))
          (equal (first segments) "v1") (equal (second segments) "software")
          (equal (fourth segments) "anchors"))
     (values :get-anchors (list :software (third segments))))
    ((and (eq method :post) (= 7 (length segments))
          (equal (first segments) "v1") (equal (second segments) "admin")
          (equal (third segments) "software") (equal (fifth segments) "releases")
          (equal (nth 6 segments) "uncollectable"))
     (values :admin-mark-uncollectable
             (list :software (fourth segments) :version (nth 5 segments))))
    ((and (eq method :post) (= 6 (length segments))
          (equal (first segments) "v1") (equal (second segments) "admin")
          (equal (third segments) "software") (equal (fifth segments) "patches")
          (equal (nth 5 segments) "reverse"))
     (values :admin-build-reverse-patch
             (list :software (fourth segments))))
    (t nil)))

(defun bearer-of (env)
  "Pull the Bearer credentials out of the request, regardless of how
   Clack delivered the headers."
  (let* ((headers (getf env :headers))
         (auth (or (header-of headers "authorization")
                   (env-get env :|authorization|))))
    (when (and auth (alexandria:starts-with-subseq "Bearer " auth))
      (subseq auth 7))))

(defun authorised-admin-p (env app)
  (let ((tok (bearer-of env)))
    (and tok (string= tok (app-state-admin-token app)))))

(defun resolve-identity (env app)
  "Return a plist describing the calling identity:
     (:kind :anonymous|:client|:admin
      :classifications #(...)
      :client-id <string-or-nil>)."
  (let ((tok (bearer-of env)))
    (cond
      ((null tok)
       (list :kind :anonymous
             :classifications (app-state-default-client-classifications app)
             :client-id nil))
      ((string= tok (app-state-admin-token app))
       (list :kind :admin
             ;; Admins implicitly see everything: all classifications match.
             :classifications :all
             :client-id "admin"))
      (t
       (let ((c (ota-server.catalogue:get-client-by-token
                 (app-state-catalogue app) tok)))
         (cond (c
                (ota-server.catalogue:touch-client
                 (app-state-catalogue app) (getf c :client-id))
                (list :kind :client
                      :classifications (or (getf c :classifications)
                                           (app-state-default-client-classifications app))
                      :client-id (getf c :client-id)))
               (t
                (list :kind :anonymous
                      :classifications (app-state-default-client-classifications app)
                      :client-id nil))))))))

(defun rate-allow-p (app key)
  "Token-bucket rate limiter, in-memory, per APP-keyed identity.
   Returns T if KEY may make one more request, NIL if rate-limited."
  (let* ((cap (app-state-rate-capacity app))
         (refill (app-state-rate-refill-per-sec app))
         (buckets (app-state-rate-buckets app))
         (now (get-internal-real-time))
         (units internal-time-units-per-second)
         (cell (gethash key buckets)))
    (multiple-value-bind (tokens last)
        (if cell (values (car cell) (cdr cell)) (values cap now))
      (let* ((elapsed-sec (/ (- now last) units))
             (refilled (min cap (+ tokens (* elapsed-sec refill)))))
        (cond ((>= refilled 1)
               (setf (gethash key buckets) (cons (- refilled 1) now))
               t)
              (t
               (setf (gethash key buckets) (cons refilled now))
               nil))))))

(defun rate-limit-key (env identity)
  (or (getf identity :client-id)
      (let ((ra (or (getf env :remote-addr)
                    (and (getf env :headers)
                         (header-of (getf env :headers) "x-forwarded-for")))))
        (concatenate 'string "anon-" (or ra "?")))))

(defun rate-limited-response ()
  (list 429
        (list :content-type "application/json; charset=utf-8"
              :|retry-after| "1")
        (list (encode-json-string (obj "error" "rate limited")))))

(defun classification-match-p (identity-classifications release-classifications)
  "True if the identity is allowed to see the release.  An admin
   (:all) sees everything.  Any other identity must share at least
   one classification with the release.  A release with no
   classifications is treated as 'public' for back-compat."
  (cond ((eq identity-classifications :all) t)
        (t (let ((rcls (if (or (null release-classifications)
                               (zerop (length release-classifications)))
                           #("public")
                           release-classifications)))
             (loop for ic across (or identity-classifications #())
                   thereis (loop for rc across rcls
                                 thereis (string= ic rc)))))))

(defun read-request-body-bytes (env)
  "Read the raw request body into a byte vector."
  (let* ((stream (getf env :raw-body))
         (length (or (getf env :content-length) 0)))
    (when stream
      (let ((buf (make-array length :element-type '(unsigned-byte 8))))
        (read-sequence buf stream)
        buf))))

(defun handle-health ()
  (json-response 200 (obj "status" "ok")))

(defun detect-os (env)
  (let* ((headers (getf env :headers))
         (ua (or (header-of headers "user-agent") "")))
    (cond ((search "Windows" ua) "windows")
          ((or (search "Mac OS" ua) (search "Macintosh" ua)) "macos")
          ((search "Linux" ua) "linux")
          (t "linux"))))

(defun handle-install-page (app env params)
  "A minimal HTML install page.  Detects the OS from the User-Agent,
   tells the user the one-line CLI to run, and offers the agent
   binary download.  An admin must mint and embed the install token
   server-side (or hand-out token URLs from a separate flow) — this
   page itself does not require auth, so it cannot mint tokens."
  (declare (ignore env))
  (let* ((sw (getf params :software))
         (host (or (app-state-hostname app) "localhost")))
    (list 200
          (list :content-type "text/html; charset=utf-8")
          (list (install-page-html sw host)))))

(defun install-page-html (software hostname)
  (format nil "<!DOCTYPE html>
<html><head><meta charset=\"utf-8\">
<title>Install ~A</title>
<style>
body { font-family: -apple-system, BlinkMacSystemFont, sans-serif;
       max-width: 720px; margin: 4rem auto; padding: 0 1rem;
       color: #222; line-height: 1.5; }
h1 { font-size: 1.6rem; }
code { background: #f4f4f4; padding: 0.15rem 0.35rem; border-radius: 3px; }
pre { background: #f4f4f4; padding: 1rem; border-radius: 6px;
      overflow-x: auto; }
.btn { display: inline-block; background: #0a64a4; color: white;
       padding: 0.5rem 1rem; border-radius: 4px; text-decoration: none; }
small { color: #666; }
</style>
</head><body>
<h1>Install ~A</h1>
<p>Welcome.  This page guides you through installing
<strong>~A</strong> on your workstation.</p>

<h2>1. Get the agent</h2>
<p>Download the <code>ota-agent</code> binary for your operating system:</p>
<p><a class=\"btn\" href=\"https://~A/downloads/ota-agent-linux-amd64\">Linux (amd64)</a>
   <a class=\"btn\" href=\"https://~A/downloads/ota-agent-darwin-arm64\">macOS</a>
   <a class=\"btn\" href=\"https://~A/downloads/ota-agent-windows-amd64.exe\">Windows</a></p>

<h2>2. Get an install token</h2>
<p>Your administrator will email you a one-shot install token —
or paste one provided to you below.</p>

<h2>3. Install</h2>
<p>Run the following command, substituting your install token:</p>
<pre>ota-agent install ~A \\
    --server https://~A \\
    --install-token YOUR_TOKEN \\
    --latest</pre>

<p><small>Once the agent is running it will fetch the latest release,
verify the publisher's signature, install the software, and atomically
flip your <code>current</code> pointer.  Every subsequent run upgrades
incrementally — typically a small fraction of the full payload.</small></p>

<hr>
<small>Powered by <a href=\"https://gitlab.com/ogamita/delta-ota\">Ogamita Delta OTA</a> &middot;
<a href=\"https://~A/v1/health\">server health</a></small>
</body></html>~%"
          software software software
          hostname hostname hostname
          software hostname
          hostname))

(defun handle-list-software (app)
  (let ((items (mapcar #'plist-to-json-software
                       (ota-server.catalogue:list-software (app-state-catalogue app)))))
    (json-response 200 (coerce items 'vector))))

(defun plist-to-json-software (sw)
  (obj "name"            (getf sw :name)
       "display_name"    (getf sw :display-name)
       "default_patcher" (getf sw :default-patcher)
       "created_at"      (getf sw :created-at)))

(defun plist-to-json-release (r app)
  (declare (ignore app))
  (obj "release_id"       (getf r :release-id)
       "software"         (getf r :software)
       "os"               (getf r :os)
       "arch"             (getf r :arch)
       "os_versions"      (getf r :os-versions)
       "version"          (getf r :version)
       "blob_sha256"      (getf r :blob-sha256)
       "blob_size"        (getf r :blob-size)
       "manifest_sha256"  (getf r :manifest-sha256)
       "signed_manifest_url"
       (format nil "/v1/software/~A/releases/~A/manifest"
               (getf r :software) (getf r :version))
       "channels"         (getf r :channels)
       "classifications"  (getf r :classifications)
       "uncollectable"    (if (getf r :uncollectable) t nil)
       "deprecated"       (if (getf r :deprecated) t nil)
       "published_at"     (getf r :published-at)
       "published_by"     (or (getf r :published-by) "")
       "notes"            (or (getf r :notes) "")))

(defun handle-get-software (app params)
  (let ((sw (ota-server.catalogue:get-software
             (app-state-catalogue app) (getf params :software))))
    (if sw
        (json-response 200 (plist-to-json-software sw))
        (error-response 404 "software not found"))))

(defun visible-release-p (identity rel)
  (classification-match-p (getf identity :classifications)
                          (getf rel :classifications)))

(defun handle-list-releases (app env params)
  (let* ((id (resolve-identity env app))
         (rs (remove-if-not
              (lambda (r) (visible-release-p id r))
              (ota-server.catalogue:list-releases
               (app-state-catalogue app) (getf params :software)))))
    (json-response 200
                   (coerce (mapcar (lambda (r) (plist-to-json-release r app)) rs)
                           'vector))))

(defun handle-latest-release (app env params)
  (let* ((id (resolve-identity env app))
         ;; Latest visible release: walk releases newest-first and return
         ;; the first one the identity may see.
         (rs (ota-server.catalogue:list-releases
              (app-state-catalogue app) (getf params :software)))
         (vis (find-if (lambda (r) (visible-release-p id r)) rs)))
    (if vis
        (json-response 200 (plist-to-json-release vis app))
        (error-response 404 "no release"))))

(defun handle-get-release (app env params)
  (let* ((id (resolve-identity env app))
         (r (ota-server.catalogue:get-release
             (app-state-catalogue app)
             (getf params :software) (getf params :version))))
    (cond ((null r) (error-response 404 "release not found"))
          ((not (visible-release-p id r)) (error-response 404 "release not found"))
          (t (json-response 200 (plist-to-json-release r app))))))

(defun handle-get-manifest (app env params)
  "Return the signed manifest JSON, with the signature in the
   X-Ota-Signature header (hex-encoded Ed25519)."
  (let* ((id (resolve-identity env app))
         (rel (ota-server.catalogue:get-release
               (app-state-catalogue app)
               (getf params :software) (getf params :version)))
         (dir (app-state-manifests-dir app))
         (path (merge-pathnames
                (format nil "~A/~A.json"
                        (getf params :software) (getf params :version))
                dir))
         (sig-path (merge-pathnames
                    (format nil "~A/~A.sig"
                            (getf params :software) (getf params :version))
                    dir)))
    (cond ((or (null rel) (not (visible-release-p id rel)))
           (error-response 404 "manifest not found"))
          ((not (probe-file path))
           (error-response 404 "manifest not found"))
          (t
           (let ((sig (read-bytes sig-path)))
             (list 200
                   (list :content-type "application/json; charset=utf-8"
                         :|x-ota-signature| (ironclad:byte-array-to-hex-string sig)
                         :|x-ota-public-key| (ota-server.manifest:keypair-public-hex
                                              (app-state-keypair app)))
                   path))))))

(defun read-bytes (path)
  (with-open-file (in path :direction :input :element-type '(unsigned-byte 8))
    (let* ((n (file-length in))
           (buf (make-array n :element-type '(unsigned-byte 8))))
      (read-sequence buf in)
      buf)))

(defun handle-get-blob (app env params)
  (let ((path (ota-server.storage:cas-blob-path
               (app-state-cas app) (getf params :sha256))))
    (serve-file-with-optional-range path env "blob not found")))

(defun handle-get-patch (app env params)
  (let ((path (ota-server.storage:cas-patch-path
               (app-state-cas app) (getf params :sha256))))
    (serve-file-with-optional-range path env "patch not found")))

;; ---------------------------------------------------------------------------
;; HTTP Range support (since v1.3) for /v1/blobs/<sha> and /v1/patches/<sha>.
;;
;; Why: a 2 GB initial install over a flaky link used to throw away the
;; whole transfer on every disconnect (the client deleted the .part
;; file).  v1.3 keeps the .part across attempts and resumes via
;; `Range: bytes=N-`.  Server-side we honour the request and reply
;; `206 Partial Content` with the requested slice; full-file responses
;; advertise `Accept-Ranges: bytes` so clients know the option exists.
;;
;; Full requests (no Range header) keep the v1.0–v1.2 sendfile(2) fast
;; path — the kernel ships the file from disk to socket without bytes
;; ever touching SBCL.  Partial requests use a userspace
;; lambda-responder loop, which is the price of supporting resume; in
;; practice partial requests are rare (only after a failed transfer)
;; and a 64 KB read+write per chunk is bounded by network bandwidth
;; anyway.
;;
;; See ADR-0008 for the design and what was rejected (e.g. patching
;; Woo for sendfile-with-offset).
;; ---------------------------------------------------------------------------

(defun serve-file-with-optional-range (path env not-found-msg)
  "Serve PATH, honouring `Range:` when present.  Falls back to a
sendfile(2) full-content response when Range is absent.  Returns the
clack response triple (or a lambda-responder for the streaming
partial path)."
  (let ((real (and path (probe-file path))))
    (cond
      ((null real)
       (error-response 404 not-found-msg))
      (t
       (let* ((headers (env-get env :headers))
              (range-hdr (and (hash-table-p headers)
                              (gethash "range" headers))))
         (cond
           ((null range-hdr)
            ;; Full content, sendfile fast path.  Advertise Accept-Ranges
            ;; so the client knows it can resume on a subsequent attempt.
            ;; Content-Length is set by Woo from the file's stat()
            ;; -- duplicating it here yields two headers which some
            ;; clients (dexador, curl --fail-with-body) trip over.
            (list 200
                  (list :content-type "application/octet-stream"
                        :|accept-ranges| "bytes")
                  real))
           (t
            (serve-file-range real range-hdr))))))))

(defun file-byte-length (path)
  (with-open-file (in path :direction :input :element-type '(unsigned-byte 8))
    (file-length in)))

(defun parse-range-header (range-header total-size)
  "Parse a single-range `Range: bytes=N-[M]` or `bytes=-K` header
against a file of TOTAL-SIZE bytes.  Returns (values START END) where
both are inclusive byte offsets clamped to [0, TOTAL-SIZE-1], or NIL
when the header is malformed or unsatisfiable.

We only accept the `bytes=` unit and a single range -- multi-range
(`bytes=0-99,200-299`) is uncommon in practice and would require
multipart/byteranges responses, which add complexity for no win on
our use case (the client always asks for one open-ended `N-` to
resume)."
  (block parse
    (unless (and range-header
                 (>= (length range-header) 7)
                 (string-equal "bytes=" (subseq range-header 0 6)))
      (return-from parse nil))
    (let* ((spec (subseq range-header 6))
           (dash (position #\- spec))
           (comma (position #\, spec)))
      (when (or (null dash) comma)
        (return-from parse nil))
      (let ((before (string-trim " " (subseq spec 0 dash)))
            (after  (string-trim " " (subseq spec (1+ dash)))))
        (handler-case
            (cond
              ;; `-K` (suffix range): last K bytes.
              ((and (zerop (length before)) (plusp (length after)))
               (let* ((k (parse-integer after))
                      (start (max 0 (- total-size k))))
                 (when (and (plusp total-size) (plusp k))
                   (values start (1- total-size)))))
              ;; `N-` (open-ended) or `N-M`.
              ((plusp (length before))
               (let* ((start (parse-integer before))
                      (end   (cond
                               ((zerop (length after)) (1- total-size))
                               (t (parse-integer after)))))
                 (cond
                   ;; Out of range entirely -> 416 (caller maps NIL).
                   ((or (< start 0) (>= start total-size)) nil)
                   ;; Clamp end to file size.
                   (t (values start (min end (1- total-size))))))))
          (error () nil))))))

(defparameter *range-chunk-size* 65536
  "Chunk size for streaming partial-content responses.  64 KB matches
the client's read buffer and keeps per-chunk overhead small relative
to the network write cost.")

(defun serve-file-range (path range-header)
  "Stream a 206 Partial Content response covering the byte slice
requested by RANGE-HEADER.  On a malformed or unsatisfiable range,
reply 416 with `Content-Range: bytes */SIZE` per RFC 7233."
  (let* ((total (file-byte-length path)))
    (multiple-value-bind (start end) (parse-range-header range-header total)
      (cond
        ((null start)
         (list 416
               (list :content-type "text/plain"
                     :|content-range| (format nil "bytes */~D" total)
                     :|accept-ranges| "bytes")
               (list "requested range not satisfiable")))
        (t
         (let ((length (1+ (- end start))))
           (lambda (responder)
             ;; Note: Woo will use Transfer-Encoding: chunked for the
             ;; lambda-responder body and adding a fixed Content-Length
             ;; here would conflict (HTTP forbids both).  The client
             ;; learns the slice length from Content-Range's "N-M/T".
             (let ((writer (funcall responder
                                    (list 206
                                          (list :content-type "application/octet-stream"
                                                :|content-range| (format nil "bytes ~D-~D/~D"
                                                                         start end total)
                                                :|accept-ranges| "bytes")))))
               (unwind-protect
                    (with-open-file (in path :direction :input
                                             :element-type '(unsigned-byte 8))
                      (file-position in start)
                      (let ((buf (make-array *range-chunk-size*
                                             :element-type '(unsigned-byte 8)))
                            (remaining length))
                        (loop while (plusp remaining)
                              for to-read = (min *range-chunk-size* remaining)
                              for n = (read-sequence buf in :end to-read)
                              while (plusp n) do
                                (funcall writer
                                         (if (= n (length buf))
                                             buf
                                             (subseq buf 0 n)))
                                (decf remaining n))))
                 (funcall writer "" :close t))))))))))

(defun handle-admin-create-software (app env)
  (unless (authorised-admin-p env app)
    (return-from handle-admin-create-software (error-response 401 "unauthorised")))
  (let* ((body (read-request-body-bytes env))
         (json (and body (com.inuoe.jzon:parse
                          (sb-ext:octets-to-string body :external-format :utf-8))))
         (name (gethash "name" json))
         (display (gethash "display_name" json)))
    (cond ((or (null name) (zerop (length name)))
           (error-response 400 "missing name"))
          (t
           (ota-server.catalogue:ensure-software
            (app-state-catalogue app)
            :name name
            :display-name (or display name))
           (ota-server.catalogue:append-audit
            (app-state-catalogue app)
            :identity "admin" :action "create-software" :target name :detail nil)
           (json-response 201 (obj "name" name "display_name" (or display name)))))))

(defun %publish-finalize-and-emit (app emit &key software os arch version release-id
                                                 osversions sha size manifest-bytes
                                                 manifest-sha sig notes)
  "Post-INSERT-RELEASE-IF-NEW work: write manifest to disk, append
audit, enqueue patch jobs, tail them to emit per-patch progress, and
re-sign the manifest with `patches_in` once they are all done.

v1.2 architecture: the bsdiff invocations themselves run in the async
worker pool (workers/pool.lisp), not in this thread — we just enqueue
N jobs and watch the catalogue for completion.  When the pool is NIL
(some tests / out-of-tree callers), we fall back to the legacy
synchronous fan-in via BUILD-PATCHES-FOR-RELEASE.

Called only when the row was newly inserted (the :inserted branch of
the publish handler) — so we never touch disk for an idempotent
re-publish or a 409 conflict.

EMIT is a one-arg function called with a plist per event."
  (let ((mdir (app-state-manifests-dir app)))
    (ensure-directories-exist (merge-pathnames (format nil "~A/" software) mdir))
    (write-bytes (merge-pathnames (format nil "~A/~A.json" software version) mdir)
                 manifest-bytes)
    (write-bytes (merge-pathnames (format nil "~A/~A.sig"  software version) mdir)
                 sig)
    (ota-server.catalogue:append-audit
     (app-state-catalogue app)
     :identity "admin" :action "publish-release"
     :target release-id
     :detail (format nil "blob=~A size=~A" sha size))
    (funcall emit (list :event :stored
                        :release-id release-id
                        :blob-sha256 sha :blob-size size
                        :manifest-sha256 manifest-sha))
    ;; Patch fan-in.  Two paths:
    ;;   - Pool present (production): enqueue N jobs and tail the
    ;;     PATCH_JOBS table for completion events.
    ;;   - Pool absent (legacy / some tests): run synchronously inline.
    ;; Failures don't roll back the publish: the full blob is always
    ;; available as fallback.
    (let* ((patches-in
             (handler-case
                 (cond
                   ((app-state-pool app)
                    (%fan-in-via-pool app emit
                                      :software software :os os :arch arch
                                      :version version :release-id release-id
                                      :new-blob-sha sha))
                   (t
                    (%fan-in-synchronous app emit
                                         :software software :os os :arch arch
                                         :version version :release-id release-id
                                         :new-blob-sha sha)))
               (error (e)
                 (format *error-output* "publish: patch build failed: ~A~%" e)
                 nil)))
           (final-manifest-sha manifest-sha))
      (when patches-in
        (let* ((mp (ota-server.manifest:build-manifest-plist
                    :software software :os os :arch arch
                    :os-versions osversions :version version
                    :blob-sha256 sha :blob-size size
                    :blob-url (format nil "/v1/blobs/~A" sha)
                    :notes notes
                    :patches-in patches-in))
               (mb (ota-server.manifest:manifest-to-json-bytes mp))
               (sig2 (ota-server.manifest:sign-bytes
                      mb
                      (ota-server.manifest:keypair-private (app-state-keypair app))
                      (ota-server.manifest:keypair-public  (app-state-keypair app)))))
          (write-bytes (merge-pathnames (format nil "~A/~A.json" software version)
                                        (app-state-manifests-dir app))
                       mb)
          (write-bytes (merge-pathnames (format nil "~A/~A.sig"  software version)
                                        (app-state-manifests-dir app))
                       sig2)
          (setf final-manifest-sha (ota-server.storage:sha256-hex-of-bytes mb))
          (funcall emit (list :event :manifest-resigned
                              :manifest-sha256 final-manifest-sha
                              :patches-built (length patches-in)))))
      (funcall emit (list :event :done
                          :release-id release-id
                          :blob-sha256 sha :blob-size size
                          :manifest-sha256 final-manifest-sha
                          :patches-built (length patches-in))))))

(defun %fan-in-synchronous (app emit &key software os arch version
                                          release-id new-blob-sha)
  "Legacy v1.0–v1.1 path: bsdiff runs inline in this thread."
  (let ((built (ota-server.workers:build-patches-for-release
                (app-state-cas app)
                (app-state-catalogue app)
                :software software :os os :arch arch
                :new-version version
                :new-release-id release-id
                :new-blob-sha new-blob-sha
                :on-progress emit)))
    built))

(defparameter *publish-tail-poll-secs* 0.2
  "How often the publish handler queries the catalogue for patch-job
completion when streaming progress to the client.  Smaller =
snappier progress events at the cost of more SQLite reads; this
value is fast enough that the user-visible UX matches the v1.1.1
inline-callback path.")

(defun %fan-in-via-pool (app emit &key software os arch version
                                       release-id new-blob-sha)
  "v1.2 path: enqueue one job per prior release, then tail the
PATCH_JOBS table for state transitions and emit per-patch events.
Returns the patches_in list (only successful jobs) when all jobs
have reached a terminal state."
  (let* ((catalogue (app-state-catalogue app))
         (enqueued (ota-server.workers:enqueue-patches-for-release
                    catalogue
                    :software software :os os :arch arch
                    :new-version version
                    :new-release-id release-id
                    :new-blob-sha new-blob-sha))
         (total (length enqueued)))
    (when (plusp total)
      (funcall emit (list :event :patches-started :total total))
      (ota-server.workers:notify-patch-pool (app-state-pool app)))
    (cond
      ((zerop total) nil)
      (t
       (%tail-patch-jobs app emit
                         :release-id release-id
                         :total total)))))

(defun %tail-patch-jobs (app emit &key release-id total)
  "Poll PATCH_JOBS for RELEASE-ID until all rows are in a terminal
state (done|failed), emitting :patch-built events for each fresh
completion (in the order the jobs were enqueued).  Returns the list
of plists for the successful patches, ready to be embedded as the
manifest's `patches_in`."
  (let ((catalogue (app-state-catalogue app))
        (seen     (make-hash-table :test 'eql))
        (i 0))
    (loop
      (let* ((rows (ota-server.catalogue:list-patch-jobs-for-release
                    catalogue release-id))
             (still-pending 0))
        (dolist (job rows)
          (let ((id     (getf job :id))
                (status (getf job :status)))
            (cond
              ((or (string= status "pending") (string= status "running"))
               (incf still-pending))
              ((gethash id seen) nil)
              (t
               ;; First time we see this job in a terminal state.
               (setf (gethash id seen) t)
               (incf i)
               (cond
                 ((string= status "done")
                  (funcall emit
                           (list :event :patch-built
                                 :i i :total total
                                 :from (getf job :from-version)
                                 :sha  (getf job :patch-sha256)
                                 :size (getf job :patch-size))))
                 (t
                  (funcall emit
                           (list :event :patch-failed
                                 :i i :total total
                                 :from (getf job :from-version)
                                 :error (or (getf job :error) "unknown")))))))))
        (when (zerop still-pending)
          (let ((built '()))
            (dolist (job rows)
              (when (string= (getf job :status) "done")
                (push (list :from (getf job :from-version)
                            :sha256 (getf job :patch-sha256)
                            :size   (getf job :patch-size)
                            :patcher (getf job :patcher))
                      built)))
            (funcall emit (list :event :patches-done :built (length built)))
            (return-from %tail-patch-jobs (nreverse built))))
        (sleep *publish-tail-poll-secs*)))))

(defun handle-admin-publish-release (app env params)
  "Single-blob uploader: request body is the binary blob, metadata in
X-Ota-* headers.  Idempotent on (software, os, arch, version):
same blob → 200 with idempotent:true; different blob → 409 Conflict.
For new releases, the response is either:

  - the legacy 201 + JSON body (default), or
  - a 200 chunked NDJSON stream of progress events (since v1.1.1)
    when the client opts in via Accept: application/x-ndjson.

The final NDJSON line is {:event :done …} carrying the same
payload as the legacy 201 body, so simple consumers can ignore
the intermediate events and parse only the last line.

v1.1.1 hardening (see ADR-0006): the lookup-and-insert decision
runs through INSERT-RELEASE-IF-NEW which wraps a `BEGIN
IMMEDIATE` transaction around both, so two ota-server processes
attempting the same publish concurrently see one win and the
other hit the :existing branch deterministically -- no
SQLITE_CONSTRAINT 500 races.  Manifest .json/.sig only land on
disk for the :inserted branch; idempotent + conflict cases never
overwrite an existing manifest with one for a different blob."
  (unless (authorised-admin-p env app)
    (return-from handle-admin-publish-release (error-response 401 "unauthorised")))
  (let* ((software (getf params :software))
         (headers (getf env :headers))
         (version  (header-of headers "x-ota-version"))
         (os       (header-of headers "x-ota-os"))
         (arch     (header-of headers "x-ota-arch"))
         (osvers (or (header-of headers "x-ota-os-versions") ""))
         (notes  (or (header-of headers "x-ota-notes") "")))
    (when (or (null version) (null os) (null arch))
      (return-from handle-admin-publish-release
        (error-response 400 "missing X-Ota-Version / X-Ota-Os / X-Ota-Arch")))
    (ota-server.catalogue:ensure-software
     (app-state-catalogue app) :name software)
    (let* ((tmp-path (write-body-to-tmp env (app-state-cas app))))
      (multiple-value-bind (sha size)
          (ota-server.storage:put-blob-from-file (app-state-cas app) tmp-path)
        (let* ((release-id     (format nil "~A/~A-~A/~A" software os arch version))
               (osversions     (parse-csv osvers))
               (classifications (parse-csv (or (header-of headers "x-ota-classifications") "")))
               (channels        (parse-csv (or (header-of headers "x-ota-channels") "")))
               ;; Build the manifest fully in memory before talking
               ;; to the catalogue.  We need its SHA to insert; we
               ;; only commit it to disk on :inserted (so a 409
               ;; conflict NEVER overwrites the existing manifest
               ;; for a different blob).
               (manifest-plist
                 (ota-server.manifest:build-manifest-plist
                  :software software :os os :arch arch
                  :os-versions osversions :version version
                  :blob-sha256 sha :blob-size size
                  :blob-url (format nil "/v1/blobs/~A" sha)
                  :notes notes))
               (manifest-bytes (ota-server.manifest:manifest-to-json-bytes manifest-plist))
               (manifest-sha   (ota-server.storage:sha256-hex-of-bytes manifest-bytes))
               (sig (ota-server.manifest:sign-bytes
                     manifest-bytes
                     (ota-server.manifest:keypair-private (app-state-keypair app))
                     (ota-server.manifest:keypair-public  (app-state-keypair app)))))
          (multiple-value-bind (status existing)
              (ota-server.catalogue:insert-release-if-new
               (app-state-catalogue app)
               :release-id release-id
               :software software :os os :arch arch
               :os-versions osversions
               :version version
               :blob-sha256 sha :blob-size size
               :manifest-sha256 manifest-sha
               :classifications classifications
               :channels        channels
               :notes notes)
            (case status
              (:existing
               (cond
                 ;; Same blob → idempotent re-publish.
                 ((string= (getf existing :blob-sha256) sha)
                  (let ((patches-in (ota-server.catalogue:list-patches-to
                                     (app-state-catalogue app)
                                     (getf existing :release-id))))
                    (json-response 200
                                   (obj "release_id"      (getf existing :release-id)
                                        "blob_sha256"     (getf existing :blob-sha256)
                                        "blob_size"       (getf existing :blob-size)
                                        "manifest_sha256" (getf existing :manifest-sha256)
                                        "patches_built"   (length patches-in)
                                        "idempotent"      t))))
                 ;; Different blob, same version → conflict.
                 (t
                  (error-response 409
                                  "release already exists with different content"
                                  (format nil
                                          "version ~A of ~A/~A-~A is published with blob ~A; ~
                                           the upload's blob is ~A. Bump the version, or delete the existing release first."
                                          version software os arch
                                          (getf existing :blob-sha256) sha)))))
              (:inserted
               ;; New release.  Now (and only now) write the
               ;; manifest to disk + audit + run patch fan-in.
               (let ((work
                       (lambda (emit)
                         (%publish-finalize-and-emit
                          app emit
                          :software software :os os :arch arch
                          :version version :release-id release-id
                          :osversions osversions
                          :sha sha :size size
                          :manifest-bytes manifest-bytes
                          :manifest-sha manifest-sha
                          :sig sig
                          :notes notes))))
                 (cond
                   ((client-accepts-ndjson-p env)
                    (streaming-ndjson-response work))
                   (t
                    (let (final)
                      (funcall work (lambda (e)
                                      (when (eq (getf e :event) :done)
                                        (setf final e))))
                      (json-response 201
                                     (obj "release_id"      (getf final :release-id)
                                          "blob_sha256"     (getf final :blob-sha256)
                                          "blob_size"       (getf final :blob-size)
                                          "manifest_sha256" (getf final :manifest-sha256)
                                          "patches_built"   (getf final :patches-built)))))))))))))))

(defun write-body-to-tmp (env cas)
  "Stream the request body into a temp file under the CAS."
  (let* ((tmp-dir (merge-pathnames "tmp/" (ota-server.storage:cas-root cas)))
         (path (merge-pathnames (format nil "upload-~A.tmp"
                                        (random (expt 2 32)))
                                tmp-dir))
         (stream (getf env :raw-body))
         (length (or (getf env :content-length) 0)))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output
                              :if-exists :supersede
                              :if-does-not-exist :create
                              :element-type '(unsigned-byte 8))
      (let ((buf (make-array 65536 :element-type '(unsigned-byte 8))))
        (loop with remaining = length
              while (plusp remaining)
              for n = (read-sequence buf stream :end (min 65536 remaining))
              do (write-sequence buf out :end n)
                 (decf remaining n)
                 (when (zerop n) (return)))))
    path))

(defun write-bytes (path bytes)
  (with-open-file (out path :direction :output
                            :if-exists :supersede
                            :if-does-not-exist :create
                            :element-type '(unsigned-byte 8))
    (write-sequence bytes out)))

(defun header-of (headers name)
  (or (and (hash-table-p headers) (gethash name headers))
      (and (listp headers) (cdr (assoc name headers :test #'string-equal)))))

(defun parse-csv (s)
  (if (zerop (length s))
      (vector)
      (coerce (mapcar (lambda (x) (string-trim '(#\Space) x))
                      (uiop:split-string s :separator ","))
              'vector)))

(defun handle-exchange-token (app env)
  "Trade a one-shot install token for a per-client bearer token.
   Body: { \"install_token\": \"...\", \"hwinfo\": \"...\" }."
  (let* ((body (read-request-body-bytes env))
         (json (and body (ignore-errors
                           (com.inuoe.jzon:parse
                            (sb-ext:octets-to-string body :external-format :utf-8)))))
         (token (and (hash-table-p json) (gethash "install_token" json)))
         (hwinfo (and (hash-table-p json) (gethash "hwinfo" json))))
    (cond
      ((or (null token) (zerop (length token)))
       (error-response 400 "missing install_token"))
      (t
       (let ((classifications
               (ota-server.catalogue:claim-install-token
                (app-state-catalogue app) token)))
         (cond
           ((null classifications)
            (error-response 401 "invalid or expired install_token"))
           (t
            (multiple-value-bind (cid bearer)
                (ota-server.catalogue:create-client
                 (app-state-catalogue app)
                 :classifications classifications
                 :hwinfo hwinfo)
              (ota-server.catalogue:append-audit
               (app-state-catalogue app)
               :identity cid :action "exchange-token"
               :target nil :detail (format nil "hwinfo=~A" (or hwinfo "")))
              (json-response 200
                             (obj "client_id"     cid
                                  "bearer_token"  bearer
                                  "classifications"
                                  (coerce classifications 'vector)))))))))))

(defun handle-admin-mint-install-token (app env)
  (unless (authorised-admin-p env app)
    (return-from handle-admin-mint-install-token (error-response 401 "unauthorised")))
  (let* ((body (read-request-body-bytes env))
         (json (and body (ignore-errors
                           (com.inuoe.jzon:parse
                            (sb-ext:octets-to-string body :external-format :utf-8)))))
         (cls (and (hash-table-p json) (gethash "classifications" json)))
         (ttl (or (and (hash-table-p json) (gethash "ttl_seconds" json))
                  900)))
    (multiple-value-bind (token expires)
        (ota-server.catalogue:mint-install-token
         (app-state-catalogue app)
         :classifications (or cls #("public"))
         :ttl-seconds ttl
         :created-by "admin")
      (ota-server.catalogue:append-audit
       (app-state-catalogue app)
       :identity "admin" :action "mint-install-token"
       :target nil :detail (format nil "ttl=~A" ttl))
      (json-response 201 (obj "install_token" token "expires_at" expires)))))

(defparameter *batch-mint-cap* 10000
  "Hard ceiling on the number of tokens a single batch call may
   mint, to keep the server's audit log and DB write path sane.")

(defun handle-admin-mint-install-tokens-batch (app env)
  (unless (authorised-admin-p env app)
    (return-from handle-admin-mint-install-tokens-batch (error-response 401 "unauthorised")))
  (let* ((body (read-request-body-bytes env))
         (json (and body (ignore-errors
                           (com.inuoe.jzon:parse
                            (sb-ext:octets-to-string body :external-format :utf-8)))))
         (count (or (and (hash-table-p json) (gethash "count" json)) 1))
         (cls (or (and (hash-table-p json) (gethash "classifications" json))
                  #("public")))
         (ttl (or (and (hash-table-p json) (gethash "ttl_seconds" json)) 604800)))
    (cond
      ((or (not (integerp count)) (< count 1))
       (error-response 400 "count must be a positive integer"))
      ((> count *batch-mint-cap*)
       (error-response 400 (format nil "count exceeds cap of ~A" *batch-mint-cap*)))
      (t
       (let ((tokens (loop repeat count collect
                           (multiple-value-bind (token expires)
                               (ota-server.catalogue:mint-install-token
                                (app-state-catalogue app)
                                :classifications cls
                                :ttl-seconds ttl
                                :created-by "admin")
                             (obj "install_token" token "expires_at" expires)))))
         (ota-server.catalogue:append-audit
          (app-state-catalogue app)
          :identity "admin" :action "mint-install-tokens-batch"
          :target nil :detail (format nil "count=~A ttl=~A" count ttl))
         (json-response 201
                        (obj "count"  count
                             "tokens" (coerce tokens 'vector))))))))

(defun handle-admin-list-audit (app env)
  (unless (authorised-admin-p env app)
    (return-from handle-admin-list-audit (error-response 401 "unauthorised")))
  (let ((rows (ota-server.catalogue:list-audit (app-state-catalogue app))))
    (json-response 200
                   (coerce
                    (mapcar
                     (lambda (r)
                       (obj "id" (getf r :id)
                            "identity" (getf r :identity)
                            "action" (getf r :action)
                            "target" (or (getf r :target) "")
                            "detail" (or (getf r :detail) "")
                            "at" (getf r :at)))
                     rows)
                    'vector))))

(defun handle-admin-build-reverse-patch (app env params)
  "Build an on-demand reverse patch from `from`->`to` (where `from`
   is the newer version), useful for the recovery tool to
   downgrade with bandwidth savings.  Body: {from: ver, to: ver}."
  (unless (authorised-admin-p env app)
    (return-from handle-admin-build-reverse-patch (error-response 401 "unauthorised")))
  (let* ((body (read-request-body-bytes env))
         (json (and body (ignore-errors
                           (com.inuoe.jzon:parse
                            (sb-ext:octets-to-string body :external-format :utf-8)))))
         (from-v (and (hash-table-p json) (gethash "from" json)))
         (to-v   (and (hash-table-p json) (gethash "to"   json)))
         (sw     (getf params :software)))
    (cond
      ((or (null from-v) (null to-v))
       (error-response 400 "both 'from' and 'to' versions required"))
      (t
       (let ((from-rel (ota-server.catalogue:get-release
                        (app-state-catalogue app) sw from-v))
             (to-rel   (ota-server.catalogue:get-release
                        (app-state-catalogue app) sw to-v)))
         (cond
           ((or (null from-rel) (null to-rel))
            (error-response 404 "release(s) not found"))
           (t
            (multiple-value-bind (sha size)
                (ota-server.workers:build-patch-from-blobs
                 (app-state-cas app) (app-state-catalogue app)
                 :from-release-id (getf from-rel :release-id)
                 :to-release-id   (getf to-rel   :release-id)
                 :from-blob-sha   (getf from-rel :blob-sha256)
                 :to-blob-sha     (getf to-rel   :blob-sha256))
              (ota-server.catalogue:append-audit
               (app-state-catalogue app)
               :identity "admin" :action "build-reverse-patch"
               :target (format nil "~A->~A" from-v to-v)
               :detail (format nil "size=~A" size))
              (json-response 201
                             (obj "from"    from-v
                                  "to"      to-v
                                  "patcher" "bsdiff"
                                  "sha256"  sha
                                  "size"    size
                                  "url"     (format nil "/v1/patches/~A" sha)))))))))))

(defun handle-admin-mark-uncollectable (app env params)
  (unless (authorised-admin-p env app)
    (return-from handle-admin-mark-uncollectable (error-response 401 "unauthorised")))
  (ota-server.catalogue:mark-uncollectable
   (app-state-catalogue app)
   (getf params :software) (getf params :version))
  (ota-server.catalogue:append-audit
   (app-state-catalogue app)
   :identity "admin" :action "mark-uncollectable"
   :target (format nil "~A/~A" (getf params :software) (getf params :version))
   :detail nil)
  (json-response 200 (obj "software" (getf params :software)
                          "version"  (getf params :version)
                          "uncollectable" t)))

(defun handle-get-anchors (app env params)
  "Return server-curated 'known-good' versions for the recovery
   tool.  v1 policy: every release marked uncollectable, plus the
   latest in each channel — filtered by the caller's
   classifications.  Newest first."
  (let* ((id (resolve-identity env app))
         (rels (remove-if-not
                (lambda (r) (visible-release-p id r))
                (ota-server.catalogue:list-releases
                 (app-state-catalogue app) (getf params :software))))
         (anchors '()))
    ;; Anchor: every uncollectable release.
    (dolist (r rels)
      (when (getf r :uncollectable)
        (push (anchor-of r "uncollectable") anchors)))
    ;; Anchor: the latest visible release (skip if already added as
    ;; uncollectable).
    (when (first rels)
      (let ((latest (first rels)))
        (unless (find (getf latest :release-id) anchors
                      :key #'anchor-release-id :test #'string=)
          (push (anchor-of latest "latest") anchors))))
    (json-response 200
                   (coerce (nreverse anchors) 'vector))))

(defun anchor-of (rel reason)
  (obj "version"     (getf rel :version)
       "release_id"  (getf rel :release-id)
       "channel"     (let ((cs (getf rel :channels)))
                       (if (and cs (plusp (length cs)))
                           (aref cs 0) ""))
       "reason"      reason
       "blob_size"   (getf rel :blob-size)))

(defun anchor-release-id (anchor)
  "Pull the 'release_id' field out of an anchor ordered-object."
  (let ((pairs (ota-server.manifest::ordered-object-pairs anchor)))
    (loop for pair across pairs
          when (string= (car pair) "release_id")
            return (cdr pair))))

(defun handle-admin-gc (app env params)
  (unless (authorised-admin-p env app)
    (return-from handle-admin-gc (error-response 401 "unauthorised")))
  (let* ((body (read-request-body-bytes env))
         (json (and body (ignore-errors
                           (com.inuoe.jzon:parse
                            (sb-ext:octets-to-string body :external-format :utf-8)))))
         (dry-run (and (hash-table-p json) (gethash "dry_run" json)))
         (min-users (or (and (hash-table-p json) (gethash "min_user_count" json)) 0))
         (min-age   (or (and (hash-table-p json) (gethash "min_age_days"   json)) 30))
         (result (ota-server.workers:gc-software
                  (app-state-cas app)
                  (app-state-catalogue app)
                  (app-state-keypair app)
                  (app-state-manifests-dir app)
                  :software (getf params :software)
                  :min-user-count min-users
                  :min-age-days min-age
                  :dry-run dry-run)))
    (ota-server.catalogue:append-audit
     (app-state-catalogue app)
     :identity "admin" :action "gc"
     :target (getf params :software)
     :detail (format nil "pruned=~A dry_run=~A"
                     (length (getf result :pruned)) (getf result :dry-run)))
    (json-response 200
                   (obj "software" (getf params :software)
                        "pruned"   (coerce (getf result :pruned) 'vector)
                        "dry_run"  (if (getf result :dry-run) t nil)))))

(defun handle-admin-verify (app env)
  (unless (authorised-admin-p env app)
    (return-from handle-admin-verify (error-response 401 "unauthorised")))
  (let ((r (ota-server.workers:verify-storage (app-state-cas app))))
    (ota-server.catalogue:append-audit
     (app-state-catalogue app)
     :identity "admin" :action "verify-storage"
     :target nil
     :detail (format nil "checked=~A ok=~A bad=~A"
                     (getf r :checked) (getf r :ok) (length (getf r :bad))))
    (json-response 200
                   (obj "checked" (getf r :checked)
                        "ok"      (getf r :ok)
                        "bad"     (coerce
                                   (mapcar (lambda (entry)
                                             (obj "path" (first entry)
                                                  "actual" (second entry)
                                                  "expected" (third entry)))
                                           (getf r :bad))
                                   'vector)))))

(defun handle-events-install (app env)
  "Best-effort install-event recorder. Always 204 even on parse error."
  (let* ((body (read-request-body-bytes env))
         (json (and body (ignore-errors
                           (com.inuoe.jzon:parse
                            (sb-ext:octets-to-string body :external-format :utf-8))))))
    (when (hash-table-p json)
      (handler-case
          (ota-server.catalogue:record-install-event
           (app-state-catalogue app)
           :client-id (or (gethash "client_id" json) "anonymous")
           :software (gethash "software" json)
           :release-id (gethash "release_id" json)
           :kind (or (gethash "kind" json) "install")
           :from-release-id (gethash "from_release_id" json)
           :status (or (gethash "status" json) "ok")
           :error (gethash "error" json))
        (error (e) (format *error-output* "events: ~A~%" e))))
    (list 204 nil nil)))

(defun env-get (env key)
  "Clack env may be plist or hash-table depending on adapter."
  (cond ((listp env) (getf env key))
        ((hash-table-p env) (gethash key env))
        (t nil)))

(defun method-keyword (env)
  (let ((m (env-get env :request-method)))
    (cond ((null m) :unknown)
          ((symbolp m) m)
          (t (intern (string-upcase (string m)) :keyword)))))

(defun make-app (state)
  (lambda (env)
    (let* ((path (env-get env :path-info))
           (segments (parse-path path))
           (method (method-keyword env)))
      (multiple-value-bind (route params) (match-route method segments)
        (cond
          ((null route) (error-response 404 "no such route" path))
          ((and (not (eq route :health))
                (not (rate-allow-p state
                                   (rate-limit-key
                                    env (resolve-identity env state)))))
           (rate-limited-response))
          (t
           (handler-case
               (case route
                 (:health                       (handle-health))
                 (:install-page                 (handle-install-page state env params))
                 (:list-software                (handle-list-software state))
                 (:get-software                 (handle-get-software state params))
                 (:list-releases                (handle-list-releases state env params))
                 (:latest-release               (handle-latest-release state env params))
                 (:get-release                  (handle-get-release state env params))
                 (:get-manifest                 (handle-get-manifest state env params))
                 (:get-blob                     (handle-get-blob state env params))
                 (:get-patch                    (handle-get-patch state env params))
                 (:admin-create-software        (handle-admin-create-software state env))
                 (:admin-publish-release        (handle-admin-publish-release state env params))
                 (:admin-mint-install-token     (handle-admin-mint-install-token state env))
                 (:admin-mint-install-tokens-batch (handle-admin-mint-install-tokens-batch state env))
                 (:admin-list-audit             (handle-admin-list-audit state env))
                 (:admin-gc                     (handle-admin-gc state env params))
                 (:admin-verify                 (handle-admin-verify state env))
                 (:get-anchors                  (handle-get-anchors state env params))
                 (:admin-mark-uncollectable     (handle-admin-mark-uncollectable state env params))
                 (:admin-build-reverse-patch    (handle-admin-build-reverse-patch state env params))
                 (:exchange-token               (handle-exchange-token state env))
                 (:events-install               (handle-events-install state env)))
             (error (e)
               (format *error-output* "handler error on ~A: ~A~%" path e)
               (error-response 500 "internal error" (princ-to-string e))))))))))

(defparameter *handler* nil)

(defun start-server (state &key (host "0.0.0.0") (port 8080) (worker-num 4))
  "Start the HTTP/JSON API.

WORKER-NUM is forwarded to Woo as :worker-num — it spawns that many
worker threads, each running its own libev loop and sharing the
listening socket.  Without this, a single slow handler (e.g. the
synchronous bsdiff patch build during publish) would wedge the
event loop and time out every concurrent request.  4 is a sane
default for evaluation; tune via [server].worker_num.

TLS is opt-in: when both tls-cert and tls-key are set on the app
state, Woo terminates TLS itself; in most deployments TLS is
terminated by a reverse proxy and the server speaks plain HTTP on
the loopback (which keeps the sendfile path active)."
  (setf *app* state)
  (let* ((cert (app-state-tls-cert state))
         (key  (app-state-tls-key  state))
         (tls (when (and cert key (probe-file cert) (probe-file key))
                (list :ssl t :ssl-cert (namestring cert)
                      :ssl-key (namestring key))))
         (workers (when (and worker-num (integerp worker-num) (plusp worker-num))
                    (list :worker-num worker-num))))
    (setf *handler*
          (apply #'clack:clackup
                 (make-app state)
                 :server :woo :address host :port port
                 (append tls workers))))
  *handler*)

(defun stop-server (&optional (handler *handler*))
  (when handler (clack:stop handler))
  (setf *handler* nil))
