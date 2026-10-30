# FlipDemon Extreme HFT: Strongest Opportunity Selection

Status: **RANKING COMPONENT IMPLEMENTED / FULL MULTI-SYMBOL EXECUTION NOT YET WIRED**

## Implemented

`MQL5/Include/AutopsyX/OpportunityScanner.mqh` provides a deterministic selector for candidates submitted by per-symbol analysis contexts.

The selector:

- Accepts only candidates explicitly marked qualified by their complete symbol-specific signal pipeline.
- Rejects invalid direction, non-finite score/confidence/spread, negative spread, stale timestamps and future timestamps.
- Retains a shortlist of one to five candidates.
- Ranks by signal score, then confidence, then lower spread, then symbol name for deterministic ties.
- Returns exactly one strongest candidate for the current scan cycle.
- Replaces an existing symbol candidate rather than creating duplicates.

The component does not calculate a signal, subscribe to symbols, size a trade or send an order. This is deliberate. It must not turn a lightweight indicator prefilter into an execution-authorizing signal.

## Critical integration blocker

The current EA still owns one global `CMarketData`, one set of signal engines, one `CExecutionEngine`, and one `SAxPositionState`. The live entry and position-management paths contain extensive `_Symbol` assumptions. The existing entry pipeline also uses symbol-specific global state for ATR, VWAP, microstructure, order flow, footprint, volume profile, stops, restart recovery and position accounting.

Feeding scores from other symbols into this global engine would mix market state and could calculate a valid-looking signal with the wrong symbol's prices or broker metadata. The scanner is therefore not yet connected to order submission.

## Next required refactor

1. Create a per-symbol context owning market data, regime, momentum, liquidity, microstructure, VWAP, order-flow and signal-score state.
2. Run the complete existing qualification pipeline independently for every selected Market Watch symbol.
3. Submit only fully qualified, fresh candidates to `COpportunityScanner`.
4. Pass the single winner's symbol and context through sizing, stop construction, broker checks, execution, position management, recovery and journaling.
5. Re-run account-wide and campaign-risk admission immediately before every order.
6. Add Strategy Tester coverage for simultaneous candidates, stale data, symbol removal, quote outages, correlated positions and restart recovery.

Until steps 1-5 are complete, the scanner is a tested selection component only. The EA remains chart-symbol execution, and no cross-symbol order routing is enabled.
