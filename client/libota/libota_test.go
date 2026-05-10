// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Ogamita Ltd.

package libota

import (
	"archive/tar"
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"gitlab.com/ogamita/delta-ota/client/internal/manifest"
	"gitlab.com/ogamita/delta-ota/client/internal/state"
)

// =============================================================================
// Test helpers
// =============================================================================

// makeTarBlob builds a minimal tar archive with one regular file
// inside, returns (bytes, sha256-hex).  The contents are
// deterministic given the inputs so tests can compute the SHA the
// server should claim.
func makeTarBlob(t *testing.T, filename, content string) ([]byte, string) {
	t.Helper()
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	hdr := &tar.Header{
		Name:     filename,
		Mode:     0o644,
		Size:     int64(len(content)),
		Typeflag: tar.TypeReg,
	}
	if err := tw.WriteHeader(hdr); err != nil {
		t.Fatalf("tar header: %v", err)
	}
	if _, err := tw.Write([]byte(content)); err != nil {
		t.Fatalf("tar write: %v", err)
	}
	if err := tw.Close(); err != nil {
		t.Fatalf("tar close: %v", err)
	}
	sum := sha256.Sum256(buf.Bytes())
	return buf.Bytes(), hex.EncodeToString(sum[:])
}

// signedManifestJSON renders a manifest plist, signs it with the
// supplied private key, and returns (json-bytes, sig-hex).  The
// schema_version + per-field shape match what the server emits.
func signedManifestJSON(t *testing.T, sw, version, blobSHA string, blobSize int64, priv ed25519.PrivateKey) ([]byte, string) {
	t.Helper()
	m := map[string]any{
		"schema_version":  1,
		"release_id":      sw + "/x86_64/" + version,
		"software":        sw,
		"os":              "linux",
		"arch":            "x86_64",
		"os_versions":     []string{},
		"version":         version,
		"published_at":    "2026-05-10T00:00:00Z",
		"blob":            map[string]any{"sha256": blobSHA, "size": blobSize, "url": "/v1/blobs/" + blobSHA},
		"patches_in":      []any{},
		"patches_out":     []any{},
		"channels":        []string{},
		"classifications": []string{},
		"deprecated":      false,
		"uncollectable":   false,
	}
	body, err := json.Marshal(m)
	if err != nil {
		t.Fatalf("manifest marshal: %v", err)
	}
	sig := ed25519.Sign(priv, body)
	return body, hex.EncodeToString(sig)
}

// fakeServer stands up a minimal /v1/* HTTP server for one
// (software, version, blob) tuple.  Returns the server, the
// trusted pubkey hex, and the on-disk SHA of the blob.  The
// caller closes the server.
type fakeOpts struct {
	software    string
	version     string
	blob        []byte
	blobSHA     string
	priv        ed25519.PrivateKey
	pubHex      string
	manifestSrv []byte // override: serve THIS as the manifest body (for tamper tests)
	sigOverride string // override: serve THIS as the X-Ota-Signature
}

func newFakeServer(t *testing.T, opts fakeOpts) *httptest.Server {
	t.Helper()
	manifestBody, sigHex := signedManifestJSON(t, opts.software, opts.version, opts.blobSHA, int64(len(opts.blob)), opts.priv)
	if opts.manifestSrv != nil {
		manifestBody = opts.manifestSrv
	}
	if opts.sigOverride != "" {
		sigHex = opts.sigOverride
	}
	mux := http.NewServeMux()
	mux.HandleFunc(fmt.Sprintf("/v1/software/%s/releases/latest", opts.software),
		func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]string{"version": opts.version})
		})
	mux.HandleFunc(fmt.Sprintf("/v1/software/%s/releases/%s/manifest", opts.software, opts.version),
		func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("X-Ota-Signature", sigHex)
			w.Header().Set("X-Ota-Public-Key", opts.pubHex)
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write(manifestBody)
		})
	mux.HandleFunc("/v1/blobs/"+opts.blobSHA,
		func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "application/octet-stream")
			_, _ = w.Write(opts.blob)
		})
	return httptest.NewServer(mux)
}

