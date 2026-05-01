// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Ogamita Ltd.

// Package manifest parses and verifies signed Ogamita Delta OTA manifests.
package manifest

import (
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"fmt"
)

type Blob struct {
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
	URL    string `json:"url"`
}

type PatchRef struct {
	From    string `json:"from,omitempty"`
	To      string `json:"to,omitempty"`
	Patcher string `json:"patcher"`
	SHA256  string `json:"sha256"`
	Size    int64  `json:"size"`
	URL     string `json:"url,omitempty"`
}

type Manifest struct {
	SchemaVersion   int        `json:"schema_version"`
	ReleaseID       string     `json:"release_id"`
	Software        string     `json:"software"`
	OS              string     `json:"os"`
	Arch            string     `json:"arch"`
	OSVersions      []string   `json:"os_versions"`
	Version         string     `json:"version"`
	PublishedAt     string     `json:"published_at"`
	PublishedBy     string     `json:"published_by,omitempty"`
	Blob            Blob       `json:"blob"`
	PatchesIn       []PatchRef `json:"patches_in"`
	PatchesOut      []PatchRef `json:"patches_out"`
	Channels        []string   `json:"channels"`
	Classifications []string   `json:"classifications"`
	Deprecated      bool       `json:"deprecated"`
	Uncollectable   bool       `json:"uncollectable"`
	Notes           string     `json:"notes,omitempty"`
}

// Parse decodes the manifest JSON. It does NOT verify the signature.
func Parse(data []byte) (*Manifest, error) {
	var m Manifest
	if err := json.Unmarshal(data, &m); err != nil {
		return nil, fmt.Errorf("manifest parse: %w", err)
	}
	if m.SchemaVersion != 1 {
		return nil, fmt.Errorf("manifest: unsupported schema_version %d", m.SchemaVersion)
	}
	return &m, nil
}

// Verify checks that hexSig is a valid Ed25519 signature over data,
// using hexPubKey as the verifier. The verifier compares the public
// key against the caller-supplied trusted set; that is the caller's
// responsibility (we just verify the signature math here).
func Verify(data []byte, hexSig, hexPubKey string) error {
	sig, err := hex.DecodeString(hexSig)
	if err != nil {
		return fmt.Errorf("manifest: signature is not hex: %w", err)
	}
	pub, err := hex.DecodeString(hexPubKey)
	if err != nil {
		return fmt.Errorf("manifest: public key is not hex: %w", err)
	}
	if len(pub) != ed25519.PublicKeySize {
		return fmt.Errorf("manifest: public key wrong size: %d", len(pub))
	}
	if !ed25519.Verify(ed25519.PublicKey(pub), data, sig) {
		return fmt.Errorf("manifest: signature does not verify")
	}
	return nil
}
