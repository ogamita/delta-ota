# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Ogamita Ltd.
#
# First-party Makefile that builds bsdiff/bspatch CLI binaries from
# the vendored mendsley/bsdiff sources WITHOUT touching the vendored
# tree. Run from the repo root via the top-level Makefile.

CC      ?= cc
CFLAGS  ?= -O2 -Wall
LDFLAGS ?=
LDLIBS  ?= -lbz2

VSRC  := vendor/mendsley-bsdiff
OUT   := server/build/bin

.PHONY: all clean
all: $(OUT)/bsdiff $(OUT)/bspatch

$(OUT):
	mkdir -p $@

$(OUT)/bsdiff: $(VSRC)/bsdiff.c | $(OUT)
	$(CC) $(CFLAGS) -DBSDIFF_EXECUTABLE -o $@ $< $(LDFLAGS) $(LDLIBS)

$(OUT)/bspatch: $(VSRC)/bspatch.c | $(OUT)
	$(CC) $(CFLAGS) -DBSPATCH_EXECUTABLE -o $@ $< $(LDFLAGS) $(LDLIBS)

clean:
	rm -f $(OUT)/bsdiff $(OUT)/bspatch
