# FlipDemon Extreme: per-symbol analysis slot

## Purpose
`CSymbolAnalysisSlot` owns independent market-data, momentum, microstructure, liquidity, regime and scoring engine instances for one broker-discovered symbol. It is intended to be composed by a future multi-symbol analysis pool.

## Output
Each update exposes the symbol, timestamp, validity, buy/sell scores, proposed direction, confidence, regime, current quote, and spread. The proposed direction is an analytical result only; it is not an order instruction or a risk approval.

## Fail-closed behavior
- A slot must initialize successfully for its own symbol.
- Missing ticks or an unsafe regime yield an invalid result and no proposed direction.
- Liquidity levels and regime are refreshed on a new timeframe bar; the first update attempts an initial refresh.
- No trade-send or position-management API is called by this module.

## Important limits
- This module is not yet wired into the main EA or the broker scanner.
- A shared ranked pool, account-wide risk arbitration, symbol-family-specific signal calibration and execution integration remain future work.
- The current score engine's weights and thresholds were not validated across synthetic indices or brokers. A score is not evidence of positive expectancy.
- Static source tests do not replace MetaEditor compilation, Strategy Tester tests or broker demo validation.
