// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Ogamita Ltd.

package verify

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"gitlab.com/ogamita/delta-ota/client/internal/transport"
)

// makeInstall lays out a minimal installed package and returns the
// otaHome path.  When blobContents != nil, also writes the saved blob
// at <home>/<sw>/blobs/<version>.blob.
func makeInstall(t *testing.T, sw, version string, blobContents []byte) string {
	t.Helper()
	root := t.TempDir()
	pkg := filepath.Join(root, sw)
	dist := filepath.Join(pkg, "distribution-"+version)
	if err := os.MkdirAll(dist, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dist, "file"), []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}
	st := fmt.Sprintf(
		`{"software":%q,"current":%q,"updated_at":"2026-01-01T00:00:00Z"}`,
		sw, version)
	if err := os.WriteFile(filepath.Join(pkg, "state.json"), []byte(st), 0o644); err != nil {
		t.Fatal(err)
	}
	// Symlink current -> distribution-<version> so the offline phase's
	// "current link" check passes.
	if err := os.Symlink(dist, filepath.Join(pkg, "current")); err != nil {
		t.Fatal(err)
	}
	if blobContents != nil {
		blobs := filepath.Join(pkg, "blobs")
		if err := os.MkdirAll(blobs, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(blobs, version+".blob"), blobContents, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

// ---------------------------------------------------------------------------
// Offline phase
// ---------------------------------------------------------------------------

func TestVerify_Offline_AllChecksPassOnAGoodInstall(t *testing.T) {
	root := makeInstall(t, "good", "1.0.0", nil)
	rep, err := Verify(root, "good", VerifyOptions{Offline: true})
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if !rep.AllOK() {
		t.Errorf("expected AllOK; checks = %+v", rep.Checks)
	}
	if rep.Version != "1.0.0" {
		t.Errorf("Version = %q; want 1.0.0", rep.Version)
	}
}

func TestVerify_Offline_NoStateJsonFlagsCurrentVersionFailure(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "naked"), 0o755); err != nil {
		t.Fatal(err)
	}
	rep, err := Verify(root, "naked", VerifyOptions{Offline: true})
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	// state.json missing -> Layout.Load returns &State{} successfully,
	// so the "state.json" check itself passes (best-effort).  But
	// "current version" must fail because Current is empty.
	for _, c := range rep.Checks {
		if c.Name == "current version" && c.OK {
			t.Errorf("current version check passed on a state with no Current")
		}
	}
	if rep.AllOK() {
		t.Errorf("expected at least one failure on a directory with no state")
	}
}

func TestVerify_Offline_MissingDistributionDirIsFatal(t *testing.T) {
	root := t.TempDir()
	pkg := filepath.Join(root, "missing-dist")
	if err := os.MkdirAll(pkg, 0o755); err != nil {
		t.Fatal(err)
	}
	st := `{"software":"missing-dist","current":"1.0.0","updated_at":"2026-01-01T00:00:00Z"}`
	if err := os.WriteFile(filepath.Join(pkg, "state.json"), []byte(st), 0o644); err != nil {
		t.Fatal(err)
	}
	rep, err := Verify(root, "missing-dist", VerifyOptions{Offline: true})
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if rep.AllOK() {
		t.Errorf("expected a failure when distribution dir is absent")
	}
}

// ---------------------------------------------------------------------------
// Online phase
// ---------------------------------------------------------------------------

