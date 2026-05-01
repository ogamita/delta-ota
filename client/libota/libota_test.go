// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Ogamita Ltd.

package libota

import (
	"context"
	"testing"
)

func TestInstallRejectsEmptyServerURL(t *testing.T) {
	if _, err := Install(context.Background(), Config{}, "hello", "1.0.0"); err == nil {
		t.Fatal("expected error for empty ServerURL")
	}
}
