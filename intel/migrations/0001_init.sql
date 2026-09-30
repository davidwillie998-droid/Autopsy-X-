-- AUTOPSY X intelligence store, migration 0001.
-- Target: PostgreSQL 15+ with TimescaleDB for the hypertables. Without
-- Timescale, drop the create_hypertable calls; everything else is plain SQL.
--
-- Conventions
--   * Every event table carries ts (event time) and seen_ts (ingest time).
--     Point-in-time reads filter on seen_ts. Never on ts alone.
--   * Natural keys (chain, tx_hash, log_index) are unique: re-ingesting the
--     same swap is an upsert, not a duplicate.
--   * Nothing is updated in place except provider health. Corrections are new
--     rows with a later seen_ts, so history reflects what was knowable when.
--   * NULL means unknown. There are no zero-filled placeholders.

BEGIN;

CREATE TABLE schema_version (
    version     INTEGER PRIMARY KEY,
    applied_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    description TEXT NOT NULL
);
INSERT INTO schema_version (version, description) VALUES (1, 'initial schema');

CREATE TABLE tokens (
    chain         TEXT NOT NULL,
    address       TEXT NOT NULL,
    symbol        TEXT NOT NULL,
    name          TEXT NOT NULL,
    launch_ts     TIMESTAMPTZ,
    creator       TEXT,
    total_supply  NUMERIC,
    description   TEXT,
    first_seen_ts TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (chain, address)
);
CREATE INDEX tokens_symbol_idx ON tokens (upper(symbol));  -- collision checks

CREATE TABLE pools (
    chain      TEXT NOT NULL,
    pool       TEXT NOT NULL,
    token      TEXT NOT NULL,
    venue      TEXT NOT NULL,
    amm_model  TEXT NOT NULL CHECK (amm_model IN ('cpmm', 'clmm', 'orderbook', 'unknown')),
    fee_bps    NUMERIC,
    created_ts TIMESTAMPTZ NOT NULL,
    seen_ts    TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (chain, pool),
    FOREIGN KEY (chain, token) REFERENCES tokens (chain, address)
);

CREATE TABLE swaps (
    chain       TEXT NOT NULL,
    tx_hash     TEXT NOT NULL,
    log_index   INTEGER NOT NULL,
    ts          TIMESTAMPTZ NOT NULL,
    seen_ts     TIMESTAMPTZ NOT NULL,
    block       BIGINT NOT NULL,
    pool        TEXT NOT NULL,
    token       TEXT NOT NULL,
    wallet      TEXT NOT NULL,
    side        TEXT NOT NULL CHECK (side IN ('buy', 'sell')),
    token_amount NUMERIC NOT NULL,
    quote_usd   NUMERIC NOT NULL,
    price_usd   NUMERIC NOT NULL,
    source      TEXT NOT NULL,
    PRIMARY KEY (chain, tx_hash, log_index, ts)
);
SELECT create_hypertable('swaps', 'ts', if_not_exists => TRUE);
CREATE INDEX swaps_token_seen_idx ON swaps (chain, token, seen_ts);
CREATE INDEX swaps_wallet_idx ON swaps (chain, wallet, ts);

CREATE TABLE liquidity_events (
    chain           TEXT NOT NULL,
    tx_hash         TEXT NOT NULL,
    log_index       INTEGER NOT NULL,
    ts              TIMESTAMPTZ NOT NULL,
    seen_ts         TIMESTAMPTZ NOT NULL,
    block           BIGINT NOT NULL,
    pool            TEXT NOT NULL,
    token           TEXT NOT NULL,
    kind            TEXT NOT NULL CHECK (kind IN ('add', 'remove')),
    usd             NUMERIC NOT NULL,
    provider_wallet TEXT NOT NULL,
    PRIMARY KEY (chain, tx_hash, log_index)
);
CREATE INDEX liq_token_seen_idx ON liquidity_events (chain, token, seen_ts);

CREATE TABLE pool_snapshots (
    chain         TEXT NOT NULL,
    pool          TEXT NOT NULL,
    token         TEXT NOT NULL,
    ts            TIMESTAMPTZ NOT NULL,
    seen_ts       TIMESTAMPTZ NOT NULL,
    liquidity_usd NUMERIC,
    price_usd     NUMERIC,
    source        TEXT NOT NULL,
    PRIMARY KEY (chain, pool, source, ts)
);
SELECT create_hypertable('pool_snapshots', 'ts', if_not_exists => TRUE);

