# FlipDemon Extreme HFT — Adaptive Aggressive Compounding Specification

Status: **DESIGN / NOT YET WIRED INTO THE EA**  
Execution default: `AX_EXEC_ANALYSIS_ONLY` (must remain unchanged).  
Scope: MT5 FX, metals, and broker-provided CFDs/synthetics where the broker supplies valid contract, volume, stop and margin metadata.

## Objective

Scale position size in response to account equity and verified continuation opportunities, while enforcing hard per-entry, campaign, account, drawdown, margin and broker constraints. Account flipping is a research objective, not a promised outcome and never overrides risk gates.

## Current-source constraints that must be resolved before activation

- `InpExecutionMode` currently defaults to `AX_EXEC_ANALYSIS_ONLY`; preserve this.
- Existing `CRiskEngine::CalculateLotSize` already sizes from equity and a configured risk percentage, so ordinary percentage sizing compounds naturally.
- The current defaults include `InpMaxOpenPositions=1`, `InpMaxPositionsPerSymbol=1`, and `InpMaxExposureLots=1.0`. These prevent the intended multi-add campaign in their current configuration. Do not simply raise these limits: implement and test campaign-level aggregate-risk accounting first.
- `CMarketData::NormalizeVolume` rejects a raw size below broker minimum rather than rounding it up. Preserve this behavior.
- The existing EA has a hard risk-engine ceiling of 2% per entry. Retain 2% as the absolute per-entry ceiling; configure a lower default for small-account deployment.
- MQL5 compilation, broker-specific contract validation, and Strategy Tester verification are outstanding. This document and the Python reference tests do not establish EA readiness.

## Sizing policy

### Inputs (all validated at initialization)

- `InpBaseRiskPercent`: default 0.50% of current equity per initial entry.
- `InpMaxRiskPercentPerEntry`: hard-capped at 2.00%; no input may raise the ceiling.
- `InpMaxCampaignRiskPercent`: default 2.00% of current equity for the sum of remaining stop-risk across all campaign entries, including the proposed addition.
- `InpMaxAccountOpenRiskPercent`: default 4.00% of equity across all positions controlled by the EA. Existing account-wide loss, daily/weekly loss, margin, position-count and lot caps remain independently active.
- `InpProgressiveSizingEnabled`: true for analysis calculations; this does not authorize orders while execution mode is ANALYSIS_ONLY.
- `InpMaxProgressiveMultiplier`: 1.50 maximum risk multiplier from equity growth; this multiplier is still subject to the 2% per-entry cap and campaign/account risk caps.
- `InpMinEquityForSizing`: configurable minimum equity. If equity is lower or unavailable, no trade.
- Broker minimum lot, maximum lot, volume step, tick/contract metadata and margin calculation are read live from the symbol; never hard-code a universal minimum lot.

### Step A — compute baseline risk

1. Require finite positive equity, a valid entry price, a valid protective stop, a valid direction, and complete symbol contract metadata.
2. Obtain the estimated one-lot loss from entry to stop in account currency using broker-aware calculation (prefer `OrderCalcProfit` for one lot). If calculation fails or is non-finite/non-positive, reject sizing.
3. Baseline risk budget = current equity × base risk percent / 100.
4. Raw lots = baseline risk budget / one-lot stop loss.
5. Never use leverage as a sizing multiplier. Leverage affects margin requirements, not the monetary loss at the stop.

### Step B — progressive equity factor

Progression is permitted only when equity is above the persisted equity high-water mark and the current entry is a fresh qualifying continuation setup. No size increase after a loss, no averaging down, and no increase solely because a position is temporarily profitable.

Use realized account-equity growth above a persisted starting-equity baseline for the first version; do not use floating PnL alone to unlock a higher tier. Suggested bounded tiers:

| Realized equity growth from sizing baseline | Growth multiplier |
|---|---:|
| Below 10% | 1.00 |
| 10% to below 25% | 1.10 |
| 25% to below 50% | 1.20 |
| 50% or more | 1.35 |

The multiplier is configurable but bounded at 1.50. Apply drawdown and risk gates after this multiplier. Persist the baseline/high-water mark across restarts; fail closed if persisted state is malformed or inconsistent.

Effective entry risk percent = min(base risk percent × growth multiplier × drawdown multiplier, configured per-entry risk cap, absolute 2.00% cap). The drawdown multiplier is 1.00 in NORMAL, 0.65 in CAUTION, 0.30 in DEFENSIVE, and 0.00 in LOCKED. Existing AFE gates may impose stricter limits and must never be bypassed.

