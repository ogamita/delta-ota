# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Ogamita Ltd.
#
# Top-level Makefile for delta-ota.
# Phase-0 targets only — later phases extend this.

.POSIX:
.SUFFIXES:

SHELL := /bin/sh

# Tool overrides (defaults are sane).
SBCL    ?= sbcl
GO      ?= go
DOCKER  ?= docker

GOFLAGS ?= -trimpath -tags=netgo,osusergo
export CGO_ENABLED ?= 0

BUILD_DIR        := build
SERVER_BUILD_DIR := server/build
ADMIN_BUILD_DIR  := admin/build
CLIENT_BUILD_DIR := client/build

GOOS   ?= $(shell $(GO) env GOOS)
GOARCH ?= $(shell $(GO) env GOARCH)

.PHONY: all help setup build test \
        vendor-verify vendor-build \
        build-server build-admin build-client build-libota \
        lisp-check go-lint go-test \
        test-unit e2e \
        run-server \
        clean

all: build

help:
	@echo "delta-ota — common targets"
	@echo "  make setup           verify toolchain"
	@echo "  make vendor-verify   re-hash vendored sources, fail on mismatch"
	@echo "  make vendor-build    build vendored C helpers (bsdiff, xdelta3)"
	@echo "  make build           build server, admin, libota, ota-agent"
	@echo "  make build-server    build the SBCL server core"
	@echo "  make build-admin     build the SBCL admin CLI"
	@echo "  make build-client    build libota + ota-agent for GOOS/GOARCH"
	@echo "  make test            unit tests (server + client)"
	@echo "  make test-unit       same as test"
	@echo "  make e2e             docker-compose end-to-end test"
	@echo "  make run-server      start ota-server locally"
	@echo "  make clean           remove build artefacts"

setup:
	@command -v $(SBCL) >/dev/null || { echo "sbcl not found" >&2; exit 1; }
	@command -v $(GO)   >/dev/null || { echo "go not found"   >&2; exit 1; }
	@$(SBCL) --version
	@$(GO) version
	@echo "setup: ok"

# ---------- vendoring ----------
vendor-verify:
	tools/vendor-verify.sh

vendor-build: $(SERVER_BUILD_DIR)/bin/bsdiff
	$(MAKE) -f tools/vendor-build/mendsley-bsdiff.mk all

# Server's patch worker uses the gabstv-go-bsdiff library via a
# first-party CLI wrapper.  This guarantees byte-for-byte format
# compatibility with the in-process bspatch on the Go client (both
# emit/consume BSDIFF40+bzip2).  The mendsley C build is kept for
# future reference and is invoked by the legacy target above.
$(SERVER_BUILD_DIR)/bin/bsdiff:
	@mkdir -p $(SERVER_BUILD_DIR)/bin
	cd client && CGO_ENABLED=0 $(GO) build $(GOFLAGS) \
	    -o ../$(SERVER_BUILD_DIR)/bin/bsdiff ./cmd/bsdiff

# ---------- build ----------
build: build-server build-admin build-client

build-server:
	@mkdir -p $(SERVER_BUILD_DIR)
	$(SBCL) --non-interactive --no-userinit --no-sysinit \
	    --load server/build.lisp

build-admin:
	@mkdir -p $(ADMIN_BUILD_DIR)
	$(SBCL) --non-interactive --no-userinit --no-sysinit \
	    --load admin/build.lisp

build-client: build-libota build-agent

# libota's C ABI is only producible with cgo enabled (and a C
# compiler that targets GOOS/GOARCH).  The pure-Go ota-agent build
# above remains cgo-free; only this target needs cgo.
LIBOTA_EXT := $(if $(filter windows,$(GOOS)),dll,$(if $(filter darwin,$(GOOS)),dylib,so))

build-libota:
	@mkdir -p $(CLIENT_BUILD_DIR)/$(GOOS)-$(GOARCH)
	cd client && GOOS=$(GOOS) GOARCH=$(GOARCH) CGO_ENABLED=1 \
	    $(GO) build -trimpath -buildmode=c-shared \
	        -o ../$(CLIENT_BUILD_DIR)/$(GOOS)-$(GOARCH)/libota.$(LIBOTA_EXT) \
	        ./cmd/libota-shared
	cd client && GOOS=$(GOOS) GOARCH=$(GOARCH) CGO_ENABLED=1 \
	    $(GO) build -trimpath -buildmode=c-archive \
	        -o ../$(CLIENT_BUILD_DIR)/$(GOOS)-$(GOARCH)/libota.a \
	        ./cmd/libota-shared

