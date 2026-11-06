# Order-flow CVD divergence integration

## What changed

`COrderFlowEngine` now compares two adjacent halves of its existing 50-tick rolling window. It flags:

- **Bullish divergence:** the recent half makes a meaningfully lower price low, while its normalized signed-volume delta is at least 0.15 stronger than the older half.
- **Bearish divergence:** the recent half makes a meaningfully higher price high, while its normalized signed-volume delta is at least 0.15 weaker than the older half.

A meaningful price extension is the greater of 1.5 times the current spread or 2 points. Each half must contain at least five direction-classified ticks. The divergence contributes up to 25 points to the existing 0-100 order-flow component, which is already blended as an advisory score bonus. It does not independently authorize an entry, bypass the regime gate, or change risk sizing.

The feature is controlled by `InpUseCvdDivergence` and defaults to enabled. Set it to false to retain the previous order-flow score behavior.

## Data limitations

The engine classifies tick direction from changes in MT5 mid-price and weights those ticks with the broker-provided volume field (or the existing per-tick fallback). This is not exchange-traded aggressor-side CVD. It is a short-horizon proxy, and its thresholds are engineering defaults, not values validated across XAUUSD, FX CFDs, or synthetic indices.

The existing session CVD and absorption calculations remain unchanged. This addition does not claim that resting DOM orders are executed volume, nor does it use fixed futures-contract imbalance thresholds.

## Validation still required

- MQL5 compile in MetaEditor.
- Unit or deterministic fixture tests for both divergence directions, no-extension cases, insufficient directional samples, and flat/zero-volume ticks.
- MT5 Strategy Tester review across each instrument class and broker feed.
- Out-of-sample comparison with the feature enabled and disabled, including spread, commission, slippage, drawdown, and trade-count effects.

No profitability claim is made.