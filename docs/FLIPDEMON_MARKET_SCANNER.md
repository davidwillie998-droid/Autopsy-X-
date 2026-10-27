# Flipdemon quote-quality scanner

`MQL5/Include/AutopsyX/MarketScanner.mqh` adds a scan-only layer on top of
`CBrokerUniverse`.

## What it does

- Filters out symbols with invalid/disallowed contract metadata.
- Supports only recognised forex, gold, and synthetic families; unknown names
  are excluded pending explicit provider mapping.
- Requires a valid current bid/ask and a quote within the configured age limit.
- Requires a positive relative-spread limit and rejects quotes above it.
- Optionally requires the symbol to be selected in Market Watch.
- Returns candidates ordered by relative spread (lowest first), including
  quote and contract metadata.

## What it does not do

This is quote-quality screening only. It does not generate a buy/sell signal,
validate strategy performance, calculate trade risk, authorise an order, or
send trades. Low spread is not a directional edge. Relative spread is a
portable first-pass filter, not a replacement for instrument-specific spread,
commission, slippage, stop-distance, and volatility calibration.

## Integration gates

Before this is connected to any execution path:
1. Add per-symbol price/indicator state and symbol-specific history warm-up.
2. Calibrate quote-age and spread limits by instrument family and broker.
3. Rank candidates only after a strategy module produces a valid setup score.
4. Send every proposed trade through the single account-wide risk coordinator.
5. Test Strategy Tester and broker demo behaviour, including stale ticks,
   disabled symbols, rejected orders, disconnects, and changing contract specs.

Keep the EA in `ANALYSIS_ONLY` during this work. This scanner cannot place trades.
