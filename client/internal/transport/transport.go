// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Ogamita Ltd.

// Package transport handles HTTP fetching of manifests, blobs and
// patches with sha256 streaming verification.
package transport

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"hash"
	"io"
	"net/http"
	"os"
	"time"
)

// Client wraps a server URL and a *http.Client. The optional Auth
// token, when set, is sent on every request as "Authorization:
// Bearer <token>".
type Client struct {
	BaseURL string
	HTTP    *http.Client
	Auth    BearerAuth
}

func New(baseURL string) *Client {
	return &Client{
		BaseURL: baseURL,
		HTTP:    &http.Client{Timeout: 30 * time.Second},
	}
}

// GetManifest fetches /v1/software/<sw>/releases/<v>/manifest and
// returns the raw bytes plus the X-Ota-Signature and
// X-Ota-Public-Key headers (hex). Verification is the caller's job.
func (c *Client) GetManifest(ctx context.Context, software, version string) (data []byte, sigHex, pubHex string, err error) {
	url := fmt.Sprintf("%s/v1/software/%s/releases/%s/manifest", c.BaseURL, software, version)
	req, err := c.authedRequest(ctx, http.MethodGet, url)
	if err != nil {
		return nil, "", "", err
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, "", "", fmt.Errorf("manifest fetch: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, "", "", fmt.Errorf("manifest fetch: %s", resp.Status)
	}
	data, err = io.ReadAll(resp.Body)
	if err != nil {
		return nil, "", "", fmt.Errorf("manifest read: %w", err)
	}
	return data, resp.Header.Get("X-Ota-Signature"), resp.Header.Get("X-Ota-Public-Key"), nil
}

// BearerAuth, if set, is appended to every outgoing request as
// "Authorization: Bearer <token>".
type BearerAuth string

func (c *Client) authedRequest(ctx context.Context, method, url string) (*http.Request, error) {
	req, err := http.NewRequestWithContext(ctx, method, url, nil)
	if err != nil {
		return nil, err
	}
	if c.Auth != "" {
		req.Header.Set("Authorization", "Bearer "+string(c.Auth))
	}
	return req, nil
}

// ExchangeInstallToken trades a short-lived install token (minted by
// the install page or by ota-admin) for a per-client bearer token
// and a stable client_id. Stores nothing — the caller is responsible
// for persisting the bearer.
type ExchangeResult struct {
	ClientID        string   `json:"client_id"`
	BearerToken     string   `json:"bearer_token"`
	Classifications []string `json:"classifications"`
}

func (c *Client) ExchangeInstallToken(ctx context.Context, installToken, hwinfo string) (*ExchangeResult, error) {
	body, _ := json.Marshal(map[string]string{
		"install_token": installToken,
		"hwinfo":        hwinfo,
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		c.BaseURL+"/v1/exchange-token", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, fmt.Errorf("exchange: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		raw, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("exchange: %s: %s", resp.Status, string(raw))
	}
	var out ExchangeResult
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, fmt.Errorf("exchange decode: %w", err)
	}
	return &out, nil
}

// Anchor is a server-curated "known-good" release that the recovery
// tool can offer to the user.
type Anchor struct {
	Version   string `json:"version"`
	ReleaseID string `json:"release_id"`
	Channel   string `json:"channel,omitempty"`
	Reason    string `json:"reason,omitempty"`
	BlobSize  int64  `json:"blob_size,omitempty"`
}

// Anchors fetches the recovery anchors for SOFTWARE.
func (c *Client) Anchors(ctx context.Context, software string) ([]Anchor, error) {
	url := fmt.Sprintf("%s/v1/software/%s/anchors", c.BaseURL, software)
	req, err := c.authedRequest(ctx, http.MethodGet, url)
	if err != nil {
		return nil, err
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, fmt.Errorf("anchors: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("anchors: %s", resp.Status)
	}
	var out []Anchor
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, fmt.Errorf("anchors decode: %w", err)
	}
	return out, nil
}

// LatestRelease fetches /v1/software/<sw>/releases/latest as raw JSON.
func (c *Client) LatestRelease(ctx context.Context, software string) ([]byte, error) {
	url := fmt.Sprintf("%s/v1/software/%s/releases/latest", c.BaseURL, software)
	req, err := c.authedRequest(ctx, http.MethodGet, url)
	if err != nil {
		return nil, err
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, fmt.Errorf("latest: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("latest: %s", resp.Status)
	}
	return io.ReadAll(resp.Body)
}

// Software is one row of the catalogue list returned by GET /v1/software.
type Software struct {
	Name           string `json:"name"`
	DisplayName    string `json:"display_name"`
	DefaultPatcher string `json:"default_patcher"`
	CreatedAt      string `json:"created_at"`
}

// Release is one row of /v1/software/<sw>/releases (a subset of the
// fields the server returns; only what `ota-agent list --remote`
// uses).
type Release struct {
	ReleaseID       string   `json:"release_id"`
	Software        string   `json:"software"`
	OS              string   `json:"os"`
	Arch            string   `json:"arch"`
	Version         string   `json:"version"`
	BlobSize        int64    `json:"blob_size"`
	PublishedAt     string   `json:"published_at"`
	Channels        []string `json:"channels"`
	Classifications []string `json:"classifications"`
	Deprecated      bool     `json:"deprecated"`
	Uncollectable   bool     `json:"uncollectable"`
}

// ListReleases fetches /v1/software/<sw>/releases (every release of
// SOFTWARE in the catalogue) and returns the parsed array.  Used by
// `ota-agent list --remote` to enumerate every version, not just the
// most-recently-published one.
func (c *Client) ListReleases(ctx context.Context, software string) ([]Release, error) {
	url := fmt.Sprintf("%s/v1/software/%s/releases", c.BaseURL, software)
	req, err := c.authedRequest(ctx, http.MethodGet, url)
	if err != nil {
		return nil, err
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, fmt.Errorf("list-releases: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("list-releases: %s", resp.Status)
	}
	var out []Release
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, fmt.Errorf("list-releases decode: %w", err)
	}
	return out, nil
}

// ListSoftware fetches /v1/software (the catalogue index) and returns
// the parsed array.  Used by `ota-agent list --remote` to enumerate
// what the server has on offer.
func (c *Client) ListSoftware(ctx context.Context) ([]Software, error) {
	url := c.BaseURL + "/v1/software"
	req, err := c.authedRequest(ctx, http.MethodGet, url)
	if err != nil {
		return nil, err
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, fmt.Errorf("list-software: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("list-software: %s", resp.Status)
	}
	var out []Software
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, fmt.Errorf("list-software decode: %w", err)
	}
	return out, nil
}

// SetClientEmail registers an email for the calling client at the
// server (v1.7).  Used by `ota-agent set-email`.  Strictly opt-in:
// the agent only calls this when the user explicitly asks.
//
// Authenticated by the per-client bearer.  Returns the parsed
// response { client_id, email, verified } on success.
type SetEmailResult struct {
	ClientID string `json:"client_id"`
	Email    string `json:"email"`
	Verified bool   `json:"verified"`
}

func (c *Client) SetClientEmail(ctx context.Context, email string) (*SetEmailResult, error) {
	body, _ := json.Marshal(map[string]string{"email": email})
	url := c.BaseURL + "/v1/clients/me/email"
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	if c.Auth != "" {
		req.Header.Set("Authorization", "Bearer "+string(c.Auth))
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, fmt.Errorf("set-email: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("set-email: %s", resp.Status)
	}
	var out SetEmailResult
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, fmt.Errorf("set-email parse: %w", err)
	}
	return &out, nil
}

// ListClientEmails returns the addresses registered for the calling
// client (v1.7).  Used by `ota-agent show-email`.
type ClientEmail struct {
	Email      string `json:"email"`
	VerifiedAt string `json:"verified_at"`
	OptedInAt  string `json:"opted_in_at"`
}

func (c *Client) ListClientEmails(ctx context.Context) ([]ClientEmail, error) {
	url := c.BaseURL + "/v1/clients/me/email"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	if c.Auth != "" {
		req.Header.Set("Authorization", "Bearer "+string(c.Auth))
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, fmt.Errorf("list-emails: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("list-emails: %s", resp.Status)
	}
	var out []ClientEmail
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, fmt.Errorf("list-emails parse: %w", err)
	}
	return out, nil
}

// DeleteClientEmail removes one (or all) registered addresses for
// the calling client (v1.7).  When `address` is empty, removes all
// -- the GDPR right-to-deletion path.
func (c *Client) DeleteClientEmail(ctx context.Context, address string) (int, error) {
	url := c.BaseURL + "/v1/clients/me/email"
	if address != "" {
		url = url + "?address=" + address
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, url, nil)
	if err != nil {
		return 0, err
	}
	if c.Auth != "" {
		req.Header.Set("Authorization", "Bearer "+string(c.Auth))
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return 0, fmt.Errorf("delete-email: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return 0, fmt.Errorf("delete-email: %s", resp.Status)
	}
	var out struct {
		Deleted int `json:"deleted"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return 0, fmt.Errorf("delete-email parse: %w", err)
	}
	return out.Deleted, nil
}

// ReportClientState PUTs the agent's current snapshot for one
// software to /v1/clients/me/software/<sw> (v1.5).  The server
// updates client_software_state, used by the GC's exact
// count-users-at-release and by the admin stats catalogue.
//
// Authenticated by the per-client bearer.  Should be called
// after every successful install / upgrade / revert / recover /
// uninstall.  Idempotent on the server side: re-PUT the same
// state is a no-op at the value level.
//
// Best-effort: callers SHOULD log the error and continue.  The
// local install state is already committed before this is
// called; a reporting failure does not roll the install back.
//
// Honours OTA_DISABLE_REPORTING=1 by short-circuiting to nil
// without making any network call.  Deployments that don't want
// the server to know their snapshot can flip this.
func (c *Client) ReportClientState(ctx context.Context,
	software, currentReleaseID, previousReleaseID, kind string) error {
	if os.Getenv("OTA_DISABLE_REPORTING") == "1" {
		return nil
	}
	body := map[string]any{
		"kind": kind,
	}
	if currentReleaseID != "" {
		body["current_release_id"] = currentReleaseID
	} else {
		body["current_release_id"] = nil
	}
	if previousReleaseID != "" {
		body["previous_release_id"] = previousReleaseID
	}
	enc, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("report-state: encode: %w", err)
	}
	url := fmt.Sprintf("%s/v1/clients/me/software/%s", c.BaseURL, software)
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, url, bytes.NewReader(enc))
	if err != nil {
		return err
	}
	if c.Auth != "" {
		req.Header.Set("Authorization", "Bearer "+string(c.Auth))
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return fmt.Errorf("report-state: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("report-state: %s", resp.Status)
	}
	return nil
}

// DownloadPatch is like DownloadBlob but for /v1/patches/<sha>.
func (c *Client) DownloadPatch(ctx context.Context, sha256Hex, dstPath string, progress func(written int64)) (int64, error) {
	return c.downloadHashed(ctx, fmt.Sprintf("%s/v1/patches/%s", c.BaseURL, sha256Hex), sha256Hex, dstPath, progress)
}

// DownloadBlob streams the blob at /v1/blobs/<sha> into dstPath,
// verifying that the bytes hash to expectedSHA256 (hex). Returns the
// number of bytes written. The destination is removed on hash
// mismatch.
func (c *Client) DownloadBlob(ctx context.Context, sha256Hex, dstPath string, progress func(written int64)) (int64, error) {
	return c.downloadHashed(ctx, fmt.Sprintf("%s/v1/blobs/%s", c.BaseURL, sha256Hex), sha256Hex, dstPath, progress)
}

// downloadHashed is the shared implementation for DownloadBlob and
// DownloadPatch.  It is resumable when the server supports HTTP
// Range (the OTA server does, since v1.3): on retry the existing
// <dst>.part file is reused, the trailing-zero tail is trimmed (a
// torn write may have grown the file's apparent size beyond what
// was committed to disk), the prefix SHA is recomputed, and the
// request is re-issued with `Range: bytes=N-`.  If the server
// returns 200 (Range ignored), the client falls back to a full
// download starting from byte 0.
//
// On any non-final error the .part file is *kept* so the next
// attempt can resume.  The .part file is only deleted when:
//   - the final SHA mismatches (corrupted or wrong blob), or
//   - the rename to the final destination succeeds.
func (c *Client) downloadHashed(ctx context.Context, url, sha256Hex, dstPath string, progress func(written int64)) (int64, error) {
	tmp := dstPath + ".part"

	// 1. Probe the existing .part for a safe resume point.  See
	//    safeResumeSize for the trailing-zero policy.
	resumeFrom, prefixHasher, err := openResumeState(tmp)
	if err != nil {
		// Probe failed (e.g. permissions); start fresh.
		resumeFrom, prefixHasher = 0, nil
	}

	// 2. Build the request, with Range when we have a prefix.
	req, err := c.authedRequest(ctx, http.MethodGet, url)
	if err != nil {
		return 0, err
	}
	if resumeFrom > 0 {
		req.Header.Set("Range", fmt.Sprintf("bytes=%d-", resumeFrom))
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		// Network error before the response: keep .part around for
		// the next attempt.
		return 0, fmt.Errorf("download: %w", err)
	}
	defer resp.Body.Close()

	// 3. Decide whether the server honoured Range.
	hasher := prefixHasher
	startOffset := resumeFrom
	switch {
	case resumeFrom > 0 && resp.StatusCode == http.StatusPartialContent:
		// Good — server gave us bytes [resumeFrom..end].
	case resp.StatusCode == http.StatusOK:
		// Either we asked for the full thing, or the server ignored
		// our Range and gave us the whole file anyway.  Restart from
		// byte 0; truncate any existing .part.
		startOffset = 0
		hasher = sha256.New()
		if err := os.Truncate(tmp, 0); err != nil && !os.IsNotExist(err) {
			return 0, fmt.Errorf("download truncate: %w", err)
		}
	default:
		return 0, fmt.Errorf("download: %s", resp.Status)
	}

	// 4. Append (when resuming) or write fresh (when starting from 0).
	flag := os.O_WRONLY | os.O_CREATE
	if startOffset == 0 {
		flag |= os.O_TRUNC
	} else {
		flag |= os.O_APPEND
	}
	out, err := os.OpenFile(tmp, flag, 0644)
	if err != nil {
		return 0, fmt.Errorf("download open: %w", err)
	}
	if hasher == nil {
		hasher = sha256.New()
	}
	mw := io.MultiWriter(out, hasher)

	// 5. Copy.  copyWithProgress reports cumulative written bytes
	//    *of the response body*; combine with startOffset so the
	//    progress callback sees the absolute position on the full
	//    file -- otherwise the UI would show "downloaded 50 MB" on
	//    a resume that has 1.5 GB on disk already.
	progressAbs := progress
	if progress != nil && startOffset > 0 {
		progressAbs = func(w int64) { progress(startOffset + w) }
	}
	bodyWritten, err := copyWithProgress(mw, resp.Body, progressAbs)
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		// Mid-transfer error (network drop, disk full, etc.).  KEEP
		// the .part around so the next attempt resumes; do *not*
		// remove it.
		return startOffset + bodyWritten, fmt.Errorf("download copy: %w", err)
	}

	// 6. Final integrity check.  A mismatch here means the bytes
	//    on disk are not what the manifest committed to: drop the
	//    .part and start over on the next attempt.
	got := hex.EncodeToString(hasher.Sum(nil))
	if got != sha256Hex {
		_ = os.Remove(tmp)
		return startOffset + bodyWritten,
			fmt.Errorf("download sha mismatch: want %s got %s", sha256Hex, got)
	}
	if err := os.Rename(tmp, dstPath); err != nil {
		// Keep .part: a rename failure is usually transient (target
		// dir gone, permissions); the bytes are correct.
		return startOffset + bodyWritten, fmt.Errorf("download rename: %w", err)
	}
	return startOffset + bodyWritten, nil
}

// openResumeState inspects an existing <dst>.part and returns the
// safe resume offset along with a SHA-256 hasher pre-fed with the
// kept prefix.  When .part is absent or empty it returns (0, nil,
// nil) -- callers then start a fresh download.
//
// The "safe" size is computed by safeResumeSize; if that comes
// back smaller than the on-disk size we truncate the .part down
// to drop any unsynced trailing zeros from a torn write before
// the previous crash.
func openResumeState(partPath string) (int64, hash.Hash, error) {
	info, err := os.Stat(partPath)
	if err != nil || info.Size() == 0 {
		return 0, nil, nil
	}
	safe, err := safeResumeSize(partPath, info.Size())
	if err != nil {
		return 0, nil, err
	}
	if safe < info.Size() {
		if err := os.Truncate(partPath, safe); err != nil {
			return 0, nil, err
		}
	}
	if safe == 0 {
		// Nothing usable; .part is now zero-length.
		return 0, nil, nil
	}
	h, err := hashPrefix(partPath, safe)
	if err != nil {
		return 0, nil, err
	}
	return safe, h, nil
}

// safeResumeSize returns a byte offset N such that bytes [0, N) of
// PARTPATH are guaranteed to be valid blob content -- i.e. not the
// trailing-zero tail of a torn write.  We do not call fsync(2) on
// every chunk (that would halve throughput on a 2 GB transfer); the
// price is that a crash may leave the file's metadata size larger
// than the data the kernel actually committed, with the gap reading
// as zeros after recovery.
//
// We can't tell legitimate trailing zeros in the blob apart from
// post-crash zero-fill, so on resume we conservatively re-fetch any
// trailing zeros at the end of .part.  Worst case: a blob whose
// last byte is zero costs us re-downloading a few hundred KB on the
// resume attempt.  Acceptable.
//
// To bound the cost of the scan on a multi-GB file we look at most
// at the last 16 MiB.  If those are *all* zeros we discard the
// whole window (returning the offset before it) -- that's a safe
// over-approximation; the next iteration of the resume loop will
// either land on real data or shrink the window further.
const safeScanWindowBytes = 16 * 1024 * 1024

func safeResumeSize(path string, fileSize int64) (int64, error) {
	if fileSize == 0 {
		return 0, nil
	}
	f, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	bufSize := int64(safeScanWindowBytes)
	if bufSize > fileSize {
		bufSize = fileSize
	}
	buf := make([]byte, bufSize)
	offset := fileSize - bufSize
	if _, err := f.ReadAt(buf, offset); err != nil && err != io.EOF {
		return 0, err
	}
	for i := len(buf) - 1; i >= 0; i-- {
		if buf[i] != 0 {
			return offset + int64(i) + 1, nil
		}
	}
	// All zero in the scan window.  Drop it.
	return offset, nil
}

// hashPrefix returns a SHA-256 hasher pre-fed with bytes [0, size)
// of PATH.  Used on resume to rebuild the hash state for the kept
// prefix so the final SHA still verifies the whole blob.
func hashPrefix(path string, size int64) (hash.Hash, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.CopyN(h, f, size); err != nil {
		return nil, err
	}
	return h, nil
}

func copyWithProgress(dst io.Writer, src io.Reader, progress func(written int64)) (int64, error) {
	buf := make([]byte, 64*1024)
	var total int64
	for {
		n, err := src.Read(buf)
		if n > 0 {
			if _, werr := dst.Write(buf[:n]); werr != nil {
				return total, werr
			}
			total += int64(n)
			if progress != nil {
				progress(total)
			}
		}
		if errors.Is(err, io.EOF) {
			return total, nil
		}
		if err != nil {
			return total, err
		}
	}
}
