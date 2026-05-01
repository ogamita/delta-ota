// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Ogamita Ltd.
//
// C ABI surface, exported when building with -buildmode=c-shared
// or -buildmode=c-archive. Phase-1 minimum: install/upgrade/revert
// via a JSON-encoded Config.

//go:build cgo

package libota

import (
	"context"
	"encoding/json"
)

import "C"

func cfgFromJSON(s *C.char) Config {
	var c Config
	if s == nil {
		return c
	}
	_ = json.Unmarshal([]byte(C.GoString(s)), &c)
	return c
}

//export ota_install
func ota_install(cfgJSON *C.char, name *C.char, version *C.char) C.int {
	cfg := cfgFromJSON(cfgJSON)
	if _, err := Install(context.Background(), cfg, C.GoString(name), C.GoString(version)); err != nil {
		return -1
	}
	return 0
}

//export ota_upgrade
func ota_upgrade(cfgJSON *C.char, name *C.char, version *C.char) C.int {
	cfg := cfgFromJSON(cfgJSON)
	if _, err := Upgrade(context.Background(), cfg, C.GoString(name), C.GoString(version)); err != nil {
		return -1
	}
	return 0
}

//export ota_revert
func ota_revert(cfgJSON *C.char, name *C.char) C.int {
	cfg := cfgFromJSON(cfgJSON)
	if err := Revert(cfg, C.GoString(name)); err != nil {
		return -1
	}
	return 0
}
