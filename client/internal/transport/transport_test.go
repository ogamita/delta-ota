// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Ogamita Ltd.

// Tests for resumable blob downloads (v1.3).
//
// Two layers, like the server-side suite:
//
//  1. Pure-function tests of safeResumeSize (the trailing-zero
//     scanner) and hashPrefix (the prefix SHA rebuilder).  Most
//     bugs in resume logic live in one of these two helpers.
//
//  2. End-to-end-ish tests against a httptest server that does
//     actually parse Range and return 206 with the requested
//     slice.  These exercise the full downloadHashed path:
//     interrupt mid-stream, retain .part, retry, verify the
//     final SHA still matches.

package transport

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
)

// ---------------------------------------------------------------------------
// safeResumeSize: trailing-zero scan.
// ---------------------------------------------------------------------------

func TestSafeResumeSize_NoTrailingZeros(t *testing.T) {
	tmp := writeTmp(t, []byte("ABCDEFGH"))
	got, err := safeResumeSize(tmp, 8)
	if err != nil {
		t.Fatalf("safeResumeSize: %v", err)
	}
	if got != 8 {
		t.Errorf("got %d, want 8 (no trailing zeros to drop)", got)
	}
}

func TestSafeResumeSize_DropsTrailingZeros(t *testing.T) {
	// A torn write: the last 4 bytes of an 8-byte file are zeros
	// (kernel grew the size but didn't commit the data).  We
	// should resume from byte 4.
	tmp := writeTmp(t, []byte{'A', 'B', 'C', 'D', 0, 0, 0, 0})
	got, err := safeResumeSize(tmp, 8)
	if err != nil {
		t.Fatalf("safeResumeSize: %v", err)
	}
	if got != 4 {
		t.Errorf("got %d, want 4 (last non-zero byte at index 3)", got)
	}
}

func TestSafeResumeSize_EmptyFile(t *testing.T) {
	tmp := writeTmp(t, nil)
	got, err := safeResumeSize(tmp, 0)
	if err != nil {
		t.Fatalf("safeResumeSize: %v", err)
	}
	if got != 0 {
		t.Errorf("got %d, want 0", got)
	}
}

func TestSafeResumeSize_AllZerosWithinScanWindow(t *testing.T) {
	// File entirely under the 16 MiB scan window and entirely
	// zero.  Conservative answer: drop the lot.
	tmp := writeTmp(t, make([]byte, 1024))
	got, err := safeResumeSize(tmp, 1024)
	if err != nil {
		t.Fatalf("safeResumeSize: %v", err)
	}
	if got != 0 {
		t.Errorf("got %d, want 0 (whole file is zero)", got)
	}
}

func TestSafeResumeSize_NonZeroJustOutsideWindow(t *testing.T) {
	// File larger than the scan window with all zeros at the
	// tail: we discard only the window, returning the offset
	// before it.  A subsequent resume cycle will trim further if
	// needed.
	if testing.Short() {
		t.Skip("allocates ~17 MiB")
	}
	size := safeScanWindowBytes + 1024
	buf := make([]byte, size)
	// Fill the first 1024 bytes with non-zero.
	for i := 0; i < 1024; i++ {
		buf[i] = 0xAA
	}
	tmp := writeTmp(t, buf)
	got, err := safeResumeSize(tmp, int64(size))
	if err != nil {
		t.Fatalf("safeResumeSize: %v", err)
	}
	want := int64(1024) // start of the all-zero window
	if got != want {
		t.Errorf("got %d, want %d", got, want)
	}
}

// ---------------------------------------------------------------------------
// hashPrefix: SHA-256 of [0, size).
// ---------------------------------------------------------------------------

func TestHashPrefix_MatchesFullSha(t *testing.T) {
	data := []byte("the quick brown fox jumps over the lazy dog")
	tmp := writeTmp(t, data)
	want := sha256.Sum256(data)
	h, err := hashPrefix(tmp, int64(len(data)))
	if err != nil {
		t.Fatalf("hashPrefix: %v", err)
	}
	got := h.Sum(nil)
	if hex.EncodeToString(got) != hex.EncodeToString(want[:]) {
		t.Errorf("hashPrefix sha mismatch:\n  got  %x\n  want %x", got, want)
	}
}

