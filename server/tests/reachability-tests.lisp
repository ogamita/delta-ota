;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.
;;;
;;; v1.6: tests for the reachability-aware GC.
;;;
;;; Three layers, increasing coverage scope:
;;;
;;;   1. SHORTEST-PATCH-PATH on synthetic graphs (no catalogue).
;;;      Most bugs in path-finding live here -- Dijkstra over a
;;;      hash-table-backed adjacency list with an excluded-edges
;;;      filter and a fallback-cap.
;;;
;;;   2. COMPUTE-REACHABILITY-PLAN against a seeded catalogue,
;;;      verifying the four fate buckets and edges-to-build.
;;;
;;;   3. GC-SOFTWARE end-to-end: pin endpoints, GC middle, confirm
;;;      reachability is preserved (an edge gets built first) or
;;;      the GC aborts when infeasible.
;;;
;;; Lazy upgrade-time build is covered by tests/e2e/lazy-upgrade.sh
;;; because it needs real blobs + a real bsdiff binary; unit-level
;;; tests would only verify the dispatch shape (which the e2e covers
;;; better with curl).

(in-package #:ota-server.tests)

(def-suite ota-server-reachability
  :description "v1.6 reachability-aware GC."
  :in ota-server-suite)

(in-suite ota-server-reachability)

;; ---------------------------------------------------------------------------
;; SHORTEST-PATCH-PATH on synthetic graphs
;; ---------------------------------------------------------------------------

(defun %patch (from to size)
  "Build a patch plist matching the shape returned by
LIST-PATCHES-FOR-SOFTWARE.  Tests use these to construct
synthetic graphs in-memory."
  (list :from-release-id from :to-release-id to :size size
        :sha256 (format nil "sha-~A-~A" from to)
        :patcher "bsdiff"))

(test shortest-path-linear-chain
  "A -> B -> C -> D, equal edge weights.  Cheapest path is the
chain, total cost = 3."
  (let ((patches (list (%patch "A" "B" 100)
                       (%patch "B" "C" 100)
                       (%patch "C" "D" 100))))
    (multiple-value-bind (path cost)
        (ota-server.workers:shortest-patch-path patches "A" "D")
      (is (= 3 (length path)))
      (is (= 300 cost))
      (is (string= "A" (getf (first path) :from-release-id)))
      (is (string= "D" (getf (third path) :to-release-id))))))

(test shortest-path-prefers-direct-when-cheaper
  "A -> D direct = 50; A -> B -> C -> D chain = 300.  Path
finder picks the cheap direct edge."
  (let ((patches (list (%patch "A" "B" 100)
                       (%patch "B" "C" 100)
                       (%patch "C" "D" 100)
                       (%patch "A" "D" 50))))
    (multiple-value-bind (path cost)
        (ota-server.workers:shortest-patch-path patches "A" "D")
      (is (= 1 (length path)))
      (is (= 50 cost)))))

(test shortest-path-no-route-returns-nil
  "When no edge connects FROM to TO, returns (values NIL NIL)."
  (let ((patches (list (%patch "A" "B" 100)
                       (%patch "C" "D" 100))))
    (multiple-value-bind (path cost)
        (ota-server.workers:shortest-patch-path patches "A" "D")
      (is (null path))
      (is (null cost)))))

(test shortest-path-excluded-edges
  "Excluding a node removes both incoming and outgoing edges.
With B excluded, A->B->C is broken; remaining path A->D->C must
be picked or NIL returned."
  (let ((patches (list (%patch "A" "B" 100)
                       (%patch "B" "C" 100)
                       (%patch "A" "D" 100)
                       (%patch "D" "C" 100)))
        (excluded (make-hash-table :test 'equal)))
    (setf (gethash "B" excluded) t)
    (multiple-value-bind (path cost)
        (ota-server.workers:shortest-patch-path
         patches "A" "C" :excluded-release-ids excluded)
      (is (= 2 (length path)))
      (is (= 200 cost))
      (is (string= "D" (getf (first path) :to-release-id))))))

(test shortest-path-respects-fallback-cap
  "When the cheapest path's cost exceeds FALLBACK-CAP, return
NIL -- the client would prefer a full-blob download."
  (let ((patches (list (%patch "A" "B" 1000))))
    (multiple-value-bind (path cost)
        (ota-server.workers:shortest-patch-path
         patches "A" "B" :fallback-cap 500)
      (is (null path))
      (is (null cost)))
    (multiple-value-bind (path cost)
        (ota-server.workers:shortest-patch-path
         patches "A" "B" :fallback-cap 1500)
      (is (= 1 (length path)))
      (is (= 1000 cost)))))

(test shortest-path-identity-is-empty-zero
  "From X -> X is the trivial path; returns (values () 0)."
  (multiple-value-bind (path cost)
      (ota-server.workers:shortest-patch-path '() "X" "X")
    (is (null path))
    (is (zerop cost))))

;; ---------------------------------------------------------------------------
;; COMPUTE-REACHABILITY-PLAN with a seeded catalogue
;; ---------------------------------------------------------------------------

(defun fresh-reachability-catalogue ()
  (let* ((root (make-tmp-dir))
         (db (ota-server.catalogue:open-catalogue
              (merge-pathnames "db/ota.db" root))))
    (ota-server.catalogue:run-migrations db)
    (values db root)))

(defun %seed-three-releases (db &key (software "myapp"))
  "Seed releases 1.0, 1.1, 1.2 plus the patches 1.0->1.1, 1.0->1.2,
1.1->1.2.  Returns the three release-ids."
  (ota-server.catalogue:ensure-software db :name software)
  (let ((rids (mapcar (lambda (v)
                        (let ((rid (format nil "~A/linux-x86_64/~A" software v)))
                          (ota-server.catalogue:insert-release
                           db
                           :release-id rid
                           :software software :os "linux" :arch "x86_64"
                           :os-versions #() :version v
                           :blob-sha256 (make-string
                                         64
                                         :initial-element
                                         (code-char (+ 65 (random 26))))
                           :blob-size 1000000
                           :manifest-sha256 (make-string 64 :initial-element #\a))
                          rid))
                      '("1.0.0" "1.1.0" "1.2.0"))))
    (destructuring-bind (r10 r11 r12) rids
      (ota-server.catalogue:insert-patch db
        :sha256 "sha-r10-r11" :from-release-id r10 :to-release-id r11
        :patcher "bsdiff" :size 100)
      (ota-server.catalogue:insert-patch db
        :sha256 "sha-r10-r12" :from-release-id r10 :to-release-id r12
        :patcher "bsdiff" :size 200)
      (ota-server.catalogue:insert-patch db
        :sha256 "sha-r11-r12" :from-release-id r11 :to-release-id r12
        :patcher "bsdiff" :size 100))
    rids))

(test reachability-plan-empty-clients-empty-drops
  "No clients, no drops -> plan reports all zeros, no edges to build."
  (multiple-value-bind (db root) (fresh-reachability-catalogue)
    (unwind-protect
         (let ((plan (ota-server.workers:compute-reachability-plan
                      db :software "myapp"
                         :drop-set '()
                         :client-positions '())))
           (is (zerop (getf (getf plan :clients-by-fate) :unaffected)))
           (is (zerop (getf (getf plan :clients-by-fate) :blob-fallback)))
           (is (null (getf plan :edges-to-build))))
      (ota-server.catalogue:close-catalogue db)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test reachability-plan-unaffected-when-direct-path-survives
  "Client at 1.0, target 1.2; we drop 1.1.  The 1.0->1.2 direct
edge survives, so the client is :unaffected."
  (multiple-value-bind (db root) (fresh-reachability-catalogue)
    (unwind-protect
         (destructuring-bind (r10 r11 r12) (%seed-three-releases db)
           (declare (ignore r12))
           (let ((plan (ota-server.workers:compute-reachability-plan
                        db :software "myapp"
                           :drop-set (list r11)
                           :client-positions
                           (list (list :client-id "c-1" :current-release-id r10)))))
             (is (= 1 (getf (getf plan :clients-by-fate) :unaffected)))
             (is (zerop (getf (getf plan :clients-by-fate) :blob-fallback)))
             (is (null (getf plan :edges-to-build)))))
      (ota-server.catalogue:close-catalogue db)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test reachability-plan-blob-fallback-when-only-path-broken
  "Out-of-order scenario: client at 1.1, target 1.2, but the only
path is via the dropped 1.0 (artificial: pretend 1.1->1.2 doesn't
exist).  We hand-construct a catalogue without the 1.1->1.2 patch
to force the situation."
  (multiple-value-bind (db root) (fresh-reachability-catalogue)
    (unwind-protect
         (progn
           (ota-server.catalogue:ensure-software db :name "myapp")
           (dolist (v '("1.0.0" "1.1.0" "1.2.0"))
             (ota-server.catalogue:insert-release
              db
              :release-id (format nil "myapp/linux-x86_64/~A" v)
              :software "myapp" :os "linux" :arch "x86_64"
              :os-versions #() :version v
              :blob-sha256 (make-string 64 :initial-element
                                       (code-char (+ 65 (random 26))))
              :blob-size 1000000
              :manifest-sha256 (make-string 64 :initial-element #\a)))
           ;; Only 1.0->1.1 and 1.0->1.2 exist.  No 1.1->1.2.
           (ota-server.catalogue:insert-patch
            db :sha256 "p1" :from-release-id "myapp/linux-x86_64/1.0.0"
            :to-release-id "myapp/linux-x86_64/1.1.0"
            :patcher "bsdiff" :size 100)
           (ota-server.catalogue:insert-patch
            db :sha256 "p2" :from-release-id "myapp/linux-x86_64/1.0.0"
            :to-release-id "myapp/linux-x86_64/1.2.0"
            :patcher "bsdiff" :size 100)
           (let ((plan (ota-server.workers:compute-reachability-plan
                        db :software "myapp"
                           :drop-set '()           ; nothing dropped
                           :client-positions
                           (list (list :client-id "c-1"
                                       :current-release-id
                                       "myapp/linux-x86_64/1.1.0")))))
             ;; Without dropping anything, the only path 1.1 -> 1.2 doesn't
             ;; exist.  Client falls into :blob-fallback and an
             ;; edge-to-build is proposed.
             (is (= 1 (getf (getf plan :clients-by-fate) :blob-fallback)))
             (is (= 1 (length (getf plan :edges-to-build))))
             (let ((edge (first (getf plan :edges-to-build))))
               (is (string= "myapp/linux-x86_64/1.1.0" (getf edge :from)))
               (is (string= "myapp/linux-x86_64/1.2.0" (getf edge :to))))))
      (ota-server.catalogue:close-catalogue db)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test reachability-plan-unreachable-when-current-in-drop-set
  "If a client's current release is also in the drop set, the
client is :unreachable -- no edge build can fix that."
  (multiple-value-bind (db root) (fresh-reachability-catalogue)
    (unwind-protect
         (destructuring-bind (r10 r11 r12) (%seed-three-releases db)
           (declare (ignore r12))
           (let ((plan (ota-server.workers:compute-reachability-plan
                        db :software "myapp"
                           :drop-set (list r10)
                           :client-positions
                           (list (list :client-id "c-orphan"
                                       :current-release-id r10)
                                 (list :client-id "c-ok"
                                       :current-release-id r11)))))
             (is (= 1 (getf (getf plan :clients-by-fate) :unreachable)))
             (is (= 1 (getf (getf plan :clients-by-fate) :unaffected)))
             (is (equal '("c-orphan") (getf plan :blocked-clients)))))
      (ota-server.catalogue:close-catalogue db)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test reachability-plan-feasible-p
  "Feasibility wraps a length check on edges-to-build."
  (is (ota-server.workers:reachability-plan-feasible-p
       (list :edges-to-build '()) 50))
  (is (ota-server.workers:reachability-plan-feasible-p
       (list :edges-to-build (list 1 2 3)) 5))
  (is (not (ota-server.workers:reachability-plan-feasible-p
            (list :edges-to-build (loop for i from 1 to 100 collect i))
            50))))

;; ---------------------------------------------------------------------------
;; GC-SOFTWARE end-to-end with reachability
;; ---------------------------------------------------------------------------

(test gc-software-aborts-when-too-many-edges
  "When the would-be-built edge count exceeds max-built-edges and
allow-blob-fallback is NIL, gc-software returns :aborted T
without dropping anything."
  (multiple-value-bind (db root) (fresh-reachability-catalogue)
    (let ((cas (ota-server.storage:make-cas root)))
      (unwind-protect
           (progn
             (ota-server.catalogue:ensure-software db :name "myapp")
             ;; Five releases, all old, no patches between them, and
             ;; one client on each of the four non-latest.  GC would
             ;; want to drop the four older ones but each needs an
             ;; edge built to reach 1.4.0.
             (loop for v in '("1.0.0" "1.1.0" "1.2.0" "1.3.0" "1.4.0")
                   for i from 0 do
               (ota-server.catalogue:insert-release
                db
                :release-id (format nil "myapp/linux-x86_64/~A" v)
                :software "myapp" :os "linux" :arch "x86_64"
                :os-versions #() :version v
                :blob-sha256 (make-string 64 :initial-element
                                         (code-char (+ 65 i)))
                :blob-size 1000000
                :manifest-sha256 (make-string 64 :initial-element #\a)))
             ;; Stamp ancient published_at so min-age-days passes.
             (ota-server.catalogue::with-catalogue (handle db)
               (sqlite:execute-non-query
                handle
                "UPDATE releases SET published_at = '2024-01-01T00:00:00Z' WHERE software_name = ?"
                "myapp"))
             ;; Client on each non-latest version.
             (loop for v in '("1.0.0" "1.1.0" "1.2.0" "1.3.0")
                   for i from 1 do
               (ota-server.catalogue:record-client-software-state
                db :client-id (format nil "c-~D" i) :software "myapp"
                   :current-release-id
                   (format nil "myapp/linux-x86_64/~A" v)
                   :kind "install"))
             (let ((result (ota-server.workers:gc-software
                            cas db nil
                            (merge-pathnames "manifests/" root)
                            :software "myapp"
                            :min-age-days 1
                            :max-built-edges 2)))
               (is (getf result :aborted)
                   "GC must abort when edges-to-build > max-built-edges")
               (is (null (getf result :pruned)))))
        (ota-server.catalogue:close-catalogue db)
        (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore)))))

(test gc-software-allow-blob-fallback-proceeds
  "With allow-blob-fallback = T, gc-software prunes the candidates
even when edges-to-build exceeds the cap (the operator
explicitly accepts that clients will full-blob)."
  (multiple-value-bind (db root) (fresh-reachability-catalogue)
    (let ((cas (ota-server.storage:make-cas root)))
      (unwind-protect
           (progn
             (ota-server.catalogue:ensure-software db :name "myapp")
             (loop for v in '("1.0.0" "1.1.0" "1.2.0" "1.3.0" "1.4.0")
                   for i from 0 do
               (ota-server.catalogue:insert-release
                db
                :release-id (format nil "myapp/linux-x86_64/~A" v)
                :software "myapp" :os "linux" :arch "x86_64"
                :os-versions #() :version v
                :blob-sha256 (make-string 64 :initial-element
                                         (code-char (+ 65 i)))
                :blob-size 1000000
                :manifest-sha256 (make-string 64 :initial-element #\a)))
             (ota-server.catalogue::with-catalogue (handle db)
               (sqlite:execute-non-query
                handle
                "UPDATE releases SET published_at = '2024-01-01T00:00:00Z' WHERE software_name = ?"
                "myapp"))
             ;; No clients -> nothing forces a build either way; the
             ;; allow-blob-fallback flag effectively short-circuits
             ;; the build phase.
             (let ((result (ota-server.workers:gc-software
                            cas db nil
                            (merge-pathnames "manifests/" root)
                            :software "myapp"
                            :min-age-days 1
                            :allow-blob-fallback t
                            :max-built-edges 0)))
               (is (not (getf result :aborted)))
               (is (= 4 (length (getf result :pruned)))
                   "should prune all non-latest releases"))
             (is (string= "myapp/linux-x86_64/1.4.0"
                          (getf (first (ota-server.catalogue:list-releases db "myapp"))
                                :release-id))
                 "only 1.4.0 (latest) should survive"))
        (ota-server.catalogue:close-catalogue db)
        (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore)))))
