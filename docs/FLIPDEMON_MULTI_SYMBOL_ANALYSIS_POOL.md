# Multi-symbol analysis pool

## Purpose
`CMultiSymbolAnalysisPool` orchestrates a bounded set of independent `CSymbolAnalysisSlot` instances using candidates from `CMarketScanner`. The pool defaults to eight symbols and hard-limits the configured count to 32.

## Behavior
- Consumes scanner candidates in their supplied order (currently relative spread order).
- Initializes per-symbol analysis state and updates each active slot.
- Exposes per-symbol results and a helper that selects the valid directional proposal with the highest confidence.
- The selected proposal is an analytical candidate only; it is not account-risk approval or an order instruction.

## Limitations and known risks
- This module is not wired into the main EA's event loop.
- Current scanner ordering is spread-based, not edge-based. Symbols near the top of the spread ranking can change between refreshes, causing slots to be re-created and their tick history to reset. A stable membership policy / refresh cadence should be added before meaningful forward evaluation.
- Confidence is a heuristic derived from the existing score engine, not a calibrated probability of success.
- The existing scoring rules have not been validated across brokers or synthetic families.
- The module does not calculate stop-risk, portfolio correlation, margin impact, or authorize orders.
- MetaEditor compilation, Strategy Tester checks, and broker-demo validation are still required.
