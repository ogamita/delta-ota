-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (C) 2026 Ogamita Ltd.
--
-- v1.7: opt-in email addresses per client.
--
-- Maintained by ota-agent via PUT /v1/clients/me/email (with
-- DELETE for the right-to-deletion path).  Authenticated by the
-- per-client bearer.  Strictly opt-in: the agent does not prompt
-- by default; users invoke `ota-agent set-email <addr>` explicitly.
--
-- The notification worker pool (workers/notifications.lisp) joins
-- this table when fanning out a publish event, dispatching one
-- webhook POST per address.

CREATE TABLE IF NOT EXISTS client_emails (
    client_id        TEXT NOT NULL,
    email            TEXT NOT NULL,
    verified_at      TEXT,                       -- NULL = unverified
    opted_in_at      TEXT NOT NULL,
    created_at       TEXT NOT NULL,
    PRIMARY KEY (client_id, email)
);

CREATE INDEX IF NOT EXISTS idx_emails_client
    ON client_emails(client_id);

INSERT OR IGNORE INTO schema_migrations (name, applied_at)
VALUES ('0006_client_emails',
        strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
