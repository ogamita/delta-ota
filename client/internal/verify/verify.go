// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Ogamita Ltd.

// Package verify implements `ota-agent verify <name>`: checks an
// installed software's on-disk integrity in two phases.
//
//	Offline phase — present even with no network:
//	  - state.json exists and parses;
//	  - state.json names a Current version;
//	  - the current symlink/shim resolves to a directory;
//	  - the distribution-<current> directory exists and is
//	    non-empty.
//
//	Online phase — opt-in (default ON, --offline skips it):
//	  - fetch the signed manifest for the current version from the
//	    server, verify the Ed25519 signature against the trusted
//	    pubkey set;
//	  - if the saved blob is on disk
//	    ($OTA_HOME/<sw>/blobs/<current>.blob), compute its
//	    SHA-256 and compare against the manifest's blob.sha256.
//
// The result is a Report aggregating all findings; the CLI command
// formats it for the human.
package verify

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"

	"gitlab.com/ogamita/delta-ota/client/internal/manifest"
	"gitlab.com/ogamita/delta-ota/client/internal/state"
	"gitlab.com/ogamita/delta-ota/client/internal/transport"
)

// Check is one finding (one line of `ota-agent verify` output).
type Check struct {
	Name   string // short label, e.g. "state.json", "blob sha256"
	OK     bool
	Detail string // human-readable extra context
}

// Report is the full set of checks for one verify invocation.
type Report struct {
	Software string
	Version  string // current version per state, "" if none
	Checks   []Check
}

// AllOK returns true when every check passed.
func (r *Report) AllOK() bool {
	for _, c := range r.Checks {
		if !c.OK {
			return false
		}
	}
	return true
}

// VerifyOptions selects which phases run.
type VerifyOptions struct {
	Offline   bool                // true: skip the network phase
	Server    string              // server URL for the online phase
	Trusted   []string            // trusted pubkeys (hex); ignored when empty
	Transport *transport.Client   // injectable for tests; built from Server when nil
	Context   context.Context     // for the network phase; defaults to context.Background()
}

