;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.
;;;
;;; Manifest construction, JSON serialisation, and Ed25519 signing /
;;; verification.  The signature is detached (delivered alongside the
;;; manifest JSON) and the JSON is the byte-exact input to both
;;; signing and verification, so the client must accept the bytes as
;;; the server emits them.

(in-package #:ota-server.manifest)

(defun bytes-to-hex (bytes)
  (ironclad:byte-array-to-hex-string bytes))

(defun hex-to-bytes (hex)
  (ironclad:hex-string-to-byte-array hex))

(defstruct keypair
  public
  private)

(defun load-or-generate-keypair (key-dir)
  "Load Ed25519 keypair from KEY-DIR, generating one on first run.
   Files: ed25519.priv (raw 32 bytes), ed25519.pub (raw 32 bytes)."
  (ensure-directories-exist key-dir)
  (let ((priv-path (merge-pathnames "ed25519.priv" key-dir))
        (pub-path  (merge-pathnames "ed25519.pub"  key-dir)))
    (cond
      ((and (probe-file priv-path) (probe-file pub-path))
       (make-keypair
        :private (read-raw-bytes priv-path)
        :public  (read-raw-bytes pub-path)))
      (t
       (multiple-value-bind (priv pub) (ironclad:generate-key-pair :ed25519)
         (let ((priv-bytes (ironclad:ed25519-key-x priv))
               (pub-bytes  (ironclad:ed25519-key-y pub)))
           (write-raw-bytes priv-path priv-bytes)
           (write-raw-bytes pub-path  pub-bytes)
           (make-keypair :private priv-bytes :public pub-bytes)))))))

(defun keypair-public-hex (kp)  (bytes-to-hex (keypair-public  kp)))
(defun keypair-private-hex (kp) (bytes-to-hex (keypair-private kp)))

(defun read-raw-bytes (path)
  (with-open-file (in path :direction :input :element-type '(unsigned-byte 8))
    (let* ((n (file-length in))
           (buf (make-array n :element-type '(unsigned-byte 8))))
      (read-sequence buf in)
      buf)))

(defun write-raw-bytes (path bytes)
  (with-open-file (out path :direction :output
                            :if-exists :supersede
                            :if-does-not-exist :create
                            :element-type '(unsigned-byte 8))
    (write-sequence bytes out)))

;; ---------------------------------------------------------------------------
;; Ordered JSON objects.
;;
;; CL hash-tables are *not* ordered by the standard, so we cannot
;; rely on jzon's hash-table-as-object encoding for a signed
;; manifest.  Use vectors of two-element pairs and a custom writer
;; that emits keys in the vector's element order.  The wrapper
;; struct distinguishes "ordered object" from "JSON array of
;; pairs" at serialisation time.
;; ---------------------------------------------------------------------------

(defstruct ordered-object pairs)

(defun ordered (&rest key-value-pairs)
  "Return an ORDERED-OBJECT whose KEY-VALUE-PAIRS are
   (k1 v1 k2 v2 ...).  Order is preserved on serialisation."
  (make-ordered-object
   :pairs (coerce
           (loop for (k v) on key-value-pairs by #'cddr collect (cons k v))
           'vector)))

(defun ensure-vector (x)
  (if (vectorp x) x (coerce x 'vector)))

(defun write-json-value (value stream)
  "Walk a value tree, writing JSON to STREAM.  ORDERED-OBJECTs are
   walked recursively; everything else is delegated to jzon."
  (cond
    ((ordered-object-p value)
     (write-char #\{ stream)
     (loop for pair across (ordered-object-pairs value)
           for first = t then nil
           do (unless first (write-char #\, stream))
              (com.inuoe.jzon:stringify (car pair) :stream stream)
              (write-char #\: stream)
              (write-json-value (cdr pair) stream))
     (write-char #\} stream))
    ((and (vectorp value) (not (stringp value)))
     (write-char #\[ stream)
     (loop for v across value
           for first = t then nil
           do (unless first (write-char #\, stream))
              (write-json-value v stream))
     (write-char #\] stream))
    (t
     (com.inuoe.jzon:stringify value :stream stream))))

(defun build-manifest-plist (&key software os arch os-versions version
                                  blob-sha256 blob-size blob-url
                                  channels classifications
                                  uncollectable deprecated published-at
                                  notes (patches-in '()))
  "Return an ORDERED-OBJECT that serialises to the manifest JSON in a
   deterministic key order — the bytes are signed, so byte-exactness
   matters.  PATCHES-IN is a list of plists with keys :from :sha256
   :size :patcher (sorted by ascending size)."
  (ordered
   "schema_version"  1
   "release_id"      (format nil "~A/~A-~A/~A" software os arch version)
   "software"        software
   "os"              os
   "arch"            arch
   "os_versions"     (ensure-vector (or os-versions #()))
   "version"         version
   "published_at"    (or published-at (iso8601-now))
   "blob"            (ordered "sha256" blob-sha256
                              "size"   blob-size
                              "url"    blob-url)
   "patches_in"      (coerce
                      (mapcar (lambda (p)
                                (ordered
                                 "from"    (getf p :from)
                                 "patcher" (or (getf p :patcher) "bsdiff")
                                 "sha256"  (getf p :sha256)
                                 "size"    (getf p :size)
                                 "url"     (format nil "/v1/patches/~A"
                                                   (getf p :sha256))))
                              patches-in)
                      'vector)
   "patches_out"     #()
   "channels"        (ensure-vector (or channels #()))
   "classifications" (ensure-vector (or classifications #()))
   "deprecated"      (if deprecated t nil)
   "uncollectable"   (if uncollectable t nil)
   "notes"           (or notes "")))

(defun iso8601-now ()
  (multiple-value-bind (s m h d mo y) (decode-universal-time (get-universal-time) 0)
    (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ" y mo d h m s)))

(defun manifest-to-json-bytes (manifest-object)
  "Render a manifest ORDERED-OBJECT to deterministic JSON bytes."
  (let ((s (make-string-output-stream)))
    (write-json-value manifest-object s)
    (sb-ext:string-to-octets (get-output-stream-string s)
                             :external-format :utf-8)))

(defun sign-bytes (bytes private-key-bytes public-key-bytes)
  "Return a 64-byte Ed25519 detached signature over BYTES."
  (let ((priv (ironclad:make-private-key :ed25519
                                          :x private-key-bytes
                                          :y public-key-bytes)))
    (ironclad:sign-message priv bytes)))

(defun verify-bytes (bytes signature public-key-bytes)
  "Verify a detached Ed25519 signature.  Returns boolean."
  (let ((pub (ironclad:make-public-key :ed25519 :y public-key-bytes)))
    (ironclad:verify-signature pub bytes signature)))
