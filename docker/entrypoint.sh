#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Ogamita Ltd.
#
# Container entrypoint for ota-server.
# - Materialises a default config if none is mounted.
# - Dispatches to subcommands: serve | migrate | gc | shell.

set -eu

: "${OTA_ROOT:=/var/lib/ota}"
: "${OTA_CONFIG:=/etc/ota/ota.toml}"

if [ ! -f "${OTA_CONFIG}" ]; then
    echo "ota-entrypoint: no config at ${OTA_CONFIG}, copying sample" >&2
    cp /etc/ota/ota.toml.sample "${OTA_CONFIG}"
fi

cmd="${1:-serve}"
shift || true

case "${cmd}" in
    serve)
        exec sbcl --core /opt/ota/ota-server.core \
                  --non-interactive \
                  --no-userinit --no-sysinit \
                  --eval "(ota-server:main :config \"${OTA_CONFIG}\")" "$@"
        ;;
    migrate)
        exec sbcl --core /opt/ota/ota-server.core \
                  --non-interactive --no-userinit --no-sysinit \
                  --eval "(ota-server:migrate :config \"${OTA_CONFIG}\")"
        ;;
    gc)
        exec sbcl --core /opt/ota/ota-server.core \
                  --non-interactive --no-userinit --no-sysinit \
                  --eval "(ota-server:run-gc :config \"${OTA_CONFIG}\")" "$@"
        ;;
    shell)
        exec sbcl --core /opt/ota/ota-server.core
        ;;
    *)
        echo "ota-entrypoint: unknown subcommand '${cmd}'" >&2
        echo "  usage: ota-entrypoint {serve|migrate|gc|shell}" >&2
        exit 2
        ;;
esac
