#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Ogamita Ltd.
#
# Container entrypoint for ota-server.
#
# Since v1.0.3 the server is a standalone executable that dispatches
# its own subcommands (serve | migrate | gc | shell | version | help)
# and parses --config / env-vars itself.  This wrapper only:
#
#   1. materialises a default config from the baked-in sample if none
#      is mounted at $OTA_CONFIG, and
#   2. exec's the binary with whatever arguments the container was
#      started with -- defaulting to `serve` when none are given.

set -eu

: "${OTA_ROOT:=/var/lib/ota}"
: "${OTA_CONFIG:=/etc/ota/ota.toml}"

if [ ! -f "${OTA_CONFIG}" ]; then
    echo "ota-entrypoint: no config at ${OTA_CONFIG}, copying sample" >&2
    cp /etc/ota/ota.toml.sample "${OTA_CONFIG}"
fi

# When the user passes no arguments, default to `serve --config=$OTA_CONFIG`.
# When they DO pass arguments, honour them verbatim: the binary's own
# subcommand parser handles dispatch, --config, --help, --version, etc.
if [ "$#" -eq 0 ]; then
    exec /opt/ota/ota-server serve --config="${OTA_CONFIG}"
fi
exec /opt/ota/ota-server "$@"