### Step C — small-account / broker minimum handling

1. Calculate raw lots from the effective risk budget and the broker-calculated one-lot stop loss.
2. Normalize downward to the broker's valid volume step; never round upward.
3. If raw lots are below broker minimum, return zero and record `REJECT_MIN_LOT_EXCEEDS_RISK_BUDGET`. Do not force a minimum lot even if the user wants aggressive growth.
4. If the stop-risk for broker minimum lot exceeds the allowed per-entry risk, reject the trade. If the broker's contract metadata or profit calculation is unavailable, reject.
5. Cap by broker maximum, configured order-lot ceiling, remaining account gross-lot allowance and available margin. Any final cap must be re-normalized downward and rechecked against all risk limits.
6. Use broker-aware margin estimation for the proposed order and reject if projected margin usage/free margin would breach the existing limits.

### Step D — pyramiding / campaign sizing

- Each add requires a *new* qualifying continuation event, not repeated ticks from the same signal.
- Preserve the discussed maximum of 10 entries per campaign as a ceiling, not a target.
- Before every add, recompute the remaining monetary stop-risk for every open campaign leg using current stops and actual volumes; include the proposed leg's stop-risk. Reject if total campaign risk would exceed `InpMaxCampaignRiskPercent`.
- Also enforce account-wide open-risk, gross-lot, directional-lot, margin, daily/weekly loss, spread, execution-quality, AFE and recovery gates.
- Never add to a losing campaign (no averaging down). A proposed add is allowed only if the campaign is in a valid continuation state and meets the configured profit/protection requirement. A profitable floating position alone is insufficient.
- If an existing stop is absent, invalid, farther from the expected direction, or cannot be verified, block additions. Never assume a stop guarantees maximum loss; gaps and slippage remain possible.
- On netting accounts, reconcile the aggregated broker position against individual campaign legs/deals; do not pretend that the broker position is one independent leg. If accurate leg attribution cannot be reconstructed after restart, block additions and preserve existing-position management.

### Step E — exit / drawdown overrides

- Risk controls always override the growth target.
- In CAUTION, reduce the risk budget; in DEFENSIVE, reduce further; in LOCKED, no new entry or pyramid add.
- Daily/weekly loss lockouts, account kill switch, unverified restart recovery, invalid deal history, margin limits and execution-quality kill switches block additions regardless of score.
- A target-equity milestone never forces a trade or changes a stop to permit more exposure.

## Required implementation sequence

1. Add a single pure sizing policy helper and unit tests for its math and fail-closed cases.
2. Integrate the helper as the only authority for initial-entry and add-on lots. Remove any competing multipliers or ensure they are folded into the same bounded risk calculation.
3. Add campaign ledger/recovery capable of tracking each entry deal, volume, stop-risk, and unique continuation signal id across netting/hedging behavior. A restart must reconcile against broker history before additions resume.
4. Add a dashboard explanation of the proposed size and every cap/rejection reason.
5. Keep execution mode ANALYSIS_ONLY. Run source tests, then MetaEditor compile, deterministic Strategy Tester cases, multi-symbol broker contract checks, walk-forward tests, and demo soak tests. Live execution remains a separate, explicit decision.

## Acceptance tests

- Invalid/non-positive equity, invalid stop, missing contract values or failed broker profit calculation -> zero lots.
- Small-account raw size below broker minimum -> zero lots; never round up.
- Valid raw size -> rounded down to broker volume step and never exceeds broker maximum.
- Effective risk cannot exceed configured per-entry cap or absolute 2.00%.
- Growth multiplier is 1.00 below 10% realized growth, then increases only at defined tiers and never exceeds 1.50.
- Growth progression never applies after a loss or without a fresh continuation setup.
- Drawdown multipliers reduce risk; LOCKED returns zero.
- Proposed add rejected when campaign/account aggregate risk would exceed limits, entry count reaches 10, signal id is reused, or campaign is losing/unprotected.
- Existing position can continue to be managed when recovery is uncertain, but new entries/additions remain blocked.
- Leverage changes must not increase the risk-sized lots when equity, entry, stop and contract economics are unchanged.
- ANALYSIS_ONLY remains the default and no order-send function is reached in that mode.
