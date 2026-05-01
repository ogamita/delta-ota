// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Ogamita Ltd.

package libota

import (
	"errors"
	"testing"
)

func TestPhase0StubsReturnNotImplemented(t *testing.T) {
	if err := Install("hello", "1.0.0"); !errors.Is(err, ErrNotImplemented) {
		t.Errorf("Install: want ErrNotImplemented, got %v", err)
	}
	if err := Upgrade("hello", "1.0.0"); !errors.Is(err, ErrNotImplemented) {
		t.Errorf("Upgrade: want ErrNotImplemented, got %v", err)
	}
	if err := Revert("hello"); !errors.Is(err, ErrNotImplemented) {
		t.Errorf("Revert: want ErrNotImplemented, got %v", err)
	}
}