// fakeServer stands up an HTTP server that serves a signed manifest
// for sw/version with the given blob hash (hex).  Returns the
// transport.Client wired to it and the trusted pubkey hex.
func fakeServer(t *testing.T, sw, version, blobSHA256Hex string) (*transport.Client, string, *httptest.Server) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	mObj := map[string]any{
		"schema_version":  1,
		"release_id":      sw + "/x86_64/" + version,
		"software":        sw,
		"os":              "any", "arch": "any", "os_versions": []string{},
		"version":         version,
		"published_at":    "2026-01-01T00:00:00Z",
		"blob":            map[string]any{"sha256": blobSHA256Hex, "size": 5, "url": "/v1/blobs/x"},
		"patches_in":      []any{}, "patches_out": []any{},
		"channels":        []string{}, "classifications": []string{},
		"deprecated":      false, "uncollectable": false,
	}
	mBytes, _ := json.Marshal(mObj)
	sig := ed25519.Sign(priv, mBytes)
	pubHex := hex.EncodeToString(pub)
	sigHex := hex.EncodeToString(sig)

	mux := http.NewServeMux()
	mux.HandleFunc("/v1/software/"+sw+"/releases/"+version+"/manifest",
		func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("X-Ota-Signature", sigHex)
			w.Header().Set("X-Ota-Public-Key", pubHex)
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write(mBytes)
		})
	srv := httptest.NewServer(mux)
	tr := transport.New(srv.URL)
	return tr, pubHex, srv
}

func TestVerify_Online_BlobHashMatch(t *testing.T) {
	contents := []byte("hello") // sha256 = "2cf24dba5..."
	sum := sha256.Sum256(contents)
	hexSum := hex.EncodeToString(sum[:])

	root := makeInstall(t, "online", "1.0.0", contents)
	tr, pubHex, srv := fakeServer(t, "online", "1.0.0", hexSum)
	defer srv.Close()

	rep, err := Verify(root, "online", VerifyOptions{
		Server:    srv.URL,
		Trusted:   []string{pubHex},
		Transport: tr,
	})
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if !rep.AllOK() {
		t.Errorf("expected AllOK; checks = %+v", rep.Checks)
	}
	// Specifically, the blob sha256 check should be present and OK.
	var sawBlobCheck bool
	for _, c := range rep.Checks {
		if c.Name == "blob sha256" {
			sawBlobCheck = true
			if !c.OK {
				t.Errorf("blob sha256 check failed: %s", c.Detail)
			}
		}
	}
	if !sawBlobCheck {
		t.Errorf("blob sha256 check missing from report; saw %d checks", len(rep.Checks))
	}
}

func TestVerify_Online_BlobHashMismatchFails(t *testing.T) {
	// Server claims the blob hashes to ZEROES, but the on-disk blob
	// is "hello" -> recompute disagrees.
	zero := strings.Repeat("0", 64)

	root := makeInstall(t, "mm", "1.0.0", []byte("hello"))
	tr, pubHex, srv := fakeServer(t, "mm", "1.0.0", zero)
	defer srv.Close()

	rep, err := Verify(root, "mm", VerifyOptions{
		Server:    srv.URL,
		Trusted:   []string{pubHex},
		Transport: tr,
	})
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if rep.AllOK() {
		t.Errorf("expected at least one failure; got AllOK=true; checks = %+v", rep.Checks)
	}
}

func TestVerify_Online_UntrustedPubkeyFails(t *testing.T) {
	contents := []byte("hello")
	sum := sha256.Sum256(contents)
	hexSum := hex.EncodeToString(sum[:])

	root := makeInstall(t, "untr", "1.0.0", contents)
	tr, _, srv := fakeServer(t, "untr", "1.0.0", hexSum) // _ = real pubkey
	defer srv.Close()

	wrongPub := strings.Repeat("0", 64)
	rep, err := Verify(root, "untr", VerifyOptions{
		Server:    srv.URL,
		Trusted:   []string{wrongPub},
		Transport: tr,
	})
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if rep.AllOK() {
		t.Errorf("expected a failure on untrusted pubkey; got AllOK")
	}
}

func TestVerify_Online_SkippedWhenOfflineFlagIsSet(t *testing.T) {
	root := makeInstall(t, "off", "1.0.0", []byte("hello"))
	rep, err := Verify(root, "off", VerifyOptions{Offline: true, Server: "http://no-such-host.invalid"})
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if !rep.AllOK() {
		t.Errorf("offline-mode verify should pass on a good install; checks=%+v", rep.Checks)
	}
	for _, c := range rep.Checks {
		if c.Name == "manifest fetch" || c.Name == "manifest signature" || c.Name == "blob sha256" {
			t.Errorf("offline mode produced an online check %q", c.Name)
		}
	}
}
