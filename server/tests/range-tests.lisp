;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.
;;;
;;; v1.3: tests for HTTP Range support on /v1/blobs/<sha> and
;;; /v1/patches/<sha>.  Two layers:
;;;
;;;   1. Pure-function tests of PARSE-RANGE-HEADER -- the parser is
;;;      where almost all the corner cases live (bytes=N-, bytes=-K,
;;;      bytes=N-M, malformed, multi-range, off-the-end).
;;;
;;;   2. End-to-end HTTP tests that boot a real Woo server, ask for
;;;      various ranges, and compare the bytes against the on-disk
;;;      blob.  These exercise the lambda-responder writer path that
;;;      streams binary chunks back; what looks fine in isolation
;;;      could still hit a Woo writer-encoding gotcha at runtime.

(in-package #:ota-server.tests)

(def-suite ota-server-range
  :description "v1.3 HTTP Range support for blob/patch downloads."
  :in ota-server-suite)

(in-suite ota-server-range)

;; ---------------------------------------------------------------------------
;; PARSE-RANGE-HEADER unit tests.
;; ---------------------------------------------------------------------------

(test parse-range-bounded
  "`bytes=10-19` against a 100-byte file -> (10, 19)."
  (multiple-value-bind (s e)
      (ota-server.http::parse-range-header "bytes=10-19" 100)
    (is (= 10 s))
    (is (= 19 e))))

(test parse-range-open-ended
  "`bytes=42-` against a 100-byte file -> (42, 99)."
  (multiple-value-bind (s e)
      (ota-server.http::parse-range-header "bytes=42-" 100)
    (is (= 42 s))
    (is (= 99 e))))

(test parse-range-suffix
  "`bytes=-10` against a 100-byte file -> last 10 bytes (90, 99)."
  (multiple-value-bind (s e)
      (ota-server.http::parse-range-header "bytes=-10" 100)
    (is (= 90 s))
    (is (= 99 e))))

(test parse-range-suffix-larger-than-file
  "`bytes=-500` against a 100-byte file clamps to the whole file
(0, 99) -- per RFC 7233 §2.1."
  (multiple-value-bind (s e)
      (ota-server.http::parse-range-header "bytes=-500" 100)
    (is (= 0 s))
    (is (= 99 e))))

(test parse-range-end-past-file-clamps
  "`bytes=10-9999` against a 100-byte file clamps end to file size."
  (multiple-value-bind (s e)
      (ota-server.http::parse-range-header "bytes=10-9999" 100)
    (is (= 10 s))
    (is (= 99 e))))

(test parse-range-start-past-file-rejected
  "`bytes=200-300` against a 100-byte file is unsatisfiable -> NIL,
which the caller maps to a 416 response."
  (is (null (ota-server.http::parse-range-header "bytes=200-300" 100))))

(test parse-range-malformed-rejected
  "Various garbage shapes return NIL, not a partial parse."
  (is (null (ota-server.http::parse-range-header "" 100)))
  (is (null (ota-server.http::parse-range-header "bytes=" 100)))
  (is (null (ota-server.http::parse-range-header "bytes=abc-def" 100)))
  (is (null (ota-server.http::parse-range-header "bytes=10" 100)))
  (is (null (ota-server.http::parse-range-header "items=10-20" 100))
      "non-`bytes=` units must be rejected"))

(test parse-range-multi-range-rejected
  "We only support a single range; `bytes=0-9,20-29` is rejected.
Multi-range responses would require multipart/byteranges, which
isn't worth implementing for our resume use case."
  (is (null (ota-server.http::parse-range-header "bytes=0-9,20-29" 100))))

;; ---------------------------------------------------------------------------
;; End-to-end HTTP test.
;; ---------------------------------------------------------------------------
;;
;; We boot a real ota-server on a high port, plant a known blob in
;; the CAS, and exercise /v1/blobs/<sha> with a handful of Range
;; combinations.  The blob is small enough to inline without
;; hammering CI but large enough that "first 10 bytes vs last 10
;; bytes" actually exercises the seek+chunk loop.

(defun random-port ()
  "Return a random high port for the test server.  Pseudo-randomness
is enough -- a collision just makes one test fail to bind, which
re-running picks up."
  (+ 19000 (random 1000)))

(defparameter *range-test-blob-bytes*
  (let ((bytes (make-array 4096 :element-type '(unsigned-byte 8))))
    (loop for i below 4096 do
      ;; A non-trivial pattern so any byte-vs-byte comparison
      ;; failure is obvious -- "all zeros" or "all 0x41" would mask
      ;; an off-by-one slice error.
      (setf (aref bytes i) (logand (* i 73) #xFF)))
    bytes)
  "4 KiB of pseudo-random bytes for the Range integration test.")

(defun http-get (url &key range)
  "Issue a single GET via dexador and return (values status body
headers).  Wraps dexador's exception-on-non-2xx behaviour so the
test can assert on 416 the same way as on 200/206."
  (multiple-value-bind (body status headers)
      (handler-case
          (dexador:get url
                       :headers (when range
                                  (list (cons "Range" range)))
                       :force-binary t)
        (dexador:http-request-failed (c)
          (values (dexador:response-body c)
                  (dexador:response-status c)
                  (dexador:response-headers c))))
    (values status body headers)))

(defun start-test-server-with-blob (port blob-bytes)
  "Boot an ota-server on PORT with BLOB-BYTES installed in its CAS;
return (values handler app-state root sha)."
  (let* ((root (make-tmp-dir))
         (cas (ota-server.storage:make-cas root))
         (db (ota-server.catalogue:open-catalogue
              (merge-pathnames "db/x.db" root)))
         (kp (ota-server.manifest:load-or-generate-keypair
              (merge-pathnames "keys/" root)))
         (state (ota-server.http::make-app-state
                 :cas cas :catalogue db :keypair kp
                 :manifests-dir (merge-pathnames "manifests/" root)
                 :admin-token "x" :hostname "localhost"))
         (tmp (merge-pathnames (format nil "seed-~A.bin" (random (expt 2 32)))
                               root)))
    (ota-server.catalogue:run-migrations db)
    (with-open-file (out tmp :direction :output
                             :if-exists :supersede
                             :element-type '(unsigned-byte 8))
      (write-sequence blob-bytes out))
    (multiple-value-bind (sha size)
        (ota-server.storage:put-blob-from-file cas tmp)
      (declare (ignore size))
      (let ((handler (ota-server.http:start-server
                      state :host "127.0.0.1" :port port :worker-num 1)))
        ;; Minimal wait for Woo to bind the socket.
        (sleep 0.3)
        (values handler state root sha)))))

(test range-end-to-end
  "Boot a real server, plant a 4 KiB blob, exercise full + various
Range requests against /v1/blobs/<sha>.  Verifies the lambda-
responder writer ships binary bytes back unchanged (no UTF-8
mangling) and that the headers + body match what we compute
locally."
  (let* ((port (random-port))
         handler state root sha)
    (unwind-protect
         (progn
           (multiple-value-setq (handler state root sha)
             (start-test-server-with-blob port *range-test-blob-bytes*))
           (let ((url (format nil "http://127.0.0.1:~D/v1/blobs/~A" port sha)))
             ;; --- Full GET advertises Accept-Ranges: bytes ---
             (multiple-value-bind (status body headers) (http-get url)
               (is (= 200 status))
               (is (equalp *range-test-blob-bytes* body))
               (is (string-equal "bytes" (gethash "accept-ranges" headers))
                   "full responses must advertise Accept-Ranges: bytes"))
             ;; --- bytes=0-99 returns the first 100 bytes ---
             (multiple-value-bind (status body headers)
                 (http-get url :range "bytes=0-99")
               (is (= 206 status))
               (is (= 100 (length body)))
               (is (equalp (subseq *range-test-blob-bytes* 0 100) body))
               (is (string= "bytes 0-99/4096" (gethash "content-range" headers))))
             ;; --- bytes=2000- is open-ended ---
             (multiple-value-bind (status body headers)
                 (http-get url :range "bytes=2000-")
               (is (= 206 status))
               (is (= 2096 (length body)))
               (is (equalp (subseq *range-test-blob-bytes* 2000) body))
               (is (string= "bytes 2000-4095/4096" (gethash "content-range" headers))))
             ;; --- bytes=-50 returns the last 50 bytes ---
             (multiple-value-bind (status body headers)
                 (http-get url :range "bytes=-50")
               (is (= 206 status))
               (is (= 50 (length body)))
               (is (equalp (subseq *range-test-blob-bytes* 4046) body))
               (is (string= "bytes 4046-4095/4096" (gethash "content-range" headers))))
             ;; --- Out-of-range returns 416 with Content-Range: bytes */SIZE
             (multiple-value-bind (status body headers)
                 (http-get url :range "bytes=99999-")
               (declare (ignore body))
               (is (= 416 status))
               (is (string= "bytes */4096" (gethash "content-range" headers))))))
      (when handler (ota-server.http:stop-server handler))
      (when state
        (ota-server.catalogue:close-catalogue
         (ota-server.http::app-state-catalogue state)))
      (when root
        (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore)))))
