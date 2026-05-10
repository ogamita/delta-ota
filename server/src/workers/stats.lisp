;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.
;;;
;;; v1.5: admin stats catalogue.
;;;
;;; A curated set of named SQL queries against the catalogue, exposed
;;; via GET /v1/admin/stats/<query-name>?... and the
;;; `ota-server stats <query-name> ...` CLI subcommand.
;;;
;;; Curated, not generic: there is no "raw SELECT" endpoint.  Each
;;; query lives in *stats-catalogue* with its SQL template, the
;;; ordered list of parameters it accepts, and the schema of its
;;; result rows.  Operators who need richer queries run the SQLite
;;; CLI directly against the catalogue file.
;;;
;;; See docs/release-1.5-plan.org §"Admin SQL statistics surface"
;;; for the design rationale.

(in-package #:ota-server.workers)

;; The catalogue uses keyword query-names.  Each entry:
;;
;;   :description   human-readable string
;;   :params        ordered list of :keyword names.  In the SQL,
;;                  each param is referenced with a single `?` -- the
;;                  order in :params matches the order of ?s.
;;   :defaults      plist of (:param default-value) for omitted params.
;;                  When the default-value is the special symbol
;;                  :since-30-days, the runtime computes an ISO-8601
;;                  string 30 days ago.
;;   :columns       ordered list of result-column names.  Bound to
;;                  the row tuples so the JSON output keys match SQL.
;;   :sql           the parameterised query.

(defparameter *stats-since-default* 30
  "Default 'since-days' value for queries with a recency window.
Matches the GC's min-age-days default (30) so 'stale enough to
prune' aligns with 'too old for current-state stats'.")

(defparameter *stats-result-cap* 1000
  "Hard ceiling on rows returned per query.  Documented in operations.org
so operators wanting fuller dumps know to use sqlite3(1) directly.
The cap is appended as LIMIT to every catalogued query.")

(defparameter *stats-catalogue*
  `((:population-per-release
     :description
     "Current population per release for one software.  Bread-and-butter
GC sanity check + deployment-status dashboard.  Reads the v1.5
snapshot, not the event log, so the count is exact."
     :params (:software)
     :defaults ()
     :columns (release_id clients)
     :sql "SELECT current_release_id AS release_id, COUNT(*) AS clients
             FROM client_software_state
            WHERE software_name = ?
              AND current_release_id IS NOT NULL
            GROUP BY current_release_id
            ORDER BY clients DESC")

    (:fleet-summary
     :description
     "How many clients per software, across the whole fleet.  Useful
for the 'where are we deployed?' question."
     :params ()
     :defaults ()
     :columns (software clients distinct_releases most_recent_update)
     :sql "SELECT software_name      AS software,
                  COUNT(*)            AS clients,
                  COUNT(DISTINCT current_release_id) AS distinct_releases,
                  MAX(last_updated_at) AS most_recent_update
             FROM client_software_state
            WHERE current_release_id IS NOT NULL
            GROUP BY software_name
            ORDER BY clients DESC")

    (:stale-clients
     :description
     "Clients we haven't heard from in N days for one software.
Candidates for 'did the install get abandoned?'.  :since-days
defaults to 30."
     :params (:software :since-days)
     :defaults (:since-days 30)
     :columns (client_id current_release_id last_updated_at)
     :sql "SELECT client_id, current_release_id, last_updated_at
             FROM client_software_state
            WHERE software_name      = ?
              AND last_updated_at    < ?
              AND current_release_id IS NOT NULL
            ORDER BY last_updated_at ASC")

    (:gc-impact
     :description
     "Per-release: age, pin status, and current client count.  Run
this before a GC pass to see what the policy would (or wouldn't)
prune."
     :params (:software)
     :defaults ()
     :columns (release_id version published_at uncollectable clients)
     :sql "SELECT r.release_id,
                  r.version,
                  r.published_at,
                  r.uncollectable,
                  COALESCE(p.clients, 0) AS clients
             FROM releases r
             LEFT JOIN (
               SELECT current_release_id, COUNT(*) AS clients
                 FROM client_software_state
                WHERE software_name = ?
                GROUP BY current_release_id
             ) p ON p.current_release_id = r.release_id
            WHERE r.software_name = ?
            ORDER BY r.published_at DESC")

    (:recent-events
     :description
     "Daily counts of install / upgrade / revert / recover events per
status for one software.  :since-days defaults to 30.  Reads the
install_events log (not the snapshot)."
     :params (:software :since-days)
     :defaults (:since-days 30)
     :columns (day kind status n)
     :sql "SELECT substr(at, 1, 10) AS day,
                  kind,
                  status,
                  COUNT(*) AS n
             FROM install_events
            WHERE software_name = ?
              AND at           >= ?
            GROUP BY day, kind, status
            ORDER BY day DESC, kind, status")

    (:upgrade-failure-rate
     :description
     "Per (from, to) pair, upgrade failure rate over the window.
HAVING attempts >= 5 keeps one-off failures out of the leaderboard.
:since-days defaults to 30."
     :params (:software :since-days)
     :defaults (:since-days 30)
     :columns (from_release_id to_release_id failures attempts failure_pct)
     :sql "SELECT from_release_id,
                  release_id      AS to_release_id,
                  SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) AS failures,
                  COUNT(*)                                            AS attempts,
                  ROUND(100.0 * SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END)
                        / COUNT(*), 1) AS failure_pct
             FROM install_events
            WHERE software_name = ?
              AND kind          = 'upgrade'
              AND at           >= ?
            GROUP BY from_release_id, release_id
           HAVING attempts >= 5
            ORDER BY failure_pct DESC, attempts DESC")

    (:adoption-curve
     :description
     "For RELEASE-ID, the daily count of clients seeing it for the
first time as an OK install_event.  Combined with the fleet
total it yields a cumulative adoption curve."
     :params (:software :release-id)
     :defaults ()
     :columns (day adopted_today total)
     :sql "WITH first_seen AS (
             SELECT client_id, MIN(at) AS first_at
               FROM install_events
              WHERE software_name = ?
                AND release_id    = ?
                AND status        = 'ok'
              GROUP BY client_id
           ),
           fleet AS (
             SELECT COUNT(*) AS total
               FROM client_software_state
              WHERE software_name = ?
           )
           SELECT substr(first_seen.first_at, 1, 10) AS day,
                  COUNT(*)                            AS adopted_today,
                  (SELECT total FROM fleet)           AS total
             FROM first_seen
            GROUP BY day
            ORDER BY day ASC")

    (:recovery-events
     :description
     "Daily count of doctor --recover events per (from, to, status).
High counts = quality regression or network issues."
     :params (:software :since-days)
     :defaults (:since-days 30)
     :columns (day from_release_id to_release_id status n)
     :sql "SELECT substr(at, 1, 10)     AS day,
                  from_release_id,
                  release_id            AS to_release_id,
                  status,
                  COUNT(*)              AS n
             FROM install_events
            WHERE software_name = ?
              AND kind          = 'recover'
              AND at           >= ?
            GROUP BY day, from_release_id, release_id, status
            ORDER BY day DESC, n DESC"))
  "The v1.5 admin stats query catalogue.  Each entry is a plist:
:DESCRIPTION, :PARAMS (ordered keyword list), :DEFAULTS (plist),
:COLUMNS (ordered symbol list matching SELECT order), :SQL.")

(defun stat-query-entry (name)
  "Return the catalogue entry for the keyword NAME, or NIL."
  (cdr (assoc name *stats-catalogue*)))

(defun list-stat-queries ()
  "Return ((:name :description :params :defaults :columns) ...) for
the GET /v1/admin/stats endpoint."
  (mapcar (lambda (entry)
            (let* ((name (car entry))
                   (rest (cdr entry)))
              (list :name name
                    :description (getf rest :description)
                    :params (getf rest :params)
                    :defaults (getf rest :defaults)
                    :columns (getf rest :columns))))
          *stats-catalogue*))

(defun %resolve-stat-param (name supplied defaults)
  "Resolve one parameter's value from SUPPLIED (the request) and
DEFAULTS.  Special handling: :since-days converts to an ISO-8601
cutoff string when used in SQL, but the user passes the integer
days.  Returns the value to bind into the SQL."
  (let ((v (getf supplied name)))
    (cond
      (v
       (cond
         ((and (eq name :since-days) (stringp v))
          (%since-days-to-iso (parse-integer v)))
         ((eq name :since-days)
          (%since-days-to-iso v))
         (t v)))
      ((member name defaults)
       (let ((d (getf defaults name)))
         (cond
           ((eq name :since-days) (%since-days-to-iso d))
           (t d))))
      (t nil))))

(defun %since-days-to-iso (days)
  (ota-server.catalogue::universal-to-iso8601
   (- (get-universal-time) (* days 86400))))

(define-condition stats-error (simple-error) ())

(defun run-stat-query (catalogue name &key params)
  "Run the catalogued query NAME against CATALOGUE.  PARAMS is a
plist of :keyword -> value pulled from the request's query
string.  Returns (values column-symbol-list row-of-tuples).
Signals STATS-ERROR when NAME isn't catalogued or a required
parameter is missing."
  (let ((entry (stat-query-entry name)))
    (unless entry
      (error 'stats-error
             :format-control "unknown stats query: ~S"
             :format-arguments (list name)))
    (let* ((sql (getf entry :sql))
           (defaults (getf entry :defaults))
           (columns (getf entry :columns))
           (resolved (mapcar (lambda (p)
                               (let ((v (%resolve-stat-param p params defaults)))
                                 (when (null v)
                                   (error 'stats-error
                                          :format-control "stats ~S: missing required parameter ~S"
                                          :format-arguments (list name p)))
                                 v))
                             (getf entry :params)))
           ;; Some queries use :software twice (gc-impact, adoption-curve);
           ;; replicate values so each ? in the SQL has its expected bind.
           (positional (%stats-positional-binds name resolved)))
      (ota-server.catalogue::with-catalogue (db catalogue)
        (let ((capped-sql (concatenate 'string
                                       sql
                                       (format nil " LIMIT ~D" *stats-result-cap*))))
          (values columns
                  (apply #'sqlite:execute-to-list db capped-sql positional)))))))

(defun %stats-positional-binds (name resolved-params)
  "Map the :PARAMS-ordered values to the ? positions in the SQL.
For most queries this is identity; gc-impact and adoption-curve
re-use :software in two places so we duplicate the value here
rather than encoding it in the params list (which would confuse
callers about what they have to pass)."
  (case name
    (:gc-impact
     ;; SQL: ... ON ... GROUP BY ...) WHERE r.software_name = ?
     ;;           ^ first ?: subquery's software_name
     ;;           ^ second ?: outer software_name
     ;; resolved-params = (software)
     (list (first resolved-params) (first resolved-params)))
    (:adoption-curve
     ;; SQL has three ? positions: software (events), release-id,
     ;; software (fleet).  resolved-params = (software release-id).
     (list (first resolved-params)
           (second resolved-params)
           (first resolved-params)))
    (t resolved-params)))
