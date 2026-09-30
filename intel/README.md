# AUTOPSY X intelligence engine (research core)

Detects, explains and ranks abnormal moves in memecoins and other high-volatility tokens, separates genuine participation from manufactured activity, and says nothing when the evidence is incomplete. It does not tell anyone to buy.

This is the Phase 1 build from the research plan in [`docs/research/`](../docs/research/README.md): every engine exists as a typed, deterministic, tested reference implementation, and none of its thresholds has been validated on historical data yet.

## Run

Python 3.11+, no runtime dependencies.

```bash
cd intel
python -m autopsyx demo            # radar, alerts, signals, timeline on synthetic scenarios
python -m autopsyx demo --json     # every stage's structured output
python -m autopsyx --log demo      # plus structured JSON logs on stderr
python -m autopsyx replay data.jsonl --as-of 1700036000000
python -m autopsyx features        # feature dictionary (source of docs/research/03)
pip install pytest && python -m pytest -q
```

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
  pipeline.py    stage wiring (no scoring logic)
config/default.toml   every threshold and weight
migrations/           Postgres/Timescale schema
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

No live data adapters ship yet. Phase 2 (data-source audit) writes them against the protocols in `providers/base.py`.
