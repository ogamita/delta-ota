;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.
;;;
;;; v1.2: async patch-build worker pool.
;;;
;;; A fixed-size pool of bordeaux-threads workers consumes pending
;;; rows from the catalogue's PATCH_JOBS table and runs vendored
;;; bsdiff(1) on the (from_blob, to_blob) pair, then records the
;;; resulting patch in the PATCHES table via INSERT-PATCH (which
;;; deduplicates on (from, to, patcher), so a re-run after a crash
;;; is harmless).
;;;
;;; The pool is signalled via a condition variable when a publish
;;; handler enqueues new work; idle workers also wake every second
;;; to handle the case where the CV signal was lost (e.g. all
;;; workers were busy and the signal arrived between two wait calls).
;;;
;;; Boot recovery: the catalogue's RESET-STALE-RUNNING-JOBS is called
;;; at server startup before the pool starts, so any 'running' row
;;; left behind by a crashed worker is reset to 'pending' and picked
;;; up by the new pool — bsdiff is deterministic and the dedup on
;;; (from, to, patcher) makes the retry idempotent.

(in-package #:ota-server.workers)

(defstruct patch-pool
  cas
  catalogue
  (size 2)
  threads             ; list of bordeaux-threads:thread
  (lock (bordeaux-threads:make-lock "ota-patch-pool"))
  (cv   (bordeaux-threads:make-condition-variable :name "ota-patch-pool"))
  (stop nil)          ; mutated under LOCK to signal shutdown
  (idle-poll-secs 1.0))

(defun start-patch-pool (cas catalogue &key (size 2))
  "Spawn SIZE worker threads and return the patch-pool struct.  The
threads start consuming from the catalogue immediately; if the queue
is empty they block on the pool's condition variable.

Callers wake the pool after enqueueing new work via NOTIFY-PATCH-POOL."
  (let ((pool (make-patch-pool :cas cas :catalogue catalogue :size size)))
    (setf (patch-pool-threads pool)
          (loop for i from 1 to size
                collect (bordeaux-threads:make-thread
                         (lambda () (%worker-loop pool i))
                         :name (format nil "ota-patch-worker-~D" i))))
    (format t "patch-pool: ~D worker thread~:P started~%" size)
    (force-output)
    pool))

(defun stop-patch-pool (pool &key (timeout 30))
  "Signal shutdown and join all workers.  TIMEOUT is the per-thread
join cap (seconds) — if a thread is mid-bsdiff we wait at most that
long and then move on (the OS reaps it when the process exits).  No-op
when POOL is NIL or already stopped."
  (when (and pool (not (patch-pool-stop pool)))
    (bordeaux-threads:with-lock-held ((patch-pool-lock pool))
      (setf (patch-pool-stop pool) t)
      (bordeaux-threads:condition-notify (patch-pool-cv pool)))
    ;; Wake every blocked worker, not just one.
    (loop repeat (length (patch-pool-threads pool))
          do (bordeaux-threads:with-lock-held ((patch-pool-lock pool))
               (bordeaux-threads:condition-notify (patch-pool-cv pool))))
    (dolist (th (patch-pool-threads pool))
      (handler-case
          (%join-with-timeout th timeout)
        (error (c)
          (format *error-output* "patch-pool: thread join failed: ~A~%" c))))
    (format t "patch-pool: stopped~%")
    (force-output)))

(defun notify-patch-pool (pool)
  "Wake one idle worker.  Called by the publish handler after enqueueing
patch jobs."
  (when pool
    (bordeaux-threads:with-lock-held ((patch-pool-lock pool))
      (bordeaux-threads:condition-notify (patch-pool-cv pool)))))

(defun %join-with-timeout (thread timeout-secs)
  "Best-effort join: spawn a watchdog that raises an interrupt if
THREAD doesn't return within TIMEOUT-SECS.  Bordeaux-threads has no
portable timed-join, so we approximate with INTERRUPT-THREAD."
  (let ((joined nil)
        (watchdog
          (bordeaux-threads:make-thread
           (lambda ()
             (sleep timeout-secs)
             (unless joined
               (handler-case
                   (bordeaux-threads:interrupt-thread
                    thread (lambda () (throw 'patch-pool-bail nil)))
                 (error () nil))))
           :name "ota-patch-pool-watchdog")))
    (handler-case
        (catch 'patch-pool-bail
          (bordeaux-threads:join-thread thread))
      (error (c)
        (format *error-output* "patch-pool: join error: ~A~%" c)))
    (setf joined t)
    ;; Best-effort cleanup; the watchdog is a daemon-ish helper.
    (handler-case (bordeaux-threads:destroy-thread watchdog)
      (error () nil))))

(defun %worker-loop (pool worker-id)
  "Main loop for one pool thread: claim a job, build the patch, mark
done; on empty queue, wait on the CV for new work.  Exits when the
pool's STOP flag is set."
  (loop
    (when (patch-pool-stop pool)
      (return))
    (let ((job (handler-case
                   (ota-server.catalogue:claim-next-patch-job
                    (patch-pool-catalogue pool))
                 (error (c)
                   (format *error-output*
                           "patch-pool[~D]: claim error: ~A~%"
                           worker-id c)
                   (force-output *error-output*)
                   nil))))
      (cond
        (job
         (%run-job pool worker-id job))
        (t
         ;; Queue empty: wait for someone to notify us, with a
         ;; 1-second timeout as a belt-and-braces against missed
         ;; signals.
         (bordeaux-threads:with-lock-held ((patch-pool-lock pool))
           (unless (patch-pool-stop pool)
             (bordeaux-threads:condition-wait
              (patch-pool-cv pool) (patch-pool-lock pool)
              :timeout (patch-pool-idle-poll-secs pool)))))))))

(defun %run-job (pool worker-id job)
  "Execute a single bsdiff job and record the outcome.  Catches every
error so the worker thread keeps running."
  (let ((id (getf job :id)))
    (handler-case
        (multiple-value-bind (sha size)
            (build-patch-from-blobs
             (patch-pool-cas pool)
             (patch-pool-catalogue pool)
             :from-release-id (getf job :from-release-id)
             :to-release-id   (getf job :to-release-id)
             :from-blob-sha   (getf job :from-blob-sha256)
             :to-blob-sha     (getf job :to-blob-sha256))
          (ota-server.catalogue:complete-patch-job
           (patch-pool-catalogue pool) id
           :sha256 sha :size size)
          (format t "patch-pool[~D]: job ~D done (~A->~A, ~A bytes)~%"
                  worker-id id
                  (getf job :from-release-id)
                  (getf job :to-release-id)
                  size)
          (force-output))
      (error (c)
        (let ((msg (princ-to-string c)))
          (handler-case
              (ota-server.catalogue:fail-patch-job
               (patch-pool-catalogue pool) id msg)
            (error (c2)
              (format *error-output*
                      "patch-pool[~D]: also failed to record failure: ~A~%"
                      worker-id c2)))
          (format *error-output*
                  "patch-pool[~D]: job ~D failed: ~A~%"
                  worker-id id msg)
          (force-output *error-output*))))))
