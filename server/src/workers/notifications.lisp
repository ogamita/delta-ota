;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.
;;;
;;; v1.7: notification worker pool.
;;;
;;; Mirrors workers/pool.lisp (the v1.2 patch-build pool) structurally:
;;; a fixed-size pool of bordeaux-threads workers consumes
;;; notifications_outbox rows, dispatching one HTTP POST per row to
;;; the operator-configured webhook URL.
;;;
;;; *No SMTP* lives in this process.  Operators run a small webhook
;;; receiver that translates our JSON payload to whatever they
;;; actually use (SMTP relay, SES, SendGrid, Slack, Teams, internal
;;; ticket system).  See ADR-0012 for the design rationale + sample
;;; receivers in tools/notifications/.
;;;
;;; Retry semantics:
;;;   2xx response       -> status='sent'
;;;   4xx response       -> status='failed' immediately (the
;;;                         operator's webhook said no; don't retry)
;;;   5xx / network err  -> stays 'pending' until max_attempts is
;;;                         reached, then 'failed'
;;;
;;; Restart-safety: RESET-STALE-RUNNING-NOTIFICATIONS at boot moves
;;; any 'running' row back to 'pending' so a worker that died
;;; mid-POST doesn't leave a row stuck.

(in-package #:ota-server.workers)

(defstruct notification-pool
  catalogue
  webhook-url
  (webhook-timeout 10)              ; seconds
  webhook-secret                    ; optional HMAC-SHA256 secret
  (max-attempts 5)
  (size 2)
  threads
  (lock (bordeaux-threads:make-lock "ota-notif-pool"))
  (cv (bordeaux-threads:make-condition-variable :name "ota-notif-pool"))
  (stop nil)
  (idle-poll-secs 5.0))

(defun start-notification-pool (catalogue
                                &key webhook-url (webhook-timeout 10)
                                     webhook-secret
                                     (max-attempts 5) (size 2))
  "Spawn SIZE worker threads consuming notifications_outbox.  When
WEBHOOK-URL is NIL the pool is not started -- a deployment that
doesn't care about notifications simply leaves the URL unset."
  (cond
    ((or (null webhook-url) (zerop (length webhook-url)))
     (format t "notification-pool: webhook_url unset, pool not started~%")
     (force-output)
     nil)
    (t
     (let ((pool (make-notification-pool
                  :catalogue catalogue
                  :webhook-url webhook-url
                  :webhook-timeout webhook-timeout
                  :webhook-secret webhook-secret
                  :max-attempts max-attempts
                  :size size)))
       (setf (notification-pool-threads pool)
             (loop for i from 1 to size
                   collect (bordeaux-threads:make-thread
                            (lambda () (%notif-worker-loop pool i))
                            :name (format nil "ota-notif-worker-~D" i))))
       (format t "notification-pool: ~D worker thread~:P started (webhook=~A)~%"
               size webhook-url)
       (force-output)
       pool))))

(defun stop-notification-pool (pool &key (timeout 30))
  (when (and pool (not (notification-pool-stop pool)))
    (bordeaux-threads:with-lock-held ((notification-pool-lock pool))
      (setf (notification-pool-stop pool) t)
      (bordeaux-threads:condition-notify (notification-pool-cv pool)))
    (loop repeat (length (notification-pool-threads pool))
          do (bordeaux-threads:with-lock-held ((notification-pool-lock pool))
               (bordeaux-threads:condition-notify (notification-pool-cv pool))))
    (dolist (th (notification-pool-threads pool))
      (handler-case
          (%notif-join-with-timeout th timeout)
        (error (c)
          (format *error-output* "notification-pool: join failed: ~A~%" c))))
    (format t "notification-pool: stopped~%")
    (force-output)))

(defun notify-notification-pool (pool)
  "Wake one idle worker after enqueueing new rows."
  (when pool
    (bordeaux-threads:with-lock-held ((notification-pool-lock pool))
      (bordeaux-threads:condition-notify (notification-pool-cv pool)))))

(defun %notif-join-with-timeout (thread timeout-secs)
  "Best-effort timed join (mirrors %JOIN-WITH-TIMEOUT in
workers/pool.lisp; bordeaux-threads has no portable timed-join)."
  (let ((joined nil)
        (watchdog
          (bordeaux-threads:make-thread
           (lambda ()
             (sleep timeout-secs)
             (unless joined
               (handler-case
                   (bordeaux-threads:interrupt-thread
                    thread (lambda () (throw 'notif-bail nil)))
                 (error () nil))))
           :name "ota-notif-pool-watchdog")))
    (handler-case
        (catch 'notif-bail
          (bordeaux-threads:join-thread thread))
      (error (c)
        (format *error-output* "notification-pool: join error: ~A~%" c)))
    (setf joined t)
    (handler-case (bordeaux-threads:destroy-thread watchdog)
      (error () nil))))

(defun %notif-worker-loop (pool worker-id)
  (loop
    (when (notification-pool-stop pool) (return))
    (let ((row (handler-case
                   (ota-server.catalogue:claim-next-notification
                    (notification-pool-catalogue pool))
                 (error (c)
                   (format *error-output*
                           "notif-pool[~D]: claim error: ~A~%" worker-id c)
                   (force-output *error-output*)
                   nil))))
      (cond
        (row (%notif-dispatch pool worker-id row))
        (t
         (bordeaux-threads:with-lock-held ((notification-pool-lock pool))
           (unless (notification-pool-stop pool)
             (bordeaux-threads:condition-wait
              (notification-pool-cv pool) (notification-pool-lock pool)
              :timeout (notification-pool-idle-poll-secs pool)))))))))

(defun %notif-dispatch (pool worker-id row)
  "POST the webhook payload for one outbox row.  Maps HTTP outcome
to the catalogue status field per the documented retry policy."
  (let* ((id (getf row :id))
         (catalogue (notification-pool-catalogue pool))
         (attempts (getf row :attempts))
         (max-attempts (notification-pool-max-attempts pool))
         (payload (%notif-build-payload catalogue row)))
    (cond
      ;; If the client has no registered emails, skip immediately --
      ;; nothing to forward to a human.  Mark sent so the row doesn't
      ;; clog the queue forever.
      ((null (getf payload :emails))
       (ota-server.catalogue:mark-notification-sent catalogue id)
       (format t "notif-pool[~D]: row ~D skipped (no emails for client)~%"
               worker-id id)
       (force-output))
      (t
       (handler-case
           (multiple-value-bind (status body)
               (%notif-post pool payload)
             (declare (ignore body))
             (cond
               ((and (integerp status) (<= 200 status 299))
                (ota-server.catalogue:mark-notification-sent catalogue id)
                (format t "notif-pool[~D]: row ~D sent (HTTP ~A)~%"
                        worker-id id status))
               ((and (integerp status) (<= 400 status 499))
                (ota-server.catalogue:mark-notification-failed
                 catalogue id (format nil "webhook returned ~A" status)
                 :give-up t)
                (format *error-output* "notif-pool[~D]: row ~D 4xx, gave up~%"
                        worker-id id))
               (t
                (%notif-failure-with-backoff catalogue id attempts max-attempts
                                             (format nil "webhook returned ~A" status)))))
         (error (c)
           (%notif-failure-with-backoff catalogue id attempts max-attempts
                                        (princ-to-string c))))))))

(defun %notif-failure-with-backoff (catalogue id attempts max-attempts msg)
  "Either re-queue or give up based on the attempts counter."
  (cond
    ((>= attempts max-attempts)
     (ota-server.catalogue:mark-notification-failed
      catalogue id msg :give-up t)
     (format *error-output*
             "notif-pool: row ~D gave up after ~D attempts: ~A~%"
             id attempts msg))
    (t
     (ota-server.catalogue:mark-notification-failed
      catalogue id msg :give-up nil))))

(defun %notif-build-payload (catalogue row)
  "Build the JSON payload for one outbox row.  Resolves the
client's registered emails and the release metadata so the
webhook receiver has everything it needs to compose a human-
readable message."
  (let* ((client-id (getf row :client-id))
         (software (getf row :software))
         (release-id (getf row :release-id))
         (emails (mapcar (lambda (e) (getf e :email))
                         (ota-server.catalogue:list-client-emails
                          catalogue client-id)))
         (rel (or (find release-id
                        (ota-server.catalogue:list-releases catalogue software)
                        :key (lambda (r) (getf r :release-id))
                        :test #'string=)
                  ;; Release was GC'd between enqueue and dispatch.
                  ;; Pass minimal info.
                  (list :version "?" :release-id release-id :blob-size 0))))
    (list :schema-version 1
          :notification-id (getf row :id)
          :reason (getf row :reason)
          :client-id client-id
          :emails emails
          :software software
          :release (list :release-id release-id
                         :version (getf rel :version)
                         :published-at (or (getf rel :published-at) "")
                         :blob-size (or (getf rel :blob-size) 0)))))

(defun %notif-post (pool payload)
  "POST PAYLOAD as JSON to the pool's webhook URL.  Returns
(values STATUS BODY).  Adds X-Ota-Webhook-Signature when a
WEBHOOK-SECRET is configured: HMAC-SHA256 over the raw body,
lowercase hex."
  (let* ((url (notification-pool-webhook-url pool))
         (secret (notification-pool-webhook-secret pool))
         (body (com.inuoe.jzon:stringify
                (%payload-to-hash payload) :pretty nil))
         (body-bytes (sb-ext:string-to-octets body :external-format :utf-8))
         (headers (list (cons "Content-Type" "application/json"))))
    (when (and secret (plusp (length secret)))
      (let ((sig (ironclad:byte-array-to-hex-string
                  (ironclad:hmac-digest
                   (ironclad:update-hmac
                    (ironclad:make-hmac
                     (sb-ext:string-to-octets secret :external-format :utf-8)
                     :sha256)
                    body-bytes)))))
        (push (cons "X-Ota-Webhook-Signature" sig) headers)))
    (multiple-value-bind (resp-body status)
        (handler-case
            (dexador:post url
                          :content body
                          :headers headers
                          :want-stream nil
                          :connect-timeout (notification-pool-webhook-timeout pool)
                          :read-timeout (notification-pool-webhook-timeout pool))
          (dexador:http-request-failed (c)
            (values (dexador:response-body c)
                    (dexador:response-status c))))
      (values status resp-body))))

(defun %payload-to-hash (plist)
  "Translate the internal payload plist into the JSON-friendly
hash-table jzon expects.  Keys are downcased with hyphens
converted to underscores -- so :schema-version becomes
\"schema_version\" -- matching the OBJ helper convention in
http/server.lisp."
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k v) on plist by #'cddr
          do (setf (gethash (substitute #\_ #\-
                                        (string-downcase (symbol-name k)))
                            h)
                   (cond
                     ((and (listp v) (keywordp (first v)))
                      (%payload-to-hash v))
                     ((listp v) (coerce (mapcar (lambda (x)
                                                  (cond
                                                    ((stringp x) x)
                                                    (t x)))
                                                v)
                                        'vector))
                     (t v))))
    h))

;; ---------------------------------------------------------------------------
;; Publish-time fan-out
;; ---------------------------------------------------------------------------

(defun enqueue-publish-notifications (catalogue
                                      &key software release-id
                                           (reason "publish"))
  "Iterate every client tracking SOFTWARE in the snapshot table and
enqueue a notification for each whose current_release_id is
different from RELEASE-ID.  The UNIQUE constraint on the outbox
table makes the operation idempotent on a re-publish.  Returns the
count of newly-enqueued rows."
  (let ((enqueued 0))
    (dolist (cid (ota-server.catalogue:list-clients-on-software
                  catalogue software))
      (let ((state (ota-server.catalogue:get-client-software-state
                    catalogue cid software)))
        (when (and state
                   (getf state :current-release-id)
                   (not (string= (getf state :current-release-id) release-id)))
          (multiple-value-bind (status _id)
              (ota-server.catalogue:enqueue-notification
               catalogue
               :client-id cid
               :software software
               :release-id release-id
               :reason reason)
            (declare (ignore _id))
            (when (eq status :enqueued) (incf enqueued))))))
    enqueued))
