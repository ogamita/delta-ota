// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Ogamita Ltd.

// Package libota is the embeddable client library of Ogamita Delta OTA.
//
// Phase 1: Install only.  Upgrade/Revert/Discovery beyond "latest"
// land in later phases.
package libota

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"gitlab.com/ogamita/delta-ota/client/internal/manifest"
	"gitlab.com/ogamita/delta-ota/client/internal/patch"
	"gitlab.com/ogamita/delta-ota/client/internal/state"
	"gitlab.com/ogamita/delta-ota/client/internal/tarx"
	"gitlab.com/ogamita/delta-ota/client/internal/transport"
)

const Version = "0.1.0-phase1"

// Config drives an Install. ServerURL is mandatory; OTAHome
// defaults to ~/.ota; TrustedPubKeys gates which signing keys we
// accept (hex-encoded). Empty TrustedPubKeys means trust-on-first-use:
// the key the server presents is pinned and recorded in state.json.
//
// FallbackRatio (default 0.7) caps the patch transfer size relative
// to the full blob: if every available patch is larger than
// FallbackRatio * blob_size, the client downloads the full blob
// instead of patching.
type Config struct {
	ServerURL      string
	OTAHome        string
	TrustedPubKeys []string
	Timeout        time.Duration
	FallbackRatio  float64

	// InstallToken, if set, is exchanged for a per-client bearer
	// token on first contact.  Once a bearer is recorded in
	// state.json it is used for all subsequent requests and
	// InstallToken is ignored.
	InstallToken string

	// Hwinfo is sent with the install-token exchange so an admin can
	// recognise the workstation in the audit log.  Free-form short
	// string (hostname is fine).
	Hwinfo string

	// Kind is the value reported to the server's v1.5 client-state
	// snapshot.  When empty, Install infers "install" or "upgrade"
	// from the prior state; callers that need to signal a specific
	// transition (e.g. doctor --recover) set this explicitly.
	// Recognised values: install | upgrade | revert | recover.
	Kind string
}

func (c Config) fallbackRatio() float64 {
	if c.FallbackRatio <= 0 {
		return 0.7
	}
	return c.FallbackRatio
}

func defaultOTAHome() string {
	if v := os.Getenv("OTA_HOME"); v != "" {
		return v
	}
	if h, err := os.UserHomeDir(); err == nil {
		return filepath.Join(h, ".ota")
	}
	return ".ota"
}

