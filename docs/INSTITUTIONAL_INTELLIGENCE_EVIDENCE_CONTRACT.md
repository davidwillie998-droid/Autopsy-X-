# AUTOPSY X Institutional Intelligence: Evidence Arbitration Contract

## Status

The first supervisory component is implemented as a compile-visible, observational module:

- `MQL5/Include/AutopsyX/EvidenceArbitrationEngine.mqh`
- Included by `AutopsyX_FlipDemon_Extreme.mq5`.
- No existing score, entry, execution, risk, or position-management path calls it yet.
- Its output is evidence balance, never a win probability or a permission to trade.

This staged integration is deliberate. The existing strategy remains the control group while the arbitration contract is reviewed and tested.

## Evidence record

Every source submits one `SAxEvidence` record containing:

| Field | Meaning |
|---|---|
| `sourceId` | Stable identifier for the producing engine/read |
| `independenceGroup` | Shared family for correlated or overlapping evidence |
| `direction` | BUY, SELL, or NONE |
| `status` | UNAVAILABLE, PROVISIONAL, or CONFIRMED |
| `quality` | Source-specific quality from 0 to 100 |
| `reliability` | Empirical reliability from 0 to 100; zero means not calibrated |
| `weight` | Normalized policy weight, 0 to 1 |
| `observedAt` | Timestamp of the underlying observation |
| `maxAgeSeconds` | Maximum allowed age; zero disables the age limit |
| `reason` | Human-readable evidence explanation |

Unavailable, invalid, future-dated, and stale evidence cannot vote. Provisional evidence receives half the confirmed status factor. An uncalibrated reliability value uses a neutral 0.5 factor, not a claimed historical hit rate.

## Arbitration rules

1. Evidence is grouped by `independenceGroup`. Related indicators do not receive separate full votes merely because several engines describe the same underlying market event.
2. Signed contributions inside a group offset one another. The resulting group contribution is capped to [-1, +1].
3. Independent group contributions are compared. Material opposing evidence produces WAIT.
4. A weak directional balance produces WAIT.
5. Only a sufficiently strong, non-conflicted balance returns BUY or SELL.
6. `directionalStrength` is a normalized evidence-balance diagnostic. It is not probability of profit, confidence calibration, expected value, or trade permission.

## Initial evidence-family mapping

This is a proposed mapping for the next adapter pass. It must be confirmed against each engine's actual output semantics before wiring.

| Independence group | Candidate sources | Role |
|---|---|---|
| HTF_DIRECTION | W1 institutional direction, D1 institutional direction | Directional context; preserve timeframe-specific disagreement |
| MARKET_STRUCTURE | Structure engine, H4 breakout | Confirmed structure and displacement |
| LIQUIDITY | Liquidity engine, daily extreme projection | Liquidity location and sweep context |
| VALUE_LOCATION | Premium/discount, dealing range | Location only |
| IMBALANCE | FVG, order block/breaker | Entry location, not standalone direction |
| ORDER_FLOW | CVD/order flow, footprint, volume profile, heatmap | Microstructure confirmation; avoid double-counting correlated feeds |
| SESSION | Advanced session ORB | Session context and breakout confirmation |
| EXECUTION | Spread/cost, quote freshness, fill quality | Execution suitability, not directional vote |

A source must not be assigned to a group solely because its name sounds similar. Correlation and shared underlying data determine grouping. HTF weekly and daily readings remain separate records so their conflict is visible, while their final aggregation policy is explicitly controlled.

## Safety boundary

The arbitration module has no broker API, no order submission method, no account-risk mutation method, and no authority over the distributed reservation coordinator. The existing account-wide risk controls remain independent and retain final veto authority.

The existing EA mode default and order-routing gates are unchanged by this commit.

## Required tests before decision-path integration

- Confirmed BUY evidence from independent groups resolves BUY.
- Confirmed SELL evidence from independent groups resolves SELL.
- Opposing independent groups above the configured conflict ratio resolve WAIT.
- Multiple same-group BUY sources do not multiply that group's maximum vote.
- Opposing sources inside one group offset rather than creating false independent conflict.
- Provisional evidence is discounted relative to confirmed evidence.
- Stale, future-dated, unavailable, and invalid records do not vote.
- Empty evidence set resolves WAIT.
- Zero/uncalibrated reliability does not masquerade as measured performance.
- Directional strength is never labelled as probability.
- Existing entry output is byte-for-byte/decision-for-decision unchanged while the module is observational.

## Next integration gate

Build adapters from actual engine outputs into evidence records, preserving timestamps, confirmation state, timeframe and source provenance. Then run deterministic historical replay in shadow mode and compare supervisor decisions against the existing EA decisions. Do not route the supervisor into entries until replay, edge calibration, and risk-boundary regression tests are complete.
