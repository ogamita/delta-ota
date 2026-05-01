// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Ogamita Ltd.

// Package state manages on-disk client state for one software
// product: current/previous distributions, the kept blobs, and the
// state.json file.
package state

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"time"
)

// Layout holds the per-software paths.
type Layout struct {
	Root            string // $OTA_HOME/<software>
	StateFile       string
	BlobsDir        string
	PatchesDir      string
	ArchivedDir     string
	CurrentSymlink  string
	PreviousSymlink string
}

func New(otaHome, software string) *Layout {
	root := filepath.Join(otaHome, software)
	return &Layout{
		Root:            root,
		StateFile:       filepath.Join(root, "state.json"),
		BlobsDir:        filepath.Join(root, "blobs"),
		PatchesDir:      filepath.Join(root, "patches"),
		ArchivedDir:     filepath.Join(root, "archived"),
		CurrentSymlink:  filepath.Join(root, "current"),
		PreviousSymlink: filepath.Join(root, "previous"),
	}
}

func (l *Layout) Ensure() error {
	for _, d := range []string{l.Root, l.BlobsDir, l.PatchesDir, l.ArchivedDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return err
		}
	}
	return nil
}

// State is the JSON structure stored at state.json.
type State struct {
	Software       string    `json:"software"`
	Current        string    `json:"current,omitempty"`
	Previous       string    `json:"previous,omitempty"`
	History        []string  `json:"history,omitempty"`
	UpdatedAt      time.Time `json:"updated_at"`
	ServerURL      string    `json:"server_url,omitempty"`
	ServerPubKeyHX string    `json:"server_pubkey_hex,omitempty"`
}

func (l *Layout) Load() (*State, error) {
	data, err := os.ReadFile(l.StateFile)
	if errors.Is(err, fs.ErrNotExist) {
		return &State{}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("state read: %w", err)
	}
	var s State
	if err := json.Unmarshal(data, &s); err != nil {
		return nil, fmt.Errorf("state parse: %w", err)
	}
	return &s, nil
}

func (l *Layout) Save(s *State) error {
	s.UpdatedAt = time.Now().UTC()
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	tmp := l.StateFile + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, l.StateFile)
}

// DistributionDir returns the path of distribution-<version>.
func (l *Layout) DistributionDir(version string) string {
	return filepath.Join(l.Root, "distribution-"+version)
}

// absDistributionDir returns the distribution path resolved to an
// absolute path. Symlink targets must be absolute for the link to
// keep working regardless of the symlink's parent directory cwd.
func (l *Layout) absDistributionDir(version string) string {
	abs, err := filepath.Abs(l.DistributionDir(version))
	if err != nil {
		return l.DistributionDir(version)
	}
	return abs
}

// BlobPath is where a kept reference blob lives on disk.
func (l *Layout) BlobPath(version string) string {
	return filepath.Join(l.BlobsDir, version+".blob")
}

// FlipCurrent atomically swaps the current symlink to point to
// distribution-<version>, and moves the old current into previous.
// If current does not exist, it is simply created.
func (l *Layout) FlipCurrent(version string) error {
	target := l.absDistributionDir(version)
	st, err := os.Lstat(l.CurrentSymlink)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		// Fresh install: just create current.
		return atomicSymlink(target, l.CurrentSymlink)
	case err != nil:
		return fmt.Errorf("state: stat current: %w", err)
	default:
		_ = st
	}
	// Move current → previous (overwriting any old previous).
	_ = os.Remove(l.PreviousSymlink)
	if err := os.Rename(l.CurrentSymlink, l.PreviousSymlink); err != nil {
		return fmt.Errorf("state: rename current->previous: %w", err)
	}
	if err := atomicSymlink(target, l.CurrentSymlink); err != nil {
		// Try to roll back previous → current to keep things sane.
		_ = os.Rename(l.PreviousSymlink, l.CurrentSymlink)
		return err
	}
	return nil
}

func atomicSymlink(target, link string) error {
	tmp := link + ".tmp"
	_ = os.Remove(tmp)
	if err := os.Symlink(target, tmp); err != nil {
		return fmt.Errorf("state: symlink: %w", err)
	}
	return os.Rename(tmp, link)
}