// Install installs the named software at "latest" or at the given
// explicit version. version=="latest" or "" means latest.
func Install(ctx context.Context, cfg Config, software, version string) (string, error) {
	if cfg.ServerURL == "" {
		return "", errors.New("libota: ServerURL required")
	}
	if cfg.OTAHome == "" {
		cfg.OTAHome = defaultOTAHome()
	}
	tr := transport.New(cfg.ServerURL)
	if cfg.Timeout > 0 {
		tr.HTTP.Timeout = cfg.Timeout
	}

	// Bearer token from prior state, or freshly exchanged from an
	// install token.  The state layout is per-software; we load it
	// before doing anything else so we can attach Auth.
	layout := state.New(cfg.OTAHome, software)
	if err := layout.Ensure(); err != nil {
		return "", err
	}
	st, err := layout.Load()
	if err != nil {
		return "", err
	}
	if st.BearerToken != "" {
		tr.Auth = transport.BearerAuth(st.BearerToken)
	} else if cfg.InstallToken != "" {
		ex, err := tr.ExchangeInstallToken(ctx, cfg.InstallToken, cfg.Hwinfo)
		if err != nil {
			return "", err
		}
		st.ClientID = ex.ClientID
		st.BearerToken = ex.BearerToken
		tr.Auth = transport.BearerAuth(ex.BearerToken)
	}

	// Resolve target version.
	if version == "" || version == "latest" {
		raw, err := tr.LatestRelease(ctx, software)
		if err != nil {
			return "", err
		}
		var r struct {
			Version string `json:"version"`
		}
		if err := json.Unmarshal(raw, &r); err != nil {
			return "", fmt.Errorf("install: parse latest: %w", err)
		}
		if r.Version == "" {
			return "", errors.New("install: server returned empty version")
		}
		version = r.Version
	}

	// Fetch manifest + signature.
	manifestData, sigHex, pubHex, err := tr.GetManifest(ctx, software, version)
	if err != nil {
		return "", err
	}

	// Public-key trust gate.
	if err := checkTrust(st, cfg.TrustedPubKeys, pubHex); err != nil {
		return "", err
	}

	// Verify signature.
	if err := manifest.Verify(manifestData, sigHex, pubHex); err != nil {
		return "", err
	}

	// Parse manifest after signature verification.
	m, err := manifest.Parse(manifestData)
	if err != nil {
		return "", err
	}
	if m.Software != software || m.Version != version {
		return "", fmt.Errorf("install: manifest software/version mismatch (%s/%s vs %s/%s)",
			m.Software, m.Version, software, version)
	}

	// Resolve transfer strategy: patch if we have a usable local blob
	// AND the manifest declares a patch from our current version
	// AND the patch is smaller than fallback_ratio * blob_size.
	blobPath := layout.BlobPath(version)
	transferred := false
	if st.Current != "" && st.Current != version {
		oldBlob := layout.BlobPath(st.Current)
		if _, err := os.Stat(oldBlob); err == nil {
			pref := pickPatch(m.PatchesIn, st.Current, m.Blob.Size, cfg.fallbackRatio())
			if pref != nil {
				patchPath := filepath.Join(layout.PatchesDir, st.Current+"-to-"+version+".patch")
				if _, err := tr.DownloadPatch(ctx, pref.SHA256, patchPath, nil); err != nil {
					return "", fmt.Errorf("upgrade: download patch: %w", err)
				}
				if _, err := patch.Apply(oldBlob, patchPath, blobPath, m.Blob.SHA256, pref.Patcher); err != nil {
					return "", err
				}
				transferred = true
			}
		}
	}
	if !transferred {
		if _, err := tr.DownloadBlob(ctx, m.Blob.SHA256, blobPath, nil); err != nil {
			return "", err
		}
	}

	// Extract into distribution-<version>.
	dist := layout.DistributionDir(version)
	_ = os.RemoveAll(dist)
	if err := os.MkdirAll(dist, 0o755); err != nil {
		return "", fmt.Errorf("install: mkdir dist: %w", err)
	}
	bf, err := os.Open(blobPath)
	if err != nil {
		return "", fmt.Errorf("install: open blob: %w", err)
	}
	if err := tarx.Extract(bf, dist); err != nil {
		bf.Close()
		return "", err
	}
	if err := bf.Close(); err != nil {
		return "", err
	}

	// Atomic symlink flip.
	if err := layout.FlipCurrent(version); err != nil {
		return "", err
	}

	// Update state.json + run local retention.
	prev := st.Current
	st.Software = software
	if st.Current != version {
		if st.Current != "" {
			st.Previous = st.Current
		}
		st.Current = version
		st.History = append(st.History, version)
	}
	st.ServerURL = cfg.ServerURL
	st.ServerPubKeyHX = pubHex
	st.OS = m.OS
	st.Arch = m.Arch
	if err := layout.Save(st); err != nil {
		return "", err
	}
	pruneOldArtefacts(layout, st, prev)

	// v1.5: report the new state to the server (best-effort).  Local
	// install state is already committed above; a reporting failure
	// is logged but not propagated.
	kind := cfg.Kind
	if kind == "" {
		if prev == "" {
			kind = "install"
		} else {
			kind = "upgrade"
		}
	}
	curRID := releaseID(m.Software, m.OS, m.Arch, version)
	prevRID := ""
	if prev != "" {
		prevRID = releaseID(m.Software, m.OS, m.Arch, prev)
	}
	if err := tr.ReportClientState(ctx, software, curRID, prevRID, kind); err != nil {
		fmt.Fprintf(os.Stderr, "libota: state report failed (non-fatal): %v\n", err)
	}
	return version, nil
}

// releaseID composes the catalogue's canonical release_id from its
// four-part form `<software>/<os>-<arch>/<version>`, matching what
// handle-admin-publish-release produces server-side.
func releaseID(software, os, arch, version string) string {
	return fmt.Sprintf("%s/%s-%s/%s", software, os, arch, version)
}

// pickPatch picks the cheapest patch from `from` to the new release
// out of a manifest's patches_in, subject to the fallback ratio cap.
// Returns nil if no acceptable patch is found.
func pickPatch(in []manifest.PatchRef, from string, blobSize int64, fallbackRatio float64) *manifest.PatchRef {
	cap := int64(float64(blobSize) * fallbackRatio)
	var best *manifest.PatchRef
	for i := range in {
		p := &in[i]
		if p.From != from {
			continue
		}
		if p.Patcher != "bsdiff" {
			continue
		}
		if cap > 0 && p.Size > cap {
			continue
		}
		if best == nil || p.Size < best.Size {
			best = p
		}
	}
	return best
}

