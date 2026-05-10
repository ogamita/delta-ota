-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (C) 2026 Ogamita Ltd.
--
-- v1.7: notifications outbox.
--
-- Mirrors the v1.2 patch_jobs table structurally: atomic claim,
-- restart-safe (reset stale running rows at boot), retry with
-- attempts counter.  The notification worker pool dequeues
-- pending rows and POSTs JSON to the operator-configured
-- webhook URL.  See ADR-0012 for the design.
--
-- UNIQUE (client_id, software_name, release_id, reason) so a
-- duplicate publish event or a retried admin announce cannot
-- enqueue twice.

CREATE TABLE IF NOT EXISTS notifications_outbox (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    client_id         TEXT NOT NULL,
    software_name     TEXT NOT NULL,
    release_id        TEXT NOT NULL,
    reason            TEXT NOT NULL,    -- 'publish'|'announce'|'security'
    status            TEXT NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending','running','sent','failed','skipped')),
    attempts          INTEGER NOT NULL DEFAULT 0,
    last_error        TEXT,
    enqueued_at       TEXT NOT NULL,
    started_at        TEXT,
    sent_at           TEXT,
    UNIQUE (client_id, software_name, release_id, reason)
);

CREATE INDEX IF NOT EXISTS idx_outbox_status
    ON notifications_outbox(status);

CREATE INDEX IF NOT EXISTS idx_outbox_pending
    ON notifications_outbox(id) WHERE status = 'pending';

INSERT OR IGNORE INTO schema_migrations (name, applied_at)
VALUES ('0007_notifications_outbox',
        strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
