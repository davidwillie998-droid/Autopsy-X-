# Shock Outcome Research Ledger

## Scope

This is an offline research and measurement component. It does not generate trade instructions and is not imported into the live EA. It measures outcomes after a completed-bar ShockDNA ONSET snapshot.

## Return conventions

All return and excursion fields are percentage changes on entry notional, before costs:

- Underlying return: `(exit_close / entry_close - 1) * 100`
- Directional return: `direction * underlying_return`, where direction is +1 for an upward shock and -1 for a downward shock
- Long MFE: maximum positive `(high / entry - 1) * 100`
- Long MAE: maximum positive `(entry - low) / entry * 100`
- Short MFE: maximum positive `(entry - low) / entry * 100`
- Short MAE: maximum positive `(high - entry) / entry * 100`

MFE and MAE are non-negative magnitudes. These are not reciprocal-price returns, broker account-currency P&L, or risk-adjusted returns. Spread, slippage, commissions, swaps/funding, contract size, conversion and margin are not included.

## Durable ledger

`ShockEventLedger` uses SQLite tables for active events, matured outcomes, event-onset idempotency and per-symbol/timeframe timestamp watermarks. Active event state is restored after restart. Outcomes are unique by `(event_id, horizon_bars)`. CSV export is available with `ledger.export_csv(path)`.

Use one database per research dataset or process. Do not share one SQLite connection concurrently across worker threads. Back up the database before changing schema or running destructive maintenance.

Example:

```python
from python.autopsy_research.shock_outcomes import ShockEventLedger, ShockOutcomeTracker

ledger = ShockEventLedger("research/shock_events.sqlite")
tracker = ShockOutcomeTracker((1, 3, 5, 10), ledger=ledger)

# Call once per completed bar, in chronological order, per instrument/timeframe.
# snapshot is the Python ShockDNASnapshot object.
outcomes = tracker.update(
    symbol="XAUUSD", timeframe="M15", timestamp=bar_timestamp_unix,
    open_price=o, high=h, low=l, close=c, snapshot=snapshot,
)
ledger.export_csv("research/shock_outcomes.csv")
ledger.close()
```

For an MQL5 `SAxShockDNASnapshot` serialized as a dictionary, call `tracker.update_mql5(..., snapshot_payload=payload)`. The adapter explicitly maps shock-state values 0-8, regime values 0-8, transmission-state values 0-7, validity, quality, confidence and optional cross-asset confirmation. The source enum order is checked against `ShockDNAEngine.mqh`, `RegimeClassifierEngine.mqh` and `InformationTransmissionEngine.mqh`. The EA itself remains unwired; this adapter does not imply that MQL5 snapshots are being emitted or transported.

## Statistical report

Run:

```bash
python -m python.autopsy_research.shock_outcome_report research/shock_events.sqlite \
  --output research/shock_summary.csv \
  --bootstrap-iterations 5000 \
  --cluster-timezone UTC
```

The report groups by symbol, timeframe, horizon, direction, onset regime and onset severity bucket. It reports counts, mean/median directional return, win rate, mean MFE/MAE, and a 95% event-day cluster-bootstrap interval for mean directional return. Change the timezone to the relevant market session timezone where appropriate.

The bootstrap resamples event-day clusters, not individual rows, to reduce same-day dependence. It does not fully correct for overlapping multi-day event windows, serial dependence, regime selection, multiple testing, survivorship bias or non-stationarity. Treat intervals as descriptive research, not proof of a tradable edge. Require walk-forward and untouched out-of-sample validation, and report costs and instrument-specific contract economics separately before making any trading decision.

## Data and integration safeguards

- Only completed bars should be supplied.
- A snapshot timestamp, when present, must match the bar timestamp.
- Bad OHLC, bad quality flags, duplicate timestamps and out-of-order timestamps are rejected.
- Invalid observations advance the timestamp watermark but do not advance active event horizons.
- Different symbol/timeframe streams have independent watermarks and event clocks.
- An event begins only on a valid, data-quality-approved ONSET snapshot with direction +/-1 and persistence bar 0.
- Outcomes are measured from the event bar close using subsequent completed bars only. Event-bar wicks are excluded.
- Results are gross price-only returns. No bid/ask, commission, slippage, financing, swap, synthetic-index contract multiplier or currency conversion is modeled.

## Acceptance boundary

Python reference tests and CI validate the research ledger and adapter contract only. They do not compile MQL5, prove parity of a running EA, verify broker feeds, or establish profitable performance. Native MetaEditor compilation and MT5 Strategy Tester/replay remain separate validation steps. No output from this module changes EA entries, sizing, permissions, risk reservations or execution.