build-agent:
	@mkdir -p $(CLIENT_BUILD_DIR)/$(GOOS)-$(GOARCH)
	cd client && GOOS=$(GOOS) GOARCH=$(GOARCH) \
	    $(GO) build $(GOFLAGS) \
	        -o ../$(CLIENT_BUILD_DIR)/$(GOOS)-$(GOARCH)/ota-agent$(if $(filter windows,$(GOOS)),.exe,) \
	        ./agent

# ---------- lint / test ----------
lisp-check:
	$(SBCL) --non-interactive --no-userinit --no-sysinit \
	    --load $(QUICKLISP_SETUP) \
	    --eval '(asdf:load-asd (truename "server/ota-server.asd"))' \
	    --eval '(asdf:load-asd (truename "admin/ota-admin.asd"))' \
	    --eval '(ql:quickload "ota-server" :silent t)' \
	    --eval '(ql:quickload "ota-admin"  :silent t)' \
	    --eval '(format t "lisp-check: 2 systems load OK~%")'

QUICKLISP_SETUP ?= $(shell test -f $(HOME)/quicklisp/setup.lisp && echo $(HOME)/quicklisp/setup.lisp || echo /opt/quicklisp/setup.lisp)

lisp-test:
	$(SBCL) --non-interactive --no-userinit --no-sysinit \
	    --load $(QUICKLISP_SETUP) \
	    --eval '(asdf:load-asd (truename "server/ota-server.asd"))' \
	    --eval '(ql:quickload "ota-server/tests" :silent t)' \
	    --eval '(asdf:test-system "ota-server")'

go-lint:
	cd client && $(GO) vet ./...

go-test:
	cd client && $(GO) test ./...

test: test-unit
test-unit: lisp-check lisp-test go-test

# ---------- documentation ----------
# Generate PDFs from .org sources. Two backends:
#   1. emacs --batch (preferred) -- richest org-mode rendering.
#   2. pandoc (fallback) -- works on any host with TeX installed.
# Either tool needs a working TeX (xelatex / pdflatex). On Debian:
#   apt-get install emacs-nox texlive-xetex pandoc
EMACS  ?= emacs
PANDOC ?= pandoc
DOCS_DIR := docs
ORG_FILES := \
    $(DOCS_DIR)/ota-specifications.org           \
    $(DOCS_DIR)/ota-implementation-plan.org      \
    $(DOCS_DIR)/operations.org                   \
    $(DOCS_DIR)/delta-ota-datasheet.org          \
    $(DOCS_DIR)/delta-ota-user-manual.org        \
    $(DOCS_DIR)/dependencies.org                 \
    $(DOCS_DIR)/THIRD_PARTY_LICENSES.org

PDF_OUT := build/docs
PDF_FILES := $(patsubst $(DOCS_DIR)/%.org,$(PDF_OUT)/%.pdf,$(ORG_FILES))

.PHONY: docs docs-pdf docs-clean
docs: docs-pdf
docs-pdf: $(PDF_FILES)
docs-clean:
	rm -rf $(PDF_OUT)

$(PDF_OUT)/%.pdf: $(DOCS_DIR)/%.org
	@mkdir -p $(PDF_OUT)
	@if command -v $(PANDOC) >/dev/null 2>&1 && command -v xelatex >/dev/null 2>&1; then \
	    $(PANDOC) --pdf-engine=xelatex \
	        -V geometry:margin=1in \
	        --toc --number-sections \
	        -o $@ $<; \
	elif command -v $(EMACS) >/dev/null 2>&1; then \
	    $(EMACS) --batch --eval "(progn \
	        (require 'ox-latex) \
	        (find-file \"$<\") \
	        (org-latex-export-to-pdf))" \
	        && mv $(DOCS_DIR)/$*.pdf $@; \
	else \
	    echo "docs: pandoc+xelatex (or emacs+org) required" >&2; \
	    exit 1; \
	fi

e2e: e2e-install e2e-auth e2e-ops
e2e-install:
	tests/e2e/run.sh
e2e-auth:
	tests/e2e/auth.sh
e2e-ops:
	tests/e2e/ops.sh

run-server: build-server
	$(SBCL) --core $(SERVER_BUILD_DIR)/ota-server.core \
	    --eval '(ota-server:main :config "server/etc/ota.dev.toml")'

# ---------- clean ----------
clean:
	rm -rf $(BUILD_DIR) $(SERVER_BUILD_DIR) $(ADMIN_BUILD_DIR) $(CLIENT_BUILD_DIR)
	-find . -name '*.fasl' -delete
