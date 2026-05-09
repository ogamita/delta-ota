;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.

(defpackage #:ota-admin
  (:use #:cl)
  (:export #:main #:publish #:mint-tokens-from-csv #:version-string))

(in-package #:ota-admin)

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
          (dexador:post (format nil "~A/v1/admin/software/~A/releases"
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
               (resp (dexador:post
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
