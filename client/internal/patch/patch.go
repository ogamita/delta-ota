// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Ogamita Ltd.

// Package patch applies binary deltas (bsdiff-format only in v1) in
// process. The encoder lives on the server; this package is the
// decoder side for the client.
package patch

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"

	"github.com/gabstv/go-bsdiff/pkg/bspatch"
)

// Apply reads the old blob and the patch file, runs bspatch in
// memory, writes the result to dstPath, and verifies the result's
// sha256 against expectedSHA256 (hex). On mismatch the destination
// is removed.
func Apply(oldBlobPath, patchPath, dstPath, expectedSHA256, patcher string) (int64, error) {
	if patcher != "bsdiff" {
		return 0, fmt.Errorf("patch: unsupported patcher %q (only bsdiff in v1)", patcher)
	}
	old, err := os.ReadFile(oldBlobPath)
	if err != nil {
		return 0, fmt.Errorf("patch: read old: %w", err)
	}
	pt, err := os.ReadFile(patchPath)
	if err != nil {
		return 0, fmt.Errorf("patch: read patch: %w", err)
	}
	out, err := bspatch.Bytes(old, pt)
	if err != nil {
		return 0, fmt.Errorf("patch: bspatch: %w", err)
	}
	got := sha256.Sum256(out)
	if hex.EncodeToString(got[:]) != expectedSHA256 {
		return 0, fmt.Errorf("patch: result sha mismatch (want %s)", expectedSHA256)
	}
	tmp := dstPath + ".part"
	if err := os.WriteFile(tmp, out, 0o644); err != nil {
		return 0, fmt.Errorf("patch: write: %w", err)
	}
	if err := os.Rename(tmp, dstPath); err != nil {
		_ = os.Remove(tmp)
		return 0, fmt.Errorf("patch: rename: %w", err)
	}
	return int64(len(out)), nil
}
