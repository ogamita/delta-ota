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
                 "src/catalogue/migrations/0002_patches.sql"))
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
