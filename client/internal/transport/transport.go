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
// DownloadPatch.
func (c *Client) downloadHashed(ctx context.Context, url, sha256Hex, dstPath string, progress func(written int64)) (int64, error) {
	req, err := c.authedRequest(ctx, http.MethodGet, url)
	if err != nil {
		return 0, err
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return 0, fmt.Errorf("download: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 0, fmt.Errorf("download: %s", resp.Status)
	}

	tmp := dstPath + ".part"
	out, err := os.Create(tmp)
	if err != nil {
		return 0, fmt.Errorf("download create: %w", err)
	}
	hasher := sha256.New()
	mw := io.MultiWriter(out, hasher)

	written, err := copyWithProgress(mw, resp.Body, progress)
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		_ = os.Remove(tmp)
		return written, fmt.Errorf("download copy: %w", err)
	}

	got := hex.EncodeToString(hasher.Sum(nil))
	if got != sha256Hex {
		_ = os.Remove(tmp)
		return written, fmt.Errorf("download sha mismatch: want %s got %s", sha256Hex, got)
	}
	if err := os.Rename(tmp, dstPath); err != nil {
		_ = os.Remove(tmp)
		return written, fmt.Errorf("download rename: %w", err)
	}
	return written, nil
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
