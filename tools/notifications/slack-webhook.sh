#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Ogamita Ltd.
#
# ota-server -> Slack incoming-webhook receiver.
#
# Tiny CGI/socat-style script: reads an HTTP POST from stdin
# (one connection per invocation), validates the optional HMAC
# signature, forwards a Slack-shaped JSON to $SLACK_WEBHOOK_URL.
#
# Run via socat for the simplest deployment:
#
#   socat TCP-LISTEN:9091,fork,reuseaddr EXEC:./slack-webhook.sh
#
# Required env:
#   SLACK_WEBHOOK_URL  https://hooks.slack.com/services/... URL
#
# Optional env:
#   OTA_WEBHOOK_SECRET HMAC-SHA256 secret to verify the inbound POST
#                      (skip verification when unset)

set -eu

CONTENT_LENGTH=0
SIG=""
while IFS= read -r line; do
    line="${line%$(printf '\r')}"
    case "${line}" in
        "") break ;;
        "Content-Length: "*)
            CONTENT_LENGTH="${line#Content-Length: }" ;;
        "X-Ota-Webhook-Signature: "*)
            SIG="${line#X-Ota-Webhook-Signature: }" ;;
    esac
done

reply() {
    printf "HTTP/1.1 %s\r\nContent-Type: text/plain\r\n\r\n%s\n" "$1" "${2:-}"
    exit 0
}

body=$(head -c "${CONTENT_LENGTH}")

if [ -n "${OTA_WEBHOOK_SECRET:-}" ]; then
    want=$(printf '%s' "${body}" \
           | openssl dgst -sha256 -hmac "${OTA_WEBHOOK_SECRET}" -r \
           | awk '{print $1}')
    [ "${want}" = "${SIG}" ] || reply "401 Unauthorized" "bad signature"
fi

[ -n "${SLACK_WEBHOOK_URL:-}" ] || reply "500 Internal Server Error" "SLACK_WEBHOOK_URL unset"

software=$(printf '%s' "${body}" | grep -o '"software":"[^"]*"' | cut -d'"' -f4)
version=$(printf '%s' "${body}" | grep -o '"version":"[^"]*"' | cut -d'"' -f4)
text=":package: new release of *${software}* ${version} is available"

slack_body=$(printf '{"text":"%s"}' "${text}")

if curl -sf -X POST -H "Content-Type: application/json" \
        --data "${slack_body}" \
        "${SLACK_WEBHOOK_URL}" >/dev/null; then
    reply "200 OK" "forwarded"
else
    reply "503 Service Unavailable" "slack failed"
fi
