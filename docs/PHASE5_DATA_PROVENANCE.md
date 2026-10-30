# Phase 5: Data Provenance

## XAUUSD

- **Provider:** Alpha Vantage, tool `GOLD_SILVER_HISTORY`, `symbol=XAU`, `interval=daily`.
- **Retrieved:** this session (2026-09-28), saved verbatim to
  `research/information_value/data/xauusd_daily_raw_alphavantage.json`.
- **Schema:** `{"nominal": "XAUUSD", "data": [{"date": "YYYY-MM-DD", "price": <float>}, ...]}`.
  **No OHLC** — a single price per calendar day only.
- **Coverage:** 5,408 rows, 2011-06-01 to 2026-09-27.
- **Timezone:** not stated by the provider; treated as date-only (no intraday timestamp).
- **Quality checks run:**
  - Zero duplicate dates, zero non-positive prices.
  - Price range $1,050.73–$5,477.79 — plausible for the stated period.
  - **1,410 of 5,408 rows (26%) are dated on a Saturday or Sunday.** FX markets (and,
    conventionally, most spot-gold desks) don't publish genuine Saturday/Sunday closes.
    Checked explicitly: Saturday prices show a small genuine drift from the preceding
    Friday (not an exact carry-forward), and **Sunday prices are then bit-for-bit
    identical to the adjacent Saturday** in every case checked. This pattern (a smooth,
    small weekday→Saturday step, then a flat Saturday→Sunday plateau) is consistent
    with an interpolated/smoothed daily series constructed by the provider, not a raw
    record of executed trades. **This is a documented limitation, not a raw
    market-microstructure record.**
- **Consequence for this research:** any close-to-close return statistic (autocorrelation,
  directional persistence, reversal frequency — all used by `VolatilitySerialityEngine`'s
  own genuinely-new metrics) computed naively across all 5,408 rows would have an
  artificial component from the interpolation itself, especially around the Fri→Sat→Sun
  seam. **Mitigation applied:** all return-based analysis in this phase filters to
  weekday-dated rows only (Mon–Fri), discarding the 1,410 weekend rows before computing
  any return series.
- **No OHLC consequence:** `CVolatilityEngine`'s ATR and `ShockDNAEngine`'s
  `onset_magnitude_atr`/`range_expansion_atr` are true-range-based (need high/low). This
  series cannot faithfully supply them. **Shock DNA and true-ATR volatility
  classification are NOT run against this real series in Phase 5** — approximating ATR
  from a close-only, weekend-interpolated series would silently test a different,
  unlabeled statistical object under the engine's real name. Those two layers remain
  synthetic-validated only pending a genuine OHLC XAUUSD source.

## EUR/USD

- **Provider:** Alpha Vantage, tool `FX_DAILY`, `from_symbol=EUR`, `to_symbol=USD`,
  `outputsize=full`.
- **Retrieved:** this session (2026-09-28), saved verbatim to
  `research/information_value/data/eurusd_daily_raw_alphavantage.json`.
- **Schema:** genuine OHLC — `{"Time Series FX (Daily)": {"YYYY-MM-DD": {open, high,
  low, close}, ...}}`.
- **Coverage:** 5,000 rows, 2007-07-27 to 2026-09-25. Timezone: UTC (stated in the
  response's own Meta Data).
- **Quality checks run:** `low ≤ open ≤ high`, `low ≤ close ≤ high`, all prices > 0 —
  **0 inconsistent rows out of 5,000.** Zero weekend-dated rows (correctly
  weekday-only, unlike XAU above).
- **Why EUR/USD specifically:** the live EA has no hardcoded Information Transmission
  leader/receiver symbol (Phase 4A was built generically and was never wired into the
  EA), so there is no "already-required" pair to defer to. EUR/USD was chosen as the
  single most liquid FX pair and the most commonly cited USD-strength proxy discussed
  alongside gold — not because it's guaranteed correct, and not as license to add
  further unrelated instruments.

## Joint sample

- Overlapping weekday dates between the two series (after the weekend filter above):
  **3,997 shared trading days**, spanning the full XAU coverage window. This is the
  usable joint sample for any cross-asset (Information Transmission) analysis.

## What this data source honestly supports vs. does not

| Analysis | Real-data feasible? |
|---|---|
| Close-to-close log-return statistics (autocorrelation, directional persistence, reversal frequency — `VolatilitySerialityEngine`'s genuinely-new metrics) | **Yes**, weekday-filtered |
| Regime-style trend/momentum descriptors built from closes only | **Yes, partially** — no true ATR-based structural-break/erratic detection |
| Information Transmission (lag-correlation between two return series) | **Yes** — needs only returns |
| `CVolatilityEngine` real ATR / percentile / acceleration classification | **No** — needs true range |
| Shock DNA onset detection / lifecycle (`onset_magnitude_atr`, `range_expansion_atr`) | **No** — needs true range |

## Reproducibility

Both raw files are committed under `research/information_value/data/` exactly as
retrieved (not re-derived), so the pipeline can be re-run deterministically from them
without hitting the API again.
