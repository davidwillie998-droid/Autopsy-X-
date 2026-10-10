# 04. Signal Specification

Every rule below is a starting hypothesis with a config key. None is validated. Values quoted are defaults from `config/default.toml`.

## 4.1 Move classification (`detection/move.py`)

**Source:** closed 1-minute bars built from swaps. **Frequency:** every closed bar. **Lookback:** `move.baseline_bars` (1440).

For each window `n ∈ {1, 3, 5, 15, 30, 60, 240, 1440}`:

```
r_n      = ln(close_t / close_{t-n})
hist_n   = { r_n at t-n, t-n-n/4, ... }  (up to baseline_bars samples, all strictly before the current window)
z_n      = (r_n - median(hist_n)) / (1.4826 * MAD(hist_n))
```

`abnormality = max_n |z_n|`, the driving window is its argmax, direction is the sign of that z.

| Class | abnormality |
|---|---|
| UNCLASSIFIED | no window has `min_baseline_samples` (60) history |
| NORMAL | < 2.0 |
| WATCH | ≥ 2.0 |
| UNUSUAL | ≥ 3.0 |
| SIGNIFICANT | ≥ 4.5 |
| EXTREME | ≥ 6.5 |

**Onset.** `t* = argmax_t  dir * ln(close_now / close_t) / (σ₁ * sqrt(now - t))` over the last 240 bars: the start point that makes the current run most statistically significant. Uses only past bars.

**Volume-only anomaly.** Price class ≤ WATCH while some window's volume z ≥ 4.5. Reported, not signalled; this is the pattern wash trading produces before price responds.

**Failure mode.** Newly launched tokens are UNCLASSIFIED until they have history. This is deliberate: the system does not pretend to know what is abnormal for a coin it has watched for ten minutes. A cohort baseline (distribution of same-age tokens) is the planned remedy and a research item (doc 14, H-aux-1).

**Test.** `test_big_moves_classified_relative_to_own_history`, `test_onset_located_near_true_start`.

## 4.2 Move Quality (`detection/move_quality.py`)

```
support  = Σ w_i c_i / Σ w_i     over components with data
penalty  = Σ p_j q_j / Σ p_j     over penalties with data
MQ       = support - penalty     ∈ [-1, 1]
coverage = observed weight / total weight
```

| Component | c ∈ [0,1] | Default weight |
|---|---|---|
| price_momentum | squash(max(z,0), 4.5) | 1.0 |
| volume_confirmation | squash(max(volume_z_15,0), 3) | 1.0 |
| wallet_participation | squash(max(ln buyer_growth,0), 1) × independence_ratio | 1.0 |
| liquidity_confirmation | squash(max(Δliquidity,0), 0.10) | 1.0 |
| market_breadth | max narrative breadth | 0.5 |
| catalyst_confirmation | catalyst score (4.6) | 0.5 |
| cross_venue_confirmation | share of venues agreeing on direction | 0.5 |

| Penalty | q ∈ [0,1] | Weight |
|---|---|---|
| manipulation_risk | manipulation score | 1.5 |
| concentration_risk | top-10 wallet share of buy volume | 1.0 |
| liquidity_risk | squash(slippage, max_slippage) | 1.0 |

`squash(x, s) = 1 - e^(-x/s)`. Missing components are excluded, never scored as zero; `coverage` reports how much of the model actually saw data. The weights are placeholders until H10's ablation study sets them.

## 4.3 Regime (`regime/classifier.py`)

Priority order; first match wins; every match is recorded.

| Regime | Rule (all conditions) |
|---|---|
| DEAD_ILLIQUID | liquidity < $5k or < 5 trades in the last hour |
| COLLAPSE | 1h return ≤ -35% and (liquidity falling or 15m sell imbalance < -0.2) |
| PARABOLIC | up-move with abnormality ≥ 6.5 and positive 5m and 15m acceleration |
| DISTRIBUTION | within 10% of 4h high, 15m imbalance < -0.1, largest wallets or creator net selling |
| REVERSAL | 4h log return > 0.2 while 15m z ≤ -3 |
| BREAKOUT | close above prior 60-bar high with 15m volume z ≥ 2 |
| EXPANSION | 1h and 4h positive, buyer growth > 1, 1h z ≥ 2 |
| ACCUMULATION | 1h |z| < 2, 15m buy imbalance > 0.1, holders rising |
| NEUTRAL | nothing matched |

## 4.4 Exhaustion (`signals/exhaustion.py`)

