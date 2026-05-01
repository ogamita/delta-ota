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
  tls-key)

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
    ((and (eq method :get) (equal segments '("v1" "admin" "audit")))
     :admin-list-audit)
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
          (t
           (handler-case
               (case route
                 (:health                       (handle-health))
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
                 (:admin-list-audit             (handle-admin-list-audit state env))
                 (:exchange-token               (handle-exchange-token state env))
                 (:events-install               (handle-events-install state env)))
             (error (e)
               (format *error-output* "handler error on ~A: ~A~%" path e)
               (error-response 500 "internal error" (princ-to-string e))))))))))

(defparameter *handler* nil)

(defun start-server (state &key (host "0.0.0.0") (port 8080))
  "Start the HTTP/JSON API.  TLS is opt-in: when both tls-cert and
   tls-key are set on the app state, Woo terminates TLS itself; in
   most deployments TLS is terminated by a reverse proxy and the
   server speaks plain HTTP on the loopback (which keeps the
   sendfile path active)."
  (setf *app* state)
  (let* ((cert (app-state-tls-cert state))
         (key  (app-state-tls-key  state))
         (extra (when (and cert key (probe-file cert) (probe-file key))
                  (list :ssl t :ssl-cert (namestring cert)
                        :ssl-key (namestring key)))))
    (setf *handler*
          (apply #'clack:clackup
                 (make-app state)
                 :server :woo :address host :port port
                 (or extra '()))))
  *handler*)

(defun stop-server (&optional (handler *handler*))
  (when handler (clack:stop handler))
  (setf *handler* nil))
