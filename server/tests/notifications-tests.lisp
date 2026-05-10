;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.
;;;
;;; v1.7: tests for opt-in client emails + notifications outbox.
;;;
;;; Three layers, matching the source split:
;;;
;;;   1. Catalogue-side: record/list/delete client emails;
;;;      enqueue/claim/mark-sent/mark-failed/restart-recovery
;;;      for the outbox.
;;;
;;;   2. ENQUEUE-PUBLISH-NOTIFICATIONS: the fan-out that the
;;;      publish handler calls.  Reads the v1.5 snapshot, joins
;;;      against the outbox uniqueness, and enqueues only for
;;;      clients on an older version.
;;;
;;; The pool dispatch path (HTTP POST + retry on 4xx vs 5xx)
;;; is exercised end-to-end by tests/e2e/notifications.sh
;;; against a Python webhook receiver; doing it here would
;;; require mocking dexador, which is heavier than it's worth
;;; given the e2e covers the same surface with a real network
;;; round-trip.

(in-package #:ota-server.tests)

(def-suite ota-server-notifications
  :description "v1.7 client emails + notifications outbox."
  :in ota-server-suite)

(in-suite ota-server-notifications)

(defun fresh-notif-catalogue ()
  (let* ((root (make-tmp-dir))
         (db (ota-server.catalogue:open-catalogue
              (merge-pathnames "db/ota.db" root))))
    (ota-server.catalogue:run-migrations db)
    (values db root)))

;; ---------------------------------------------------------------------------
;; client_emails
;; ---------------------------------------------------------------------------

(test client-emails-roundtrip
  "Register + list + delete one address.  Idempotent on re-PUT."
  (multiple-value-bind (cat root) (fresh-notif-catalogue)
    (unwind-protect
         (progn
           (ota-server.catalogue:record-client-email
            cat :client-id "c-1" :email "alice@example.com")
           ;; Re-PUT is a no-op (PRIMARY KEY).
           (ota-server.catalogue:record-client-email
            cat :client-id "c-1" :email "alice@example.com")
           (let ((rows (ota-server.catalogue:list-client-emails cat "c-1")))
             (is (= 1 (length rows)))
             (is (string= "alice@example.com" (getf (first rows) :email)))
             (is (null (getf (first rows) :verified-at))))
           ;; Multiple addresses per client.
           (ota-server.catalogue:record-client-email
            cat :client-id "c-1" :email "bob@example.com")
           (is (= 2 (length (ota-server.catalogue:list-client-emails cat "c-1"))))
           ;; Delete one.
           (let ((deleted (ota-server.catalogue:delete-client-email
                           cat :client-id "c-1" :email "alice@example.com")))
             (is (= 1 deleted)))
           (is (= 1 (length (ota-server.catalogue:list-client-emails cat "c-1")))))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test delete-all-emails-when-email-nil
  "DELETE-CLIENT-EMAIL with EMAIL=NIL removes all addresses for
the client (GDPR right-to-deletion path)."
  (multiple-value-bind (cat root) (fresh-notif-catalogue)
    (unwind-protect
         (progn
           (ota-server.catalogue:record-client-email
            cat :client-id "c-1" :email "a@x.com")
           (ota-server.catalogue:record-client-email
            cat :client-id "c-1" :email "b@x.com")
           (ota-server.catalogue:record-client-email
            cat :client-id "c-1" :email "c@x.com")
           (let ((deleted (ota-server.catalogue:delete-client-email
                           cat :client-id "c-1")))
             (is (= 3 deleted)))
           (is (null (ota-server.catalogue:list-client-emails cat "c-1"))))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

;; ---------------------------------------------------------------------------
;; notifications_outbox
;; ---------------------------------------------------------------------------

(test enqueue-notification-idempotent
  "Two enqueues with the same (client, software, release, reason)
hit the UNIQUE constraint; the second is :existing."
  (multiple-value-bind (cat root) (fresh-notif-catalogue)
    (unwind-protect
         (let ((args (list :client-id "c-1" :software "myapp"
                           :release-id "myapp/linux-x86_64/1.0.0"
                           :reason "publish")))
           (multiple-value-bind (s1 id1)
               (apply #'ota-server.catalogue:enqueue-notification cat args)
             (multiple-value-bind (s2 id2)
                 (apply #'ota-server.catalogue:enqueue-notification cat args)
               (is (eq :enqueued s1))
               (is (eq :existing s2))
               (is (integerp id1))
               (is (= id1 id2)))))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test claim-next-marks-running-and-increments-attempts
  (multiple-value-bind (cat root) (fresh-notif-catalogue)
    (unwind-protect
         (progn
           (ota-server.catalogue:enqueue-notification
            cat :client-id "c-1" :software "myapp"
                :release-id "myapp/linux-x86_64/1.0.0")
           (let ((row (ota-server.catalogue:claim-next-notification cat)))
             (is (not (null row)))
             (is (string= "running" (getf row :status)))
             (is (= 1 (getf row :attempts))))
           (is (null (ota-server.catalogue:claim-next-notification cat))
               "second claim against empty queue is NIL"))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test mark-sent-and-mark-failed
  (multiple-value-bind (cat root) (fresh-notif-catalogue)
    (unwind-protect
         (progn
           (ota-server.catalogue:enqueue-notification
            cat :client-id "c-1" :software "myapp"
                :release-id "myapp/linux-x86_64/1.0.0")
           (ota-server.catalogue:enqueue-notification
            cat :client-id "c-2" :software "myapp"
                :release-id "myapp/linux-x86_64/1.0.0")
           (let ((r1 (ota-server.catalogue:claim-next-notification cat))
                 (r2 (ota-server.catalogue:claim-next-notification cat)))
             (ota-server.catalogue:mark-notification-sent cat (getf r1 :id))
             ;; Permanent failure -- give-up T.
             (ota-server.catalogue:mark-notification-failed
              cat (getf r2 :id) "4xx" :give-up t))
           (is (= 1 (ota-server.catalogue:count-notifications cat :status "sent")))
           (is (= 1 (ota-server.catalogue:count-notifications cat :status "failed"))))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test mark-failed-keeps-pending-when-not-give-up
  "A transient failure (no give-up) leaves the row pending so the
next pool tick retries; attempts has already been incremented by
the claim that preceded this call."
  (multiple-value-bind (cat root) (fresh-notif-catalogue)
    (unwind-protect
         (progn
           (ota-server.catalogue:enqueue-notification
            cat :client-id "c-1" :software "myapp"
                :release-id "myapp/linux-x86_64/1.0.0")
           (let ((r (ota-server.catalogue:claim-next-notification cat)))
             (ota-server.catalogue:mark-notification-failed
              cat (getf r :id) "5xx" :give-up nil))
           (is (= 1 (ota-server.catalogue:count-notifications cat :status "pending")))
           (is (= 0 (ota-server.catalogue:count-notifications cat :status "failed"))))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test reset-stale-running-notifications
  "Boot recovery moves 'running' rows back to 'pending'."
  (multiple-value-bind (cat root) (fresh-notif-catalogue)
    (unwind-protect
         (progn
           (ota-server.catalogue:enqueue-notification
            cat :client-id "c-1" :software "myapp"
                :release-id "myapp/linux-x86_64/1.0.0")
           (ota-server.catalogue:claim-next-notification cat)
           (is (= 1 (ota-server.catalogue:count-notifications cat :status "running")))
           (let ((reset (ota-server.catalogue:reset-stale-running-notifications cat)))
             (is (= 1 reset)))
           (is (= 0 (ota-server.catalogue:count-notifications cat :status "running")))
           (is (= 1 (ota-server.catalogue:count-notifications cat :status "pending"))))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

;; ---------------------------------------------------------------------------
;; enqueue-publish-notifications
;; ---------------------------------------------------------------------------

(test enqueue-publish-notifications-fans-out-to-older-clients
  "Three clients on three different releases; publishing 2.0.0
enqueues one notification per client whose current isn't 2.0.0.
A client on the just-published release gets nothing."
  (multiple-value-bind (cat root) (fresh-notif-catalogue)
    (unwind-protect
         (progn
           (ota-server.catalogue:record-client-software-state
            cat :client-id "c-1" :software "myapp"
                :current-release-id "myapp/linux-x86_64/1.0.0"
                :kind "install")
           (ota-server.catalogue:record-client-software-state
            cat :client-id "c-2" :software "myapp"
                :current-release-id "myapp/linux-x86_64/1.1.0"
                :kind "install")
           (ota-server.catalogue:record-client-software-state
            cat :client-id "c-3" :software "myapp"
                :current-release-id "myapp/linux-x86_64/2.0.0"
                :kind "install")
           (let ((enqueued (ota-server.workers:enqueue-publish-notifications
                            cat :software "myapp"
                                :release-id "myapp/linux-x86_64/2.0.0")))
             (is (= 2 enqueued)))
           (is (= 2 (ota-server.catalogue:count-notifications cat :status "pending"))))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test enqueue-publish-notifications-re-run-is-no-op
  "Calling enqueue-publish-notifications twice for the same release
hits the UNIQUE constraint -- second call enqueues 0 new rows."
  (multiple-value-bind (cat root) (fresh-notif-catalogue)
    (unwind-protect
         (progn
           (ota-server.catalogue:record-client-software-state
            cat :client-id "c-1" :software "myapp"
                :current-release-id "myapp/linux-x86_64/1.0.0"
                :kind "install")
           (let ((a (ota-server.workers:enqueue-publish-notifications
                     cat :software "myapp"
                         :release-id "myapp/linux-x86_64/2.0.0"))
                 (b (ota-server.workers:enqueue-publish-notifications
                     cat :software "myapp"
                         :release-id "myapp/linux-x86_64/2.0.0")))
             (is (= 1 a))
             (is (= 0 b))))
      (ota-server.catalogue:close-catalogue cat)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))
