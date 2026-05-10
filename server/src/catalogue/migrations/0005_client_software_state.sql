-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (C) 2026 Ogamita Ltd.
--
-- v1.5: client_software_state snapshot table.
--
-- Records the current release each client has installed for each
-- software it tracks.  Maintained idempotently by ota-agent on
-- every successful install/upgrade/revert/recover/uninstall via
-- PUT /v1/clients/me/software/<sw>.
--
-- Replaces the lossy event-log scan (count-users-at-release over
-- install_events) with an exact direct lookup.  install_events
-- stays around for analytics; the snapshot is authoritative for
-- the question "who is on X right now".
--
-- current_release_id is nullable: NULL = the client uninstalled
-- this software but we keep the row for fleet stats.  See
-- docs/release-1.5-plan.org and ADR-0010 for the design rationale.

CREATE TABLE IF NOT EXISTS client_software_state (
    client_id            TEXT NOT NULL,
    software_name        TEXT NOT NULL,
    current_release_id   TEXT,
    previous_release_id  TEXT,
    last_kind            TEXT NOT NULL
                         CHECK (last_kind IN ('install','upgrade','revert',
                                              'recover','uninstall')),
    last_updated_at      TEXT NOT NULL,
    PRIMARY KEY (client_id, software_name)
);

-- Per-release population queries (the bread-and-butter of stats).
-- This is what count-users-at-release reads on the GC path.
CREATE INDEX IF NOT EXISTS idx_css_release
    ON client_software_state(software_name, current_release_id);

-- Stale-clients query: clients we haven't heard from in N days.
CREATE INDEX IF NOT EXISTS idx_css_updated
    ON client_software_state(last_updated_at);

INSERT OR IGNORE INTO schema_migrations (name, applied_at)
VALUES ('0005_client_software_state',
        strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
