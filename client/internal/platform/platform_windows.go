// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Ogamita Ltd.

//go:build windows

package platform

import "strings"

// LongPath prefixes p with `\\?\` so that the Win32 file APIs allow
// paths longer than MAX_PATH (260). Idempotent. Only applies to
// already-absolute paths; UNC paths and already-prefixed paths are
// returned unchanged.
func LongPath(p string) string {
	if strings.HasPrefix(p, `\\?\`) || strings.HasPrefix(p, `\\.\`) {
		return p
	}
	if strings.HasPrefix(p, `\\`) {
		// UNC: \\server\share\... → \\?\UNC\server\share\...
		return `\\?\UNC\` + strings.TrimPrefix(p, `\\`)
	}
	if len(p) >= 2 && p[1] == ':' {
		// Drive-letter absolute: C:\... → \\?\C:\...
		return `\\?\` + p
	}
	return p
}

func isCaseInsensitiveFS() bool { return true }
