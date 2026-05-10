// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Ogamita Ltd.

package listing

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"
)

// makeFakeOtaHome lays out a tiny $OTA_HOME under t.TempDir():
//
//	  <root>/
//	    foo/
//	      state.json   (current=1.0.1, previous=1.0.0, server=...)
//	      distribution-1.0.0/file
//	      distribution-1.0.1/file
//	    bar/
//	      state.json   (current=2.3.4, no previous)
//	      distribution-2.3.4/file
//	    not-ours/        (no state.json, no distribution-* dirs)
//	      readme.txt
//
// Returns the root path.
func makeFakeOtaHome(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	mk := func(p, content string) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", p, err)
		}
		if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
			t.Fatalf("write %s: %v", p, err)
		}
	}
	mk(filepath.Join(root, "foo", "state.json"),
		`{"software":"foo","current":"1.0.1","previous":"1.0.0","server_url":"http://x","updated_at":"2026-01-01T00:00:00Z"}`)
	mk(filepath.Join(root, "foo", "distribution-1.0.0", "file"), "v100")
	mk(filepath.Join(root, "foo", "distribution-1.0.1", "file"), "v101 bigger")
	mk(filepath.Join(root, "bar", "state.json"),
		`{"software":"bar","current":"2.3.4","server_url":"http://y","updated_at":"2026-01-02T00:00:00Z"}`)
	mk(filepath.Join(root, "bar", "distribution-2.3.4", "file"), "bar")
	mk(filepath.Join(root, "not-ours", "readme.txt"), "")
	return root
}

func TestListLocal_FindsKnownInstallsAndSkipsForeignDirs(t *testing.T) {
	root := makeFakeOtaHome(t)
	entries, err := ListLocal(root)
	if err != nil {
		t.Fatalf("ListLocal: %v", err)
	}
	got := map[string]LocalEntry{}
	for _, e := range entries {
		got[e.Software] = e
	}
	if _, ok := got["not-ours"]; ok {
		t.Errorf("ListLocal returned the not-ours dir; expected to skip it")
	}
	if got["foo"].Current != "1.0.1" {
		t.Errorf("foo current = %q; want 1.0.1", got["foo"].Current)
	}
	if got["foo"].Previous != "1.0.0" {
		t.Errorf("foo previous = %q; want 1.0.0", got["foo"].Previous)
	}
	if got["bar"].Current != "2.3.4" {
		t.Errorf("bar current = %q; want 2.3.4", got["bar"].Current)
	}
	if got["bar"].Previous != "" {
		t.Errorf("bar previous = %q; want empty", got["bar"].Previous)
	}
	if len(got["foo"].Distributions) != 2 {
		t.Errorf("foo has %d dists; want 2", len(got["foo"].Distributions))
	}
	if got["foo"].OnDiskBytes <= 0 {
		t.Errorf("foo OnDiskBytes = %d; want > 0", got["foo"].OnDiskBytes)
	}
}

func TestListLocal_MissingHomeReturnsEmpty(t *testing.T) {
	entries, err := ListLocal(filepath.Join(t.TempDir(), "no", "such", "path"))
	if err != nil {
		t.Fatalf("ListLocal on missing path should not error: %v", err)
	}
	if entries != nil {
		t.Errorf("ListLocal on missing path should return nil; got %v", entries)
	}
}

func TestLoadLocal_KnownInstall(t *testing.T) {
	root := makeFakeOtaHome(t)
	e, err := LoadLocal(root, "foo")
	if err != nil {
		t.Fatalf("LoadLocal: %v", err)
	}
	if e.Current != "1.0.1" {
		t.Errorf("Current=%q; want 1.0.1", e.Current)
	}
	if e.HistoryLength != 0 {
		t.Errorf("HistoryLength=%d; want 0", e.HistoryLength)
	}
}

func TestLoadLocal_UnknownReturnsErrNotExist(t *testing.T) {
	root := makeFakeOtaHome(t)
	_, err := LoadLocal(root, "no-such-software")
	if !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("LoadLocal: err=%v; want fs.ErrNotExist", err)
	}
}

func TestLoadLocal_DirectoryWithoutMarkersIsAlsoErrNotExist(t *testing.T) {
	root := makeFakeOtaHome(t)
	_, err := LoadLocal(root, "not-ours")
	if !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("LoadLocal not-ours: err=%v; want fs.ErrNotExist", err)
	}
}

// ---------------------------------------------------------------------------
// Prune
// ---------------------------------------------------------------------------

