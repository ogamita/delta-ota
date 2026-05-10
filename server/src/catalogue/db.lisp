;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.
;;;
;;; Direct SQLite catalogue access via cl-sqlite (Quicklisp: sqlite).
;;;
;;; v1.0.4: a CATALOGUE wraps the raw cl-sqlite handle with a recursive
;;; lock so the multi-worker Woo server can hit it from any worker
;;; thread without races.  WAL journal mode + a generous busy_timeout
;;; let SQLite serve concurrent readers and one writer at a time
;;; without starving anyone.  All public functions take the wrapper
;;; struct, acquire the lock around the underlying sqlite call(s),
;;; and release it on the way out (or on error, via UNWIND-PROTECT
;;; in BORDEAUX-THREADS:WITH-RECURSIVE-LOCK-HELD).

(in-package #:ota-server.catalogue)

(defstruct catalogue
  handle    ; the cl-sqlite connection
  lock)     ; bordeaux-threads recursive lock

(defmacro with-catalogue ((db-var catalogue) &body body)
  "Bind DB-VAR to the underlying sqlite handle of CATALOGUE while
holding its lock.  Recursive, so nested catalogue calls do not
deadlock."
  (let ((g (gensym "CATALOGUE")))
    `(let ((,g ,catalogue))
       (bordeaux-threads:with-recursive-lock-held ((catalogue-lock ,g))
         (let ((,db-var (catalogue-handle ,g)))
           ,@body)))))

(defun open-catalogue (db-path)
  "Open (or create) the SQLite catalogue at DB-PATH and configure it
for concurrent multi-worker access (WAL mode, NORMAL synchronous,
10-second busy timeout)."
  (ensure-directories-exist db-path)
  (let ((conn (sqlite:connect (namestring db-path))))
    ;; WAL allows concurrent readers + one writer; without it, every
    ;; reader would block writers (and each other through the
    ;; rollback journal).
    (sqlite:execute-non-query conn "PRAGMA journal_mode=WAL;")
    ;; If a write contends with another writer, retry up to 10s
    ;; before giving up with SQLITE_BUSY.  Generous because a
    ;; long-running publish (bsdiff for a few minutes) holds no
    ;; long transactions itself; this just covers brief overlaps.
    (sqlite:execute-non-query conn "PRAGMA busy_timeout=10000;")
    ;; NORMAL is the WAL-recommended setting: durable across app
    ;; crashes, may lose the last commit on power-loss.  Acceptable
    ;; for this catalogue (which is rebuildable from the CAS + the
    ;; manifests dir).
    (sqlite:execute-non-query conn "PRAGMA synchronous=NORMAL;")
    (make-catalogue :handle conn
                    :lock (bordeaux-threads:make-recursive-lock
                           "ota-catalogue"))))

(defun close-catalogue (catalogue)
  (with-catalogue (db catalogue)
    (sqlite:disconnect db)))

(defun read-migration-file (relative-path)
  (let* ((here (asdf:system-source-directory "ota-server"))
         (path (merge-pathnames relative-path here)))
    (with-open-file (in path :direction :input :external-format :utf-8)
      (with-output-to-string (out)
        (loop for line = (read-line in nil nil)
              while line do (write-line line out))))))

(defun run-migrations (catalogue)
  "Apply all schema migrations idempotently."
  (with-catalogue (db catalogue)
    (dolist (mig '("src/catalogue/migrations/0001_init.sql"
                   "src/catalogue/migrations/0002_patches.sql"
                   "src/catalogue/migrations/0003_auth.sql"
                   "src/catalogue/migrations/0004_patch_jobs.sql"
                   "src/catalogue/migrations/0005_client_software_state.sql"))
      (dolist (stmt (split-statements (read-migration-file mig)))
        (let ((trimmed (string-trim '(#\Space #\Tab #\Newline #\Return) stmt)))
          (when (plusp (length trimmed))
            (sqlite:execute-non-query db trimmed)))))))

(defun split-statements (sql)
  "Split a SQL string at top-level semicolons.  Skips `--` line
comments and single-quoted string literals so that a `;` inside
either does not start a new statement.  Good enough for our
migrations; if we ever need C-style /* … */ block comments or
double-quoted identifiers with semicolons in them, extend here."
  (let ((statements '())
        (start 0)
        (i 0)
        (n (length sql)))
    (loop while (< i n) do
      (let ((c (char sql i)))
        (cond
          ;; -- ... \n  : skip the rest of the line.
          ((and (char= c #\-) (< (1+ i) n) (char= (char sql (1+ i)) #\-))
           (loop while (and (< i n) (not (char= (char sql i) #\Newline)))
                 do (incf i)))
          ;; '...' : skip to the matching quote (SQL doubles '' to escape).
          ((char= c #\')
           (incf i)
           (loop while (< i n)
                 for ch = (char sql i)
                 do (cond
                      ((and (char= ch #\') (< (1+ i) n)
                            (char= (char sql (1+ i)) #\'))
                       (incf i 2))
                      ((char= ch #\') (return))
                      (t (incf i))))
           (when (< i n) (incf i)))
          ;; Top-level semicolon: end of statement.
          ((char= c #\;)
           (push (subseq sql start i) statements)
           (setf start (1+ i))
           (incf i))
          (t (incf i)))))
    (let ((tail (subseq sql start)))
      (when (some (lambda (c) (not (member c '(#\Space #\Tab #\Newline #\Return))))
                  tail)
        (push tail statements)))
    (nreverse statements)))

(defun ensure-software (catalogue &key name display-name (default-patcher "bsdiff"))
  (with-catalogue (db catalogue)
    (sqlite:execute-non-query
     db
     "INSERT OR IGNORE INTO software (name, display_name, default_patcher, created_at) VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))"
     name (or display-name name) default-patcher)))

(defun row-to-software (row)
  (destructuring-bind (name display-name default-patcher created-at) row
    (list :name name :display-name display-name
          :default-patcher default-patcher :created-at created-at)))

(defun list-software (catalogue)
  (with-catalogue (db catalogue)
    (mapcar #'row-to-software
            (sqlite:execute-to-list
             db "SELECT name, display_name, default_patcher, created_at FROM software ORDER BY name"))))

(defun get-software (catalogue name)
  (with-catalogue (db catalogue)
    (let ((rows (sqlite:execute-to-list
                 db "SELECT name, display_name, default_patcher, created_at FROM software WHERE name = ?"
                 name)))
      (when rows (row-to-software (first rows))))))

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

(defun insert-release (catalogue &key release-id software os arch os-versions version
                                      blob-sha256 blob-size manifest-sha256
                                      (channels #()) (classifications #())
                                      uncollectable deprecated
                                      published-by notes)
  (with-catalogue (db catalogue)
    ;; Compute published_at catalogue-side so that two back-to-back
    ;; publishes within the same wall-clock second don't tie -- see
    ;; NEXT-PUBLISHED-AT for the rationale.  (Replaces the prior
    ;; SQL-side "strftime('%Y-%m-%dT%H:%M:%SZ', 'now')".)
    (let ((published-at (next-published-at db software)))
      (sqlite:execute-non-query
       db
       (format nil "INSERT INTO releases (~A) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
               *release-columns*)
       release-id software os arch
       (com.inuoe.jzon:stringify os-versions :pretty nil)
       version blob-sha256 blob-size manifest-sha256
       (com.inuoe.jzon:stringify channels :pretty nil)
       (com.inuoe.jzon:stringify classifications :pretty nil)
       (if uncollectable 1 0)
       (if deprecated    1 0)
       published-at
       published-by
       (or notes "")))))

(defun insert-release-if-new (catalogue &key release-id software os arch os-versions
                                            version blob-sha256 blob-size manifest-sha256
                                            (channels #()) (classifications #())
                                            uncollectable deprecated
                                            published-by notes)
  "Atomic 'insert this release if no row with the same
(software, os, arch, version) tuple exists'.  Returns one of:

  (values :existing EXISTING-ROW-PLIST)  ;; tuple already in catalogue
  (values :inserted NIL)                  ;; row was just inserted

The lookup + INSERT happen inside a single =BEGIN IMMEDIATE=
transaction, which acquires SQLite's write lock at BEGIN time --
so two ota-server processes attempting the same publish
concurrently against the same data dir see one win and the other
hit the :existing branch deterministically.  Without this,
they would both pass the lookup, both try to insert, and the
loser would propagate a SQLITE_CONSTRAINT 500 to the client.

NEXT-PUBLISHED-AT is invoked inside the same transaction, so the
SELECT MAX(published_at) sees no concurrent inserts -- the
strict-monotonic published_at guarantee (added in v1.1.0) holds
across processes too, not just within one.

The publish handler in HTTP/server.lisp is the only caller that
needs this stronger guarantee; the e2e harness and tests can
keep using the simpler INSERT-RELEASE."
  (with-catalogue (db catalogue)
    (sqlite:execute-non-query db "BEGIN IMMEDIATE")
    (handler-case
        (let ((existing-rows
                (sqlite:execute-to-list
                 db
                 (format nil "SELECT ~A FROM releases WHERE software_name = ? AND os = ? AND arch = ? AND version = ?"
                         *release-columns*)
                 software os arch version)))
          (cond
            (existing-rows
             (sqlite:execute-non-query db "COMMIT")
             (values :existing (row-to-release (first existing-rows))))
            (t
             ;; Compute published_at while still holding the write
             ;; lock so the MAX(published_at) lookup is consistent
             ;; with the INSERT we're about to do.
             (let ((published-at (next-published-at db software)))
               (sqlite:execute-non-query
                db
                (format nil "INSERT INTO releases (~A) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
                        *release-columns*)
                release-id software os arch
                (com.inuoe.jzon:stringify os-versions :pretty nil)
                version blob-sha256 blob-size manifest-sha256
                (com.inuoe.jzon:stringify channels :pretty nil)
                (com.inuoe.jzon:stringify classifications :pretty nil)
                (if uncollectable 1 0)
                (if deprecated    1 0)
                published-at
                published-by
                (or notes "")))
             (sqlite:execute-non-query db "COMMIT")
             (values :inserted nil))))
      (error (c)
        ;; Roll back so the connection isn't left mid-transaction.
        ;; If ROLLBACK itself errors (extremely unlikely outside of
        ;; a closed connection), swallow it and re-raise the
        ;; original cause.
        (handler-case (sqlite:execute-non-query db "ROLLBACK")
          (error () nil))
        (error c)))))

(defun list-releases (catalogue software-name)
  (with-catalogue (db catalogue)
    (mapcar #'row-to-release
            (sqlite:execute-to-list
             db
             (format nil "SELECT ~A FROM releases WHERE software_name = ? ORDER BY published_at DESC"
                     *release-columns*)
             software-name))))

(defun get-release (catalogue software-name version)
  (with-catalogue (db catalogue)
    (let ((rows (sqlite:execute-to-list
                 db
                 (format nil "SELECT ~A FROM releases WHERE software_name = ? AND version = ?"
                         *release-columns*)
                 software-name version)))
      (when rows (row-to-release (first rows))))))

(defun get-release-by-tuple (catalogue software-name os arch version)
  "Look up a release by the full UNIQUE tuple (software_name, os,
arch, version).  Returns the release plist or NIL.  Used by the
publish handler for idempotent re-publish detection."
  (with-catalogue (db catalogue)
    (let ((rows (sqlite:execute-to-list
                 db
                 (format nil "SELECT ~A FROM releases WHERE software_name = ? AND os = ? AND arch = ? AND version = ?"
                         *release-columns*)
                 software-name os arch version)))
      (when rows (row-to-release (first rows))))))

(defun get-latest-release (catalogue software-name)
  "Return the release of SOFTWARE-NAME that should be served as
\"latest\".  v1.1.0 semantics: the highest *semver* version when at
least one release has a parseable semver string; otherwise the
most-recently-published release (the v1.0.x semantics).

Why the change: under the prior `published_at DESC` rule, a hotfix
re-published to an older version after a newer one was already out
would silently become \"latest\" -- and `ota-agent watch` would
then downgrade every installed client.  Real-world bug; see the
v1.1.0 CHANGELOG entry."
  (let ((all (list-releases catalogue software-name)))
    (cond ((null all) nil)
          (t (or (highest-semver-release all)
                 ;; LIST-RELEASES returns published_at DESC; the
                 ;; first row is the v1.0.x \"latest\".  Used when no
                 ;; version parses as semver.
                 (first all))))))

(defun highest-semver-release (releases)
  "Return the entry of RELEASES (a list of release plists) with the
highest parseable semver in its :VERSION; NIL when none parse."
  (let ((parseable
          (remove-if-not (lambda (r) (parse-semver (getf r :version)))
                         releases)))
    (when parseable
      (first
       (sort (copy-list parseable)
             (lambda (a b)
               (semver< (parse-semver (getf b :version))
                        (parse-semver (getf a :version)))))))))

;; ---------------------------------------------------------------------------
;; Semver parsing (subset).  Handles MAJOR.MINOR.PATCH and the
;; MAJOR.MINOR.PATCH-PRERELEASE form.  No build-metadata support
;; (`+build`) -- it is not used in our catalogue today.
;; ---------------------------------------------------------------------------

(defun parse-semver (version-string)
  "Parse \"1.2.3\" or \"1.2.3-rc1\" into the structured form
((1 2 3) . PRERELEASE-OR-NIL).  Returns NIL when VERSION-STRING is
not parseable as semver (e.g. \"alpha\", or has a non-integer
component)."
  (when (and version-string (plusp (length version-string)))
    (let* ((dash (position #\- version-string))
           (numeric (if dash (subseq version-string 0 dash) version-string))
           (prerelease (and dash (subseq version-string (1+ dash))))
           (parts (split-on-dot numeric)))
      (when (and (consp parts)
                 (every (lambda (p)
                          (and (plusp (length p))
                               (every #'digit-char-p p)))
                        parts))
        (cons (mapcar #'parse-integer parts) prerelease)))))

(defun split-on-dot (s)
  (let ((acc '()) (start 0))
    (dotimes (i (length s))
      (when (char= (char s i) #\.)
        (push (subseq s start i) acc)
        (setf start (1+ i))))
    (push (subseq s start) acc)
    (nreverse acc)))

(defun semver< (a b)
  "Return T when parsed semver A is strictly less than B.  Both A
and B must be the (NUMS . PRERELEASE) shape returned by
PARSE-SEMVER.

Per the semver spec: number lists are compared lexicographically;
when they tie, a release with a prerelease tag is *less than* one
without (1.0.0-rc1 < 1.0.0); when both have prerelease tags, they
are string-compared (a coarse approximation -- spec'd ordering
rules are subtler but not needed for our publish-monotonic
catalogue use case)."
  (let ((nums-a (car a))
        (nums-b (car b))
        (pre-a  (cdr a))
        (pre-b  (cdr b)))
    (cond
      ((nums< nums-a nums-b) t)
      ((nums< nums-b nums-a) nil)
      ;; numeric components tied
      ((and pre-a (null pre-b)) t)         ; 1.0.0-rc < 1.0.0
      ((and (null pre-a) pre-b) nil)
      ((and pre-a pre-b)        (string< pre-a pre-b))
      (t nil))))                            ; equal

(defun nums< (a b)
  "Lex compare of two integer lists, with the missing-tail
treated as zero (so (1 0) and (1 0 0) are equal)."
  (cond
    ((and (null a) (null b)) nil)
    ((null a) (some #'plusp b))
    ((null b) nil)
    ((< (first a) (first b)) t)
    ((> (first a) (first b)) nil)
    (t (nums< (rest a) (rest b)))))

(defun insert-patch (catalogue &key sha256 from-release-id to-release-id patcher size)
  (with-catalogue (db catalogue)
    (sqlite:execute-non-query
     db
     "INSERT OR REPLACE INTO patches (sha256, from_release_id, to_release_id, patcher, size, built_at) VALUES (?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))"
     sha256 from-release-id to-release-id patcher size)))

(defun list-patches-to (catalogue to-release-id)
  "Return list of plists describing every patch ending at TO-RELEASE-ID."
  (with-catalogue (db catalogue)
    (mapcar (lambda (row)
              (destructuring-bind (sha from-id to-id patcher size built-at) row
                (list :sha256 sha :from-release-id from-id :to-release-id to-id
                      :patcher patcher :size size :built-at built-at)))
            (sqlite:execute-to-list
             db
             "SELECT sha256, from_release_id, to_release_id, patcher, size, built_at FROM patches WHERE to_release_id = ? ORDER BY size ASC"
             to-release-id))))

(defun record-install-event (catalogue &key client-id software release-id kind
                                            from-release-id status error)
  (with-catalogue (db catalogue)
    (sqlite:execute-non-query
     db
     "INSERT INTO install_events (client_id, software_name, release_id, kind, from_release_id, status, error, at) VALUES (?, ?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))"
     client-id software release-id (string-downcase (string kind))
     from-release-id (string-downcase (string status)) error)))

;; ---------------- Phase-4 auth ----------------

(defun random-hex (n)
  "Return 2*N hex chars of cryptographic randomness."
  (let ((bytes (make-array n :element-type '(unsigned-byte 8))))
    (loop for i below n
          do (setf (aref bytes i)
                   (ldb (byte 8 0) (ironclad:strong-random 256))))
    (ironclad:byte-array-to-hex-string bytes)))

(defun mint-install-token (catalogue &key (classifications #("public")) (ttl-seconds 900) created-by)
  "Generate a one-shot install token; return (values token expires-at)."
  (with-catalogue (db catalogue)
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
      (values token expires))))

(defun universal-to-iso8601 (univ)
  (multiple-value-bind (s m h d mo y) (decode-universal-time univ 0)
    (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ" y mo d h m s)))

(defun iso8601-to-universal (iso)
  "Inverse of UNIVERSAL-TO-ISO8601 for the strict
\"YYYY-MM-DDTHH:MM:SSZ\" shape we emit ourselves."
  (encode-universal-time
   (parse-integer iso :start 17 :end 19)   ; ss
   (parse-integer iso :start 14 :end 16)   ; mm
   (parse-integer iso :start 11 :end 13)   ; hh
   (parse-integer iso :start  8 :end 10)   ; dd
   (parse-integer iso :start  5 :end  7)   ; MM
   (parse-integer iso :start  0 :end  4)   ; YYYY
   0))                                      ; UTC

(defun succ-iso8601 (iso)
  "Return the ISO-8601 string one second after ISO."
  (universal-to-iso8601 (1+ (iso8601-to-universal iso))))

(defun next-published-at (db software-name)
  "Return an ISO-8601 timestamp suitable as the new release's
published_at: the wall-clock now, OR -- if a prior release of
SOFTWARE-NAME already has that timestamp (or any in its future,
e.g. after an NTP correction) -- the maximum existing
published_at plus one second.

This keeps published_at *strictly* monotonic per-software: two
back-to-back publishes in the same wall-clock second do not tie,
so any ORDER BY published_at DESC consumer (notably the v1.0.x
get-latest-release fallback) is deterministic.  No sleeps;
purely catalogue-side."
  (let* ((now  (universal-to-iso8601 (get-universal-time)))
         (rows (sqlite:execute-to-list
                db
                "SELECT MAX(published_at) FROM releases WHERE software_name = ?"
                software-name))
         (prev (caar rows)))
    (cond
      ((null prev)         now)
      ((string< prev now)  now)            ; clock has advanced; use it
      (t                   (succ-iso8601 prev)))))

(defun claim-install-token (catalogue token)
  "Mark an install token as used (one-shot).  Returns the token's
   classifications as a vector, or NIL if the token is unknown,
   already used, or expired."
  (with-catalogue (db catalogue)
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
            (com.inuoe.jzon:parse cls)))))))

(defun create-client (catalogue &key classifications hwinfo cert-subject)
  "Create a new client row; return (values client-id bearer-token)."
  (with-catalogue (db catalogue)
    (let ((client-id (concatenate 'string "c-" (random-hex 8)))
          (bearer    (random-hex 32)))
      (sqlite:execute-non-query
       db
       "INSERT INTO clients (client_id, bearer_token, classifications, hwinfo, cert_subject, created_at, last_seen_at) VALUES (?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))"
       client-id bearer
       (com.inuoe.jzon:stringify (or classifications #("public")) :pretty nil)
       hwinfo cert-subject)
      (values client-id bearer))))

(defun get-client-by-token (catalogue bearer-token)
  (with-catalogue (db catalogue)
    (let ((row (first (sqlite:execute-to-list
                       db
                       "SELECT client_id, classifications, cert_subject FROM clients WHERE bearer_token = ?"
                       bearer-token))))
      (when row
        (destructuring-bind (client-id cls cert) row
          (list :client-id client-id
                :classifications (com.inuoe.jzon:parse cls)
                :cert-subject cert))))))

(defun touch-client (catalogue client-id)
  (with-catalogue (db catalogue)
    (sqlite:execute-non-query
     db
     "UPDATE clients SET last_seen_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE client_id = ?"
     client-id)))

(defun append-audit (catalogue &key identity action target detail)
  (with-catalogue (db catalogue)
    (sqlite:execute-non-query
     db
     "INSERT INTO audit_log (identity, action, target, detail, at) VALUES (?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))"
     identity action target detail)))

;; ---------------- Phase-5 operations ----------------

(defun count-users-at-release (catalogue software-name release-id &key (window-days nil))
  "Exact count of clients whose current_release_id equals RELEASE-ID
for SOFTWARE-NAME, drawn from the v1.5 client_software_state
snapshot.

When WINDOW-DAYS is supplied, the count is further restricted to
clients whose last_updated_at falls within the recency window --
useful so a long-abandoned install (agent never reported in
6 months) isn't treated as 'still active' by the GC.  NIL window
means 'no recency filter; trust the snapshot'.

Returns 0 when no client_software_state rows exist (e.g. a brand-
new deployment with no clients reporting yet), matching the v1.0-
v1.4 fallback semantics that callers already handle."
  (with-catalogue (db catalogue)
    (let ((rows
            (cond
              (window-days
               (let* ((cutoff-iso (universal-to-iso8601
                                   (- (get-universal-time)
                                      (* window-days 86400)))))
                 (sqlite:execute-to-list
                  db
                  "SELECT COUNT(*) FROM client_software_state
                    WHERE software_name      = ?
                      AND current_release_id = ?
                      AND last_updated_at   >= ?"
                  software-name release-id cutoff-iso)))
              (t
               (sqlite:execute-to-list
                db
                "SELECT COUNT(*) FROM client_software_state
                  WHERE software_name      = ?
                    AND current_release_id = ?"
                software-name release-id)))))
      (or (caar rows) 0))))

;; ---------------- v1.5: client-software state snapshot ----------------
;;
;; Maintained by ota-agent via PUT /v1/clients/me/software/<sw>;
;; authoritative for the question "who is on X right now".  See
;; ADR-0010 and docs/release-1.5-plan.org for the design rationale.
;; install_events stays around as an append-only audit/analytics
;; stream; that's the historical record, this is the current state.

(defun record-client-software-state (catalogue
                                     &key client-id software
                                          current-release-id
                                          previous-release-id
                                          (kind "upgrade")
                                          (at nil))
  "Set (or update) the snapshot row for (CLIENT-ID, SOFTWARE).
Idempotent on the primary key; a re-PUT of the same state is a
no-op at the value level.  AT defaults to the server's current
wall-clock; clients may pass their own ISO-8601 string when they
need to record an out-of-band transition (e.g. a recover from a
network-disconnected install).

KIND is one of install / upgrade / revert / recover / uninstall;
checked by the schema CHECK constraint.  Uninstall is recorded
with CURRENT-RELEASE-ID = NIL (preserved in SQL as NULL), keeping
the row for stats while excluding it from \"who is on X\" counts."
  (with-catalogue (db catalogue)
    (sqlite:execute-non-query
     db
     "INSERT INTO client_software_state
        (client_id, software_name, current_release_id, previous_release_id,
         last_kind, last_updated_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(client_id, software_name) DO UPDATE SET
         current_release_id  = excluded.current_release_id,
         previous_release_id = excluded.previous_release_id,
         last_kind           = excluded.last_kind,
         last_updated_at     = excluded.last_updated_at"
     client-id
     software
     current-release-id
     previous-release-id
     (string-downcase (string kind))
     (or at (universal-to-iso8601 (get-universal-time))))))

(defun get-client-software-state (catalogue client-id software)
  "Return the snapshot row plist or NIL when the client has never
reported for this software.  Used by the agent-side state-show
subcommand and by the admin stats queries."
  (with-catalogue (db catalogue)
    (let ((rows (sqlite:execute-to-list
                 db
                 "SELECT current_release_id, previous_release_id,
                         last_kind, last_updated_at
                    FROM client_software_state
                   WHERE client_id = ? AND software_name = ?"
                 client-id software)))
      (when rows
        (destructuring-bind (current previous kind updated) (first rows)
          (list :current-release-id current
                :previous-release-id previous
                :last-kind kind
                :last-updated-at updated))))))

(defun list-client-software-states (catalogue
                                    &key client-id software
                                         current-release-id)
  "Filterable scan over the snapshot table.  Any combination of
filters may be NIL to widen the match.  Used by the admin stats
catalogue (workers/stats.lisp); rate-limited at the HTTP layer
because a no-filter scan can return the whole fleet."
  (with-catalogue (db catalogue)
    (let ((sql "SELECT client_id, software_name, current_release_id, previous_release_id, last_kind, last_updated_at FROM client_software_state WHERE 1=1")
          (args '()))
      (when client-id
        (setf sql (concatenate 'string sql " AND client_id = ?"))
        (push client-id args))
      (when software
        (setf sql (concatenate 'string sql " AND software_name = ?"))
        (push software args))
      (when current-release-id
        (setf sql (concatenate 'string sql " AND current_release_id = ?"))
        (push current-release-id args))
      (setf sql (concatenate 'string sql " ORDER BY last_updated_at DESC"))
      (mapcar (lambda (row)
                (destructuring-bind (cid sw curr prev kind updated) row
                  (list :client-id cid
                        :software sw
                        :current-release-id curr
                        :previous-release-id prev
                        :last-kind kind
                        :last-updated-at updated)))
              (apply #'sqlite:execute-to-list db sql (nreverse args))))))

(defun count-releases-using-blob (catalogue blob-sha256)
  "How many releases reference this blob hash."
  (with-catalogue (db catalogue)
    (caar (sqlite:execute-to-list
           db "SELECT COUNT(*) FROM releases WHERE blob_sha256 = ?"
           blob-sha256))))

(defun get-patch-by-tuple (catalogue from-release-id to-release-id
                           &key (patcher "bsdiff"))
  "Look up an existing patch by (from, to, patcher).  Returns the
patch plist or NIL.  Used by the v1.6 lazy-upgrade endpoint to
decide whether to build on demand."
  (with-catalogue (db catalogue)
    (let ((rows (sqlite:execute-to-list
                 db
                 "SELECT sha256, from_release_id, to_release_id, patcher, size, built_at FROM patches WHERE from_release_id = ? AND to_release_id = ? AND patcher = ?"
                 from-release-id to-release-id patcher)))
      (when rows
        (destructuring-bind (sha from to p size built-at) (first rows)
          (list :sha256 sha :from-release-id from :to-release-id to
                :patcher p :size size :built-at built-at))))))

(defun list-patches-for-software (catalogue software-name)
  "Return every patch row whose endpoints belong to releases of
SOFTWARE-NAME.  Used by the v1.6 reachability-aware GC to build
the patches graph in one query rather than N round-trips through
LIST-PATCHES-BY-FROM-OR-TO.  Result rows are
plists :SHA256 :FROM-RELEASE-ID :TO-RELEASE-ID :PATCHER :SIZE.

The join restricts to patches whose `to_release_id` belongs to
the software; since the fan-in is forward-only and bidirectional
patches don't exist outside of `admin-build-reverse-patch`, this
captures every edge in the software's upgrade graph."
  (with-catalogue (db catalogue)
    (mapcar (lambda (row)
              (destructuring-bind (sha from-id to-id patcher size) row
                (list :sha256 sha :from-release-id from-id
                      :to-release-id to-id :patcher patcher :size size)))
            (sqlite:execute-to-list
             db
             "SELECT DISTINCT p.sha256, p.from_release_id, p.to_release_id,
                              p.patcher, p.size
                FROM patches p
                JOIN releases r ON r.release_id = p.to_release_id
               WHERE r.software_name = ?"
             software-name))))

(defun list-patches-by-from-or-to (catalogue release-id)
  (with-catalogue (db catalogue)
    (mapcar (lambda (row)
              (destructuring-bind (sha from-id to-id patcher size) row
                (list :sha256 sha :from-release-id from-id
                      :to-release-id to-id :patcher patcher :size size)))
            (sqlite:execute-to-list
             db
             "SELECT sha256, from_release_id, to_release_id, patcher, size
                FROM patches
               WHERE from_release_id = ? OR to_release_id = ?"
             release-id release-id))))

(defun delete-patches-touching (catalogue release-id)
  (with-catalogue (db catalogue)
    (sqlite:execute-non-query
     db "DELETE FROM patches WHERE from_release_id = ? OR to_release_id = ?"
     release-id release-id)))

(defun delete-release (catalogue software-name version)
  (with-catalogue (db catalogue)
    (sqlite:execute-non-query
     db "DELETE FROM releases WHERE software_name = ? AND version = ?"
     software-name version)))

(defun mark-uncollectable (catalogue software-name version)
  "Mark a release as uncollectable (permanent archive)."
  (with-catalogue (db catalogue)
    (sqlite:execute-non-query
     db "UPDATE releases SET uncollectable = 1 WHERE software_name = ? AND version = ?"
     software-name version)))

;; ---------------- v1.2: persistent patch-build job queue ----------------
;;
;; The schema in 0004_patch_jobs.sql declares UNIQUE (from, to, patcher),
;; so an INSERT that conflicts with an existing row no-ops.  We exploit
;; that for idempotent re-publishes: the publish handler enqueues one
;; job per prior release, and a duplicate enqueue (idempotent re-publish
;; or a transient retry) silently does nothing.

(defparameter *patch-job-columns*
  "id, from_release_id, to_release_id, software_name, os, arch, from_version, from_blob_sha256, to_blob_sha256, patcher, status, attempts, error, patch_sha256, patch_size, enqueued_at, started_at, completed_at")

(defun row-to-patch-job (row)
  (destructuring-bind (id from-id to-id sw os arch from-ver
                       from-sha to-sha patcher status
                       attempts error sha size
                       enqueued started completed)
      row
    (list :id id
          :from-release-id from-id :to-release-id to-id
          :software sw :os os :arch arch
          :from-version from-ver
          :from-blob-sha256 from-sha :to-blob-sha256 to-sha
          :patcher patcher :status status
          :attempts attempts :error error
          :patch-sha256 sha :patch-size size
          :enqueued-at enqueued :started-at started :completed-at completed)))

(defun enqueue-patch-job (catalogue &key from-release-id to-release-id
                                         software os arch from-version
                                         from-blob-sha256 to-blob-sha256
                                         (patcher "bsdiff"))
  "Enqueue one bsdiff job.  Idempotent: an INSERT that conflicts with
the (from, to, patcher) UNIQUE silently no-ops, so a re-publish or
double-enqueue does not duplicate work.  Returns one of:

  (values :enqueued JOB-ID)   -- newly inserted row
  (values :existing JOB-ID)   -- a row was already there"
  (with-catalogue (db catalogue)
    (let ((now (universal-to-iso8601 (get-universal-time))))
      (sqlite:execute-non-query
       db
       "INSERT OR IGNORE INTO patch_jobs (from_release_id, to_release_id, software_name, os, arch, from_version, from_blob_sha256, to_blob_sha256, patcher, status, enqueued_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?)"
       from-release-id to-release-id software os arch from-version
       from-blob-sha256 to-blob-sha256 patcher now)
      ;; SQLite's changes() reports 1 when the INSERT actually wrote a
      ;; row, 0 when OR IGNORE swallowed it (i.e. UNIQUE conflict).
      (let* ((changed (or (caar (sqlite:execute-to-list db "SELECT changes()")) 0))
             (id (caar (sqlite:execute-to-list
                        db
                        "SELECT id FROM patch_jobs WHERE from_release_id = ? AND to_release_id = ? AND patcher = ?"
                        from-release-id to-release-id patcher))))
        (values (if (plusp changed) :enqueued :existing) id)))))

(defun claim-next-patch-job (catalogue)
  "Atomically pick the oldest pending job and mark it running.  Returns
the claimed job's plist, or NIL when no pending job exists.  Wrapped
in `BEGIN IMMEDIATE` so two workers (or two server processes) racing
on the same row see exactly one winner.  attempts is incremented on
each claim so a recovered stale-running job that fails repeatedly is
visible."
  (with-catalogue (db catalogue)
    (sqlite:execute-non-query db "BEGIN IMMEDIATE")
    (handler-case
        (let* ((rows (sqlite:execute-to-list
                      db
                      (format nil "SELECT ~A FROM patch_jobs WHERE status = 'pending' ORDER BY id ASC LIMIT 1"
                              *patch-job-columns*)))
               (job (and rows (row-to-patch-job (first rows)))))
          (cond
            ((null job)
             (sqlite:execute-non-query db "COMMIT")
             nil)
            (t
             (let ((now (universal-to-iso8601 (get-universal-time))))
               (sqlite:execute-non-query
                db
                "UPDATE patch_jobs SET status = 'running', started_at = ?, attempts = attempts + 1 WHERE id = ?"
                now (getf job :id)))
             (sqlite:execute-non-query db "COMMIT")
             ;; Reflect the field updates in the returned plist so the
             ;; caller sees the post-claim state without a re-fetch.
             (setf (getf job :status) "running")
             (incf (getf job :attempts))
             job)))
      (error (c)
        (handler-case (sqlite:execute-non-query db "ROLLBACK")
          (error () nil))
        (error c)))))

(defun complete-patch-job (catalogue job-id &key sha256 size)
  "Mark JOB-ID as done with the resulting patch (sha, size)."
  (with-catalogue (db catalogue)
    (sqlite:execute-non-query
     db
     "UPDATE patch_jobs SET status = 'done', completed_at = ?, patch_sha256 = ?, patch_size = ?, error = NULL WHERE id = ?"
     (universal-to-iso8601 (get-universal-time)) sha256 size job-id)))

(defun fail-patch-job (catalogue job-id error-msg)
  "Mark JOB-ID as failed with ERROR-MSG (a short string)."
  (with-catalogue (db catalogue)
    (sqlite:execute-non-query
     db
     "UPDATE patch_jobs SET status = 'failed', completed_at = ?, error = ? WHERE id = ?"
     (universal-to-iso8601 (get-universal-time))
     (or error-msg "")
     job-id)))

(defun list-patch-jobs-for-release (catalogue to-release-id)
  "All patch jobs targeting TO-RELEASE-ID, oldest id first."
  (with-catalogue (db catalogue)
    (mapcar #'row-to-patch-job
            (sqlite:execute-to-list
             db
             (format nil "SELECT ~A FROM patch_jobs WHERE to_release_id = ? ORDER BY id ASC"
                     *patch-job-columns*)
             to-release-id))))

(defun count-patch-jobs (catalogue &key status to-release-id)
  "Count rows in patch_jobs filtered by STATUS and/or TO-RELEASE-ID.
Either filter may be NIL.  Returns an integer."
  (with-catalogue (db catalogue)
    (let ((sql "SELECT COUNT(*) FROM patch_jobs WHERE 1=1")
          (args '()))
      (when status
        (setf sql (concatenate 'string sql " AND status = ?"))
        (push status args))
      (when to-release-id
        (setf sql (concatenate 'string sql " AND to_release_id = ?"))
        (push to-release-id args))
      (or (caar (apply #'sqlite:execute-to-list db sql (nreverse args)))
          0))))

(defun delete-patch-jobs-touching (catalogue release-id)
  "Drop every patch_jobs row whose from or to release equals
RELEASE-ID.  Called from drop-release after the patches table
itself has been cleaned up -- so a release GC takes its
corresponding patch-build audit trail with it.

Pinned releases are protected automatically: drop-release is
never called for an uncollectable release, so its rows survive."
  (with-catalogue (db catalogue)
    (sqlite:execute-non-query
     db
     "DELETE FROM patch_jobs WHERE from_release_id = ? OR to_release_id = ?"
     release-id release-id)))

(defun reset-stale-running-jobs (catalogue)
  "Boot-time recovery: any job left in 'running' (because a worker or
the whole server died mid-bsdiff) is reset to 'pending' so the pool
re-picks it up.  Bsdiff is deterministic and INSERT-PATCH dedupes on
(from, to, patcher), so re-running a partially-completed job is
idempotent.  Returns the number of rows reset."
  (with-catalogue (db catalogue)
    (let ((before (or (caar (sqlite:execute-to-list
                             db "SELECT COUNT(*) FROM patch_jobs WHERE status = 'running'"))
                      0)))
      (sqlite:execute-non-query
       db
       "UPDATE patch_jobs SET status = 'pending', started_at = NULL WHERE status = 'running'")
      before)))

(defun list-audit (catalogue &optional (limit 100))
  (with-catalogue (db catalogue)
    (mapcar (lambda (row)
              (destructuring-bind (id identity action target detail at) row
                (list :id id :identity identity :action action
                      :target target :detail detail :at at)))
            (sqlite:execute-to-list
             db
             "SELECT id, identity, action, target, detail, at FROM audit_log ORDER BY id DESC LIMIT ?"
             limit))))
