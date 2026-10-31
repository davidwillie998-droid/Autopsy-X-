# FlipDemon Extreme HFT: Per-Symbol Analysis Contexts

Status: **FOUNDATION IMPLEMENTED / MULTI-SYMBOL EXECUTION NOT WIRED**

## What this phase adds

`MQL5/Include/AutopsyX/PerSymbolAnalysisContext.mqh` introduces an independently owned context for one broker symbol.

Each context owns its own:

- `CMarketData` tick buffer and symbol metadata.
- `CMomentumEngine` state.
- `CMicrostructureEngine` state.
- `CLiquidityEngine` structure and sweep state.
- Signal-timeframe `CRegimeEngine`.
- Higher-timeframe `CRegimeEngine`.
- `CSignalScorer`.
- `COrderFlowEngine` and `CFootprintEngine`, including independent CVD, rolling delta, absorption, per-bar price bins and stacked-imbalance history.
- `CVolumeProfileEngine`, with context-local POC, VAH, VAL, value-area position and advisory bullish/bearish components.
- `CVWAPEngine`, with a rolling 240-bar VWAP read, closed-bar classification, 0.1 ATR deadband and explicit neutral/unavailable handling.
- `CHeatmapEngine`, with an independent Market Depth subscription, prior-book snapshot and wall-pressure state. Missing broker DOM is non-fatal and remains unavailable rather than fabricating a reading.
- `CSniperEngine`, with independent arm, pullback, resumption, timeout and anti-chase state. Its price thresholds are converted from points using this context's own `CMarketData.Point()`.
- Signal and higher-timeframe bar clocks.

The context initializes market data and indicator handles against its explicit symbol. Tick, bar, price, point, spread, ATR, regime and liquidity reads are symbol-keyed. It exposes a base score and symbol-specific context readings.

Order flow is classified from the context's own tick buffer. As the engine documentation states, this is tick-direction inference on quote-based FX/CFD feeds, not verified exchange aggressor-side trade data. Footprint consumes the same classified tick volumes and snapshots against the configured symbol-specific footprint bar clock. Volume Profile refreshes on the context signal-bar boundary using that symbol and timeframe. VWAP also reads that symbol and timeframe, uses closed bars for the rolling calculation, and classifies the last closed signal bar against VWAP. The current defaults are 120 Volume Profile bars with a 10-point bin and 240 rolling VWAP bars; these are analysis defaults, not broker-validated optimal settings.

## Deliberate qualification boundary

`EvaluateBaseScore()` is explicitly a base score, not a fully qualified trade candidate. It does not include the EA's entire existing execution qualification chain, including order-flow, footprint, volume-profile, heatmap, VWAP, sniper state, adaptive flip state, spread/session filters, H4/daily confluence policy, risk sizing, restart recovery, account campaign admission and broker execution preflight.

The base context therefore does **not** submit candidates to `COpportunityScanner` and does not place orders. Calling a partial signal "qualified" would bypass existing safety logic.

## Remaining work before routing a winning symbol

1. Migrate adaptive-flip state and complete per-symbol entry qualification and stop construction.
2. Build a bounded Market Watch context registry. Initialize, refresh, invalidate and release contexts safely as symbols are added or removed.
3. Feed only fully qualified and fresh candidates into the strongest-opportunity scanner.
4. Refactor the position manager, exit logic, trade journal, restart recovery and deal reconciliation to key state by symbol and broker position identifier/ticket.
5. Pass the selected symbol through every downstream sizing, broker preflight, execution and management call. Re-run account-wide and campaign-risk admission immediately before each order.
6. Add MT5 Strategy Tester cases for multiple simultaneous symbols, stale quotes, history gaps, symbol removal, restart recovery and cross-symbol open-risk changes.

## Safety boundary

The EA's execution mode remains `AX_EXEC_ANALYSIS_ONLY`. This phase does not alter order routing, does not remove the hedging-account restriction, and does not enable pyramiding. Existing chart-symbol execution remains unchanged until the full per-symbol pipeline and manager have been migrated and tested.

## Verification

The added Python tests validate reference isolation behavior and source contracts. They do not execute MQL5 indicator handles, broker feeds or order operations. MetaEditor compilation, Strategy Tester and demo-forward verification remain mandatory and are not claimed as completed.
