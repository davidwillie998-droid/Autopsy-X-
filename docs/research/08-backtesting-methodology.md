# 08. Backtesting Methodology

A memecoin backtest that ignores fill reality measures the author's optimism. The engine (`backtest/engine.py`) is built around the failure modes, and every run records dataset version, config fingerprint and code version.

## Bias controls

| Bias | Control |
|---|---|
| Look-ahead | Decisions at t read only `store.view(t)` (records with `seen_ts ≤ t`). Only closed bars. Tested: adding future data leaves the assessment byte-identical |
| Timestamp leakage | `seen_ts` is stamped by the ingestor. Historical data without a real ingestion time gets `seen_ts = ts + p95 provider latency` from the Phase 2 probe, never `seen_ts = ts` |
| Future-information contamination | Outcome data (news reactions, journal outcomes) lives in separate tables that feature code cannot read. Wallet skill scores use only trades closed before t |
| Survivorship | The universe at t is every token discovered by t, including those that later went to zero or vanished from vendor APIs. Historical collection must archive dead tokens; vendor "current token lists" are unusable for this |
| Selection | Strategy universes are defined by rules evaluated at t (e.g. liquidity ≥ $50k at t), never by hindsight lists of famous runners |
| Data snooping | Train / validation / test split by time. The test period is touched once per hypothesis; each touch is logged in `backtest_runs` with `split = 'test'` |
| Multiple testing | Every configuration tried is logged. Reported results state how many variants were tested; significance uses a deflated threshold (Bonferroni across variants, or the deflated Sharpe ratio) |

## Fill model

* **Latency.** Orders fill `latency_bars` (1) after the decision, at the price and liquidity visible then.
* **Entry slippage.** CPMM impact `notional / (liquidity / 2)` plus LP fee, from fill-time liquidity. CLMM and order-book venues are flagged as approximations until their depth models exist.
* **Failed entries.** If liquidity is missing, below the minimum, or no size fits the slippage limit at fill time, the entry fails and counts toward `failed_execution_rate`.
* **Exit slippage.** Entry-model slippage × `exit_slippage_multiplier` (2). Exits happen when others are also leaving.
* **Failed exits.** An exit larger than 10% of fill-time pool liquidity, or with no observable liquidity, is marked `failed_exit`. The modelled price is kept, which flatters the result; the flag rate says by how much to distrust it.
* **Fees.** Venue fee, plus a per-trade priority fee.

## Metrics (`backtest/metrics.py`)

Reported every run: total return, CAGR (≥ 90 days only), maximum drawdown, Sharpe and Sortino (per-trade, annualised; withheld below 30 trades or 30 days with a `sample_warning`), profit factor, win rate, average win, average loss, expectancy, trade count, turnover, fees, slippage, failed execution rate, failed exit rate, liquidity impact in bps, worst trade, 5th-percentile trade return (≥ 20 trades), worst consecutive sequence, and a per-regime breakdown.

Ranking order for memecoin strategies: **maximum drawdown, tail loss, slippage, failed-exit rate**, then return. A strategy with better return and a doubled failed-exit rate is worse.

## Walk-forward protocol

1. Split history into contiguous periods. Fit or tune on period k, evaluate on k+1, roll forward.
2. **Purge** training samples whose label window overlaps the evaluation period; **embargo** a further gap (default 24 h) so autocorrelated moves do not leak (`research/models.py::purged_walk_forward`).
3. Report every fold, not the average alone. A strategy that wins in aggregate while losing in most folds is one lucky period.

## Event studies (`backtest/event_study.py`)

For each event of a kind (listing, influencer post, launch, liquidity migration, large wallet buy or sale, social acceleration, narrative emergence):

* Entry reference price: the first price visible `entry_delay` (60 s) after the system *saw* the event.
* Horizons: 5m, 15m, 30m, 1h, 4h, 12h, 24h.
* Controls: up to three tokens with the nearest log liquidity at event time and no event of any kind in the same hour.
* Outputs: mean return, mean control return, mean abnormal return, t-statistic of abnormal returns, realised volatility.

Event studies are descriptive. They say whether a class of event has historically been followed by abnormal returns under realistic entry timing, which is the precondition for building a signal on it.

## Model validation (`research/models.py`)

Target probabilities: P(MAJOR_MOVE), P(CONTINUATION), P(EXHAUSTION), P(MANIPULATION), P(LIQUIDITY_FAILURE). Label definitions are versioned (`LABEL_RULES_VERSION`).

Order of candidates, each promoted only if it beats the previous on every walk-forward fold:

1. Base-rate forecaster (the bar every model must clear)
2. Current rule set, scored as a classifier
3. L2 logistic regression on the feature dictionary
4. Random forest, gradient boosting (LightGBM/XGBoost when the dependency is justified)
5. Survival models for time-to-exhaustion; isolation forest for anomaly scoring; graph methods for clusters
6. Neural networks, only with a demonstrated out-of-sample gain over 4

Metrics: Brier score, log loss, reliability curve (predicted vs observed per decile). A model that ranks well but is miscalibrated can order tokens; it cannot size positions.

## What counts as a result

A hypothesis (doc 14) is supported only when: the effect appears on the untouched test period, survives the fill model, survives the multiple-testing adjustment, and holds in more than one market regime. Anything less is an observation, recorded as such.
