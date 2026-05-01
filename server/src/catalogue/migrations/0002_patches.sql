-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (C) 2026 Ogamita Ltd.

CREATE TABLE IF NOT EXISTS patches (
    sha256             TEXT PRIMARY KEY,
    from_release_id    TEXT NOT NULL,
    to_release_id      TEXT NOT NULL,
    patcher            TEXT NOT NULL,
    size               INTEGER NOT NULL,
    built_at           TEXT NOT NULL,
    UNIQUE (from_release_id, to_release_id, patcher)
);

CREATE INDEX IF NOT EXISTS idx_patches_to ON patches(to_release_id);
CREATE INDEX IF NOT EXISTS idx_patches_from ON patches(from_release_id);

INSERT OR IGNORE INTO schema_migrations (name, applied_at)
VALUES ('0002_patches', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