func TestHashPrefix_PartialPlusContinuation(t *testing.T) {
	// Whole-message SHA must equal hashPrefix(half) extended with
	// the second half -- this is the actual property the resume
	// path relies on.
	full := []byte("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
	tmp := writeTmp(t, full[:32])
	h, err := hashPrefix(tmp, 32)
	if err != nil {
		t.Fatalf("hashPrefix: %v", err)
	}
	h.Write(full[32:])
	got := h.Sum(nil)
	want := sha256.Sum256(full)
	if hex.EncodeToString(got) != hex.EncodeToString(want[:]) {
		t.Errorf("split-then-rejoin sha mismatch:\n  got  %x\n  want %x", got, want)
	}
}

// ---------------------------------------------------------------------------
// downloadHashed end-to-end: interrupt + resume.
// ---------------------------------------------------------------------------

// rangeServer is a deliberately simple HTTP server that serves
// `body` at /blob/<sha>, parses `Range: bytes=N-` (the only form
// the client sends on resume), and -- crucially -- supports a
// "kill mid-response" knob so the test can simulate a network
// drop after K bytes.
type rangeServer struct {
	body            []byte
	cutAfter        int64 // when > 0, hijack the conn and close after this many bytes (full GET)
	rangeBehaviour  string // "honour" | "ignore" | "off"
	hits            []rangeHit
}

type rangeHit struct {
	rangeHeader string
	startedAt   int64
	wrote       int64
	cut         bool
}

func (s *rangeServer) handler(w http.ResponseWriter, r *http.Request) {
	rangeH := r.Header.Get("Range")
	hit := rangeHit{rangeHeader: rangeH}

	// "off" means: pretend to be a server that doesn't support Range.
	// "ignore" means: advertise Accept-Ranges but ignore the header
	// (some misconfigured CDNs do this).
	switch s.rangeBehaviour {
	case "off":
		// Treat any Range as a full-content request.
		rangeH = ""
	case "ignore":
		w.Header().Set("Accept-Ranges", "bytes")
		rangeH = ""
	default:
		w.Header().Set("Accept-Ranges", "bytes")
	}

	start := int64(0)
	end := int64(len(s.body)) - 1
	if rangeH != "" && strings.HasPrefix(rangeH, "bytes=") {
		spec := strings.TrimPrefix(rangeH, "bytes=")
		dash := strings.IndexByte(spec, '-')
		if dash > 0 {
			n, err := strconv.ParseInt(spec[:dash], 10, 64)
			if err == nil {
				start = n
			}
			if rest := spec[dash+1:]; rest != "" {
				if m, err := strconv.ParseInt(rest, 10, 64); err == nil {
					end = m
				}
			}
		}
	}
	hit.startedAt = start

	slice := s.body[start : end+1]
	if rangeH != "" {
		w.Header().Set("Content-Range",
			fmt.Sprintf("bytes %d-%d/%d", start, end, len(s.body)))
		w.WriteHeader(http.StatusPartialContent)
	} else {
		w.WriteHeader(http.StatusOK)
	}

	if s.cutAfter > 0 && int64(len(slice)) > s.cutAfter {
		// Write only `cutAfter` bytes then hijack-close to simulate
		// a network drop.
		_, _ = w.Write(slice[:s.cutAfter])
		hit.wrote = s.cutAfter
		hit.cut = true
		// Force the writer to flush, then close the connection
		// abruptly via the hijacker.
		if hj, ok := w.(http.Hijacker); ok {
			conn, _, err := hj.Hijack()
			if err == nil {
				_ = conn.Close()
			}
		}
	} else {
		_, _ = w.Write(slice)
		hit.wrote = int64(len(slice))
	}
	s.hits = append(s.hits, hit)
}

func TestDownloadHashed_FreshThenResumeAfterInterrupt(t *testing.T) {
	// 64 KiB blob with a recognisable pattern -- not all zeros, so
	// the trailing-zero scanner won't have anything to chew on.
	body := make([]byte, 64*1024)
	for i := range body {
		body[i] = byte(i*73) ^ 0x55
	}
	wantSHA := sha256.Sum256(body)
	wantHex := hex.EncodeToString(wantSHA[:])

	srv := &rangeServer{body: body, cutAfter: 20 * 1024}
	ts := httptest.NewServer(http.HandlerFunc(srv.handler))
	defer ts.Close()

	tmpDir := t.TempDir()
	dst := filepath.Join(tmpDir, "blob.out")
	c := New(ts.URL)

	// Attempt 1: server cuts the connection after 20 KiB.  Expect
	// an error.  The .part file must survive (no Remove).
	ctx := context.Background()
	url := ts.URL + "/blob/x"
	if _, err := c.downloadHashed(ctx, url, wantHex, dst, nil); err == nil {
		t.Fatalf("attempt 1: expected error from cut-after, got nil")
	}
	partPath := dst + ".part"
	info, err := os.Stat(partPath)
	if err != nil {
		t.Fatalf("attempt 1: .part should still exist after a cut, got %v", err)
	}
	if info.Size() == 0 {
		t.Fatalf("attempt 1: .part should be non-empty after a cut, got 0")
	}

	// Attempt 2: no longer cutting.  Should resume via Range and
	// land the final blob successfully.
	srv.cutAfter = 0
	written, err := c.downloadHashed(ctx, url, wantHex, dst, nil)
	if err != nil {
		t.Fatalf("attempt 2: %v", err)
	}
	if written != int64(len(body)) {
		t.Errorf("attempt 2 written = %d, want %d (absolute, not just the second leg)",
			written, len(body))
	}

	// .part should be gone, dst should match the original body.
	if _, err := os.Stat(partPath); !os.IsNotExist(err) {
		t.Errorf(".part should be gone after success, stat err = %v", err)
	}
	got, err := os.ReadFile(dst)
	if err != nil {
		t.Fatalf("read dst: %v", err)
	}
	if string(got) != string(body) {
		t.Errorf("final blob bytes mismatch")
	}

	// We should have seen exactly two requests: the first with no
	// Range, the second with `bytes=N-` resuming from the cut
	// position (or wherever the trailing-zero trim landed us).
	if len(srv.hits) != 2 {
		t.Fatalf("server saw %d requests, want 2: %+v", len(srv.hits), srv.hits)
	}
	if srv.hits[0].rangeHeader != "" {
		t.Errorf("attempt 1 should have no Range header, got %q",
			srv.hits[0].rangeHeader)
	}
	if !strings.HasPrefix(srv.hits[1].rangeHeader, "bytes=") {
		t.Errorf("attempt 2 should send a Range header, got %q",
			srv.hits[1].rangeHeader)
	}
	if srv.hits[1].startedAt == 0 {
		t.Errorf("attempt 2 should resume from > 0, got start=%d (no resume happened)",
			srv.hits[1].startedAt)
	}
}

func TestDownloadHashed_FallsBackWhenServerIgnoresRange(t *testing.T) {
	// Some servers/proxies advertise Accept-Ranges but actually
	// return the full body on a Range request.  We must detect
	// (status 200 with a Range request) and fall back to a fresh
	// download from byte 0 -- otherwise we'd append the full body
	// onto the existing .part prefix and the SHA would never match.
	body := make([]byte, 8*1024)
	for i := range body {
		body[i] = byte(i)
	}
	wantSHA := sha256.Sum256(body)
	wantHex := hex.EncodeToString(wantSHA[:])

	srv := &rangeServer{body: body, rangeBehaviour: "ignore"}
	ts := httptest.NewServer(http.HandlerFunc(srv.handler))
	defer ts.Close()

	tmpDir := t.TempDir()
	dst := filepath.Join(tmpDir, "blob.out")
	partPath := dst + ".part"

	// Pre-seed a fake .part with garbage so the client computes a
	// non-zero resume offset (and a wrong prefix hash).  The
	// server-ignores-Range branch must throw it all away, not feed
	// the bogus prefix into the SHA.
	if err := os.WriteFile(partPath, []byte("GARBAGE-FROM-PRIOR-RUN"), 0644); err != nil {
		t.Fatalf("seed .part: %v", err)
	}

	c := New(ts.URL)
	written, err := c.downloadHashed(context.Background(),
		ts.URL+"/blob/x", wantHex, dst, nil)
	if err != nil {
		t.Fatalf("download (server ignores Range): %v", err)
	}
	if written != int64(len(body)) {
		t.Errorf("written = %d, want %d", written, len(body))
	}
	got, err := os.ReadFile(dst)
	if err != nil {
		t.Fatalf("read dst: %v", err)
	}
	if string(got) != string(body) {
		t.Errorf("body mismatch after fallback restart")
	}
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

func writeTmp(t *testing.T, data []byte) string {
	t.Helper()
	dir := t.TempDir()
	p := filepath.Join(dir, "f")
	if err := os.WriteFile(p, data, 0644); err != nil {
		t.Fatalf("write tmp: %v", err)
	}
	return p
}

// Quiet `imported and not used: io` for go test if a future change
// removes the only io use.  Keep this side-effect import inert.
var _ = io.EOF

// ---------------------------------------------------------------------------
// ReportClientState (v1.5)
// ---------------------------------------------------------------------------

func TestReportClientState_PutsBodyWithAuth(t *testing.T) {
	var seenAuth string
	var seenBody map[string]any
	var seenMethod string
	var seenPath string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenMethod = r.Method
		seenPath = r.URL.Path
		seenAuth = r.Header.Get("Authorization")
		_ = json.NewDecoder(r.Body).Decode(&seenBody)
		w.WriteHeader(200)
		_, _ = w.Write([]byte(`{"client_id":"c-x","software":"myapp","current_release_id":"myapp/linux-x86_64/1.0.0"}`))
	}))
	defer srv.Close()

	c := New(srv.URL)
	c.Auth = "BEARER123"
	err := c.ReportClientState(context.Background(),
		"myapp",
		"myapp/linux-x86_64/1.0.0",
		"myapp/linux-x86_64/0.9.0",
		"upgrade")
	if err != nil {
		t.Fatalf("ReportClientState: %v", err)
	}
	if seenMethod != "PUT" {
		t.Errorf("method = %q, want PUT", seenMethod)
	}
	if seenPath != "/v1/clients/me/software/myapp" {
		t.Errorf("path = %q, want /v1/clients/me/software/myapp", seenPath)
	}
	if seenAuth != "Bearer BEARER123" {
		t.Errorf("authorization = %q, want Bearer BEARER123", seenAuth)
	}
	if seenBody["kind"] != "upgrade" {
		t.Errorf("kind = %v, want upgrade", seenBody["kind"])
	}
	if seenBody["current_release_id"] != "myapp/linux-x86_64/1.0.0" {
		t.Errorf("current_release_id wrong: %v", seenBody["current_release_id"])
	}
	if seenBody["previous_release_id"] != "myapp/linux-x86_64/0.9.0" {
		t.Errorf("previous_release_id wrong: %v", seenBody["previous_release_id"])
	}
}

