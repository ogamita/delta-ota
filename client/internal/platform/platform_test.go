// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Ogamita Ltd.

package platform

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestSetAndReadCurrent_Symlink(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlink path requires developer mode on Windows; covered by SetCurrent which falls back to shim")
	}
	dir := t.TempDir()
	target := filepath.Join(dir, "distribution-1.0.0")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "current")
	kind, err := SetCurrent(target, link)
	if err != nil {
		t.Fatalf("SetCurrent: %v", err)
	}
	if kind != KindSymlink {
		t.Fatalf("kind: want symlink, got %s", kind)
	}
	got, err := ReadCurrent(link)
	if err != nil {
		t.Fatal(err)
	}
	if got != target {
		t.Errorf("ReadCurrent: want %q got %q", target, got)
	}
}

func TestSetAndReadCurrent_Shim(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "distribution-1.0.0")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "current")
	// Force the shim path by making the symlink target a forbidden
	// sentinel — easiest: just write the shim ourselves and verify
	// ReadCurrent finds it.
	if err := writeShim(link+shimSuffix, target); err != nil {
		t.Fatal(err)
	}
	got, err := ReadCurrent(link)
	if err != nil {
		t.Fatal(err)
	}
	if got != target {
		t.Errorf("ReadCurrent shim: want %q got %q", target, got)
	}
}

func TestSwapCurrentToPrevious_Symlink(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlink-only test")
	}
	dir := t.TempDir()
	target := filepath.Join(dir, "distribution-1.0.0")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatal(err)
	}
	cur := filepath.Join(dir, "current")
	prev := filepath.Join(dir, "previous")
	if _, err := SetCurrent(target, cur); err != nil {
		t.Fatal(err)
	}
	if err := SwapCurrentToPrevious(cur, prev); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(cur); !os.IsNotExist(err) {
		t.Errorf("current should be gone after swap")
	}
	got, err := os.Readlink(prev)
	if err != nil {
		t.Fatal(err)
	}
	if got != target {
		t.Errorf("previous: want %q got %q", target, got)
	}
}

func TestLongPath(t *testing.T) {
	switch runtime.GOOS {
	case "windows":
		if got := LongPath(`C:\foo\bar`); got != `\\?\C:\foo\bar` {
			t.Errorf("Windows abs: got %q", got)
		}
		if got := LongPath(`\\srv\share\x`); got != `\\?\UNC\srv\share\x` {
			t.Errorf("Windows UNC: got %q", got)
		}
		if got := LongPath(`\\?\C:\already`); got != `\\?\C:\already` {
			t.Errorf("idempotent: got %q", got)
		}
	default:
		if got := LongPath("/foo/bar"); got != "/foo/bar" {
			t.Errorf("POSIX: got %q", got)
		}
	}
}

func TestPathEqual(t *testing.T) {
	if !PathEqual("/Foo/Bar", "/Foo/Bar") {
		t.Error("identical paths should be equal")
	}
	if runtime.GOOS == "linux" {
		if PathEqual("/foo", "/FOO") {
			t.Error("Linux is case-sensitive")
		}
	} else {
		if !PathEqual("/foo", "/FOO") {
			t.Errorf("%s should be case-insensitive", runtime.GOOS)
		}
	}
}
