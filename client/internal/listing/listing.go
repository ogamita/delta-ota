// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Ogamita Ltd.

// Package listing collects the data displayed by `ota-agent list`,
// `ota-agent show`, and `ota-agent prune`.  Pure-data structures and
// I/O helpers; no presentation logic (the CLI commands format the
// output themselves).
package listing

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"gitlab.com/ogamita/delta-ota/client/internal/state"
	"gitlab.com/ogamita/delta-ota/client/internal/transport"
)

// LocalEntry summarises one software directory under $OTA_HOME.
type LocalEntry struct {
	Software       string
	Current        string    // active version, "" if none
	Previous       string    // one-step revert target, "" if none
	ServerURL      string    // from state.json
	UpdatedAt      time.Time // from state.json
	Distributions  []string  // every distribution-* directory found, sorted desc by mtime
	HistoryLength  int       // len(state.History)
	OnDiskBytes    int64     // total bytes under the software root
}

// ListLocal walks otaHome (one subdirectory per software product) and
// returns one LocalEntry per child directory.  Directories without a
// readable state.json are skipped silently — those aren't ours.
func ListLocal(otaHome string) ([]LocalEntry, error) {
	entries, err := os.ReadDir(otaHome)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("listing: read %s: %w", otaHome, err)
	}
	out := make([]LocalEntry, 0, len(entries))
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		entry, ok := loadOne(otaHome, e.Name())
		if !ok {
			continue
		}
		out = append(out, entry)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Software < out[j].Software })
	return out, nil
}

// LoadLocal returns a single LocalEntry for one software, or
// fs.ErrNotExist if there is no installation under otaHome/<software>.
func LoadLocal(otaHome, software string) (*LocalEntry, error) {
	entry, ok := loadOne(otaHome, software)
	if !ok {
		return nil, fs.ErrNotExist
	}
	return &entry, nil
}

func loadOne(otaHome, software string) (LocalEntry, bool) {
	layout := state.New(otaHome, software)
	st, err := layout.Load()
	// Layout.Load returns &State{} on missing-file; treat that as
	// "not one of ours" only when the directory itself is empty of
	// any of our markers.
	if err != nil {
		return LocalEntry{}, false
	}
	if st.Software == "" && !hasOurMarkers(layout.Root) {
		return LocalEntry{}, false
	}
	dists := scanDistributions(layout.Root)
	bytes := totalBytes(layout.Root)
	return LocalEntry{
		Software:      software,
		Current:       st.Current,
		Previous:      st.Previous,
		ServerURL:     st.ServerURL,
		UpdatedAt:     st.UpdatedAt,
		Distributions: dists,
		HistoryLength: len(st.History),
		OnDiskBytes:   bytes,
	}, true
}

// hasOurMarkers checks that the directory looks like an OTA install
// even when state.json is missing or empty -- i.e. it has at least
// one distribution-* subdir or the current/blobs/patches scaffolding.
func hasOurMarkers(root string) bool {
	for _, m := range []string{"current", "blobs", "patches", "state.json"} {
		if _, err := os.Lstat(filepath.Join(root, m)); err == nil {
			return true
		}
	}
	if dists := scanDistributions(root); len(dists) > 0 {
		return true
	}
	return false
}

// scanDistributions returns the names of every distribution-* directory
// under root, sorted *descending* by mtime (newest first).
func scanDistributions(root string) []string {
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil
	}
	type item struct {
		name  string
		mtime time.Time
	}
	var items []item
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		if !strings.HasPrefix(e.Name(), "distribution-") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		items = append(items, item{name: e.Name(), mtime: info.ModTime()})
	}
	sort.Slice(items, func(i, j int) bool { return items[i].mtime.After(items[j].mtime) })
	out := make([]string, len(items))
	for i, it := range items {
		out[i] = it.name
	}
	return out
}

// totalBytes is filepath.Walk + sum of file sizes; symlinks are
// followed-Lstat'd (not target-followed) so a current -> distribution
// symlink doesn't double-count.
func totalBytes(root string) int64 {
	var total int64
	_ = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil // skip unreadable; we only want a best-effort total
		}
		if d.Type()&fs.ModeSymlink != 0 {
			return nil
		}
		info, ierr := d.Info()
		if ierr != nil {
			return nil
		}
		if !info.IsDir() {
			total += info.Size()
		}
		return nil
	})
	return total
}

// RemoteSoftware summarises one row of GET /v1/software with the
// latest release's version filled in.  Used by
// `ota-agent list --remote --latest`.
type RemoteSoftware struct {
	Name          string
	DisplayName   string
	CreatedAt     string
	LatestVersion string // "" if no release published yet
	LatestErr     error  // populated when the per-software latest fetch failed
}

