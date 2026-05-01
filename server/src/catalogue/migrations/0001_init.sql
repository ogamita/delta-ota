-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (C) 2026 Ogamita Ltd.

CREATE TABLE IF NOT EXISTS software (
    name             TEXT PRIMARY KEY,
    display_name     TEXT NOT NULL,
    default_patcher  TEXT NOT NULL DEFAULT 'bsdiff',
    created_at       TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS releases (
    release_id       TEXT PRIMARY KEY,
    software_name    TEXT NOT NULL REFERENCES software(name),
    os               TEXT NOT NULL,
    arch             TEXT NOT NULL,
    os_versions      TEXT NOT NULL,           -- JSON array
    version          TEXT NOT NULL,
    blob_sha256      TEXT NOT NULL,
    blob_size        INTEGER NOT NULL,
    manifest_sha256  TEXT NOT NULL,
    channels         TEXT NOT NULL DEFAULT '[]',
    classifications  TEXT NOT NULL DEFAULT '[]',
    uncollectable    INTEGER NOT NULL DEFAULT 0,
    deprecated       INTEGER NOT NULL DEFAULT 0,
    published_at     TEXT NOT NULL,
    published_by     TEXT,
    notes            TEXT,
    UNIQUE (software_name, os, arch, version)
);

CREATE INDEX IF NOT EXISTS idx_releases_software ON releases(software_name);
CREATE INDEX IF NOT EXISTS idx_releases_published_at ON releases(published_at);

CREATE TABLE IF NOT EXISTS install_events (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    client_id        TEXT NOT NULL,
    software_name    TEXT NOT NULL,
    release_id       TEXT NOT NULL,
    kind             TEXT NOT NULL,           -- install|upgrade|revert|recover
    from_release_id  TEXT,
    status           TEXT NOT NULL,           -- ok|failed
    error            TEXT,
    at               TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_install_events_client_software
    ON install_events(client_id, software_name);

CREATE TABLE IF NOT EXISTS schema_migrations (
    name TEXT PRIMARY KEY,
    applied_at TEXT NOT NULL
);

INSERT OR IGNORE INTO schema_migrations (name, applied_at)
VALUES ('0001_init', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