// pruneOldArtefacts implements the local retention policy. After
// upgrade vX -> vY, vX-2 material is dropped:
//   - distribution-vX-2.archived
//   - blob-vX-2
//   - patch vX-2 -> vX-1
func pruneOldArtefacts(layout *state.Layout, st *state.State, lastPrev string) {
	if len(st.History) < 3 {
		return
	}
	older := st.History[len(st.History)-3]
	_ = lastPrev
	for _, p := range []string{
		layout.BlobPath(older),
		filepath.Join(layout.Root, "distribution-"+older+".archived"),
	} {
		_ = os.RemoveAll(p)
	}
	// Patch files matching <older>-to-*.patch
	if entries, err := os.ReadDir(layout.PatchesDir); err == nil {
		prefix := older + "-to-"
		for _, e := range entries {
			if !e.IsDir() && len(e.Name()) > len(prefix) && e.Name()[:len(prefix)] == prefix {
				_ = os.Remove(filepath.Join(layout.PatchesDir, e.Name()))
			}
		}
	}
}

func checkTrust(st *state.State, trusted []string, presented string) error {
	if len(trusted) > 0 {
		for _, p := range trusted {
			if p == presented {
				return nil
			}
		}
		return fmt.Errorf("install: server pubkey %s not in trusted set", short(presented))
	}
	if st.ServerPubKeyHX == "" || st.ServerPubKeyHX == presented {
		return nil
	}
	return fmt.Errorf("install: server pubkey changed (was %s, now %s) — refuse",
		short(st.ServerPubKeyHX), short(presented))
}

func short(hex string) string {
	if len(hex) > 12 {
		return hex[:12] + "..."
	}
	return hex
}

// Upgrade is reserved for phase 2 (patches).
func Upgrade(ctx context.Context, cfg Config, software, version string) (string, error) {
	// In phase 1, upgrade falls through to Install (full re-download).
	return Install(ctx, cfg, software, version)
}

// Revert flips current/previous symlinks atomically.
func Revert(cfg Config, software string) error {
	if cfg.OTAHome == "" {
		cfg.OTAHome = defaultOTAHome()
	}
	layout := state.New(cfg.OTAHome, software)
	st, err := layout.Load()
	if err != nil {
		return err
	}
	if st.Previous == "" {
		return errors.New("revert: no previous distribution")
	}
	prev := st.Previous
	cur := st.Current
	// Note: prev/cur captured for the v1.5 state report after the
	// swap below; the local revert succeeds either way.
	_ = cur
	// Just call FlipCurrent on the previous version's distribution.
	// FlipCurrent moves what's at current → previous, then points
	// current to the new target.
	if err := layout.FlipCurrent(prev); err != nil {
		return err
	}
	st.Current = prev
	st.Previous = cur
	if err := layout.Save(st); err != nil {
		return err
	}

	// v1.5: report the new state.  No network on the revert local
	// path itself; this is a best-effort PUT.  Skip if we have no
	// server context (offline revert is legitimate).  When the CLI
	// didn't pass --server, fall back to the URL persisted from the
	// original install in state.json so a plain `ota-agent revert`
	// invocation still reports.
	server := cfg.ServerURL
	if server == "" {
		server = st.ServerURL
	}
	if server != "" && st.BearerToken != "" && st.OS != "" && st.Arch != "" {
		tr := transport.New(server)
		if cfg.Timeout > 0 {
			tr.HTTP.Timeout = cfg.Timeout
		}
		tr.Auth = transport.BearerAuth(st.BearerToken)
		curRID := releaseID(software, st.OS, st.Arch, prev)
		prevRID := releaseID(software, st.OS, st.Arch, cur)
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := tr.ReportClientState(ctx, software, curRID, prevRID, "revert"); err != nil {
			fmt.Fprintf(os.Stderr, "libota: revert state report failed (non-fatal): %v\n", err)
		}
	}
	return nil
}

// Drain is a tiny utility to copy a stream to /dev/null counting
// bytes (used by tests).
func Drain(r io.Reader) (int64, error) { return io.Copy(io.Discard, r) }
