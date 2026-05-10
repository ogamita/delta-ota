-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (C) 2026 Ogamita Ltd.
--
-- v1.2: persistent patch-build job queue.  Each row is one (from->to,
-- patcher) bsdiff invocation.  The async worker pool (workers/pool.lisp)
-- consumes pending rows.  The publish handler enqueues them and tails
-- the table to emit progress events.  Restart-safe: any row left in
-- 'running' at boot is reset to 'pending' (see RESET-STALE-RUNNING-JOBS).
--
-- The UNIQUE (from, to, patcher) constraint deduplicates re-publishes
-- of the same release tuple — the catalogue insert silently no-ops the
-- second time, which is exactly the idempotent behaviour we want.

CREATE TABLE IF NOT EXISTS patch_jobs (
    id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    from_release_id    TEXT NOT NULL,
    to_release_id      TEXT NOT NULL,
    software_name      TEXT NOT NULL,
    os                 TEXT NOT NULL,
    arch               TEXT NOT NULL,
    from_version       TEXT NOT NULL,
    from_blob_sha256   TEXT NOT NULL,
    to_blob_sha256     TEXT NOT NULL,
    patcher            TEXT NOT NULL DEFAULT 'bsdiff',
    status             TEXT NOT NULL DEFAULT 'pending'
                       CHECK (status IN ('pending','running','done','failed')),
    attempts           INTEGER NOT NULL DEFAULT 0,
    error              TEXT,
    patch_sha256       TEXT,           -- populated on success
    patch_size         INTEGER,        -- populated on success
    enqueued_at        TEXT NOT NULL,
    started_at         TEXT,
    completed_at       TEXT,
    UNIQUE (from_release_id, to_release_id, patcher)
);

CREATE INDEX IF NOT EXISTS idx_patch_jobs_status
    ON patch_jobs(status);

CREATE INDEX IF NOT EXISTS idx_patch_jobs_to
    ON patch_jobs(to_release_id);

CREATE INDEX IF NOT EXISTS idx_patch_jobs_pending_id
    ON patch_jobs(id) WHERE status = 'pending';

INSERT OR IGNORE INTO schema_migrations (name, applied_at)
VALUES ('0004_patch_jobs', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
