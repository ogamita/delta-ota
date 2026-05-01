// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Ogamita Ltd.

package patch

import (
	"os"
	"path/filepath"
	"testing"
)

// FuzzApply: feeding garbage patch + old-blob bytes must always
// return an error, never panic. We never want a malicious patch
// file from a man-in-the-middle to crash the agent.
func FuzzApply(f *testing.F) {
	f.Add([]byte("AAAAAAAAAA"), []byte("not a patch"))
	f.Add([]byte{}, []byte{})
	f.Add([]byte{0xFF, 0xFE, 0xFD}, []byte{0x00, 0x01})

	f.Fuzz(func(t *testing.T, oldBytes, patchBytes []byte) {
		dir, err := os.MkdirTemp("", "patch-fuzz-")
		if err != nil {
			t.Fatal(err)
		}
		defer os.RemoveAll(dir)

		oldPath := filepath.Join(dir, "old")
		patchPath := filepath.Join(dir, "p")
		dstPath := filepath.Join(dir, "new")
		if err := os.WriteFile(oldPath, oldBytes, 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(patchPath, patchBytes, 0o644); err != nil {
			t.Fatal(err)
		}
		// Use a hash that the result almost certainly will NOT match.
		expected := "0000000000000000000000000000000000000000000000000000000000000000"
		_, _ = Apply(oldPath, patchPath, dstPath, expected, "bsdiff")
	})
}
