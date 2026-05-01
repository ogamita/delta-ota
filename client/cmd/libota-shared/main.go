// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Ogamita Ltd.
//
// libota-shared is the C-ABI build of libota. Build it with
//   go build -buildmode=c-shared -o libota.{so,dylib,dll} ./cmd/libota-shared
// or (for static linking into another C binary):
//   go build -buildmode=c-archive -o libota.a ./cmd/libota-shared
//
// The generated header (libota.h) is the canonical C contract for
// embedding libota into non-Go applications (Python via ctypes,
// .NET via P/Invoke, AutoLISP via shell-out to ota-agent).

package main

import "C"

import (
	"context"
	"encoding/json"
	"sync"
	"time"

	"gitlab.com/ogamita/delta-ota/client/libota"
)

// main is required by go's c-shared build mode but is never called
// from C. It exits immediately if invoked as a Go program.
func main() {}

var (
	lastErrMu sync.Mutex
	lastErr   string
)

func setLastError(err error) {
	lastErrMu.Lock()
	defer lastErrMu.Unlock()
	if err == nil {
		lastErr = ""
	} else {
		lastErr = err.Error()
	}
}

//export ota_last_error
func ota_last_error() *C.char {
	lastErrMu.Lock()
	defer lastErrMu.Unlock()
	return C.CString(lastErr)
}

//export ota_version
func ota_version() *C.char {
	return C.CString(libota.Version)
}

//export ota_install
//   cfgJSON  — JSON-encoded libota.Config (server_url, ota_home, ...)
//   name     — software name
//   version  — version or "" / "latest"
// Returns 0 on success, -1 on failure (call ota_last_error for detail).
func ota_install(cfgJSON, name, version *C.char) C.int {
	cfg := decodeCfg(cfgJSON)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()
	if _, err := libota.Install(ctx, cfg, C.GoString(name), C.GoString(version)); err != nil {
		setLastError(err)
		return -1
	}
	setLastError(nil)
	return 0
}

//export ota_upgrade
func ota_upgrade(cfgJSON, name, version *C.char) C.int {
	cfg := decodeCfg(cfgJSON)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()
	if _, err := libota.Upgrade(ctx, cfg, C.GoString(name), C.GoString(version)); err != nil {
		setLastError(err)
		return -1
	}
	setLastError(nil)
	return 0
}

//export ota_revert
func ota_revert(cfgJSON, name *C.char) C.int {
	cfg := decodeCfg(cfgJSON)
	if err := libota.Revert(cfg, C.GoString(name)); err != nil {
		setLastError(err)
		return -1
	}
	setLastError(nil)
	return 0
}

func decodeCfg(s *C.char) libota.Config {
	var c libota.Config
	if s == nil {
		return c
	}
	_ = json.Unmarshal([]byte(C.GoString(s)), &c)
	return c
}
