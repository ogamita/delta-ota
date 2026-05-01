;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.
;;;
;;; Local smoke test: build a tiny payload, run it through the server's
;;; storage + manifest + catalogue stack (no HTTP), verify roundtrip.

(in-package #:ota-server.tests)

(in-suite ota-server-suite)

(defvar *test-tmp-counter* 0)

(defun make-tmp-dir ()
  (let* ((id (format nil "ota-test-~A-~A-~A"
                     (get-universal-time)
                     (sb-ext:get-time-of-day)
                     (incf *test-tmp-counter*)))
         (p (merge-pathnames (concatenate 'string id "/")
                             (uiop:temporary-directory))))
    (when (probe-file p)
      (uiop:delete-directory-tree p :validate t))
    (ensure-directories-exist p)
    p))

(defun write-tmp-file (path content)
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output :if-exists :supersede
                            :element-type '(unsigned-byte 8))
    (write-sequence (sb-ext:string-to-octets content :external-format :utf-8) out)))

(test storage-cas-roundtrip
  (let* ((root (make-tmp-dir))
         (cas (ota-server.storage:make-cas root))
         (src (merge-pathnames "src.txt" root))
         (bytes #(72 101 108 108 111 10)))
    (with-open-file (out src :direction :output :if-exists :supersede
                             :element-type '(unsigned-byte 8))
      (write-sequence bytes out))
    (multiple-value-bind (sha size)
        (ota-server.storage:put-blob-from-file cas src)
      (is (= size 6))
      (is (= 64 (length sha)))
      (is (ota-server.storage:has-blob cas sha))
      (is (probe-file (ota-server.storage:cas-blob-path cas sha))))))

(test deterministic-tar
  (let* ((root (make-tmp-dir))
         (src (merge-pathnames "payload/" root)))
    (ensure-directories-exist src)
    (write-tmp-file (merge-pathnames "a.txt" src) "alpha")
    (write-tmp-file (merge-pathnames "b.txt" src) "beta")
    (write-tmp-file (merge-pathnames "sub/c.txt" src) "gamma")
    (let* ((out1 (merge-pathnames "out1.tar" root))
           (out2 (merge-pathnames "out2.tar" root)))
      (ota-server.storage:tar-directory-to-file src out1)
      (ota-server.storage:tar-directory-to-file src out2)
      (is (equalp (ota-server.storage:sha256-hex-of-file out1)
                  (ota-server.storage:sha256-hex-of-file out2))
          "two builds produce byte-identical tar"))))

(test manifest-sign-verify
  (let* ((root (make-tmp-dir))
         (kp (ota-server.manifest:load-or-generate-keypair
              (merge-pathnames "keys/" root)))
         (m (ota-server.manifest:build-manifest-plist
             :software "hello" :os "linux" :arch "x86_64"
             :os-versions #() :version "1.0.0"
             :blob-sha256 (make-string 64 :initial-element #\a)
             :blob-size 12345
             :blob-url "/v1/blobs/...")))
    (let* ((bytes (ota-server.manifest:manifest-to-json-bytes m))
           (sig (ota-server.manifest:sign-bytes
                 bytes (ota-server.manifest:keypair-private kp)
                 (ota-server.manifest:keypair-public kp))))
      (is (ota-server.manifest:verify-bytes
           bytes sig (ota-server.manifest:keypair-public kp))
          "good signature verifies")
      (is (not (ota-server.manifest:verify-bytes
                (concatenate '(simple-array (unsigned-byte 8) (*))
                             bytes #(0))
                sig (ota-server.manifest:keypair-public kp)))
          "tampered bytes do not verify"))))

(test catalogue-crud
  (let* ((root (make-tmp-dir))
         (db (ota-server.catalogue:open-catalogue
              (merge-pathnames "ota.db" root))))
    (ota-server.catalogue:run-migrations db)
    (ota-server.catalogue:ensure-software db :name "hello" :display-name "Hello")
    (ota-server.catalogue:insert-release
     db
     :release-id "hello/linux-x86_64/1.0.0"
     :software "hello" :os "linux" :arch "x86_64"
     :os-versions #() :version "1.0.0"
     :blob-sha256 (make-string 64 :initial-element #\a)
     :blob-size 100
     :manifest-sha256 (make-string 64 :initial-element #\b))
    (is (= 1 (length (ota-server.catalogue:list-software db))))
    (is (= 1 (length (ota-server.catalogue:list-releases db "hello"))))
    (let ((latest (ota-server.catalogue:get-latest-release db "hello")))
      (is (string= "1.0.0" (getf latest :version))))
    (ota-server.catalogue:close-catalogue db)))