func freshKeypair(t *testing.T) (ed25519.PublicKey, ed25519.PrivateKey, string) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("keypair: %v", err)
	}
	return pub, priv, hex.EncodeToString(pub)
}

// =============================================================================
// Pure-function tests: defaultOTAHome, fallbackRatio, pickPatch,
//                      checkTrust, short, pruneOldArtefacts.
// =============================================================================

func TestDefaultOTAHome_EnvWins(t *testing.T) {
	t.Setenv("OTA_HOME", "/tmp/forced-home")
	if got := defaultOTAHome(); got != "/tmp/forced-home" {
		t.Errorf("defaultOTAHome=%q; want /tmp/forced-home", got)
	}
}

func TestDefaultOTAHome_FallsBackToHome(t *testing.T) {
	t.Setenv("OTA_HOME", "")
	// os.UserHomeDir reads $HOME on Unix and %USERPROFILE% on Windows
	// (and $home on Plan 9).  Setting $HOME alone left the runner's
	// real profile leaking through on Windows; set both so the test
	// is OS-portable.  t.TempDir gives an OS-appropriate absolute
	// path so we don't hard-code a Unix-style "/tmp/..." that
	// Windows' os.UserHomeDir wouldn't accept anyway.
	fakeHome := t.TempDir()
	t.Setenv("HOME", fakeHome)
	t.Setenv("USERPROFILE", fakeHome)
	want := filepath.Join(fakeHome, ".ota")
	if got := defaultOTAHome(); got != want {
		t.Errorf("defaultOTAHome=%q; want %q", got, want)
	}
}

func TestFallbackRatio_DefaultIs0_7(t *testing.T) {
	if r := (Config{}).fallbackRatio(); r != 0.7 {
		t.Errorf("fallbackRatio=%v; want 0.7", r)
	}
}

func TestFallbackRatio_RespectsExplicit(t *testing.T) {
	if r := (Config{FallbackRatio: 0.5}).fallbackRatio(); r != 0.5 {
		t.Errorf("fallbackRatio=%v; want 0.5", r)
	}
}

func TestFallbackRatio_NonpositiveFallsBack(t *testing.T) {
	if r := (Config{FallbackRatio: -1}).fallbackRatio(); r != 0.7 {
		t.Errorf("negative ratio should fall back to default; got %v", r)
	}
	if r := (Config{FallbackRatio: 0}).fallbackRatio(); r != 0.7 {
		t.Errorf("zero ratio should fall back to default; got %v", r)
	}
}

func TestPickPatch_PicksSmallestMatchingFrom(t *testing.T) {
	in := []manifest.PatchRef{
		{From: "1.0.0", Patcher: "bsdiff", SHA256: "a", Size: 200},
		{From: "1.0.0", Patcher: "bsdiff", SHA256: "b", Size: 100},
		{From: "0.9.0", Patcher: "bsdiff", SHA256: "c", Size: 50},
	}
	got := pickPatch(in, "1.0.0", 1000, 0.7)
	if got == nil || got.SHA256 != "b" {
		t.Errorf("pickPatch picked %v; want SHA=b (size 100, the smallest 1.0.0 match)", got)
	}
}

func TestPickPatch_NilWhenNoFromMatch(t *testing.T) {
	in := []manifest.PatchRef{
		{From: "0.9.0", Patcher: "bsdiff", SHA256: "x", Size: 10},
	}
	if got := pickPatch(in, "1.0.0", 1000, 0.7); got != nil {
		t.Errorf("pickPatch should return nil; got %v", got)
	}
}