// RemoteRelease is one row of GET /v1/software/<sw>/releases — every
// version of every software product on the server.  Used by
// `ota-agent list --remote` (the default flatter view, one row per
// release).
type RemoteRelease struct {
	Software      string
	Version       string
	OS            string
	Arch          string
	BlobSize      int64
	PublishedAt   string
	Deprecated    bool
	Uncollectable bool
}

// ListRemoteSoftware calls GET /v1/software, then for each entry
// calls /releases/latest to fill in LatestVersion.  Per-software
// fetch failures don't fail the whole listing -- they're surfaced
// via LatestErr on the affected row.
func ListRemoteSoftware(ctx context.Context, tr *transport.Client) ([]RemoteSoftware, error) {
	sws, err := tr.ListSoftware(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]RemoteSoftware, 0, len(sws))
	for _, sw := range sws {
		re := RemoteSoftware{
			Name:        sw.Name,
			DisplayName: sw.DisplayName,
			CreatedAt:   sw.CreatedAt,
		}
		if data, err := tr.LatestRelease(ctx, sw.Name); err != nil {
			re.LatestErr = err
		} else {
			var rel struct {
				Version string `json:"version"`
			}
			if jerr := json.Unmarshal(data, &rel); jerr != nil {
				re.LatestErr = jerr
			} else {
				re.LatestVersion = rel.Version
			}
		}
		out = append(out, re)
	}
	return out, nil
}

// ListRemoteReleases calls GET /v1/software, then for each software
// calls /releases (the full per-software release list).  Returns one
// row per (software, version) pair, sorted by software then by
// published_at (newest first).
func ListRemoteReleases(ctx context.Context, tr *transport.Client) ([]RemoteRelease, error) {
	sws, err := tr.ListSoftware(ctx)
	if err != nil {
		return nil, err
	}
	var out []RemoteRelease
	for _, sw := range sws {
		rels, err := tr.ListReleases(ctx, sw.Name)
		if err != nil {
			// Soft-fail: skip this software, surface in subsequent
			// rows as a single placeholder entry so the operator
			// sees the gap.
			out = append(out, RemoteRelease{
				Software: sw.Name,
				Version:  "(error: " + err.Error() + ")",
			})
			continue
		}
		for _, r := range rels {
			out = append(out, RemoteRelease{
				Software:      r.Software,
				Version:       r.Version,
				OS:            r.OS,
				Arch:          r.Arch,
				BlobSize:      r.BlobSize,
				PublishedAt:   r.PublishedAt,
				Deprecated:    r.Deprecated,
				Uncollectable: r.Uncollectable,
			})
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Software != out[j].Software {
			return out[i].Software < out[j].Software
		}
		// Within one software, newest publish first (server already
		// returned in this order; sort here for stability).
		return out[i].PublishedAt > out[j].PublishedAt
	})
	return out, nil
}

// PruneCandidates returns the names of distribution-* directories that
// are safe to delete given the keep-list (current, previous, plus
// archiveDepth most recent extras).  Order: oldest-first so the caller
// can stop early on disk-space targets.
func PruneCandidates(otaHome, software string, archiveDepth int) ([]string, error) {
	layout := state.New(otaHome, software)
	st, err := layout.Load()
	if err != nil {
		return nil, fmt.Errorf("prune: read state for %s: %w", software, err)
	}
	dists := scanDistributions(layout.Root) // newest first
	keep := make(map[string]bool)
	if st.Current != "" {
		keep["distribution-"+st.Current] = true
	}
	if st.Previous != "" {
		keep["distribution-"+st.Previous] = true
	}
	// Walk the most-recent N (excluding already-kept) into keep.
	added := 0
	for _, d := range dists {
		if added >= archiveDepth {
			break
		}
		if keep[d] {
			continue
		}
		keep[d] = true
		added++
	}
	// Everything not in keep is a prune candidate.  Reverse so the
	// candidates come out oldest-first (matches scanDistributions's
	// newest-first output -- iterate in reverse).
	var candidates []string
	for i := len(dists) - 1; i >= 0; i-- {
		if !keep[dists[i]] {
			candidates = append(candidates, dists[i])
		}
	}
	return candidates, nil
}

// DeleteDistribution removes one distribution-* subtree from a
// software's root.  Refuses to touch anything that isn't a
// distribution-* name (defence in depth).
func DeleteDistribution(otaHome, software, distributionName string) error {
	if !strings.HasPrefix(distributionName, "distribution-") {
		return fmt.Errorf("prune: refusing to delete non-distribution dir %q", distributionName)
	}
	layout := state.New(otaHome, software)
	target := filepath.Join(layout.Root, distributionName)
	return os.RemoveAll(target)
}
