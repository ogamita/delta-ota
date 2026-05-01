// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Ogamita Ltd.
//
// First-party bsdiff CLI built from the vendored gabstv-go-bsdiff
// library. Used by the SBCL server's patch worker. Producing patches
// from the same library that the client decodes guarantees format
// compatibility (BSDIFF40 + dsnet/compress bzip2) — using the
// mendsley C bsdiff binary instead would emit "ENDSLEY/BSDIFF43"
// which the client cannot read.

package main

import (
	"fmt"
	"os"

	"github.com/gabstv/go-bsdiff/pkg/bsdiff"
)

func main() {
	if len(os.Args) != 4 {
		fmt.Fprintf(os.Stderr, "usage: %s oldfile newfile patchfile\n", os.Args[0])
		os.Exit(2)
	}
	if err := bsdiff.File(os.Args[1], os.Args[2], os.Args[3]); err != nil {
		fmt.Fprintf(os.Stderr, "bsdiff: %v\n", err)
		os.Exit(1)
	}
}
