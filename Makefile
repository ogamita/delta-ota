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

vendor-build: $(SERVER_BUILD_DIR)/bin/bsdiff $(SERVER_BUILD_DIR)/bin/xdelta3

$(SERVER_BUILD_DIR)/bin/bsdiff: vendor/mendsley-bsdiff/Makefile
	@mkdir -p $(SERVER_BUILD_DIR)/bin
	$(MAKE) -C vendor/mendsley-bsdiff
	cp vendor/mendsley-bsdiff/build/bsdiff $@
	cp vendor/mendsley-bsdiff/build/bspatch $(SERVER_BUILD_DIR)/bin/bspatch

$(SERVER_BUILD_DIR)/bin/xdelta3: vendor/jmacd-xdelta3/xdelta3/Makefile
	@mkdir -p $(SERVER_BUILD_DIR)/bin
	$(MAKE) -C vendor/jmacd-xdelta3/xdelta3
	cp vendor/jmacd-xdelta3/xdelta3/xdelta3 $@

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

build-libota:
	@mkdir -p $(CLIENT_BUILD_DIR)/$(GOOS)-$(GOARCH)
	cd client && GOOS=$(GOOS) GOARCH=$(GOARCH) \
	    $(GO) build $(GOFLAGS) -buildmode=c-shared \
	        -o ../$(CLIENT_BUILD_DIR)/$(GOOS)-$(GOARCH)/libota.$(if $(filter windows,$(GOOS)),dll,$(if $(filter darwin,$(GOOS)),dylib,so)) \
	        ./libota
	cd client && GOOS=$(GOOS) GOARCH=$(GOARCH) \
	    $(GO) build $(GOFLAGS) -buildmode=c-archive \
	        -o ../$(CLIENT_BUILD_DIR)/$(GOOS)-$(GOARCH)/libota.a \
	        ./libota

build-agent:
	@mkdir -p $(CLIENT_BUILD_DIR)/$(GOOS)-$(GOARCH)
	cd client && GOOS=$(GOOS) GOARCH=$(GOARCH) \
	    $(GO) build $(GOFLAGS) \
	        -o ../$(CLIENT_BUILD_DIR)/$(GOOS)-$(GOARCH)/ota-agent$(if $(filter windows,$(GOOS)),.exe,) \
	        ./agent

# ---------- lint / test ----------
lisp-check:
	$(SBCL) --non-interactive --no-userinit --no-sysinit \
	    --eval '(require :asdf)' \
	    --eval '(asdf:load-asd (truename "server/ota-server.asd"))' \
	    --eval '(asdf:load-asd (truename "admin/ota-admin.asd"))' \
	    --eval '(format t "lisp-check: ~A systems load OK~%" 2)'

go-lint:
	cd client && $(GO) vet ./...

go-test:
	cd client && $(GO) test ./...

test: test-unit
test-unit: lisp-check go-test

e2e:
	tests/e2e/run.sh

run-server: build-server
	$(SBCL) --core $(SERVER_BUILD_DIR)/ota-server.core \
	    --eval '(ota-server:main :config "server/etc/ota.dev.toml")'

# ---------- clean ----------
clean:
	rm -rf $(BUILD_DIR) $(SERVER_BUILD_DIR) $(ADMIN_BUILD_DIR) $(CLIENT_BUILD_DIR)
	-find . -name '*.fasl' -delete
