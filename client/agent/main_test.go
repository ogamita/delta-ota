// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Ogamita Ltd.

package main

import "testing"

func TestUsageMentionsAllSubcommands(t *testing.T) {
	for _, sub := range []string{"install", "upgrade", "revert", "list", "show", "verify", "prune", "watch", "doctor"} {
		if !contains(usage, sub) {
			t.Errorf("usage text missing subcommand %q", sub)
		}
	}
}

func contains(haystack, needle string) bool {
	for i := 0; i+len(needle) <= len(haystack); i++ {
		if haystack[i:i+len(needle)] == needle {
			return true
		}
	}
	return false
}
