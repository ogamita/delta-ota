;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.

(defpackage #:ota-admin
  (:use #:cl)
  (:export #:main #:publish #:mint-tokens-from-csv #:version-string))

(in-package #:ota-admin)

;; ---------------------------------------------------------------------------
;; HTTP error friendlification
;; ---------------------------------------------------------------------------
;;
;; Dexador / cl+ssl error messages are precise but unfriendly: an
;; OpenSSL "wrong version number" surfaces as a stack-trace-shaped
;; blob that stumps anyone who hasn't seen it before.  We intercept
;; the most common HTTP/TLS misconfiguration patterns and rewrite
;; them into one sentence the operator can act on.  Unknown errors
;; pass through unchanged.

(defun %http-scheme-of (url)
  "Return :HTTP, :HTTPS, or NIL."
  (cond ((alexandria:starts-with-subseq "https://" url) :https)
        ((alexandria:starts-with-subseq "http://"  url) :http)))

(defun %swap-scheme (url to)
  "Return URL with its scheme replaced by TO (e.g. \"http\")."
  (let ((colon (position #\: url)))
    (if colon
        (concatenate 'string to (subseq url colon))
        url)))

(defun %base-url (url)
  "Return URL truncated at the path component (i.e. just
scheme://host[:port]).  Used so we can suggest a clean OTA_SERVER
value without echoing the request path back at the user."
  (let* ((scheme-end (search "://" url))
         (search-from (if scheme-end (+ scheme-end 3) 0))
         (slash (position #\/ url :start search-from)))
    (if slash (subseq url 0 slash) url)))

(defun %condition-typename (err)
  "Return the package-qualified class name of ERR as a string,
e.g. \"USOCKET:NS-HOST-NOT-FOUND-ERROR\".  Some libraries
(notably USOCKET) signal conditions whose default print form is
just \"Condition USOCKET:FOO-ERROR was signalled.\" — the
diagnostic information lives in the class name, not the printed
message, so we match on both.  Including the package prefix lets
us distinguish a transport-level USOCKET error from any unrelated
symbol that happens to share a short name."
  (let* ((sym (class-name (class-of err)))
         (pkg (symbol-package sym)))
    (if pkg
        (concatenate 'string (package-name pkg) ":" (symbol-name sym))
        (symbol-name sym))))

(defun %friendlier-message (err url)
  "Given an error condition ERR raised while talking to URL, return
a short user-facing string when the error matches a known pattern,
or NIL when we have nothing better to say than the raw message."
  (let ((msg (princ-to-string err))
        (cls (%condition-typename err)))
    (cond
      ;; OpenSSL handshake against a plain-HTTP server: the first
      ;; response bytes are 'HTTP/1.1 ...' (0x48), not a TLS record
      ;; (0x16).  This is the single most common bring-up mistake.
      ((and (eq (%http-scheme-of url) :https)
            (or (search "wrong version number"        msg)
                (search "tls_validate_record_header"  msg)))
       (format nil
               "TLS handshake failed against ~A — the server appears to be ~
                serving plain HTTP, not HTTPS.~%~
                Try OTA_SERVER=~A (no 's'), or configure TLS on the server ~
                ([tls].cert / .key in ota.toml, or OTA_TLS_CERT / OTA_TLS_KEY)."
               (%base-url url)
               (%swap-scheme (%base-url url) "http")))
      ;; cl+ssl complaining about a missing CA / self-signed cert.
      ((and (eq (%http-scheme-of url) :https)
            (or (search "certificate verify failed"   msg)
                (search "self signed certificate"     msg)
                (search "self-signed certificate"     msg)
                (search "unable to get local issuer"  msg)))
       (format nil
               "TLS certificate verification failed against ~A — the ~
                server's certificate is not trusted by this host. Use a ~
                cert from a trusted CA, or install the server's CA into ~
                the system trust store."
               url))
      ;; DNS failures.  Match on substrings AND on usocket class names.
      ((or (search "Name or service not known"  msg)
           (search "nodename nor servname"      msg)
           (search "No such host is known"      msg)
           (search "NS-HOST-NOT-FOUND"          cls)
           (search "NS-NO-RECOVERY"             cls)
           (search "NS-TRY-AGAIN"               cls))
       (format nil
               "could not resolve hostname in ~A. Check OTA_SERVER / ~
                --server and your DNS."
               url))
      ;; Connection-level failures: explicit refusal first.
      ((or (search "Connection refused"      msg)
           (search "ECONNREFUSED"            msg)
           (search "Couldn't connect"        msg)
           (search "CONNECTION-REFUSED"      cls))
       (format nil
               "could not connect to ~A: connection refused. Is the server ~
                running and listening on that host:port?"
               url))
      ;; Any remaining usocket error is almost certainly some other
      ;; transport-level problem (timeout, EINVAL on a privileged port,
      ;; routing failure, …).  Don't try to guess the cause -- just say
      ;; we couldn't reach the URL and pass the underlying class name
      ;; through for debugging.  SEARCH (not STARTS-WITH-SUBSEQ) so we
      ;; also catch test stubs whose package name contains USOCKET.
      ((search "USOCKET" cls)
       (format nil
               "could not reach ~A (~A). Check OTA_SERVER / --server, the ~
                host:port, and your network."
               url cls))
      (t nil))))

(defun %post (url &rest args)
  "Like DEXADOR:POST but rewrites known TLS / connection errors into
clearer one-line messages.  Other errors propagate unchanged."
  (handler-case (apply #'dexador:post url args)
    (error (c)
      (let ((friendly (%friendlier-message c url)))
        (if friendly
            (error friendly)
            (error c))))))

(defun publish (&key dir software version os arch
                     (server "http://127.0.0.1:8080")
                     (token (uiop:getenv "OTA_ADMIN_TOKEN"))
                     (os-versions ""))
  "Tar DIR with the deterministic tar writer, then upload it as a new
   release of SOFTWARE/VERSION on SERVER.  Requires the server's
   admin TOKEN."
  (unless token
    (error "ota-admin publish: OTA_ADMIN_TOKEN env var or :token argument required"))
  (let ((tar-path (merge-pathnames (format nil "~A-~A-publish.tar"
                                           software version)
                                   (uiop:temporary-directory))))
    (ota-server.storage:tar-directory-to-file dir tar-path)
    (let ((bytes (with-open-file (in tar-path
                                     :direction :input
                                     :element-type '(unsigned-byte 8))
                   (let* ((n (file-length in))
                          (buf (make-array n :element-type '(unsigned-byte 8))))
                     (read-sequence buf in)
                     buf))))
      (multiple-value-bind (resp code)
          (%post (format nil "~A/v1/admin/software/~A/releases"
                         server software)
                 :headers (list (cons "Authorization"
                                      (format nil "Bearer ~A" token))
                                (cons "X-Ota-Version" version)
                                (cons "X-Ota-Os" os)
                                (cons "X-Ota-Arch" arch)
                                (cons "X-Ota-Os-Versions" os-versions)
                                (cons "Content-Type" "application/octet-stream"))
                 :content bytes)
        (delete-file tar-path)
        (format t "publish: code=~A body=~A~%" code resp)
        (force-output)
        (unless (= code 201)
          (uiop:quit 1))
        resp))))

(defun parse-ttl (s)
  "Parse a TTL like \"7d\", \"3h\", \"45m\", \"60s\" into seconds."
  (when (zerop (length s)) (return-from parse-ttl nil))
  (let* ((unit (char s (1- (length s))))
         (n (parse-integer s :end (1- (length s)) :junk-allowed t)))
    (case unit
      (#\s n)
      (#\m (* n 60))
      (#\h (* n 3600))
      (#\d (* n 86400))
      (t (parse-integer s)))))

(defun split-csv-line (line)
  (loop with acc = '()
        with start = 0
        for i below (length line)
        when (char= (char line i) #\,)
          do (push (subseq line start i) acc)
             (setf start (1+ i))
        finally (push (subseq line start) acc)
                (return (nreverse acc))))

(defun mint-tokens-from-csv (&key csv classifications (ttl-seconds 604800)
                                  (server "http://127.0.0.1:8080")
                                  (token (uiop:getenv "OTA_ADMIN_TOKEN"))
                                  (output "tokens.tsv"))
  "Read a CSV (one identifier per line, optional second column for
   classifications), mint one install token per line, and write a
   TSV at OUTPUT with columns: identifier, classifications,
   install_token, expires_at, install_url."
  (unless token
    (error "mint-tokens-from-csv: OTA_ADMIN_TOKEN env var or :token argument required"))
  (let ((lines '()))
    (with-open-file (in csv :direction :input)
      (loop for line = (read-line in nil nil) while line
            for s = (string-trim '(#\Space #\Tab #\Return) line)
            when (and (plusp (length s)) (not (char= (char s 0) #\#)))
              do (push s lines)))
    (with-open-file (out output :direction :output :if-exists :supersede)
      (format out "identifier~Cclassifications~Cinstall_token~Cexpires_at~Cinstall_url~%"
              #\Tab #\Tab #\Tab #\Tab)
      (dolist (line (nreverse lines))
        (let* ((cells (split-csv-line line))
               (identifier (first cells))
               (cls-from-csv (second cells))
               (cls (or (and cls-from-csv (split-string cls-from-csv #\;))
                        classifications
                        '("public")))
               (resp (%post
                      (format nil "~A/v1/admin/install-tokens" server)
                      :headers (list (cons "Authorization" (format nil "Bearer ~A" token))
                                     (cons "Content-Type" "application/json"))
                      :content (com.inuoe.jzon:stringify
                                (let ((h (make-hash-table :test 'equal)))
                                  (setf (gethash "classifications" h)
                                        (coerce cls 'vector))
                                  (setf (gethash "ttl_seconds" h) ttl-seconds)
                                  h))))
               (parsed (com.inuoe.jzon:parse resp))
               (tok    (gethash "install_token" parsed))
               (exp    (gethash "expires_at"    parsed))
               (url    (format nil "~A/v1/install/SOFTWARE?token=~A" server tok)))
          (format out "~A~C~{~A~^;~}~C~A~C~A~C~A~%"
                  identifier #\Tab cls #\Tab tok #\Tab exp #\Tab url)
          (format t "minted: ~A~%" identifier))))
    (format t "wrote ~A~%" output)))

(defun split-string (s sep)
  (loop with acc = '()
        with start = 0
        for i below (length s)
        when (char= (char s i) sep)
          do (push (subseq s start i) acc)
             (setf start (1+ i))
        finally (push (subseq s start) acc)
                (return (nreverse acc))))

(defun version-string ()
  "Return the version recorded in ota-admin.asd."
  (or (asdf:component-version (asdf:find-system "ota-admin" nil))
      "unknown"))

(defun usage ()
  (format *error-output*
"ota-admin — Ogamita Delta OTA admin CLI

Usage:
  ota-admin publish <dir> --software=NAME --version=X --os=OS --arch=ARCH
                          [--os-versions=12,13] [--classifications=stable]
                          [--server=URL]

  ota-admin mint-tokens --csv=PATH --classifications=stable [--ttl=7d]
                        [--server=URL] [--output=tokens.tsv]

  ota-admin version       print version and exit
  ota-admin help          print this message and exit

Environment:
  OTA_ADMIN_TOKEN   bearer token for admin auth (required)
  OTA_SERVER        default --server URL
")
  (uiop:quit 2))

(defun get-flag (argv name)
  (loop for a in argv
        when (alexandria:starts-with-subseq (concatenate 'string "--" name "=") a)
          return (subseq a (+ 3 (length name)))
        when (string= a (concatenate 'string "--" name))
          return (let ((rest (cdr (member a argv :test #'string=))))
                   (and rest (first rest)))))

(defun positional-args (argv)
  (loop for a in argv
        unless (alexandria:starts-with-subseq "--" a)
          collect a))

(defun main (&rest argv)
  (let ((argv (or argv (uiop:command-line-arguments))))
    (cond ((or (null argv)
               (member (first argv) '("help" "-h" "--help") :test #'string=))
           (usage))
          ((member (first argv) '("version" "-v" "--version") :test #'string=)
           (format t "ota-admin ~A~%" (version-string))
           (uiop:quit 0))
          ((string= (first argv) "mint-tokens")
           (let ((rest (rest argv)))
             (mint-tokens-from-csv
              :csv (or (get-flag rest "csv")
                       (progn (format *error-output* "missing --csv~%") (uiop:quit 2)))
              :classifications (let ((c (get-flag rest "classifications")))
                                 (when c (split-string c #\,)))
              :ttl-seconds (or (parse-ttl (or (get-flag rest "ttl") "")) 604800)
              :server (or (get-flag rest "server")
                          (uiop:getenv "OTA_SERVER")
                          "http://127.0.0.1:8080")
              :output (or (get-flag rest "output") "tokens.tsv"))))
          ((string= (first argv) "publish")
           (let ((rest (rest argv)))
             (publish :dir (or (first (positional-args rest))
                               (progn (format *error-output* "publish: missing <dir>~%") (uiop:quit 2)))
                      :software    (or (get-flag rest "software")
                                       (progn (format *error-output* "missing --software~%") (uiop:quit 2)))
                      :version     (or (get-flag rest "version")
                                       (progn (format *error-output* "missing --version~%") (uiop:quit 2)))
                      :os          (or (get-flag rest "os")
                                       (progn (format *error-output* "missing --os~%") (uiop:quit 2)))
                      :arch        (or (get-flag rest "arch")
                                       (progn (format *error-output* "missing --arch~%") (uiop:quit 2)))
                      :os-versions (or (get-flag rest "os-versions") "")
                      :server      (or (get-flag rest "server")
                                       (uiop:getenv "OTA_SERVER")
                                       "http://127.0.0.1:8080"))))
          (t (usage)))))