// Verify runs the offline checks and (unless opt.Offline) the online
// checks for SOFTWARE under OTAHOME.  Returns a Report whose Checks
// reflect every finding; AllOK() summarises the result.
func Verify(otaHome, software string, opt VerifyOptions) (*Report, error) {
	r := &Report{Software: software}
	layout := state.New(otaHome, software)

	// --- Offline phase --------------------------------------------------
	st, sterr := layout.Load()
	if sterr != nil {
		r.Checks = append(r.Checks, Check{Name: "state.json", OK: false,
			Detail: sterr.Error()})
		return r, nil
	}
	r.Checks = append(r.Checks, Check{Name: "state.json", OK: true,
		Detail: layout.StateFile})

	if st.Current == "" {
		r.Checks = append(r.Checks, Check{Name: "current version", OK: false,
			Detail: "state.json names no current version (never installed?)"})
		return r, nil
	}
	r.Version = st.Current
	r.Checks = append(r.Checks, Check{Name: "current version", OK: true,
		Detail: st.Current})

	target, terr := layout.CurrentTarget()
	switch {
	case errors.Is(terr, fs.ErrNotExist):
		r.Checks = append(r.Checks, Check{Name: "current link", OK: false,
			Detail: "no current symlink/shim at " + layout.CurrentSymlink})
	case terr != nil:
		r.Checks = append(r.Checks, Check{Name: "current link", OK: false,
			Detail: terr.Error()})
	default:
		r.Checks = append(r.Checks, Check{Name: "current link", OK: true,
			Detail: target})
	}

	distroDir := layout.DistributionDir(st.Current)
	if info, err := os.Stat(distroDir); err != nil {
		r.Checks = append(r.Checks, Check{Name: "distribution dir", OK: false,
			Detail: err.Error()})
	} else if !info.IsDir() {
		r.Checks = append(r.Checks, Check{Name: "distribution dir", OK: false,
			Detail: distroDir + " is not a directory"})
	} else {
		// Walk to count files / total bytes -- a bare existence check
		// would miss "directory exists but is empty".
		var nFiles int
		var nBytes int64
		_ = walkSize(distroDir, &nFiles, &nBytes)
		ok := nFiles > 0
		detail := fmt.Sprintf("%s (%d file(s), %d bytes)", distroDir, nFiles, nBytes)
		if !ok {
			detail += " — empty"
		}
		r.Checks = append(r.Checks, Check{Name: "distribution dir", OK: ok,
			Detail: detail})
	}

	// --- Online phase ---------------------------------------------------
	if opt.Offline {
		return r, nil
	}
	if opt.Server == "" {
		r.Checks = append(r.Checks, Check{Name: "manifest", OK: false,
			Detail: "--server / OTA_SERVER not set; cannot fetch manifest (use --offline to skip)"})
		return r, nil
	}
	tr := opt.Transport
	if tr == nil {
		tr = transport.New(opt.Server)
	}
	ctx := opt.Context
	if ctx == nil {
		ctx = context.Background()
	}
	mdata, sigHex, pubHex, merr := tr.GetManifest(ctx, software, st.Current)
	if merr != nil {
		r.Checks = append(r.Checks, Check{Name: "manifest fetch", OK: false,
			Detail: merr.Error()})
		return r, nil
	}
	r.Checks = append(r.Checks, Check{Name: "manifest fetch", OK: true,
		Detail: fmt.Sprintf("%d bytes from %s", len(mdata), opt.Server)})

	if verr := manifest.Verify(mdata, sigHex, pubHex); verr != nil {
		r.Checks = append(r.Checks, Check{Name: "manifest signature", OK: false,
			Detail: verr.Error()})
		return r, nil
	}
	r.Checks = append(r.Checks, Check{Name: "manifest signature", OK: true,
		Detail: "Ed25519 OK; pubkey " + short(pubHex)})

	if len(opt.Trusted) > 0 {
		trusted := false
		for _, t := range opt.Trusted {
			if t == pubHex {
				trusted = true
				break
			}
		}
		if !trusted {
			r.Checks = append(r.Checks, Check{Name: "pubkey trusted", OK: false,
				Detail: fmt.Sprintf("server pubkey %s not in trusted set", short(pubHex))})
			return r, nil
		}
		r.Checks = append(r.Checks, Check{Name: "pubkey trusted", OK: true,
			Detail: short(pubHex)})
	}

	m, perr := manifest.Parse(mdata)
	if perr != nil {
		r.Checks = append(r.Checks, Check{Name: "manifest parse", OK: false,
			Detail: perr.Error()})
		return r, nil
	}

	// Saved blob (if still on disk) → recompute SHA-256, compare.
	blobPath := layout.BlobPath(st.Current)
	if _, err := os.Stat(blobPath); errors.Is(err, fs.ErrNotExist) {
		r.Checks = append(r.Checks, Check{Name: "blob on disk", OK: true,
			Detail: "absent (likely pruned); skipping hash check"})
	} else if err != nil {
		r.Checks = append(r.Checks, Check{Name: "blob on disk", OK: false,
			Detail: err.Error()})
	} else {
		got, herr := sha256File(blobPath)
		if herr != nil {
			r.Checks = append(r.Checks, Check{Name: "blob sha256", OK: false,
				Detail: herr.Error()})
		} else if got != m.Blob.SHA256 {
			r.Checks = append(r.Checks, Check{Name: "blob sha256", OK: false,
				Detail: fmt.Sprintf("on-disk %s vs manifest %s", short(got), short(m.Blob.SHA256))})
		} else {
			r.Checks = append(r.Checks, Check{Name: "blob sha256", OK: true,
				Detail: short(got)})
		}
	}

	return r, nil
}

func walkSize(root string, nFiles *int, nBytes *int64) error {
	return walkDir(root, func(p string, info os.FileInfo) {
		if info.Mode().IsRegular() {
			*nFiles++
			*nBytes += info.Size()
		}
	})
}

// walkDir is a tiny WalkDir wrapper that ignores errors (we want a
// best-effort total) and calls fn with the path + os.FileInfo.
func walkDir(root string, fn func(string, os.FileInfo)) error {
	entries, err := os.ReadDir(root)
	if err != nil {
		return err
	}
	for _, e := range entries {
		p := root + string(os.PathSeparator) + e.Name()
		info, ierr := e.Info()
		if ierr != nil {
			continue
		}
		fn(p, info)
		if e.IsDir() {
			_ = walkDir(p, fn)
		}
	}
	return nil
}

func sha256File(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func short(hex string) string {
	if len(hex) <= 16 {
		return hex
	}
	return hex[:8] + "…" + hex[len(hex)-8:]
}
