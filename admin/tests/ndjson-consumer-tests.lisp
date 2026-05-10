;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.
;;;
;;; v1.1.1 publish streaming -- client-side NDJSON consumer tests.
;;;
;;; The streaming consumer reads from a binary stream that dexador
;;; gives us when :want-stream + :force-binary are set.  We can't
;;; spin up a real HTTP server in a unit test (the e2e harness
;;; covers that), but we CAN simulate the response by opening a
;;; temp file in :element-type '(unsigned-byte 8) and feeding it
;;; to %CONSUME-PUBLISH-RESPONSE with a synthetic headers hash.

(in-package #:ota-admin.tests)

(def-suite ota-admin-ndjson-consumer
  :description "Client-side NDJSON consumer (v1.1.1).")

(in-suite ota-admin-ndjson-consumer)

(defun headers-with (content-type)
  (let ((h (make-hash-table :test 'equal)))
    (setf (gethash "content-type" h) content-type)
    h))

(defun bytes-stream (string)
  "Write STRING (UTF-8) to a temp file and return an open binary
input stream over it.  Caller closes it (or it's GC'd; but tests
should close to be polite)."
  (let* ((path (merge-pathnames
                (format nil "ota-ndjson-test-~A" (random 1000000))
                (uiop:temporary-directory)))
         (bytes (sb-ext:string-to-octets string :external-format :utf-8)))
    (with-open-file (out path :direction :output :if-exists :supersede
                              :element-type '(unsigned-byte 8))
      (write-sequence bytes out))
    (open path :direction :input :element-type '(unsigned-byte 8))))

;; ---------------------------------------------------------------------------
;; %read-utf8-line
;; ---------------------------------------------------------------------------

(test read-utf8-line-splits-on-newline
  "Reads up to the next #\\Newline; trailing newline is stripped."
  (let ((s (bytes-stream "first
second
third")))
    (unwind-protect
         (progn
           (is (string= "first"  (ota-admin::%read-utf8-line s)))
           (is (string= "second" (ota-admin::%read-utf8-line s)))
           (is (string= "third"  (ota-admin::%read-utf8-line s)))
           (is (null (ota-admin::%read-utf8-line s))))
      (close s))))

(test read-utf8-line-handles-utf8-multibyte
  "UTF-8 sequences spanning multiple bytes round-trip."
  (let ((s (bytes-stream "résumé
中文
")))
    (unwind-protect
         (progn
           (is (string= "résumé" (ota-admin::%read-utf8-line s)))
           (is (string= "中文"   (ota-admin::%read-utf8-line s)))
           (is (null (ota-admin::%read-utf8-line s))))
      (close s))))

(test read-utf8-line-empty-stream-returns-nil
  (let ((s (bytes-stream "")))
    (unwind-protect
         (is (null (ota-admin::%read-utf8-line s)))
      (close s))))

;; ---------------------------------------------------------------------------
;; %consume-publish-response — happy path: ndjson stream
;; ---------------------------------------------------------------------------

(test consume-ndjson-returns-final-done-event
  "Stream of 5 events -- the final {\"event\":\"done\", …} is what
%consume returns as a hash-table; the intermediate events are
rendered to stderr but not in the return value."
  (let ((s (bytes-stream
            (format nil "~A~%~A~%~A~%~A~%~A~%"
                    "{\"event\":\"stored\",\"release_id\":\"r/x-y/1\"}"
                    "{\"event\":\"patches-started\",\"total\":2}"
                    "{\"event\":\"patch-built\",\"i\":1,\"total\":2,\"from\":\"0.9\",\"sha\":\"a\",\"size\":100}"
                    "{\"event\":\"patch-built\",\"i\":2,\"total\":2,\"from\":\"0.8\",\"sha\":\"b\",\"size\":110}"
                    "{\"event\":\"done\",\"release_id\":\"r/x-y/1\",\"blob_sha256\":\"c0ffee\",\"patches_built\":2}"))))
    (unwind-protect
         (let* ((parsed (let ((*error-output* (make-broadcast-stream)))
                          (ota-admin::%consume-publish-response
                           s (headers-with "application/x-ndjson")))))
           (is (hash-table-p parsed))
           (is (string= "done"      (gethash "event"         parsed)))
           (is (string= "r/x-y/1"   (gethash "release_id"    parsed)))
           (is (string= "c0ffee"    (gethash "blob_sha256"   parsed)))
           (is (= 2                 (gethash "patches_built" parsed))))
      (close s))))

(test consume-ndjson-skips-blank-and-malformed-lines
  "Blank lines are skipped silently; an unparseable JSON line is
also skipped (the server may emit non-JSON debug output if
something goes very wrong server-side, and we don't want to
crash the client)."
  (let ((s (bytes-stream
            (format nil "~A~%~%~A~%~A~%~A~%"
                    "{\"event\":\"stored\",\"release_id\":\"r\"}"
                    "this is not json"
                    "" ; blank
                    "{\"event\":\"done\",\"release_id\":\"r\",\"patches_built\":0}"))))
    (unwind-protect
         (let* ((parsed (let ((*error-output* (make-broadcast-stream)))
                          (ota-admin::%consume-publish-response
                           s (headers-with "application/x-ndjson")))))
           (is (string= "done" (gethash "event" parsed)))
           (is (string= "r"    (gethash "release_id" parsed))))
      (close s))))

;; ---------------------------------------------------------------------------
;; %consume-publish-response — failure modes
;; ---------------------------------------------------------------------------

(test consume-ndjson-stream-without-done-synthesises-error
  "When the stream ends without a {\"event\":\"done\", …} (server
crashed mid-publish, or client EOF'd early), %CONSUME returns a
synthetic {\"event\":\"error\", …} so the publish caller can
detect the failure rather than seeing NIL."
  (let ((s (bytes-stream
            (format nil "~A~%~A~%"
                    "{\"event\":\"stored\",\"release_id\":\"r\"}"
                    "{\"event\":\"patches-started\",\"total\":3}"))))
    (unwind-protect
         (let* ((parsed (let ((*error-output* (make-broadcast-stream)))
                          (ota-admin::%consume-publish-response
                           s (headers-with "application/x-ndjson")))))
           (is (hash-table-p parsed))
           (is (string= "error" (gethash "event" parsed)))
           (is (search "without a final" (gethash "message" parsed))))
      (close s))))

(test consume-ndjson-explicit-error-event-survives
  "If the server emits an {\"event\":\"error\", …}, that is NOT a
:done event -- so the consumer's 'no done received' branch fires
and the synthesized error message wins.  Either way the caller
sees event=error.  (Future: we may want the server's error event
to win; doc'd as a v1.2 follow-up if it bites.)"
  (let ((s (bytes-stream
            (format nil "~A~%~A~%"
                    "{\"event\":\"stored\",\"release_id\":\"r\"}"
                    "{\"event\":\"error\",\"message\":\"bsdiff died\"}"))))
    (unwind-protect
         (let* ((parsed (let ((*error-output* (make-broadcast-stream)))
                          (ota-admin::%consume-publish-response
                           s (headers-with "application/x-ndjson")))))
           (is (string= "error" (gethash "event" parsed))))
      (close s))))

;; ---------------------------------------------------------------------------
;; %consume-publish-response — legacy sync (application/json) path
;; ---------------------------------------------------------------------------

(test consume-json-slurps-whole-body
  "When Content-Type is application/json (old server / --no-stream),
the consumer reads the full body and JSON-parses it into a
hash-table -- same shape as what dexador's default mode would
have produced."
  (let ((s (bytes-stream
            "{\"release_id\":\"r/x-y/1\",\"blob_sha256\":\"abc\",\"patches_built\":3}")))
    (unwind-protect
         (let ((parsed (ota-admin::%consume-publish-response
                        s (headers-with "application/json"))))
           (is (string= "r/x-y/1" (gethash "release_id" parsed)))
           (is (string= "abc"     (gethash "blob_sha256" parsed)))
           (is (= 3               (gethash "patches_built" parsed))))
      (close s))))

(test consume-no-content-type-falls-back-to-json
  "Defensive: if the response has no Content-Type at all, treat as
the legacy JSON path rather than guessing.  The body must then
be a single JSON document."
  (let ((s (bytes-stream "{\"event\":\"done\"}")))
    (unwind-protect
         (let ((parsed (ota-admin::%consume-publish-response
                        s (make-hash-table :test 'equal))))
           (is (string= "done" (gethash "event" parsed))))
      (close s))))