func TestPickPatch_IgnoresNonBsdiffPatcher(t *testing.T) {
	in := []manifest.PatchRef{
		{From: "1.0.0", Patcher: "xdelta3", SHA256: "x", Size: 10},
	}
	if got := pickPatch(in, "1.0.0", 1000, 0.7); got != nil {
		t.Errorf("pickPatch should ignore non-bsdiff; got %v", got)
	}
}

func TestPickPatch_EnforcesFallbackRatioCap(t *testing.T) {
	// blob 1000 * ratio 0.5 = cap 500; the patch is 600 → reject.
	in := []manifest.PatchRef{
		{From: "1.0.0", Patcher: "bsdiff", SHA256: "x", Size: 600},
	}
	if got := pickPatch(in, "1.0.0", 1000, 0.5); got != nil {
		t.Errorf("pickPatch should reject patch over cap; got %v", got)
	}
	// Same patch under a higher ratio: accepted.
	if got := pickPatch(in, "1.0.0", 1000, 0.9); got == nil || got.SHA256 != "x" {
		t.Errorf("pickPatch should accept patch under cap; got %v", got)
	}
}

func TestPickPatch_ZeroBlobSizeMeansNoCap(t *testing.T) {
	// When blob_size=0 the cap is 0 → the function's `cap > 0`
	// guard short-circuits and accepts any size.
	in := []manifest.PatchRef{
		{From: "1.0.0", Patcher: "bsdiff", SHA256: "x", Size: 999999},
	}
	if got := pickPatch(in, "1.0.0", 0, 0.5); got == nil {
		t.Errorf("pickPatch with blob_size=0 should accept any size; got nil")
	}
}

func TestCheckTrust_EmptyTrustedSetAcceptsAnyKeyOnFirstUse(t *testing.T) {
	st := &state.State{} // ServerPubKeyHX == ""
	if err := checkTrust(st, nil, "deadbeef"); err != nil {
		t.Errorf("first-use trust should accept; got %v", err)
	}
}

func TestCheckTrust_EmptyTrustedSetMatchesPersistedKey(t *testing.T) {
	st := &state.State{ServerPubKeyHX: "aabbccdd"}
	if err := checkTrust(st, nil, "aabbccdd"); err != nil {
		t.Errorf("matching pinned key should pass; got %v", err)
	}
}

func TestCheckTrust_EmptyTrustedSetRejectsChangedPersistedKey(t *testing.T) {
	st := &state.State{ServerPubKeyHX: "aabbccdd"}
	err := checkTrust(st, nil, "ee11ee22")
	if err == nil {
		t.Errorf("changed pinned key should be rejected")
	}
	if !strings.Contains(err.Error(), "pubkey changed") {
		t.Errorf("err message should mention 'pubkey changed'; got %v", err)
	}
}

func TestCheckTrust_NonEmptyTrustedSetAcceptsListedKey(t *testing.T) {
	st := &state.State{}
	if err := checkTrust(st, []string{"aaaa", "bbbb"}, "bbbb"); err != nil {
		t.Errorf("trusted-set match should pass; got %v", err)
	}
}

func TestCheckTrust_NonEmptyTrustedSetRejectsUnlistedKey(t *testing.T) {
	st := &state.State{}
	err := checkTrust(st, []string{"aaaa", "bbbb"}, "ccccccccccccc")
	if err == nil {
		t.Errorf("unlisted key should be rejected")
	}
	if !strings.Contains(err.Error(), "not in trusted set") {
		t.Errorf("err message should mention 'not in trusted set'; got %v", err)
	}
}

func TestShort_LongStringIsTruncated(t *testing.T) {
	if got := short("0123456789abcdef0123456789"); got != "0123456789ab..." {
		t.Errorf("short=%q; want 0123456789ab...", got)
	}
}

func TestShort_ShortStringIsAsIs(t *testing.T) {
	if got := short("abc"); got != "abc" {
		t.Errorf("short=%q; want abc", got)
	}
}