CREATE TABLE holder_snapshots (
    chain       TEXT NOT NULL,
    token       TEXT NOT NULL,
    ts          TIMESTAMPTZ NOT NULL,
    seen_ts     TIMESTAMPTZ NOT NULL,
    holders     INTEGER,
    top10_pct   NUMERIC,
    creator_pct NUMERIC,
    excluded_addresses TEXT[],  -- LP, burn, exchange addresses removed before computing concentration
    source      TEXT NOT NULL,
    PRIMARY KEY (chain, token, source, ts)
);

CREATE TABLE funding_transfers (
    chain   TEXT NOT NULL,
    tx_hash TEXT NOT NULL,
    ts      TIMESTAMPTZ NOT NULL,
    seen_ts TIMESTAMPTZ NOT NULL,
    block   BIGINT NOT NULL,
    src     TEXT NOT NULL,
    dst     TEXT NOT NULL,
    amount  NUMERIC NOT NULL,
    PRIMARY KEY (chain, tx_hash, src, dst)
);
CREATE INDEX funding_dst_idx ON funding_transfers (chain, dst, ts);
CREATE INDEX funding_src_idx ON funding_transfers (chain, src, ts);

-- Known infrastructure (exchanges, bridges, routers) excluded as funders.
CREATE TABLE address_book (
    chain    TEXT NOT NULL,
    address  TEXT NOT NULL,
    category TEXT NOT NULL CHECK (category IN ('exchange', 'bridge', 'router', 'burn', 'lp_locker', 'other')),
    label    TEXT,
    source   TEXT NOT NULL,
    added_ts TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (chain, address)
);

CREATE TABLE news_events (
    event_id    TEXT PRIMARY KEY,
    story_id    TEXT,
    ts          TIMESTAMPTZ NOT NULL,   -- publisher timestamp
    seen_ts     TIMESTAMPTZ NOT NULL,   -- ingestion timestamp
    source      TEXT NOT NULL,
    source_tier SMALLINT NOT NULL CHECK (source_tier BETWEEN 1 AND 4),
    headline    TEXT NOT NULL,
    summary     TEXT,
    entities    TEXT[],
    tokens      TEXT[],                 -- chain:address keys
    chains      TEXT[],
    narrative   TEXT,
    event_type  TEXT NOT NULL,
    sentiment   NUMERIC,
    novelty     NUMERIC,
    credibility NUMERIC,
    market_relevance NUMERIC,
    expected_impact  SMALLINT,          -- -1, 0, +1
    raw         JSONB
);
CREATE INDEX news_seen_idx ON news_events (seen_ts);
CREATE INDEX news_tokens_idx ON news_events USING GIN (tokens);

-- Measured after the fact; kept separate so it can never leak into features.
CREATE TABLE news_reactions (
    event_id   TEXT NOT NULL REFERENCES news_events (event_id),
    token      TEXT NOT NULL,
    horizon    TEXT NOT NULL,
    log_return NUMERIC,
    abnormal_return NUMERIC,
    computed_ts TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (event_id, token, horizon)
);

CREATE TABLE social_posts (
    post_id           TEXT NOT NULL,
    platform          TEXT NOT NULL,
    ts                TIMESTAMPTZ NOT NULL,
    seen_ts           TIMESTAMPTZ NOT NULL,
    author_id         TEXT NOT NULL,
    author_created_ts TIMESTAMPTZ,
    author_followers  INTEGER,
    text              TEXT NOT NULL,
    tokens            TEXT[],
    is_repost         BOOLEAN NOT NULL,
    engagement        INTEGER,
    PRIMARY KEY (platform, post_id)
);
SELECT create_hypertable('social_posts', 'ts', if_not_exists => TRUE, migrate_data => TRUE);

