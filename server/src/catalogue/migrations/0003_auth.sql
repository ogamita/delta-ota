-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (C) 2026 Ogamita Ltd.

-- Phase-4: classifications, install tokens, per-client bearer tokens,
-- and an audit log of admin writes.

CREATE TABLE IF NOT EXISTS clients (
    client_id        TEXT PRIMARY KEY,
    bearer_token     TEXT NOT NULL UNIQUE,
    classifications  TEXT NOT NULL DEFAULT '["public"]',  -- JSON array
    hwinfo           TEXT,
    cert_subject     TEXT,
    last_seen_at     TEXT,
    created_at       TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_clients_bearer ON clients(bearer_token);

CREATE TABLE IF NOT EXISTS install_tokens (
    token            TEXT PRIMARY KEY,
    classifications  TEXT NOT NULL DEFAULT '["public"]',
    expires_at       TEXT NOT NULL,
    used_at          TEXT,
    created_by       TEXT,
    created_at       TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_install_tokens_expires ON install_tokens(expires_at);

CREATE TABLE IF NOT EXISTS audit_log (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    identity         TEXT NOT NULL,
    action           TEXT NOT NULL,
    target           TEXT,
    detail           TEXT,
    at               TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_audit_at ON audit_log(at);

INSERT OR IGNORE INTO schema_migrations (name, applied_at)
VALUES ('0003_auth', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
