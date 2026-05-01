// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Ogamita Ltd.

// ota-agent is the user-facing CLI of Ogamita Delta OTA.
//
// Phase-0 skeleton: subcommands are declared but not implemented.
package main

import (
	"flag"
	"fmt"
	"os"

	"gitlab.com/ogamita/delta-ota/client/libota"
)

const usage = `ota-agent — Ogamita Delta OTA client

Usage:
  ota-agent install   <name> [--version=X|--latest]
  ota-agent upgrade   <name> [--to=X|--latest]
  ota-agent revert    <name>
  ota-agent list      [--remote|--local]
  ota-agent show      <name>
  ota-agent verify    <name>
  ota-agent prune     <name> [--archive-depth=N]
  ota-agent watch     <name> [--interval=24h]
  ota-agent doctor    [<name> --recover]
  ota-agent licenses
  ota-agent version

Phase-0 skeleton: only 'version' and 'licenses' do anything useful.
`

func main() {
	flag.Usage = func() { fmt.Fprint(os.Stderr, usage) }
	flag.Parse()

	if flag.NArg() == 0 {
		flag.Usage()
		os.Exit(2)
	}

	switch flag.Arg(0) {
	case "version":
		fmt.Printf("ota-agent %s\n", libota.Version)
	case "licenses":
		fmt.Println("Ogamita Delta OTA — AGPL-3.0-or-later")
		fmt.Println("Copyright (C) 2026 Ogamita Ltd.")
		fmt.Println("See docs/THIRD_PARTY_LICENSES.org for vendored components.")
	case "install", "upgrade", "revert", "list", "show", "verify", "prune", "watch", "doctor":
		fmt.Fprintf(os.Stderr, "ota-agent: %q not implemented yet (phase 0 skeleton)\n", flag.Arg(0))
		os.Exit(1)
	default:
		flag.Usage()
		os.Exit(2)
	}
}
