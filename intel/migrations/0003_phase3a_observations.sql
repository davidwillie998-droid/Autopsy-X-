-- AUTOPSY X intelligence store, migration 0003: Phase 3A observations.
-- One table for funding transfers, liquidity events, creator / holder state,
-- news and social. The database enforces the observation contract again:
-- only OBSERVED rows carry a value, every other state carries a reason, a
-- missing source time has an explicit state, and point-in-time reads filter
-- on ingestion_ts.

BEGIN;

INSERT INTO schema_version (version, description) VALUES (3, 'phase 3a observations, per-attempt telemetry');

ALTER TABLE raw_manifest
    ADD COLUMN attempt_log         JSONB NOT NULL DEFAULT '[]'::jsonb,
    ADD COLUMN method              TEXT NOT NULL DEFAULT 'GET' CHECK (method IN ('GET', 'POST')),
    ADD COLUMN request_body_sha256 CHAR(64),
    ADD CONSTRAINT raw_manifest_post_has_body CHECK (method = 'GET' OR request_body_sha256 IS NOT NULL);

CREATE TABLE observations (
    run_id          TEXT NOT NULL,
    kind            TEXT NOT NULL CHECK (kind IN ('funding_transfer', 'liquidity_event', 'creator_state',
                                                  'holder_state', 'news', 'social')),
    entity          TEXT NOT NULL,
    chain           TEXT NOT NULL,
    venue           TEXT,
    state           TEXT NOT NULL CHECK (state IN ('OBSERVED', 'NOT_OBSERVED', 'UNAVAILABLE', 'STALE', 'ERROR',
                                                   'UNKNOWN', 'NOT_APPLICABLE')),
    observation_ts  TIMESTAMPTZ NOT NULL,
    source_ts       TIMESTAMPTZ,
    source_ts_state TEXT NOT NULL CHECK (source_ts_state IN ('OBSERVED', 'NOT_OBSERVED', 'UNAVAILABLE', 'STALE',
                                                             'ERROR', 'UNKNOWN', 'NOT_APPLICABLE')),
    ingestion_ts    TIMESTAMPTZ NOT NULL,
    provider        TEXT NOT NULL,
    response_status INTEGER,
    raw_id          CHAR(64),
    slot            BIGINT CHECK (slot IS NULL OR slot >= 0),
    signature       TEXT,
    value           JSONB NOT NULL DEFAULT '{}'::jsonb,
    reason          TEXT NOT NULL DEFAULT '',
    schema_version  TEXT NOT NULL,
    CHECK ((source_ts IS NULL) = (source_ts_state <> 'OBSERVED')),
    CHECK (source_ts IS NULL OR source_ts <= ingestion_ts + INTERVAL '5 seconds'),
    CHECK ((state = 'OBSERVED') = (value <> '{}'::jsonb)),
    CHECK (state = 'OBSERVED' OR reason <> ''),
    CHECK (state <> 'OBSERVED' OR raw_id IS NOT NULL),
    -- a signer is never recorded as the beneficiary
    CHECK (kind <> 'funding_transfer' OR state <> 'OBSERVED' OR value->>'beneficiary_status' = 'UNKNOWN')
);
CREATE INDEX observations_pit_idx ON observations (kind, entity, ingestion_ts);
CREATE INDEX observations_raw_idx ON observations (raw_id);

-- The only point-in-time door for observations.
CREATE FUNCTION observations_as_of(as_of TIMESTAMPTZ) RETURNS SETOF observations
    LANGUAGE sql STABLE AS $$ SELECT * FROM observations WHERE ingestion_ts <= as_of $$;

COMMIT;
