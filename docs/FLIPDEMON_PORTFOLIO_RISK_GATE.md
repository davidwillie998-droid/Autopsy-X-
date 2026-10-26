# Portfolio risk gate (first integration contract)

## Status
\`CPortfolioRiskGate\` is a new, standalone, fail-closed pre-trade gate. It is **not wired into the EA event loop** and does not place, modify, or close orders. It does not replace \`CRiskEngine\`, \`CEntryEngine\`, drawdown/loss locks, or final execution confirmation.

## Current behavior
- Defaults to a maximum projected stop-loss risk of 0.5% of current equity and maximum projected margin usage below 30%.
- Requires a valid market BUY/SELL candidate, positive entry and stop, and stop-loss on the loss side of entry.
- Checks current broker min/max/step volume metadata.
- Uses \`OrderCalcProfit\` to estimate the monetary stop-loss and rejects estimates above the configured risk ceiling; calculation failure blocks entry.
- Defaults to requiring a flat account, consistent with the current one-position-at-a-time constraint.
- Always blocks while any pending order exists because pending-order risk is not reconstructed by this first version.
- Uses \`OrderCalcMargin\` and current free/used margin to reject insufficient free margin or projected usage at/above the configured ceiling.
- Does not assume high broker leverage makes exposure safe.

## Important limitations
- The gate is a conservative first layer, not a complete portfolio optimizer.
- When flat-account mode is explicitly disabled, existing positions are not yet aggregated into a stop-risk budget. Do not disable it until portfolio aggregation is implemented and tested.
- It does not identify ownership of positions or pending orders; in default mode it conservatively treats any account position as a blocker.
- It does not yet account for commissions, swaps, gaps, slippage, correlated instruments, or stop-loss execution uncertainty.
- It is not connected to the main EA and must not be treated as trade authorization.
- Static tests are not a substitute for MetaEditor compilation, Strategy Tester, and broker demo validation.

## Required before integration
1. Inspect and reconcile the EA execution mode/default (the current EA source has \`InpMode = AX_MODE_AGGRESSIVE\`; do not infer analysis-only from documentation).
2. Compile in MetaEditor and fix all MQL5 API/compiler issues.
3. Add account-wide tests for positions, pending orders, invalid stop data, broker volume steps, projected risk, and projected margin.
4. Wire the gate only after those checks pass, immediately before existing final execution confirmation, while preserving all existing risk controls.
5. Keep live execution disabled until Strategy Tester and broker-demo evidence are reviewed.
