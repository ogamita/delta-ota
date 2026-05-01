// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Ogamita Ltd.

//go:build !windows

package platform

import "runtime"

// LongPath is a no-op on POSIX.
func LongPath(p string) string { return p }

func isCaseInsensitiveFS() bool {
	// macOS default volumes are case-insensitive (HFS+ / APFS) but
	// can be created case-sensitive. Treat as case-insensitive for
	// safety — the agent's job is to handle both.
	return runtime.GOOS == "darwin"
}
