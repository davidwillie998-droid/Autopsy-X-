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
- Scanner ordering is spread-based, not edge-based. The pool now retains existing symbols while they remain eligible anywhere in the scanner candidate list, and fills open slots by current scanner rank. A symbol is still removed if it fails eligibility, so refresh cadence and membership churn must be measured during demo testing.
- Confidence is a heuristic derived from the existing score engine, not a calibrated probability of success.
- The existing scoring rules have not been validated across brokers or synthetic families.
- The module does not calculate stop-risk, portfolio correlation, margin impact, or authorize orders.
- MetaEditor compilation, Strategy Tester checks, and broker-demo validation are still required.
