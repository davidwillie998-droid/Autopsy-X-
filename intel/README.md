# AUTOPSY X intelligence engine (research core)

Detects, explains and ranks abnormal moves in memecoins and other high-volatility tokens, separates genuine participation from manufactured activity, and says nothing when the evidence is incomplete. It does not tell anyone to buy.

Phase 1 built every engine as a typed, deterministic, tested reference implementation ([`docs/research/`](../docs/research/README.md)). Phase 2 connected real market data with byte-level provenance and point-in-time replay ([`docs/SYSTEM_STATUS.md`](../docs/SYSTEM_STATUS.md)). No threshold has been validated on market data, and nothing here is a trading system: there is no order, wallet or execution code.

## Install

Python 3.11+, no runtime dependencies. Tests need `pytest`; the database tests also need a PostgreSQL 16 server (they skip with the reason `DATABASE EXECUTION UNVERIFIED` when none is reachable).

```bash
cd intel
pip install pytest
python -m pytest -q          # set AUTOPSYX_PG="host=... port=... user=..." to run the database tests
```

## Run

Nothing below contacts the network except `acquire --live`.

```bash
cd intel
python -m autopsyx demo            # radar, alerts, signals, timeline on synthetic scenarios
python -m autopsyx demo --json     # every stage's structured output
python -m autopsyx --log demo      # plus structured JSON logs on stderr
python -m autopsyx replay data.jsonl --as-of 1700036000000
python -m autopsyx features        # feature dictionary (source of docs/research/03)
```

## Real data (Phase 2)

```bash
# 1. acquire: live, explicit. Public keyless APIs (GeckoTerminal, DexScreener). Writes a raw archive.
python -m autopsyx acquire --live --request datasets/phase2/REQUEST.json --out datasets/phase2/runs/<run_id>

# 2. normalize: raw bytes -> provenance-carrying records + quality report (deterministic)
python -m autopsyx normalize datasets/phase2/runs/<run_id>

# 3. replay: point-in-time, deterministic, config-pinned
python -m autopsyx replay-run datasets/phase2/runs/<run_id> --step-min 5 --expect-config <config hash>

# 4. descriptive statistics for the replay report
python -m autopsyx phase2-report datasets/phase2/runs/<run_id> datasets/phase2/runs/<run_id>/replay_<hash>
```

In this repository step 1 runs on GitHub Actions (`.github/workflows/phase2-acquire.yml`, triggered by editing `intel/datasets/phase2/REQUEST.json`), because the development container's network policy blocks vendor hosts. The workflow commits the raw archive back to the branch.

### Data-source configuration and environment variables

The Phase 2 sources are keyless, so no credentials are needed today. Adapters read credentials only through `core.config.secret(NAME)`, which reads environment variables and never logs or stores them. Reserved names for sources documented but not integrated:

| Variable | Source | Status |
|---|---|---|
| `ALPHAVANTAGE_API_KEY` | Alpha Vantage news & sentiment | not integrated |
| `HELIUS_API_KEY` | Solana RPC / enhanced transactions (funding transfers) | not integrated |
| `X_BEARER_TOKEN` | X API (social) | not integrated |
| `AUTOPSYX_PG` | libpq-style `host=... port=... user=...` for database tests | test-only |

Never commit keys; `.env` files are ignored.

### Limitations of the real-data path

See [`docs/PHASE2_DATA_SOURCE_MATRIX.md`](../docs/PHASE2_DATA_SOURCE_MATRIX.md) and [`docs/PHASE2_REPORT.md`](../docs/PHASE2_REPORT.md). In short: no funding transfers, no LP add/remove events, no liquidity history before collection starts, trades capped at the latest 300 per poll, creator holdings almost always null, no news, no social.

The demo data is synthetic: an organic news-led breakout, a wash-traded pump, a creator rug, a quiet token, and a follower that lags the breakout by three minutes. It exists to prove each engine separates cases whose ground truth is known. It is not market evidence.

## Layout

```
autopsyx/
  core/          Obs (explicit availability), canonical records, failure modes, stats, config, JSON logs
  providers/     provider protocols, point-in-time EventStore, HTTP transport (rate limit, retry, circuit breaker)
  quality/       dedupe, reorg depth, staleness, cross-source conflicts, symbol collisions
  features/      bars, market state, participation, liquidity, feature registry
  detection/     move classification + onset, Move Quality
  onchain/       wallet cluster graph, wallet track records
  manipulation/  evidence-bearing pattern detectors
  news/          taxonomy, source tiers, news-to-move timing
  social/        effective independent authors, artificial attention
  narrative/     membership, momentum, phases, leader/follower
  regime/        momentum regime rules
  signals/       exhaustion, entry (conditions + vetoes), exit
  risk/          sizing and refusal
  alerts/        alert text from measured numbers, audit timelines
  journal/       hash-chained journal, outcome labels
  backtest/      point-in-time engine, fill model, metrics, event studies
  research/      purged walk-forward, logistic baseline, calibration
  sim/           synthetic scenarios
  data/          raw archive, provider adapters, acquisition, normalization, SQL export
  replay.py      deterministic point-in-time replay with journal
  pipeline.py    stage wiring (no scoring logic)
config/default.toml   every threshold and weight
migrations/           Postgres/Timescale schema (0001 core, 0002 provenance + replay)
datasets/phase2/      acquisition request and committed raw archives
```

## Using it from Python

```python
from autopsyx.core.config import Config
from autopsyx.pipeline import scan
from autopsyx.providers.store import EventStore
from autopsyx.backtest import engine as backtest

cfg = Config.load()
store = EventStore.load_jsonl("dataset.jsonl")
result = scan(store.view(as_of_ms), cfg)
result.signals["solana:<address>"].to_dict()

bt = backtest.run(store, cfg, start_ms, end_ms, step_ms=300_000)
bt.metrics["max_drawdown"], bt.metrics["failed_exit_rate"]
```

Live adapters live in `autopsyx/data/providers/`; they are pure parsers over archived raw responses, so engines never touch vendor payloads.
