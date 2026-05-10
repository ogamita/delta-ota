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
DIST_DIR         := build/dist

# Version stamp for distribution tarballs. Override on the command line
# or in CI (GITLAB: CI_COMMIT_TAG; GITHUB: GITHUB_REF_NAME).
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)

GOOS   ?= $(shell $(GO) env GOOS)
GOARCH ?= $(shell $(GO) env GOARCH)

.PHONY: all help setup build test \
        vendor-verify vendor-build \
        build-server build-admin build-client build-libota \
        lisp-check lisp-test lisp-test-admin go-lint go-test \
        test-unit e2e \
        run-server \
        publish mint-tokens \
        dist-server \
        clean

all: build

help:
	@echo "delta-ota — common targets"
	@echo "  make setup           verify toolchain"
	@echo "  make vendor-verify   re-hash vendored sources, fail on mismatch"
	@echo "  make vendor-build    build vendored C helpers (bsdiff, xdelta3)"
	@echo "  make build           build server, admin, libota, ota-agent"
	@echo "  make build-server    build the ota-server executable"
	@echo "  make build-admin     build the ota-admin executable"
	@echo "  make build-client    build libota + ota-agent for GOOS/GOARCH"
	@echo "  make test            unit tests (server + client)"
	@echo "  make test-unit       same as test"
	@echo "  make e2e             docker-compose end-to-end test"
	@echo "  make run-server      start ota-server locally"
	@echo "  make publish         publish a release via ota-admin (DIR=, SOFTWARE=, VERSION=, OS=, ARCH=)"
	@echo "  make mint-tokens     mint install tokens via ota-admin (CSV=, CLASSIFICATIONS=, TTL=, OUTPUT=)"
	@echo "  make dist-server     build delta-ota-server-VERSION.tar.gz (debug/test/eval install)"
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

lisp-test: build-server
	$(SBCL) --non-interactive --no-userinit --no-sysinit \
	    --load $(QUICKLISP_SETUP) \
	    --eval '(asdf:load-asd (truename "server/ota-server.asd"))' \
	    --eval '(ql:quickload "ota-server/tests" :silent t)' \
	    --eval '(asdf:test-system "ota-server")'

# Admin CLI tests are black-box checks against the built executable.
# `build-admin` is a prerequisite so the smoke tests have a binary
# to spawn; without it they are skipped.
lisp-test-admin: build-admin
	$(SBCL) --non-interactive --no-userinit --no-sysinit \
	    --load $(QUICKLISP_SETUP) \
	    --eval '(asdf:load-asd (truename "server/ota-server.asd"))' \
	    --eval '(asdf:load-asd (truename "admin/ota-admin.asd"))' \
	    --eval '(ql:quickload "ota-admin/tests" :silent t)' \
	    --eval '(asdf:test-system "ota-admin")'

go-lint:
	cd client && $(GO) vet ./...

go-test:
	cd client && $(GO) test ./...

# Short fuzz burst suitable for CI: each target gets FUZZTIME
# seconds. Run it longer locally with FUZZTIME=60s make fuzz.
FUZZTIME ?= 5s
fuzz:
	cd client && $(GO) test -run=- -fuzz=FuzzParse    -fuzztime=$(FUZZTIME) ./internal/manifest/
	cd client && $(GO) test -run=- -fuzz=FuzzVerify   -fuzztime=$(FUZZTIME) ./internal/manifest/
	cd client && $(GO) test -run=- -fuzz=FuzzExtract  -fuzztime=$(FUZZTIME) ./internal/tarx/
	cd client && $(GO) test -run=- -fuzz=FuzzSafeName -fuzztime=$(FUZZTIME) ./internal/tarx/
	cd client && $(GO) test -run=- -fuzz=FuzzApply    -fuzztime=$(FUZZTIME) ./internal/patch/

test: test-unit
test-unit: lisp-check lisp-test lisp-test-admin go-test

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
    $(DOCS_DIR)/delta-ota-executive-summary.org  \
    $(DOCS_DIR)/dependencies.org                 \
    $(DOCS_DIR)/THIRD_PARTY_LICENSES.org         \
    $(DOCS_DIR)/perf.org

PDF_OUT := build/docs
PDF_FILES := $(patsubst $(DOCS_DIR)/%.org,$(PDF_OUT)/%.pdf,$(ORG_FILES))

.PHONY: docs docs-pdf docs-clean
docs: docs-pdf
docs-pdf: $(PDF_FILES)
docs-clean:
	rm -rf $(PDF_OUT)
	rm -f server/system-index.txt

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

e2e: e2e-install e2e-auth e2e-ops e2e-recovery e2e-parallel e2e-two-process e2e-resume e2e-admin-identity e2e-client-state e2e-stats e2e-lazy-upgrade
e2e-install:
	tests/e2e/run.sh
e2e-auth:
	tests/e2e/auth.sh
e2e-ops:
	tests/e2e/ops.sh
e2e-recovery:
	tests/e2e/recovery.sh
e2e-parallel:
	tests/e2e/parallel.sh
e2e-two-process:
	tests/e2e/two-process-publish.sh
e2e-resume:
	tests/e2e/resume-download.sh
e2e-admin-identity:
	tests/e2e/admin-identity.sh
e2e-client-state:
	tests/e2e/client-state.sh
e2e-stats:
	tests/e2e/stats.sh