Flags: parabolic acceleration; new-wallet velocity < 1 during an up-move; top-10 holders > 60%; liquidity down > 5%; largest wallets net selling; 15m volume z > 6 with negative acceleration (climax); mention velocity > 5 while effective-author velocity < a third of it (frenzy); reference-trade slippage > 3%; ≥ 4 of last 10 bars with dominant upper wicks; 15m imbalance < -0.25.

| State | Rule |
|---|---|
| DISTRIBUTION | regime DISTRIBUTION matched |
| EXHAUSTION_RISK | ≥ 4 flags |
| EXTENDED | ≥ 2 flags |
| HEALTHY_EXPANSION | otherwise |

## 4.5 Entry signal (`signals/entry.py`)

Conditions, each `passed ∈ {true, false, unknown}` with evidence text:

| # | Condition | Pass rule | Veto |
|---|---|---|---|
| 1 | abnormal_momentum | up-move, class ≥ UNUSUAL | |
| 2 | accelerating_volume | 15m volume z ≥ 2 and volume acceleration > 1 | |
| 3 | expanding_liquidity | Δliquidity ≥ 0 | |
| 4 | independent_wallet_growth | buyer growth > 1.5 and independence ratio ≥ 0.6 | |
| 5 | catalyst | NEWS_FIRST or SIMULTANEOUS, confirmed, direction consistent | |
| 6 | narrative_strength | a specific narrative EMERGING or ACCELERATING | |
| 7 | low_manipulation | manipulation score ≤ 0.4 | yes |
| 8 | creator_concentration_ok | creator holds ≤ 15% | yes |
| 9 | healthy_structure | HEALTHY or EXTENDED, regime not DEAD/COLLAPSE/DISTRIBUTION | yes |
| 10 | execution_liquidity | liquidity ≥ $50k and est. slippage ≤ 2% | yes |
| 11 | follower_independent_confirmation (followers only) | own wallet growth and liquidity confirm | yes |

**Output type:**

* `NO_SIGNAL` when any blocking failure mode is present (`NO_DATA, STALE_DATA, CONFLICTING_DATA, API_FAILURE, EXECUTION_UNAVAILABLE, LOW_LIQUIDITY`), a veto failed, a veto input is unknown, or Move Quality coverage < 0.7.
* `HIGH_CONVICTION_CONTINUATION` when not blocked, condition 1 passes, and ≥ 6 conditions pass.
* `WATCH` for an unblocked up-move at WATCH class or better that does not reach the bar.

**Required fields** (all present in `Signal.to_dict()`): TOKEN, CHAIN, TIMESTAMP, CURRENT_PRICE, MOVE_PERCENT, VOLUME_ACCELERATION, LIQUIDITY, WALLET_GROWTH, NEWS_CATALYST, NARRATIVE, MANIPULATION_RISK, REGIME, SIGNAL_SCORE, CONFIDENCE, INVALIDATION, RISK_FLAGS, plus the full condition list and `blocked_by`.

**Invalidation:** price below the move's onset close; liquidity down 15% from entry; independence ratio below 0.4; any creator selling. Any one ends the thesis.

## 4.6 Catalyst score

`base(timing) × credibility`, zero when the event's expected direction contradicts the move. `base`: NEWS_FIRST 1.0, SIMULTANEOUS 0.6, MOVE_FIRST 0.25, else 0. Unconfirmed stories cap credibility at 0.3.

## 4.7 Confidence

`confidence = agreement × coverage`, where agreement is the share of evaluable conditions that passed. This is **not a probability**. It becomes one only after calibration against journal outcomes (reliability curve per doc 08); until then the field carries `confidence_note: "uncalibrated"`. NO_SIGNAL carries no confidence at all.

## 4.8 Exit (`signals/exit.py`)

| Action | Triggers |
|---|---|
| EMERGENCY_EXIT | liquidity down ≥ 30% since entry; creator-linked selling ≥ 5% of observed position; confirmed exploit or delisting |
| EXIT | liquidity down ≥ 15%; liquidity unobservable; price at invalidation; regime COLLAPSE / DISTRIBUTION / DEAD; exhaustion DISTRIBUTION |
| REDUCE | two or more of: reversal regime, exhaustion risk, large-wallet outflow, volume below 0.3x baseline, mentions below 0.5x baseline, narrative decaying, market risk-off |
| HOLD | otherwise, with remaining soft warnings listed |

Every decision returns its reasons. H7 tests whether the liquidity triggers beat a fixed percentage stop.