// makeOnePackage builds <otaHome>/<software>/ with the named
// distribution-* directories AND a state.json saying current=current,
// previous=previous (both may be "" to skip).
func makeOnePackage(t *testing.T, name, current, previous string, dists []string) string {
	t.Helper()
	root := t.TempDir()
	pkg := filepath.Join(root, name)
	if err := os.MkdirAll(pkg, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, d := range dists {
		if err := os.MkdirAll(filepath.Join(pkg, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	st := `{"software":"` + name + `","current":"` + current + `","previous":"` + previous + `","updated_at":"2026-01-01T00:00:00Z"}`
	if err := os.WriteFile(filepath.Join(pkg, "state.json"), []byte(st), 0o644); err != nil {
		t.Fatal(err)
	}
	return root
}

func TestPruneCandidates_KeepsCurrentAndPreviousAlways(t *testing.T) {
	root := makeOnePackage(t, "p", "v3", "v2",
		[]string{"distribution-v1", "distribution-v2", "distribution-v3"})
	cands, err := PruneCandidates(root, "p", 0)
	if err != nil {
		t.Fatalf("PruneCandidates: %v", err)
	}
	want := []string{"distribution-v1"}
	if !equalStringSet(cands, want) {
		t.Errorf("cands = %v; want %v", cands, want)
	}
}

func TestPruneCandidates_ArchiveDepthExtendsKeepList(t *testing.T) {
	root := makeOnePackage(t, "p", "v5", "v4",
		[]string{"distribution-v1", "distribution-v2", "distribution-v3",
			"distribution-v4", "distribution-v5"})
	// Force every distribution-* dir to share the same mtime, the
	// way back-to-back MkdirAll calls on Linux ext4 / GitHub
	// runners leave them.  Without a deterministic tie-breaker in
	// scanDistributions, sort.Slice's non-stable ordering then
	// makes the prune-candidate selection filesystem-iteration-
	// order-dependent (passes on macOS APFS, fails on Linux).
	sameTime := time.Unix(1700000000, 0)
	pkg := filepath.Join(root, "p")
	for _, d := range []string{"distribution-v1", "distribution-v2",
		"distribution-v3", "distribution-v4", "distribution-v5"} {
		if err := os.Chtimes(filepath.Join(pkg, d), sameTime, sameTime); err != nil {
			t.Fatalf("Chtimes %s: %v", d, err)
		}
	}
	// depth=2: keep current+previous (v5,v4) + 2 most recent extras (v3,v2).
	// v1 is the only candidate.
	cands, err := PruneCandidates(root, "p", 2)
	if err != nil {
		t.Fatalf("PruneCandidates: %v", err)
	}
	want := []string{"distribution-v1"}
	if !equalStringSet(cands, want) {
		t.Errorf("cands = %v; want %v", cands, want)
	}
}

func TestPruneCandidates_NothingToPruneWhenAllKept(t *testing.T) {
	root := makeOnePackage(t, "p", "v2", "v1",
		[]string{"distribution-v1", "distribution-v2"})
	cands, err := PruneCandidates(root, "p", 5)
	if err != nil {
		t.Fatalf("PruneCandidates: %v", err)
	}
	if len(cands) != 0 {
		t.Errorf("cands = %v; want empty", cands)
	}
}

func TestDeleteDistribution_RefusesNonDistributionDir(t *testing.T) {
	root := makeOnePackage(t, "p", "v1", "", []string{"distribution-v1"})
	err := DeleteDistribution(root, "p", "../../../etc")
	if err == nil {
		t.Errorf("DeleteDistribution accepted a non-distribution dir; expected refusal")
	}
	if !strings.Contains(err.Error(), "non-distribution") {
		t.Errorf("err = %v; want 'non-distribution' message", err)
	}
}

func TestDeleteDistribution_RemovesTheTree(t *testing.T) {
	root := makeOnePackage(t, "p", "v2", "v1",
		[]string{"distribution-v1", "distribution-v2", "distribution-v3"})
	if err := DeleteDistribution(root, "p", "distribution-v3"); err != nil {
		t.Fatalf("DeleteDistribution: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "p", "distribution-v3")); !os.IsNotExist(err) {
		t.Errorf("distribution-v3 still exists; err=%v", err)
	}
}

// equalStringSet compares two slices ignoring order.
func equalStringSet(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	aa := append([]string(nil), a...)
	bb := append([]string(nil), b...)
	sort.Strings(aa)
	sort.Strings(bb)
	for i := range aa {
		if aa[i] != bb[i] {
			return false
		}
	}
	return true
}