-- Feature store: one row per (token, feature, as_of). status is never NULL.
CREATE TABLE feature_values (
    token       TEXT NOT NULL,
    feature     TEXT NOT NULL,
    as_of       TIMESTAMPTZ NOT NULL,
    value       DOUBLE PRECISION,
    status      TEXT NOT NULL CHECK (status IN ('OK', 'MISSING', 'STALE', 'INSUFFICIENT_HISTORY', 'UNVERIFIED', 'CONFLICTING')),
    reason      TEXT,
    feature_version TEXT NOT NULL,
    PRIMARY KEY (token, feature, as_of, feature_version),
    CHECK (status <> 'OK' OR value IS NOT NULL)
);
SELECT create_hypertable('feature_values', 'as_of', if_not_exists => TRUE);

CREATE TABLE assessments (
    token        TEXT NOT NULL,
    as_of        TIMESTAMPTZ NOT NULL,
    config_hash  TEXT NOT NULL,
    code_version TEXT NOT NULL,
    move_class   TEXT NOT NULL,
    regime       TEXT NOT NULL,
    exhaustion   TEXT NOT NULL,
    move_quality DOUBLE PRECISION,
    manipulation DOUBLE PRECISION,
    failures     TEXT[] NOT NULL,
    payload      JSONB NOT NULL,       -- full Assessment.to_dict()
    PRIMARY KEY (token, as_of, config_hash)
);

CREATE TABLE manipulation_flags (
    token       TEXT NOT NULL,
    as_of       TIMESTAMPTZ NOT NULL,
    kind        TEXT NOT NULL,
    confidence  DOUBLE PRECISION NOT NULL,
    evidence    JSONB NOT NULL,
    wallets     TEXT[] NOT NULL,
    tx_hashes   TEXT[] NOT NULL,
    methodology TEXT NOT NULL,
    alternative_explanation TEXT NOT NULL,
    PRIMARY KEY (token, as_of, kind)
);

CREATE TABLE signals (
    signal_id    BIGSERIAL PRIMARY KEY,
    token        TEXT NOT NULL,
    as_of        TIMESTAMPTZ NOT NULL,
    type         TEXT NOT NULL,
    signal_score DOUBLE PRECISION,
    confidence   DOUBLE PRECISION,
    invalidation JSONB NOT NULL,
    conditions   JSONB NOT NULL,
    blocked_by   TEXT[] NOT NULL,
    risk_flags   TEXT[] NOT NULL,
    config_hash  TEXT NOT NULL,
    mode         TEXT NOT NULL CHECK (mode IN ('backtest', 'paper', 'live'))
);
CREATE INDEX signals_token_idx ON signals (token, as_of);

CREATE TABLE alerts (
    alert_id BIGSERIAL PRIMARY KEY,
    kind     TEXT NOT NULL,
    token    TEXT,
    ts       TIMESTAMPTZ NOT NULL,
    text     TEXT NOT NULL,
    evidence JSONB NOT NULL
);

-- Append-only journal with hash chain (see autopsyx/journal).
CREATE TABLE journal (
    seq         BIGSERIAL PRIMARY KEY,
    kind        TEXT NOT NULL,
    config_hash TEXT NOT NULL,
    label_rules TEXT NOT NULL,
    prev_hash   TEXT NOT NULL,
    hash        TEXT NOT NULL UNIQUE,
    payload     JSONB NOT NULL,
    written_ts  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE RULE journal_no_update AS ON UPDATE TO journal DO INSTEAD NOTHING;
CREATE RULE journal_no_delete AS ON DELETE TO journal DO INSTEAD NOTHING;

CREATE TABLE backtest_runs (
    run_id        TEXT PRIMARY KEY,
    started_ts    TIMESTAMPTZ NOT NULL,
    dataset_version TEXT NOT NULL,
    config_hash   TEXT NOT NULL,
    code_version  TEXT NOT NULL,
    split         TEXT NOT NULL CHECK (split IN ('train', 'validation', 'test')),
    period_start  TIMESTAMPTZ NOT NULL,
    period_end    TIMESTAMPTZ NOT NULL,
    metrics       JSONB NOT NULL
);

CREATE TABLE provider_health (
    provider        TEXT PRIMARY KEY,
    ok              BOOLEAN NOT NULL,
    last_success_ts TIMESTAMPTZ,
    last_error      TEXT,
    rate_limited    BOOLEAN NOT NULL DEFAULT FALSE,
    updated_ts      TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMIT;