func TestReportClientState_NullCurrentForUninstall(t *testing.T) {
	var seenBody map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewDecoder(r.Body).Decode(&seenBody)
		w.WriteHeader(200)
		_, _ = w.Write([]byte(`{}`))
	}))
	defer srv.Close()

	c := New(srv.URL)
	c.Auth = "BEARER123"
	err := c.ReportClientState(context.Background(),
		"myapp", "", "myapp/linux-x86_64/1.0.0", "uninstall")
	if err != nil {
		t.Fatalf("ReportClientState: %v", err)
	}
	// Uninstall sends an explicit null (not the empty string) so the
	// server-side JSON parser sees the field as missing-vs-NULL the
	// way operations.org documents.
	if v, ok := seenBody["current_release_id"]; !ok || v != nil {
		t.Errorf("current_release_id should be JSON null on uninstall, got %v", v)
	}
}

func TestReportClientState_OptOutHonoured(t *testing.T) {
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&calls, 1)
		w.WriteHeader(200)
	}))
	defer srv.Close()

	t.Setenv("OTA_DISABLE_REPORTING", "1")
	c := New(srv.URL)
	c.Auth = "BEARER123"
	err := c.ReportClientState(context.Background(), "myapp", "v1", "", "install")
	if err != nil {
		t.Fatalf("ReportClientState (opt-out): %v", err)
	}
	if atomic.LoadInt32(&calls) != 0 {
		t.Errorf("OTA_DISABLE_REPORTING=1 should suppress the network call, saw %d", calls)
	}
}

func TestReportClientState_NetworkFailureSurfaced(t *testing.T) {
	// Connect-refused on a closed listener.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	url := srv.URL
	srv.Close() // ensure subsequent dials fail
	c := New(url)
	c.Auth = "BEARER123"
	err := c.ReportClientState(context.Background(), "myapp", "v1", "", "install")
	if err == nil {
		t.Fatalf("expected error on closed-server PUT")
	}
	if !strings.Contains(err.Error(), "report-state") {
		t.Errorf("error should be wrapped with 'report-state', got %q", err)
	}
}

func TestReportClientState_4xxReportedAsError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(401)
		_, _ = w.Write([]byte(`{"error":"unauthorised"}`))
	}))
	defer srv.Close()

	c := New(srv.URL)
	c.Auth = "WRONG"
	err := c.ReportClientState(context.Background(), "myapp", "v1", "", "install")
	if err == nil {
		t.Fatalf("expected error on 401")
	}
	if !strings.Contains(err.Error(), "401") {
		t.Errorf("error should mention 401, got %q", err)
	}
}
