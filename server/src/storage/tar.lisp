;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Copyright (C) 2026 Ogamita Ltd.
;;;
;;; Deterministic POSIX ustar writer.
;;;
;;; The release blob is a single uncompressed .tar archive whose
;;; content is *byte-identical* across two builds of the same source
;;; tree. This is essential because the patch quality and the
;;; manifest sha256 are computed over these bytes; non-deterministic
;;; metadata would break delta compression and identity.
;;;
;;; Determinism rules:
;;;  - Entries sorted by path, byte-wise (LC_ALL=C equivalent).
;;;  - mtime = 0, uid/gid = 0, uname/gname empty.
;;;  - Modes normalised to 0644 for regular files, 0755 if marked
;;;    executable by the build manifest (NOT by the source fs bits).
;;;  - No xattrs, no sparse entries, no @LongLink. Names that would
;;;    overflow ustar's 100-byte name field are rejected (the build
;;;    is expected to reject such names earlier).
;;;
;;; Phase 1 supports regular files only.  Directories, symlinks, etc.
;;; are added when first needed.

(in-package #:ota-server.storage)

(defstruct tar-entry
  (name nil :type string)
  (bytes nil :type (simple-array (unsigned-byte 8) (*)))
  (executable nil :type boolean))

(defun walk-files (root)
  "Return a sorted list of TAR-ENTRY for every regular file under ROOT."
  (let ((root (truename (uiop:ensure-directory-pathname root)))
        (entries '()))
    (uiop:collect-sub*directories
     root
     (constantly t)
     (constantly t)
     (lambda (subdir)
       (dolist (file (uiop:directory-files subdir))
         (let* ((rel (enough-namestring file root))
                (bytes (read-file-bytes file)))
           (push (make-tar-entry
                  :name rel
                  :bytes bytes
                  :executable (executable-mode-p file))
                 entries)))))
    (sort entries #'string< :key #'tar-entry-name)))

(defun read-file-bytes (path)
  (with-open-file (in path :direction :input :element-type '(unsigned-byte 8))
    (let* ((n (file-length in))
           (buf (make-array n :element-type '(unsigned-byte 8))))
      (read-sequence buf in)
      buf)))

(defun executable-mode-p (path)
  "Phase-1 simplification: trust the source filesystem's user-execute
   bit. The proper build manifest will replace this in phase 2."
  #+sbcl
  (let ((st (sb-posix:stat (namestring path))))
    (logtest (sb-posix:stat-mode st) #o100))
  #-sbcl nil)

(defparameter +block-size+ 512)

(defun blank-block ()
  (make-array +block-size+ :element-type '(unsigned-byte 8) :initial-element 0))

(defun write-octal (target start width value)
  "Write VALUE as zero-padded octal of WIDTH chars, then NUL.  The
   slot uses WIDTH+1 bytes total (octal digits + trailing NUL)."
  (let ((s (format nil "~v,'0O" width value)))
    (assert (= (length s) width))
    (loop for i below width do
      (setf (aref target (+ start i)) (char-code (char s i))))
    (setf (aref target (+ start width)) 0)))

(defun write-string-field (target start max-len str)
  "ASCII string into a fixed-width slot, NUL-padded."
  (let ((bytes (sb-ext:string-to-octets str :external-format :utf-8)))
    (assert (<= (length bytes) max-len))
    (loop for i below (length bytes)
          do (setf (aref target (+ start i)) (aref bytes i)))))

(defun ustar-header (entry)
  "Construct the 512-byte ustar header for ENTRY."
  (let* ((header (blank-block))
         (name (tar-entry-name entry))
         (mode (if (tar-entry-executable entry) #o755 #o644))
         (size (length (tar-entry-bytes entry))))
    (assert (<= (length name) 100))
    (write-string-field header 0 100 name)
    (write-octal header 100 7 mode)            ; mode (8 bytes incl NUL)
    (write-octal header 108 7 0)               ; uid
    (write-octal header 116 7 0)               ; gid
    (write-octal header 124 11 size)           ; size (12 bytes incl NUL)
    (write-octal header 136 11 0)              ; mtime
    ;; Checksum field starts as 8 spaces (ASCII 32) for the chksum
    ;; computation, then is overwritten with the octal sum.
    (loop for i from 148 below 156 do (setf (aref header i) 32))
    (setf (aref header 156) (char-code #\0))   ; typeflag '0' = regular
    ;; magic "ustar" + version "00"
    (write-string-field header 257 6 "ustar ") ; "ustar" + space (USTAR + space format)
    (setf (aref header 257) (char-code #\u))
    (setf (aref header 258) (char-code #\s))
    (setf (aref header 259) (char-code #\t))
    (setf (aref header 260) (char-code #\a))
    (setf (aref header 261) (char-code #\r))
    (setf (aref header 262) 0)                 ; magic NUL
    (setf (aref header 263) (char-code #\0))
    (setf (aref header 264) (char-code #\0))
    ;; uname/gname empty (already NUL).
    ;; Compute checksum.
    (let ((sum 0))
      (dotimes (i +block-size+)
        (incf sum (aref header i)))
      ;; Write octal in 6 digits + NUL + space (8 bytes total).
      (let ((s (format nil "~6,'0O" sum)))
        (loop for i below 6 do
          (setf (aref header (+ 148 i)) (char-code (char s i))))
        (setf (aref header 154) 0)
        (setf (aref header 155) 32)))
    header))

(defun pad-to-block (n)
  (mod (- +block-size+ (mod n +block-size+)) +block-size+))

(defun write-deterministic-tar (entries out)
  "Write a deterministic POSIX-ustar archive to OUT (a binary stream)."
  (dolist (entry entries)
    (write-sequence (ustar-header entry) out)
    (write-sequence (tar-entry-bytes entry) out)
    (let ((pad (pad-to-block (length (tar-entry-bytes entry)))))
      (when (plusp pad)
        (write-sequence (make-array pad :element-type '(unsigned-byte 8)
                                        :initial-element 0)
                        out))))
  ;; Two zero blocks mark end-of-archive.
  (write-sequence (blank-block) out)
  (write-sequence (blank-block) out))

(defun tar-directory-to-file (src-dir out-path)
  "Walk SRC-DIR, build the deterministic tar, write it to OUT-PATH."
  (let ((entries (walk-files src-dir)))
    (with-open-file (out out-path
                         :direction :output
                         :if-exists :supersede
                         :if-does-not-exist :create
                         :element-type '(unsigned-byte 8))
      (write-deterministic-tar entries out)))
  out-path)
