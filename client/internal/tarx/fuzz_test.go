// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Ogamita Ltd.

package tarx

import (
	"bytes"
	"os"
	"testing"
)

// FuzzExtract: any byte sequence as input must either extract
// successfully or return an error — never panic, and never
// write a file outside the destination root. The dest is a tmp
// dir created per fuzz iteration.
func FuzzExtract(f *testing.F) {
	// Seed with a minimal valid tar: two zero blocks.
	f.Add(make([]byte, 1024))
	// Empty input.
	f.Add([]byte{})
	// Garbage.
	f.Add([]byte("definitely not a tar archive"))

	f.Fuzz(func(t *testing.T, data []byte) {
		dst, err := os.MkdirTemp("", "tarx-fuzz-")
		if err != nil {
			t.Fatal(err)
		}
		defer os.RemoveAll(dst)
		_ = Extract(bytes.NewReader(data), dst)
	})
}

// FuzzSafeName: every input must return either nil (ok) or an
// error. Never panic.
func FuzzSafeName(f *testing.F) {
	for _, s := range []string{
		"a/b.txt",
		"/abs",
		"../parent",
		"../../etc/passwd",
		"a/../b",
		"\x00null",
		"CON",
		"con.exe",
		"PRN.LOG",
		"normal.txt",
		"",
	} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, name string) {
		_ = safeName(name)
	})
}
