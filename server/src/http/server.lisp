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
  (rate-refill-per-sec 10))        ; tokens/sec

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

(defun handle-get-blob (app params)
  (let ((path (ota-server.storage:cas-blob-path
               (app-state-cas app) (getf params :sha256))))
    (cond ((not (probe-file path))
           (error-response 404 "blob not found"))
          (t
           ;; Returning a pathname tells Woo to use sendfile(2).
           (list 200
                 (list :content-type "application/octet-stream")
                 (probe-file path))))))

(defun handle-get-patch (app params)
  (let ((path (ota-server.storage:cas-patch-path
               (app-state-cas app) (getf params :sha256))))
    (cond ((not (probe-file path))
           (error-response 404 "patch not found"))
          (t
           (list 200
                 (list :content-type "application/octet-stream")
                 (probe-file path))))))

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

(defun handle-admin-publish-release (app env params)
  "Phase-1 simple uploader: a single binary blob is the request body,
   metadata is in headers (X-Ota-Version, X-Ota-Os, X-Ota-Arch,
   X-Ota-Os-Versions). Multipart support comes later."
  (unless (authorised-admin-p env app)
    (return-from handle-admin-publish-release (error-response 401 "unauthorised")))
  (let* ((software (getf params :software))
         (headers (getf env :headers))
         (version  (header-of headers "x-ota-version"))
         (os       (header-of headers "x-ota-os"))
         (arch     (header-of headers "x-ota-arch"))
         (osvers (or (header-of headers "x-ota-os-versions") ""))
         (notes  (or (header-of headers "x-ota-notes") "")))
    (cond
      ((or (null version) (null os) (null arch))
       (error-response 400 "missing X-Ota-Version / X-Ota-Os / X-Ota-Arch"))
      (t
       (ota-server.catalogue:ensure-software
        (app-state-catalogue app) :name software)
       (let* ((tmp-path (write-body-to-tmp env (app-state-cas app))))
         (multiple-value-bind (sha size)
             (ota-server.storage:put-blob-from-file (app-state-cas app) tmp-path)
           (let* ((release-id (format nil "~A/~A-~A/~A" software os arch version))
                  (osversions (parse-csv osvers))
                  (manifest-plist
                    (ota-server.manifest:build-manifest-plist
                     :software software :os os :arch arch
                     :os-versions osversions :version version
                     :blob-sha256 sha :blob-size size
                     :blob-url (format nil "/v1/blobs/~A" sha)
                     :notes notes))
                  (manifest-bytes (ota-server.manifest:manifest-to-json-bytes manifest-plist))
                  (manifest-sha (ota-server.storage:sha256-hex-of-bytes manifest-bytes))
                  (sig (ota-server.manifest:sign-bytes
                        manifest-bytes
                        (ota-server.manifest:keypair-private (app-state-keypair app))
                        (ota-server.manifest:keypair-public  (app-state-keypair app))))
                  (mdir (app-state-manifests-dir app)))
             (ensure-directories-exist
              (merge-pathnames (format nil "~A/" software) mdir))
             (write-bytes (merge-pathnames
                           (format nil "~A/~A.json" software version) mdir)
                          manifest-bytes)
             (write-bytes (merge-pathnames
                           (format nil "~A/~A.sig" software version) mdir)
                          sig)
             (ota-server.catalogue:insert-release
              (app-state-catalogue app)
              :release-id release-id
              :software software :os os :arch arch
              :os-versions osversions
              :version version
              :blob-sha256 sha :blob-size size
              :manifest-sha256 manifest-sha
              :classifications (parse-csv (or (header-of headers "x-ota-classifications") ""))
              :channels        (parse-csv (or (header-of headers "x-ota-channels") ""))
              :notes notes)
             (ota-server.catalogue:append-audit
              (app-state-catalogue app)
              :identity "admin" :action "publish-release"
              :target release-id
              :detail (format nil "blob=~A size=~A" sha size))
             ;; Build patches from every prior release of the same
             ;; (software, os, arch) to this new release, then
             ;; re-render the manifest with patches_in populated and
             ;; re-sign.  Failures here do not roll back the publish:
             ;; the full blob is always available as fallback.
             (let* ((built (handler-case
                               (ota-server.workers:build-patches-for-release
                                (app-state-cas app)
                                (app-state-catalogue app)
                                :software software :os os :arch arch
                                :new-version version
                                :new-release-id release-id
                                :new-blob-sha sha)
                             (error (e)
                               (format *error-output* "publish: patch build failed: ~A~%" e)
                               nil)))
                    (patches-in built))
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
                   (write-bytes (merge-pathnames
                                 (format nil "~A/~A.json" software version)
                                 (app-state-manifests-dir app))
                                mb)
                   (write-bytes (merge-pathnames
                                 (format nil "~A/~A.sig" software version)
                                 (app-state-manifests-dir app))
                                sig2)))
               (json-response 201
                              (obj "release_id" release-id
                                   "blob_sha256" sha
                                   "blob_size" size
                                   "manifest_sha256" manifest-sha
                                   "patches_built" (length patches-in)))))))))))

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
                 (:get-blob                     (handle-get-blob state params))
                 (:get-patch                    (handle-get-patch state params))
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