e2e-lazy-upgrade:
	tests/e2e/lazy-upgrade.sh

run-server:
	@test -x $(SERVER_BUILD_DIR)/ota-server || $(MAKE) build-server
	$(SERVER_BUILD_DIR)/ota-server serve --config=server/etc/ota.dev.toml

# ---------- ota-admin convenience targets ----------
# Publish a new release. Required: DIR, SOFTWARE, VERSION, OS, ARCH.
# Optional: OS_VERSIONS (comma-separated), CLASSIFICATIONS, SERVER (URL).
# OTA_SERVER and OTA_ADMIN_TOKEN env vars are honoured by the binary.
#
# Example:
#   OTA_ADMIN_TOKEN=dev-token \
#     make publish DIR=./examples/hello SOFTWARE=hello \
#                  VERSION=1.0.0 OS=darwin ARCH=arm64
publish:
	@test -x $(ADMIN_BUILD_DIR)/ota-admin || $(MAKE) build-admin
	@test -n "$(DIR)"      || { echo "publish: DIR=... required"      >&2; exit 2; }
	@test -n "$(SOFTWARE)" || { echo "publish: SOFTWARE=... required" >&2; exit 2; }
	@test -n "$(VERSION)"  || { echo "publish: VERSION=... required"  >&2; exit 2; }
	@test -n "$(OS)"       || { echo "publish: OS=... required"       >&2; exit 2; }
	@test -n "$(ARCH)"     || { echo "publish: ARCH=... required"     >&2; exit 2; }
	$(ADMIN_BUILD_DIR)/ota-admin publish "$(DIR)" \
	    --software=$(SOFTWARE) \
	    --version=$(VERSION) \
	    --os=$(OS) --arch=$(ARCH) \
	    $(if $(OS_VERSIONS),--os-versions=$(OS_VERSIONS),) \
	    $(if $(CLASSIFICATIONS),--classifications=$(CLASSIFICATIONS),) \
	    $(if $(SERVER),--server=$(SERVER),)

# Mint install tokens in bulk from a CSV. Required: CSV.
# Optional: CLASSIFICATIONS (comma-separated), TTL ("7d", "3h"…),
# OUTPUT (default tokens.tsv), SERVER.
#
# Example:
#   OTA_ADMIN_TOKEN=dev-token \
#     make mint-tokens CSV=users.csv CLASSIFICATIONS=stable TTL=7d
mint-tokens:
	@test -x $(ADMIN_BUILD_DIR)/ota-admin || $(MAKE) build-admin
	@test -n "$(CSV)" || { echo "mint-tokens: CSV=... required" >&2; exit 2; }
	$(ADMIN_BUILD_DIR)/ota-admin mint-tokens \
	    --csv="$(CSV)" \
	    $(if $(CLASSIFICATIONS),--classifications=$(CLASSIFICATIONS),) \
	    $(if $(TTL),--ttl=$(TTL),) \
	    $(if $(OUTPUT),--output=$(OUTPUT),) \
	    $(if $(SERVER),--server=$(SERVER),)

# ---------- distribution tarball ----------
# Bundle the standalone ota-server executable, the vendored
# bsdiff/bspatch helpers, the sample config, and the systemd unit
# into a single self-contained tarball:
#   build/dist/delta-ota-server-$(VERSION).tar.gz
#
# Since v1.0.3, ota-server is a real standalone executable that
# dispatches its own subcommands -- there is no entrypoint wrapper
# to ship.  The systemd unit invokes /opt/ota/ota-server serve
# directly.
#
# This artefact exists for evaluation, debugging, and air-gapped
# single-host installs.  Production deployments use the published
# container image (registry.gitlab.com/ogamita/delta-ota/server) --
# the tarball is *not* attached to GitLab/GitHub Releases.
DIST_STAGE := $(DIST_DIR)/delta-ota-server-$(VERSION)

dist-server: build-server vendor-build
	@rm -rf $(DIST_STAGE) $(DIST_DIR)/delta-ota-server-$(VERSION).tar.gz
	@mkdir -p $(DIST_STAGE)/bin $(DIST_STAGE)/etc
	cp $(SERVER_BUILD_DIR)/ota-server        $(DIST_STAGE)/
	cp $(SERVER_BUILD_DIR)/bin/bsdiff        $(DIST_STAGE)/bin/
	cp $(SERVER_BUILD_DIR)/bin/bspatch       $(DIST_STAGE)/bin/
	cp server/etc/ota.toml.sample            $(DIST_STAGE)/etc/
	cp server/etc/ota-server.service         $(DIST_STAGE)/etc/
	cp LICENSE README.md CHANGELOG.md        $(DIST_STAGE)/
	@echo $(VERSION) > $(DIST_STAGE)/VERSION
	tar -C $(DIST_DIR) -czf $(DIST_DIR)/delta-ota-server-$(VERSION).tar.gz \
	    delta-ota-server-$(VERSION)
	@echo "dist-server: wrote $(DIST_DIR)/delta-ota-server-$(VERSION).tar.gz"

# ---------- clean ----------
clean:
	rm -rf $(BUILD_DIR) $(SERVER_BUILD_DIR) $(ADMIN_BUILD_DIR) $(CLIENT_BUILD_DIR) $(DIST_DIR)
	-find . -name '*.fasl' -delete
