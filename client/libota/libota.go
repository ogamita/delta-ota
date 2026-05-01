// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Ogamita Ltd.

// Package libota is the embeddable client library of Ogamita Delta OTA.
//
// It is built as both a c-shared library (DLL/dylib/so) and a c-archive
// (static .a) for embedding into host applications. A pure-Go API also
// exists for Go consumers.
//
// Phase-0 skeleton: the public surface from the spec is declared but
// every entry point is a stub. Real implementations land starting in
// phase 1.
package libota

import "errors"

// Version follows the project version, set at link time when relevant.
const Version = "0.1.0-dev"

// ErrNotImplemented is returned by every phase-0 stub.
var ErrNotImplemented = errors.New("libota: not implemented yet (phase 0 skeleton)")

// Install installs the named software at the given version (or "latest").
func Install(name, version string) error {
	_ = name
	_ = version
	return ErrNotImplemented
}

// Upgrade upgrades the named software to the given version (or "latest").
func Upgrade(name, version string) error {
	_ = name
	_ = version
	return ErrNotImplemented
}

// Revert flips current/previous symlinks atomically.
func Revert(name string) error {
	_ = name
	return ErrNotImplemented
}

// CurrentRelease returns the version of the currently active install.
func CurrentRelease(name string) (string, error) {
	_ = name
	return "", ErrNotImplemented
}