func TestPruneOldArtefacts_HistoryUnder3IsNoop(t *testing.T) {
	root := t.TempDir()
	layout := state.New(root, "p")
	if err := layout.Ensure(); err != nil {
		t.Fatal(err)
	}
	// Drop a fake blob; pruneOldArtefacts should NOT remove it
	// because History has fewer than 3 entries.
	stale := layout.BlobPath("v1")
	if err := os.WriteFile(stale, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	st := &state.State{Software: "p", Current: "v2",
		Previous: "v1", History: []string{"v1", "v2"}}
	pruneOldArtefacts(layout, st, "v1")
	if _, err := os.Stat(stale); err != nil {
		t.Errorf("History<3 should not have pruned %s; err=%v", stale, err)
	}
}

func TestPruneOldArtefacts_HistoryGE3DropsOldestBlobAndPatches(t *testing.T) {
	root := t.TempDir()
	layout := state.New(root, "p")
	if err := layout.Ensure(); err != nil {
		t.Fatal(err)
	}
	// History v1, v2, v3 → "older" = History[len-3] = v1.
	// pruneOldArtefacts drops v1's blob + v1's archived dist
	// + any patches whose name starts with v1-to-.
	v1Blob := layout.BlobPath("v1")
	v1Archive := filepath.Join(layout.Root, "distribution-v1.archived")
	v1Patch := filepath.Join(layout.PatchesDir, "v1-to-v2.patch")
	v2Blob := layout.BlobPath("v2") // must NOT be pruned
	for _, p := range []string{v1Blob, v1Archive, v1Patch, v2Blob} {
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	st := &state.State{Software: "p", Current: "v3",
		Previous: "v2", History: []string{"v1", "v2", "v3"}}
	pruneOldArtefacts(layout, st, "v2")
	for _, p := range []string{v1Blob, v1Archive, v1Patch} {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Errorf("expected %s removed; err=%v", p, err)
		}
	}
	if _, err := os.Stat(v2Blob); err != nil {
		t.Errorf("v2 blob should NOT have been pruned; err=%v", err)
	}
}

// =============================================================================
// Install — smoke + happy paths
// =============================================================================

func TestInstallRejectsEmptyServerURL(t *testing.T) {
	if _, err := Install(context.Background(), Config{}, "hello", "1.0.0"); err == nil {
		t.Fatal("expected error for empty ServerURL")
	}
}

func TestInstall_HappyPath_ExplicitVersion(t *testing.T) {
	blob, sha := makeTarBlob(t, "hello.txt", "Hello, world.\n")
	_, priv, pubHex := freshKeypair(t)
	srv := newFakeServer(t, fakeOpts{
		software: "hello", version: "1.0.0",
		blob: blob, blobSHA: sha,
		priv: priv, pubHex: pubHex,
	})
	defer srv.Close()
	home := t.TempDir()

	got, err := Install(context.Background(),
		Config{ServerURL: srv.URL, OTAHome: home}, "hello", "1.0.0")
	if err != nil {
		t.Fatalf("Install: %v", err)
	}
	if got != "1.0.0" {
		t.Errorf("Install returned version=%q; want 1.0.0", got)
	}
	// State recorded.
	st, err := state.New(home, "hello").Load()
	if err != nil {
		t.Fatalf("state.Load: %v", err)
	}
	if st.Current != "1.0.0" {
		t.Errorf("state.Current=%q; want 1.0.0", st.Current)
	}
	if st.ServerURL != srv.URL {
		t.Errorf("state.ServerURL=%q; want %q", st.ServerURL, srv.URL)
	}
	if st.ServerPubKeyHX != pubHex {
		t.Errorf("state.ServerPubKeyHX=%q; want %q", st.ServerPubKeyHX, pubHex)
	}
	// Distribution dir extracted.
	out := filepath.Join(home, "hello", "distribution-1.0.0", "hello.txt")
	body, err := os.ReadFile(out)
	if err != nil {
		t.Fatalf("read extracted file: %v", err)
	}
	if string(body) != "Hello, world.\n" {
		t.Errorf("extracted content=%q; want Hello, world.\\n", body)
	}
}

func TestInstall_LatestVersionResolution(t *testing.T) {
	blob, sha := makeTarBlob(t, "f", "data")
	_, priv, pubHex := freshKeypair(t)
	srv := newFakeServer(t, fakeOpts{
		software: "rl", version: "2.3.4",
		blob: blob, blobSHA: sha,
		priv: priv, pubHex: pubHex,
	})
	defer srv.Close()
	home := t.TempDir()

	// Empty version → server's /releases/latest is consulted.
	got, err := Install(context.Background(),
		Config{ServerURL: srv.URL, OTAHome: home}, "rl", "")
	if err != nil {
		t.Fatalf("Install latest: %v", err)
	}
	if got != "2.3.4" {
		t.Errorf("Install latest resolved to %q; want 2.3.4", got)
	}
}

func TestInstall_LatestKeywordResolution(t *testing.T) {
	blob, sha := makeTarBlob(t, "f", "data")
	_, priv, pubHex := freshKeypair(t)
	srv := newFakeServer(t, fakeOpts{
		software: "lk", version: "9.9.9",
		blob: blob, blobSHA: sha,
		priv: priv, pubHex: pubHex,
	})
	defer srv.Close()
	home := t.TempDir()

	got, err := Install(context.Background(),
		Config{ServerURL: srv.URL, OTAHome: home}, "lk", "latest")
	if err != nil {
		t.Fatalf("Install latest: %v", err)
	}
	if got != "9.9.9" {
		t.Errorf("Install \"latest\" resolved to %q; want 9.9.9", got)
	}
}

// =============================================================================
// Install — error paths
// =============================================================================

func TestInstall_RejectsManifestSoftwareMismatch(t *testing.T) {
	blob, sha := makeTarBlob(t, "f", "data")
	_, priv, pubHex := freshKeypair(t)
	// Build a manifest claiming to be a DIFFERENT software, but
	// serve it on the URL for "expected".  The client should
	// detect the mismatch.
	bogusManifest, sigHex := signedManifestJSON(t, "different-software", "1.0.0", sha, int64(len(blob)), priv)
	srv := newFakeServer(t, fakeOpts{
		software: "expected", version: "1.0.0",
		blob: blob, blobSHA: sha,
		priv: priv, pubHex: pubHex,
		manifestSrv: bogusManifest,
		sigOverride: sigHex,
	})
	defer srv.Close()
	home := t.TempDir()

	_, err := Install(context.Background(),
		Config{ServerURL: srv.URL, OTAHome: home}, "expected", "1.0.0")
	if err == nil {
		t.Fatal("expected install to fail on software mismatch")
	}
	if !strings.Contains(err.Error(), "mismatch") {
		t.Errorf("err should mention mismatch; got %v", err)
	}
}

func TestInstall_RejectsTamperedManifest(t *testing.T) {
	blob, sha := makeTarBlob(t, "f", "data")
	_, priv, pubHex := freshKeypair(t)
	// Sign one body, serve a different one.
	authentic, sigHex := signedManifestJSON(t, "tamper", "1.0.0", sha, int64(len(blob)), priv)
	tampered := bytes.Replace(authentic, []byte(`"version":"1.0.0"`),
		[]byte(`"version":"1.0.1"`), 1)
	srv := newFakeServer(t, fakeOpts{
		software: "tamper", version: "1.0.0",
		blob: blob, blobSHA: sha,
		priv: priv, pubHex: pubHex,
		manifestSrv: tampered,
		sigOverride: sigHex, // signature is for `authentic`, not `tampered`
	})
	defer srv.Close()
	home := t.TempDir()

	_, err := Install(context.Background(),
		Config{ServerURL: srv.URL, OTAHome: home}, "tamper", "1.0.0")
	if err == nil {
		t.Fatal("expected install to fail on signature mismatch")
	}
}

func TestInstall_RejectsUntrustedPubkey(t *testing.T) {
	blob, sha := makeTarBlob(t, "f", "data")
	_, priv, pubHex := freshKeypair(t)
	srv := newFakeServer(t, fakeOpts{
		software: "untrusted", version: "1.0.0",
		blob: blob, blobSHA: sha,
		priv: priv, pubHex: pubHex,
	})
	defer srv.Close()
	home := t.TempDir()

	// Trusted set lists a DIFFERENT key.
	_, err := Install(context.Background(),
		Config{
			ServerURL:      srv.URL,
			OTAHome:        home,
			TrustedPubKeys: []string{strings.Repeat("0", 64)},
		}, "untrusted", "1.0.0")
	if err == nil {
		t.Fatal("expected install to fail on untrusted pubkey")
	}
	if !strings.Contains(err.Error(), "not in trusted set") {
		t.Errorf("err should mention trusted set; got %v", err)
	}
}

func TestInstall_RejectsBlobHashMismatch(t *testing.T) {
	blob, _ := makeTarBlob(t, "f", "data")
	_, priv, pubHex := freshKeypair(t)
	wrongSHA := strings.Repeat("0", 64) // not the real blob's hash
	srv := newFakeServer(t, fakeOpts{
		software: "lying", version: "1.0.0",
		blob: blob, blobSHA: wrongSHA, // server claims this hash
		priv: priv, pubHex: pubHex,
	})
	defer srv.Close()
	home := t.TempDir()

	_, err := Install(context.Background(),
		Config{ServerURL: srv.URL, OTAHome: home}, "lying", "1.0.0")
	if err == nil {
		t.Fatal("expected install to fail on blob hash mismatch")
	}
}

func TestInstall_RejectsPinnedKeyChange(t *testing.T) {
	blob, sha := makeTarBlob(t, "f", "data")
	_, priv1, pubHex1 := freshKeypair(t)

	// First install pins the key via TOFU.
	srv1 := newFakeServer(t, fakeOpts{
		software: "pinned", version: "1.0.0",
		blob: blob, blobSHA: sha,
		priv: priv1, pubHex: pubHex1,
	})
	home := t.TempDir()
	if _, err := Install(context.Background(),
		Config{ServerURL: srv1.URL, OTAHome: home}, "pinned", "1.0.0"); err != nil {
		t.Fatalf("first install: %v", err)
	}
	srv1.Close()

	// Second install with a DIFFERENT signing key under the same
	// state directory must be rejected.
	_, priv2, pubHex2 := freshKeypair(t)
	srv2 := newFakeServer(t, fakeOpts{
		software: "pinned", version: "1.0.1",
		blob: blob, blobSHA: sha,
		priv: priv2, pubHex: pubHex2,
	})
	defer srv2.Close()
	_, err := Install(context.Background(),
		Config{ServerURL: srv2.URL, OTAHome: home}, "pinned", "1.0.1")
	if err == nil {
		t.Fatal("expected install to fail on pinned-key change")
	}
	if !strings.Contains(err.Error(), "pubkey changed") {
		t.Errorf("err should mention pubkey change; got %v", err)
	}
}

// =============================================================================
// Upgrade (which Install-falls-through in v1.x)
// =============================================================================

func TestUpgrade_AfterInstallPopulatesPrevious(t *testing.T) {
	blob1, sha1 := makeTarBlob(t, "f", "v1")
	blob2, sha2 := makeTarBlob(t, "f", "v2-content-larger")
	_, priv, pubHex := freshKeypair(t)

	// First server: v1.0.0
	srv := newFakeServer(t, fakeOpts{
		software: "up", version: "1.0.0",
		blob: blob1, blobSHA: sha1,
		priv: priv, pubHex: pubHex,
	})
	defer srv.Close()
	home := t.TempDir()
	if _, err := Install(context.Background(),
		Config{ServerURL: srv.URL, OTAHome: home}, "up", "1.0.0"); err != nil {
		t.Fatalf("install v1: %v", err)
	}

	// Stand up a new server for v1.0.1 (we need a different
	// version path; httptest mux dispatches by path).
	srv2 := newFakeServer(t, fakeOpts{
		software: "up", version: "1.0.1",
		blob: blob2, blobSHA: sha2,
		priv: priv, pubHex: pubHex,
	})
	defer srv2.Close()

	if _, err := Upgrade(context.Background(),
		Config{ServerURL: srv2.URL, OTAHome: home}, "up", "1.0.1"); err != nil {
		t.Fatalf("upgrade v1.0.1: %v", err)
	}
	st, err := state.New(home, "up").Load()
	if err != nil {
		t.Fatalf("state.Load: %v", err)
	}
	if st.Current != "1.0.1" {
		t.Errorf("Current=%q; want 1.0.1", st.Current)
	}
	if st.Previous != "1.0.0" {
		t.Errorf("Previous=%q; want 1.0.0", st.Previous)
	}
	if len(st.History) != 2 {
		t.Errorf("History=%v; want 2 entries", st.History)
	}
}

// =============================================================================
// Revert
// =============================================================================

func TestRevert_NoPreviousReturnsError(t *testing.T) {
	home := t.TempDir()
	// state.json doesn't even exist -- Revert must fail cleanly.
	err := Revert(Config{OTAHome: home}, "no-such")
	if err == nil {
		t.Fatal("expected error when there's no previous distribution")
	}
}

func TestRevert_SwapsCurrentAndPrevious(t *testing.T) {
	blob1, sha1 := makeTarBlob(t, "f", "v1")
	blob2, sha2 := makeTarBlob(t, "f", "v2-bigger-payload")
	_, priv, pubHex := freshKeypair(t)
	home := t.TempDir()

	srv1 := newFakeServer(t, fakeOpts{
		software: "rv", version: "1.0.0",
		blob: blob1, blobSHA: sha1, priv: priv, pubHex: pubHex,
	})
	if _, err := Install(context.Background(),
		Config{ServerURL: srv1.URL, OTAHome: home}, "rv", "1.0.0"); err != nil {
		t.Fatalf("install v1: %v", err)
	}
	srv1.Close()

	srv2 := newFakeServer(t, fakeOpts{
		software: "rv", version: "1.0.1",
		blob: blob2, blobSHA: sha2, priv: priv, pubHex: pubHex,
	})
	if _, err := Install(context.Background(),
		Config{ServerURL: srv2.URL, OTAHome: home}, "rv", "1.0.1"); err != nil {
		t.Fatalf("install v2: %v", err)
	}
	srv2.Close()

	// state has Current=1.0.1, Previous=1.0.0; revert flips them.
	if err := Revert(Config{OTAHome: home}, "rv"); err != nil {
		t.Fatalf("Revert: %v", err)
	}
	st, err := state.New(home, "rv").Load()
	if err != nil {
		t.Fatalf("state.Load: %v", err)
	}
	if st.Current != "1.0.0" {
		t.Errorf("after revert, Current=%q; want 1.0.0", st.Current)
	}
	if st.Previous != "1.0.1" {
		t.Errorf("after revert, Previous=%q; want 1.0.1", st.Previous)
	}
}

// =============================================================================
// Drain (utility)
// =============================================================================

func TestDrain_CountsBytes(t *testing.T) {
	n, err := Drain(io.LimitReader(zeroReader{}, 4096))
	if err != nil {
		t.Fatalf("Drain: %v", err)
	}
	if n != 4096 {
		t.Errorf("Drain returned %d; want 4096", n)
	}
}

type zeroReader struct{}

func (zeroReader) Read(p []byte) (int, error) {
	for i := range p {
		p[i] = 0
	}
	return len(p), nil
}
