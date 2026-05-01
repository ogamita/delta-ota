;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.
;;;
;;; Direct SQLite catalogue access via cl-sqlite (Quicklisp: sqlite).
;;; Phase-1 keeps this single-host; the cl-dbi indirection comes back
;;; in phase 5 when PostgreSQL joins.

(in-package #:ota-server.catalogue)

(defun open-catalogue (db-path)
  (ensure-directories-exist db-path)
  (sqlite:connect (namestring db-path)))

(defun close-catalogue (db)
  (sqlite:disconnect db))

(defun read-migration-file (relative-path)
  (let* ((here (asdf:system-source-directory "ota-server"))
         (path (merge-pathnames relative-path here)))
    (with-open-file (in path :direction :input :external-format :utf-8)
      (with-output-to-string (out)
        (loop for line = (read-line in nil nil)
              while line do (write-line line out))))))

(defun run-migrations (db)
  "Apply all schema migrations idempotently."
  (dolist (mig '("src/catalogue/migrations/0001_init.sql"
                 "src/catalogue/migrations/0002_patches.sql"
                 "src/catalogue/migrations/0003_auth.sql"))
    (dolist (stmt (split-statements (read-migration-file mig)))
      (let ((trimmed (string-trim '(#\Space #\Tab #\Newline #\Return) stmt)))
        (when (plusp (length trimmed))
          (sqlite:execute-non-query db trimmed))))))

(defun split-statements (sql)
  "Split a SQL string at top-level semicolons.  Good enough for our
   migrations (no semicolons inside strings or quoted identifiers)."
  (let ((statements '())
        (start 0))
    (dotimes (i (length sql))
      (when (char= (char sql i) #\;)
        (push (subseq sql start i) statements)
        (setf start (1+ i))))
    (let ((tail (subseq sql start)))
      (when (some (lambda (c) (not (member c '(#\Space #\Tab #\Newline #\Return))))
                  tail)
        (push tail statements)))
    (nreverse statements)))

(defun ensure-software (db &key name display-name (default-patcher "bsdiff"))
  (sqlite:execute-non-query
   db
   "INSERT OR IGNORE INTO software (name, display_name, default_patcher, created_at) VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))"
   name (or display-name name) default-patcher))

(defun row-to-software (row)
  (destructuring-bind (name display-name default-patcher created-at) row
    (list :name name :display-name display-name
          :default-patcher default-patcher :created-at created-at)))

(defun list-software (db)
  (mapcar #'row-to-software
          (sqlite:execute-to-list
           db "SELECT name, display_name, default_patcher, created_at FROM software ORDER BY name")))

(defun get-software (db name)
  (let ((rows (sqlite:execute-to-list
               db "SELECT name, display_name, default_patcher, created_at FROM software WHERE name = ?"
               name)))
    (when rows (row-to-software (first rows)))))

(defun row-to-release (row)
  (destructuring-bind (release-id software os arch os-versions version
                       blob-sha blob-size manifest-sha
                       channels classifications uncollectable deprecated
                       published-at published-by notes)
      row
    (list :release-id release-id
          :software software :os os :arch arch
          :os-versions (com.inuoe.jzon:parse os-versions)
          :version version
          :blob-sha256 blob-sha :blob-size blob-size
          :manifest-sha256 manifest-sha
          :channels (com.inuoe.jzon:parse channels)
          :classifications (com.inuoe.jzon:parse classifications)
          :uncollectable (not (zerop uncollectable))
          :deprecated (not (zerop deprecated))
          :published-at published-at
          :published-by published-by
          :notes notes)))

(defparameter *release-columns*
  "release_id, software_name, os, arch, os_versions, version, blob_sha256, blob_size, manifest_sha256, channels, classifications, uncollectable, deprecated, published_at, published_by, notes")

(defun insert-release (db &key release-id software os arch os-versions version
                              blob-sha256 blob-size manifest-sha256
                              (channels #()) (classifications #())
                              uncollectable deprecated
                              published-by notes)
  (sqlite:execute-non-query
   db
   (format nil "INSERT INTO releases (~A) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), ?, ?)"
           *release-columns*)
   release-id software os arch
   (com.inuoe.jzon:stringify os-versions :pretty nil)
   version blob-sha256 blob-size manifest-sha256
   (com.inuoe.jzon:stringify channels :pretty nil)
   (com.inuoe.jzon:stringify classifications :pretty nil)
   (if uncollectable 1 0)
   (if deprecated    1 0)
   published-by
   (or notes "")))

(defun list-releases (db software-name)
  (mapcar #'row-to-release
          (sqlite:execute-to-list
           db
           (format nil "SELECT ~A FROM releases WHERE software_name = ? ORDER BY published_at DESC"
                   *release-columns*)
           software-name)))

(defun get-release (db software-name version)
  (let ((rows (sqlite:execute-to-list
               db
               (format nil "SELECT ~A FROM releases WHERE software_name = ? AND version = ?"
                       *release-columns*)
               software-name version)))
    (when rows (row-to-release (first rows)))))

(defun get-latest-release (db software-name)
  (let ((rows (sqlite:execute-to-list
               db
               (format nil "SELECT ~A FROM releases WHERE software_name = ? ORDER BY published_at DESC LIMIT 1"
                       *release-columns*)
               software-name)))
    (when rows (row-to-release (first rows)))))

(defun insert-patch (db &key sha256 from-release-id to-release-id patcher size)
  (sqlite:execute-non-query
   db
   "INSERT OR REPLACE INTO patches (sha256, from_release_id, to_release_id, patcher, size, built_at) VALUES (?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))"
   sha256 from-release-id to-release-id patcher size))

(defun list-patches-to (db to-release-id)
  "Return list of plists describing every patch ending at TO-RELEASE-ID."
  (mapcar (lambda (row)
            (destructuring-bind (sha from-id to-id patcher size built-at) row
              (list :sha256 sha :from-release-id from-id :to-release-id to-id
                    :patcher patcher :size size :built-at built-at)))
          (sqlite:execute-to-list
           db
           "SELECT sha256, from_release_id, to_release_id, patcher, size, built_at FROM patches WHERE to_release_id = ? ORDER BY size ASC"
           to-release-id)))

(defun record-install-event (db &key client-id software release-id kind
                                     from-release-id status error)
  (sqlite:execute-non-query
   db
   "INSERT INTO install_events (client_id, software_name, release_id, kind, from_release_id, status, error, at) VALUES (?, ?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))"
   client-id software release-id (string-downcase (string kind))
   from-release-id (string-downcase (string status)) error))

;; ---------------- Phase-4 auth ----------------

(defun random-hex (n)
  "Return 2*N hex chars of cryptographic randomness."
  (let ((bytes (make-array n :element-type '(unsigned-byte 8))))
    (loop for i below n
          do (setf (aref bytes i)
                   (ldb (byte 8 0) (ironclad:strong-random 256))))
    (ironclad:byte-array-to-hex-string bytes)))

(defun mint-install-token (db &key (classifications #("public")) (ttl-seconds 900) created-by)
  "Generate a one-shot install token; return (values token expires-at)."
  (let* ((token (random-hex 24))
         (expires (universal-to-iso8601
                   (+ (get-universal-time) ttl-seconds))))
    (sqlite:execute-non-query
     db
     "INSERT INTO install_tokens (token, classifications, expires_at, created_by, created_at) VALUES (?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))"
     token
     (com.inuoe.jzon:stringify (coerce classifications 'vector) :pretty nil)
     expires
     (or created-by "admin"))
    (values token expires)))

(defun universal-to-iso8601 (univ)
  (multiple-value-bind (s m h d mo y) (decode-universal-time univ 0)
    (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ" y mo d h m s)))

(defun claim-install-token (db token)
  "Mark an install token as used (one-shot).  Returns the token's
   classifications as a vector, or NIL if the token is unknown,
   already used, or expired."
  (let ((row (first (sqlite:execute-to-list
                     db
                     "SELECT classifications, expires_at, used_at FROM install_tokens WHERE token = ?"
                     token))))
    (when row
      (destructuring-bind (cls expires used) row
        (when (and (null used)
                   (string< (universal-to-iso8601 (get-universal-time)) expires))
          (sqlite:execute-non-query
           db
           "UPDATE install_tokens SET used_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE token = ?"
           token)
          (com.inuoe.jzon:parse cls))))))

(defun create-client (db &key classifications hwinfo cert-subject)
  "Create a new client row; return (values client-id bearer-token)."
  (let ((client-id (concatenate 'string "c-" (random-hex 8)))
        (bearer    (random-hex 32)))
    (sqlite:execute-non-query
     db
     "INSERT INTO clients (client_id, bearer_token, classifications, hwinfo, cert_subject, created_at, last_seen_at) VALUES (?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))"
     client-id bearer
     (com.inuoe.jzon:stringify (or classifications #("public")) :pretty nil)
     hwinfo cert-subject)
    (values client-id bearer)))

(defun get-client-by-token (db bearer-token)
  (let ((row (first (sqlite:execute-to-list
                     db
                     "SELECT client_id, classifications, cert_subject FROM clients WHERE bearer_token = ?"
                     bearer-token))))
    (when row
      (destructuring-bind (client-id cls cert) row
        (list :client-id client-id
              :classifications (com.inuoe.jzon:parse cls)
              :cert-subject cert)))))

(defun touch-client (db client-id)
  (sqlite:execute-non-query
   db
   "UPDATE clients SET last_seen_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE client_id = ?"
   client-id))

(defun append-audit (db &key identity action target detail)
  (sqlite:execute-non-query
   db
   "INSERT INTO audit_log (identity, action, target, detail, at) VALUES (?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))"
   identity action target detail))

;; ---------------- Phase-5 operations ----------------

(defun count-users-at-release (db software-name release-id &key (window-days 180))
  "Number of distinct clients whose latest successful install_event
   for SOFTWARE-NAME points at RELEASE-ID and is within the recency
   window. Approximate by design (uninstalls aren't reported)."
  (let* ((cutoff-univ (- (get-universal-time)
                         (* window-days 86400)))
         (cutoff-iso (universal-to-iso8601 cutoff-univ))
         (rows (sqlite:execute-to-list
                db
                "SELECT COUNT(DISTINCT client_id)
                   FROM install_events
                  WHERE software_name = ?
                    AND release_id    = ?
                    AND status        = 'ok'
                    AND at           >= ?"
                software-name release-id cutoff-iso)))
    (or (caar rows) 0)))

(defun count-releases-using-blob (db blob-sha256)
  "How many releases reference this blob hash."
  (caar (sqlite:execute-to-list
         db "SELECT COUNT(*) FROM releases WHERE blob_sha256 = ?"
         blob-sha256)))

(defun list-patches-by-from-or-to (db release-id)
  (mapcar (lambda (row)
            (destructuring-bind (sha from-id to-id patcher size) row
              (list :sha256 sha :from-release-id from-id
                    :to-release-id to-id :patcher patcher :size size)))
          (sqlite:execute-to-list
           db
           "SELECT sha256, from_release_id, to_release_id, patcher, size
              FROM patches
             WHERE from_release_id = ? OR to_release_id = ?"
           release-id release-id)))

(defun delete-patches-touching (db release-id)
  (sqlite:execute-non-query
   db "DELETE FROM patches WHERE from_release_id = ? OR to_release_id = ?"
   release-id release-id))

(defun delete-release (db software-name version)
  (sqlite:execute-non-query
   db "DELETE FROM releases WHERE software_name = ? AND version = ?"
   software-name version))

(defun mark-uncollectable (db software-name version)
  "Mark a release as uncollectable (permanent archive)."
  (sqlite:execute-non-query
   db "UPDATE releases SET uncollectable = 1 WHERE software_name = ? AND version = ?"
   software-name version))

(defun list-audit (db &optional (limit 100))
  (mapcar (lambda (row)
            (destructuring-bind (id identity action target detail at) row
              (list :id id :identity identity :action action
                    :target target :detail detail :at at)))
          (sqlite:execute-to-list
           db
           "SELECT id, identity, action, target, detail, at FROM audit_log ORDER BY id DESC LIMIT ?"
           limit)))
