;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.
;;;
;;; v1.6: reachability-aware GC.
;;;
;;; Through v1.5 the GC dropped a release whenever (it wasn't pinned,
;;; old enough, count-users-at-release <= min_user_count).  v1.6 adds
;;; a layer on top: for every active client, Dijkstra over the
;;; patches graph computes the cheapest upgrade path to the client's
;;; target release.  If the simulated drop set would break a client's
;;; only viable path, the GC either pre-builds the minimum set of
;;; missing edges (via the v1.2 patch-build pool) or, with
;;; `allow_blob_fallback`, accepts that affected clients will pull
;;; the full blob on their next upgrade.
;;;
;;; See ADR-0011 for the algorithm + alternatives rejected (bidir
;;; fan-in at publish time, no-snapshot heuristics, etc.).

(in-package #:ota-server.workers)

;; ---------------------------------------------------------------------------
;; Shortest path (Dijkstra over patches)
;; ---------------------------------------------------------------------------

(defun shortest-patch-path (patches from-release-id to-release-id
                            &key excluded-release-ids fallback-cap)
  "Find the cheapest patch path FROM-RELEASE-ID -> TO-RELEASE-ID
in PATCHES (a list of patch plists with :FROM-RELEASE-ID,
:TO-RELEASE-ID, :SIZE).

EXCLUDED-RELEASE-IDS, when supplied, is a hash-table mapping
release-id -> T for releases to *omit* from the graph (i.e.
simulate dropping them).  Any patch whose `from` or `to` is in
this set is treated as if it didn't exist.

FALLBACK-CAP, when supplied, is an upper bound on the total path
cost.  If the cheapest path exceeds it, returns (values NIL NIL)
-- the client would prefer a full-blob download to a chain of
patches.

Returns (values PATH TOTAL-COST), where PATH is the ordered list
of patch plists, or (values NIL NIL) when no acceptable path
exists."
  (when (string= from-release-id to-release-id)
    (return-from shortest-patch-path (values '() 0)))
  (let ((dist (make-hash-table :test 'equal))     ; release-id -> cost
        (prev (make-hash-table :test 'equal))     ; release-id -> patch plist
        (visited (make-hash-table :test 'equal))
        ;; Adjacency: from-release-id -> list of outgoing patch plists.
        (adj  (make-hash-table :test 'equal)))
    (dolist (p patches)
      (let ((from (getf p :from-release-id))
            (to   (getf p :to-release-id)))
        (unless (and excluded-release-ids
                     (or (gethash from excluded-release-ids)
                         (gethash to excluded-release-ids)))
          (push p (gethash from adj '())))))
    (setf (gethash from-release-id dist) 0)
    ;; Naive priority queue -- pick the unvisited node with the
    ;; lowest current cost.  Graphs are small (hundreds of releases
    ;; tops); the O(n²) traversal is negligible.
    (loop
      (multiple-value-bind (next next-cost)
          (%pq-pop-cheapest dist visited)
        (unless next (return))
        (setf (gethash next visited) t)
        (when (and fallback-cap (> next-cost fallback-cap))
          (return))
        (when (string= next to-release-id) (return))
        (dolist (edge (gethash next adj '()))
          (let* ((neighbour (getf edge :to-release-id))
                 (new-cost (+ next-cost (or (getf edge :size) 0)))
                 (old-cost (gethash neighbour dist)))
            (when (or (null old-cost) (< new-cost old-cost))
              (setf (gethash neighbour dist) new-cost
                    (gethash neighbour prev) edge))))))
    (let ((cost (gethash to-release-id dist)))
      (cond
        ((null cost) (values nil nil))
        ((and fallback-cap (> cost fallback-cap)) (values nil nil))
        (t (values (%reconstruct-path prev to-release-id) cost))))))

(defun %pq-pop-cheapest (dist visited)
  "Linear scan: pick the cheapest unvisited node in DIST.  Returns
(values release-id cost) or (values NIL NIL) when DIST has no
remaining unvisited entries."
  (let ((best-r nil) (best-c nil))
    (maphash (lambda (r c)
               (unless (gethash r visited)
                 (when (or (null best-c) (< c best-c))
                   (setf best-r r best-c c))))
             dist)
    (values best-r best-c)))

(defun %reconstruct-path (prev to-id)
  "Walk PREV back from TO-ID, returning the ordered list of edge
patch plists from start to end."
  (let ((path '())
        (cur to-id))
    (loop for edge = (gethash cur prev)
          while edge
          do (push edge path)
             (setf cur (getf edge :from-release-id)))
    path))

;; ---------------------------------------------------------------------------
;; GC plan computation (pure)
;; ---------------------------------------------------------------------------
;;
;; A "plan" answers: given (candidate drops, active clients, current
;; releases, current patches), what would the world look like
;; afterwards?  Two key outputs:
;;
;;   - clients-by-fate: partitions active clients into
;;       :unaffected     -- their cheapest path doesn't touch the drop set
;;       :graceful       -- path changed but still under fallback-ratio
;;       :blob-fallback  -- no acceptable path; would download full blob
;;       :unreachable    -- their current release is also being dropped
;;
;;   - edges-to-build: minimum set of (from -> to) edges that, if
;;     built, would move blob-fallback clients into :graceful.

(defun compute-reachability-plan (catalogue
                                  &key software drop-set client-positions
                                       (fallback-ratio 0.7))
  "Compute the reachability impact of dropping the releases in
DROP-SET from SOFTWARE's catalogue.

DROP-SET     : list of release-id strings the v1.5 GC has marked
               prunable (not pinned, age threshold met, count ≤
               threshold).
CLIENT-POSITIONS : list of plists :CLIENT-ID :CURRENT-RELEASE-ID,
                   as returned by LIST-CLIENT-SOFTWARE-STATES
                   filtered to the software in question.

Returns a plist:
  :clients-by-fate  plist :unaffected/:graceful/:blob-fallback/:unreachable
                    each value an integer count.
  :edges-to-build   list of plists (:FROM :TO :ESTIMATED-SIZE) for
                    the minimal set of patches to pre-build before
                    the drop is safe.
  :drops            the input DROP-SET (echoed for the response).
  :blocked-clients  list of client-ids whose path can't be restored
                    even by building (their `current` is in DROP-SET)."
  (let* ((all-releases (ota-server.catalogue:list-releases catalogue software))
         (target (ota-server.catalogue:highest-semver-release
                  (remove-if (lambda (r)
                               (member (getf r :release-id) drop-set
                                       :test #'string=))
                             all-releases))))
    (cond
      ((null target)
       ;; The drop set swallowed every visible release; plan is empty
       ;; in the sense that there's nowhere left to land.  Report all
       ;; clients as unreachable.
       (list :clients-by-fate
             (list :unaffected 0 :graceful 0 :blob-fallback 0
                   :unreachable (length client-positions))
             :edges-to-build nil
             :drops drop-set
             :blocked-clients
             (mapcar (lambda (c) (getf c :client-id)) client-positions)))
      (t
       (%compute-plan-with-target catalogue software drop-set
                                  client-positions target
                                  fallback-ratio)))))

(defun %compute-plan-with-target (catalogue software drop-set
                                  client-positions target fallback-ratio)
  (let* ((target-rid (getf target :release-id))
         (target-blob-size (getf target :blob-size))
         (cap (and target-blob-size
                   (floor (* fallback-ratio target-blob-size))))
         (patches (ota-server.catalogue:list-patches-for-software
                   catalogue software))
         (drop-hash (make-hash-table :test 'equal))
         (unaffected 0) (graceful 0) (blob-fallback 0) (unreachable 0)
         (edges-needed (make-hash-table :test 'equal))
         (blocked '()))
    (dolist (d drop-set) (setf (gethash d drop-hash) t))
    (dolist (c client-positions)
      (let ((cur (getf c :current-release-id)))
        (cond
          ;; Client's current release is being dropped -- orphaned.
          ((gethash cur drop-hash)
           (incf unreachable)
           (push (getf c :client-id) blocked))
          ;; Client is already on target -- no upgrade needed.
          ((string= cur target-rid)
           (incf unaffected))
          (t
           (%classify-client patches cur target-rid drop-hash cap
                             (lambda (fate)
                               (case fate
                                 (:unaffected (incf unaffected))
                                 (:graceful (incf graceful))
                                 (:blob-fallback
                                  (incf blob-fallback)
                                  (setf (gethash (cons cur target-rid)
                                                 edges-needed)
                                        (list :from cur :to target-rid
                                              :estimated-size
                                              (or target-blob-size 0)))))))))))
    (list :clients-by-fate
          (list :unaffected unaffected
                :graceful graceful
                :blob-fallback blob-fallback
                :unreachable unreachable)
          :edges-to-build (loop for v being the hash-values of edges-needed
                                collect v)
          :drops drop-set
          :blocked-clients (nreverse blocked))))

(defun %classify-client (patches cur target-rid drop-hash cap on-fate)
  "Classify one client position: call ON-FATE with :unaffected,
:graceful, or :blob-fallback."
  (multiple-value-bind (pre-path _pc)
      (shortest-patch-path patches cur target-rid :fallback-cap cap)
    (declare (ignore _pc))
    (cond
      ((and pre-path
            (notany (lambda (edge)
                      (or (gethash (getf edge :from-release-id) drop-hash)
                          (gethash (getf edge :to-release-id) drop-hash)))
                    pre-path))
       (funcall on-fate :unaffected))
      (t
       (multiple-value-bind (post-path _qc)
           (shortest-patch-path patches cur target-rid
                                :excluded-release-ids drop-hash
                                :fallback-cap cap)
         (declare (ignore _qc))
         (cond
           (post-path (funcall on-fate :graceful))
           (t (funcall on-fate :blob-fallback))))))))

(defun reachability-plan-feasible-p (plan max-built-edges)
  "T when PLAN's edges-to-build set fits under MAX-BUILT-EDGES."
  (<= (length (getf plan :edges-to-build)) max-built-edges))

;; ---------------------------------------------------------------------------
;; GC plan execution
;; ---------------------------------------------------------------------------

(defun execute-reachability-builds (cas catalogue plan)
  "Build the edges-to-build in PLAN synchronously via
BUILD-PATCH-FROM-BLOBS (the same path the pool worker calls).
The GC pass itself is offline / cron-scheduled, so blocking on
a handful of builds is acceptable.  Returns the count of edges
built; signals an error on the first build failure (caller must
retry or abort the entire GC).

A future iteration could enqueue the builds through the worker
pool (workers/pool.lisp) and wait on the queue; the queue path
adds inter-process coordination value for two-server deployments
running concurrent GCs.  For v1.6 we keep it simple."
  (let* ((software (and (getf plan :drops)
                        (%software-of-release-id (first (getf plan :drops)))))
         (rels (and software
                    (ota-server.catalogue:list-releases catalogue software)))
         (built 0))
    (dolist (edge (getf plan :edges-to-build))
      (let* ((from-rid (getf edge :from))
             (to-rid   (getf edge :to))
             (from-rel (find from-rid rels
                             :key (lambda (r) (getf r :release-id))
                             :test #'string=))
             (to-rel   (find to-rid rels
                             :key (lambda (r) (getf r :release-id))
                             :test #'string=)))
        (cond
          ((or (null from-rel) (null to-rel))
           (error "reachability: cannot build ~A -> ~A: release not found"
                  from-rid to-rid))
          (t
           (build-patch-from-blobs
            cas catalogue
            :from-release-id from-rid
            :to-release-id   to-rid
            :from-blob-sha   (getf from-rel :blob-sha256)
            :to-blob-sha     (getf to-rel   :blob-sha256))
           (incf built)))))
    built))

(defun %software-of-release-id (release-id)
  "Release IDs are canonically `<software>/<os>-<arch>/<version>`;
return the software name before the first slash."
  (let ((slash (position #\/ release-id)))
    (when slash (subseq release-id 0 slash))))
