#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Ogamita Ltd.
"""
ota-server -> SMTP webhook receiver.

Usage:
    SMTP_HOST=mail.example.com SMTP_PORT=587 \\
    SMTP_USER=alice@example.com SMTP_PASS=$PASS \\
    SMTP_FROM=ota@example.com \\
    OTA_WEBHOOK_SECRET=$SECRET \\
    BIND=127.0.0.1:9090 \\
    python3 smtp-relay.py

Listens on $BIND for POSTs from ota-server.  Validates the
X-Ota-Webhook-Signature header (HMAC-SHA256 of the body) when
OTA_WEBHOOK_SECRET is set, then forwards a plain-text email to
each address in the "emails" array via the configured SMTP
server.

Returns 200 on successful relay.  4xx on bad signature / bad
body / permanent SMTP failure.  5xx on transient SMTP failure --
ota-server will retry.

This is reference code: hardening (TLS cert pinning,
rate-limit-per-source, dead-letter queue, structured logging)
is the operator's job.
"""

import hmac, hashlib, json, os, smtplib, ssl, sys
from email.message import EmailMessage
from http.server import BaseHTTPRequestHandler, HTTPServer


def verify_signature(body: bytes, header: str | None, secret: str) -> bool:
    if not secret:
        return True
    if not header:
        return False
    want = hmac.new(secret.encode("utf-8"), body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(want, header)


def relay(payload: dict) -> None:
    """Forward the payload to each address via SMTP.  Raises on
    SMTP error so the HTTP handler can map to 5xx."""
    host = os.environ.get("SMTP_HOST", "localhost")
    port = int(os.environ.get("SMTP_PORT", "25"))
    user = os.environ.get("SMTP_USER")
    pwd  = os.environ.get("SMTP_PASS")
    sender = os.environ.get("SMTP_FROM", "ota@localhost")

    sw  = payload.get("software", "?")
    rel = payload.get("release", {})
    ver = rel.get("version", "?")
    size = rel.get("blob_size", 0)

    subject = f"[OTA] {sw} {ver} is available"
    body = (
        f"A new release of {sw} ({ver}) was published "
        f"on {rel.get('published_at', '?')}.\n\n"
        f"Blob size: {size} bytes.\n\n"
        f"Your client (id={payload.get('client_id', '?')}) will pick "
        f"it up on the next `ota-agent upgrade {sw}` invocation, "
        f"or automatically if you have `ota-agent watch` running.\n"
    )

    if port == 465:
        ctx = ssl.create_default_context()
        smtp = smtplib.SMTP_SSL(host, port, context=ctx, timeout=10)
    else:
        smtp = smtplib.SMTP(host, port, timeout=10)
        if port != 25:
            smtp.starttls(context=ssl.create_default_context())
    try:
        if user:
            smtp.login(user, pwd or "")
        for to in payload.get("emails", []):
            msg = EmailMessage()
            msg["From"] = sender
            msg["To"] = to
            msg["Subject"] = subject
            msg.set_content(body)
            smtp.send_message(msg)
    finally:
        smtp.quit()


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        try:
            n = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(n)
            sig = self.headers.get("X-Ota-Webhook-Signature")
            secret = os.environ.get("OTA_WEBHOOK_SECRET", "")
            if not verify_signature(body, sig, secret):
                self.send_response(401)
                self.end_headers()
                return
            payload = json.loads(body)
        except Exception as e:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(f"bad request: {e}".encode())
            return
        try:
            relay(payload)
        except smtplib.SMTPRecipientsRefused as e:
            # Permanent: bad address.
            self.send_response(422)
            self.end_headers()
            self.wfile.write(str(e).encode())
            return
        except Exception as e:
            # Transient: connection / temporary 4xx.
            sys.stderr.write(f"smtp-relay: error: {e}\n")
            self.send_response(503)
            self.end_headers()
            return
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok\n")

    def log_message(self, *_):
        # Quiet default access log; emit our own structured lines.
        sys.stderr.write(f"smtp-relay: {self.command} {self.path}\n")


def main():
    bind = os.environ.get("BIND", "127.0.0.1:9090")
    host, port = bind.rsplit(":", 1)
    HTTPServer((host, int(port)), Handler).serve_forever()


if __name__ == "__main__":
    main()
