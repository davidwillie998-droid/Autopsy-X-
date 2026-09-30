-- AUTOPSY X intelligence store, migration 0002: provenance, provider bars,
-- coverage claims, normalization issues, replay runs and replay records.
-- Phase 2 contract: every normalized row names the adapter that produced it
-- (source) and the sha256 of the exact response body it came from (raw_id).

BEGIN;

INSERT INTO schema_version (version, description) VALUES (2, 'provenance, provider bars, coverage, replay');

-- One row per HTTP exchange, including failures. Bodies live in the content-
-- addressed archive (raw/<raw_id>.json.gz); raw_id is NULL when no body arrived.
CREATE TABLE raw_manifest (
    run_id       TEXT NOT NULL,
    seq          INTEGER NOT NULL,
    provider     TEXT NOT NULL,
    endpoint     TEXT NOT NULL,
    url          TEXT NOT NULL,
    request_ts   TIMESTAMPTZ NOT NULL,
    response_ts  TIMESTAMPTZ,
    status       INTEGER,
    raw_id       CHAR(64),
    bytes        INTEGER CHECK (bytes IS NULL OR bytes >= 0),
    attempts     INTEGER CHECK (attempts IS NULL OR attempts >= 1),
    error        TEXT,
    context      JSONB NOT NULL DEFAULT '{}'::jsonb,
    PRIMARY KEY (run_id, seq),
    CHECK ((raw_id IS NULL) = (response_ts IS NULL)),
    CHECK (error IS NOT NULL OR raw_id IS NOT NULL),
    CHECK (response_ts IS NULL OR response_ts >= request_ts)
);
CREATE INDEX raw_manifest_raw_idx ON raw_manifest (raw_id);

ALTER TABLE tokens           ADD COLUMN source TEXT, ADD COLUMN raw_id CHAR(64);
ALTER TABLE pools            ADD COLUMN source TEXT, ADD COLUMN raw_id CHAR(64);
ALTER TABLE swaps            ADD COLUMN raw_id CHAR(64);
ALTER TABLE pool_snapshots   ADD COLUMN raw_id CHAR(64);
ALTER TABLE holder_snapshots ADD COLUMN raw_id CHAR(64);

-- Value sanity that adapters already enforce; the database enforces it again.
ALTER TABLE swaps ADD CONSTRAINT swaps_positive CHECK (price_usd > 0 AND quote_usd >= 0 AND token_amount >= 0);
ALTER TABLE swaps ADD CONSTRAINT swaps_two_clocks CHECK (seen_ts >= ts - INTERVAL '5 seconds');
ALTER TABLE pool_snapshots ADD CONSTRAINT snapshots_nonneg CHECK (
    (liquidity_usd IS NULL OR liquidity_usd >= 0) AND (price_usd IS NULL OR price_usd > 0));
ALTER TABLE holder_snapshots ADD CONSTRAINT holders_sane CHECK (
    (holders IS NULL OR holders >= 0) AND (top10_pct IS NULL OR top10_pct BETWEEN 0 AND 1)
    AND (creator_pct IS NULL OR creator_pct BETWEEN 0 AND 1));

-- Provider OHLCV. Providers revise recent bars, so every version is kept; the
-- point-in-time read picks the latest version with seen_ts <= as_of.
CREATE TABLE provider_bars (
    chain       TEXT NOT NULL,
    pool        TEXT NOT NULL,
    token       TEXT NOT NULL,
    ts          TIMESTAMPTZ NOT NULL,      -- bar open
    interval_ms INTEGER NOT NULL CHECK (interval_ms > 0),
    seen_ts     TIMESTAMPTZ NOT NULL,
    open        NUMERIC NOT NULL CHECK (open > 0),
    high        NUMERIC NOT NULL CHECK (high > 0),
    low         NUMERIC NOT NULL CHECK (low > 0),
    close       NUMERIC NOT NULL CHECK (close > 0),
    volume_usd  NUMERIC CHECK (volume_usd IS NULL OR volume_usd >= 0),
    source      TEXT NOT NULL,
    raw_id      CHAR(64) NOT NULL,
    PRIMARY KEY (chain, pool, source, ts, seen_ts),
    CHECK (high >= low AND high >= open AND high >= close AND low <= open AND low <= close),
    -- a bar is only an observation once it has closed
    CHECK (seen_ts >= ts + make_interval(secs => interval_ms / 1000.0))
);
SELECT create_hypertable('provider_bars', 'ts', if_not_exists => TRUE);
CREATE INDEX provider_bars_pit_idx ON provider_bars (chain, token, seen_ts);

-- Claims that a stream was complete over [start_ts, end_ts) as of seen_ts.
CREATE TABLE coverage (
    chain    TEXT NOT NULL,
    token    TEXT NOT NULL,
    pool     TEXT NOT NULL,
    kind     TEXT NOT NULL CHECK (kind IN ('trades', 'bars')),
    start_ts TIMESTAMPTZ NOT NULL,
    end_ts   TIMESTAMPTZ NOT NULL,
    seen_ts  TIMESTAMPTZ NOT NULL,
    source   TEXT NOT NULL,
    raw_id   CHAR(64) NOT NULL,
    PRIMARY KEY (chain, pool, kind, raw_id),
    CHECK (end_ts > start_ts),
    CHECK (end_ts <= seen_ts)          -- nobody can vouch for data they have not seen yet
);
CREATE INDEX coverage_pit_idx ON coverage (chain, token, kind, seen_ts);

CREATE TABLE normalization_issues (
    run_id  TEXT NOT NULL,
    code    TEXT NOT NULL,
    raw_id  CHAR(64),
    detail  TEXT NOT NULL,
    action  TEXT NOT NULL CHECK (action IN ('dropped_record', 'dropped_field', 'flagged', 'derived', 'skipped_response'))
);
CREATE INDEX normalization_issues_run_idx ON normalization_issues (run_id, code);

CREATE TABLE replay_runs (
    replay_id       TEXT PRIMARY KEY,           -- dataset_id + config hash + code version
    dataset_id      TEXT NOT NULL,
    config_hash     TEXT NOT NULL,
    code_version    TEXT NOT NULL,
    start_ts        TIMESTAMPTZ NOT NULL,
    end_ts          TIMESTAMPTZ NOT NULL,
    step_ms         INTEGER NOT NULL CHECK (step_ms > 0),
    capabilities    JSONB NOT NULL,
    records_sha256  CHAR(64) NOT NULL,
    summary         JSONB NOT NULL,
    UNIQUE (dataset_id, config_hash, code_version),
    CHECK (end_ts >= start_ts)
);

CREATE TABLE replay_records (
    replay_id          TEXT NOT NULL REFERENCES replay_runs (replay_id),
    token              TEXT NOT NULL,
    chain              TEXT NOT NULL,
    as_of              TIMESTAMPTZ NOT NULL,
    configuration_hash TEXT NOT NULL,
    code_version       TEXT NOT NULL,
    dataset_id         TEXT NOT NULL,
    signal             TEXT NOT NULL CHECK (signal IN ('HIGH_CONVICTION_CONTINUATION', 'WATCH', 'NO_SIGNAL')),
    move_class         TEXT NOT NULL,
    data_quality       TEXT[] NOT NULL,
    risk               JSONB,
    entry              JSONB,
    exit               JSONB,
    reason             JSONB,
    outcome            JSONB,
    payload            JSONB NOT NULL,
    PRIMARY KEY (replay_id, token, as_of)
);

COMMIT;
