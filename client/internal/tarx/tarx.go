// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Ogamita Ltd.

// Package tarx is a safe tar extractor.
//
// It refuses entries that escape the destination root via absolute
// paths, "..", or symlinks pointing outside, and rejects names that
// match Windows reserved devices (CON, PRN, ...). Phase-1 supports
// regular files only; directories are created on demand from the
// file paths.
package tarx

import (
	"archive/tar"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

var windowsReserved = map[string]bool{
	"CON": true, "PRN": true, "AUX": true, "NUL": true,
	"COM1": true, "COM2": true, "COM3": true, "COM4": true,
	"COM5": true, "COM6": true, "COM7": true, "COM8": true, "COM9": true,
	"LPT1": true, "LPT2": true, "LPT3": true, "LPT4": true,
	"LPT5": true, "LPT6": true, "LPT7": true, "LPT8": true, "LPT9": true,
}

// Extract reads a tar archive from src and writes its files under
// destRoot. The archive is expected to contain regular files with
// sanitised names. The destination directory must already exist.
func Extract(src io.Reader, destRoot string) error {
	tr := tar.NewReader(src)
	cleanRoot, err := filepath.Abs(destRoot)
	if err != nil {
		return fmt.Errorf("tarx: abs root: %w", err)
	}
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return fmt.Errorf("tarx: read header: %w", err)
		}
		if hdr.Typeflag != tar.TypeReg && hdr.Typeflag != tar.TypeRegA {
			// Phase-1: ignore non-regular entries silently.
			continue
		}
		if err := safeName(hdr.Name); err != nil {
			return fmt.Errorf("tarx: %s: %w", hdr.Name, err)
		}
		out := filepath.Join(cleanRoot, filepath.FromSlash(hdr.Name))
		// Belt and braces: re-check that the resolved path is under root.
		rel, err := filepath.Rel(cleanRoot, out)
		if err != nil || strings.HasPrefix(rel, "..") {
			return fmt.Errorf("tarx: %s: escapes root", hdr.Name)
		}
		if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
			return fmt.Errorf("tarx: mkdir %s: %w", filepath.Dir(out), err)
		}
		mode := os.FileMode(hdr.Mode & 0o777)
		if mode == 0 {
			mode = 0o644
		}
		f, err := os.OpenFile(out, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, mode)
		if err != nil {
			return fmt.Errorf("tarx: create %s: %w", out, err)
		}
		if _, err := io.Copy(f, tr); err != nil {
			f.Close()
			return fmt.Errorf("tarx: copy %s: %w", out, err)
		}
		if err := f.Close(); err != nil {
			return fmt.Errorf("tarx: close %s: %w", out, err)
		}
	}
}

func safeName(name string) error {
	if name == "" {
		return fmt.Errorf("empty name")
	}
	if strings.HasPrefix(name, "/") {
		return fmt.Errorf("absolute path forbidden")
	}
	if strings.Contains(name, "\x00") {
		return fmt.Errorf("NUL in name forbidden")
	}
	cleaned := filepath.ToSlash(filepath.Clean(name))
	if cleaned == ".." || strings.HasPrefix(cleaned, "../") || strings.Contains(cleaned, "/../") {
		return fmt.Errorf("parent traversal forbidden")
	}
	for _, part := range strings.Split(cleaned, "/") {
		base := strings.ToUpper(strings.TrimSuffix(part, filepath.Ext(part)))
		if windowsReserved[base] {
			return fmt.Errorf("windows reserved name: %s", part)
		}
	}
	return nil
}
