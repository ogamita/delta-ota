// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Ogamita Ltd.

// Package platform abstracts OS-specific bits the client needs:
//   - the "current" link that points at the active distribution;
//   - long-path mangling on Windows;
//   - case-preserving path comparison.
//
// The "current" link is a symlink on POSIX. On Windows, it is also
// a symlink when CreateSymbolicLinkW succeeds (developer mode, or
// admin, or SeCreateSymbolicLinkPrivilege). When that fails, we
// fall back to writing a small text file `current.path` containing
// the absolute path of the active distribution. A launcher shim
// reads `current.path` and re-exec's the binary inside.
package platform

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
)

// shimFile is the on-disk fallback when a symlink cannot be created
// (typically Windows without developer mode). It sits next to the
// `link` path with the same basename + ".path".
const shimSuffix = ".path"

// SetCurrent atomically points `link` at `target`. Tries a real
// symlink first; on failure, writes a `<link>.path` shim file.
// Returns the kind of link actually used so the caller can decide
// whether to invoke the launcher shim.
func SetCurrent(target, link string) (Kind, error) {
	abs, err := filepath.Abs(target)
	if err != nil {
		return KindNone, err
	}

	// Remove any prior link or shim.
	_ = os.Remove(link)
	_ = os.Remove(link + shimSuffix)

	// First attempt: real symlink (atomic via tmp + rename).
	tmp := link + ".tmp"
	_ = os.Remove(tmp)
	if err := os.Symlink(abs, tmp); err == nil {
		if err := os.Rename(tmp, link); err == nil {
			return KindSymlink, nil
		}
		_ = os.Remove(tmp)
	}

	// Fallback: write a path-pointer shim file.
	if err := writeShim(link+shimSuffix, abs); err != nil {
		return KindNone, err
	}
	return KindShim, nil
}

// ReadCurrent returns the path of the active distribution, whether
// it is reached via a symlink or a `<link>.path` shim file. Returns
// fs.ErrNotExist when neither exists.
func ReadCurrent(link string) (string, error) {
	if t, err := os.Readlink(link); err == nil {
		return t, nil
	}
	if data, err := os.ReadFile(link + shimSuffix); err == nil {
		return strings.TrimRight(string(data), "\r\n \t"), nil
	}
	return "", os.ErrNotExist
}

// SwapCurrentToPrevious moves the current link/shim to be the
// previous link/shim, atomically when both ends are the same kind.
// If a previous already exists it is overwritten.
func SwapCurrentToPrevious(currentLink, previousLink string) error {
	// If a real symlink exists at current, rename it. If a shim,
	// rename the .path file. We don't mix kinds across previous and
	// current — whatever was last written wins.
	if _, err := os.Readlink(currentLink); err == nil {
		_ = os.Remove(previousLink)
		_ = os.Remove(previousLink + shimSuffix)
		return os.Rename(currentLink, previousLink)
	}
	currentShim := currentLink + shimSuffix
	if _, err := os.Stat(currentShim); err == nil {
		_ = os.Remove(previousLink)
		_ = os.Remove(previousLink + shimSuffix)
		return os.Rename(currentShim, previousLink+shimSuffix)
	}
	return nil // nothing to swap
}

// Kind identifies how the current link is materialised.
type Kind int

const (
	KindNone Kind = iota
	KindSymlink
	KindShim
)

func (k Kind) String() string {
	switch k {
	case KindSymlink:
		return "symlink"
	case KindShim:
		return "shim"
	default:
		return "none"
	}
}

func writeShim(path, target string) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(target+"\n"), 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

// PathEqual compares two filesystem paths in an OS-appropriate way.
// On Windows and macOS (default APFS/HFS+ case-insensitive) the
// comparison ignores ASCII case; on Linux it is byte-exact.
func PathEqual(a, b string) bool {
	if isCaseInsensitiveFS() {
		return strings.EqualFold(a, b)
	}
	return a == b
}

// ErrNotALink is returned by ReadCurrent when neither a symlink nor
// a shim file exists.
var ErrNotALink = errors.New("platform: link/shim does not exist")
