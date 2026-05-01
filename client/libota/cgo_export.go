// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Ogamita Ltd.
//
// C ABI surface, exported when building with -buildmode=c-shared
// or -buildmode=c-archive. The generated header (libota.h) is the
// canonical contract for non-Go hosts (Python ctypes, .NET P/Invoke,
// AutoLISP via ota-agent shell-out, Common Lisp cffi).
//
// Phase-0 skeleton.

//go:build cgo

package libota

import "C"

//export ota_install
func ota_install(name *C.char, version *C.char) C.int {
	if err := Install(C.GoString(name), C.GoString(version)); err != nil {
		return -1
	}
	return 0
}

//export ota_upgrade
func ota_upgrade(name *C.char, version *C.char) C.int {
	if err := Upgrade(C.GoString(name), C.GoString(version)); err != nil {
		return -1
	}
	return 0
}

//export ota_revert
func ota_revert(name *C.char) C.int {
	if err := Revert(C.GoString(name)); err != nil {
		return -1
	}
	return 0
}
