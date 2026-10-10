# 14. Research Hypotheses

Each hypothesis has a test design, a success criterion set in advance, and a kill criterion. The system is built to be allowed to disprove every one of them.

**Common setup.** Universe: tokens with ≥ $50k liquidity at t on supported chains. Event: a move reaching UNUSUAL or higher, up direction, at t. Outcomes measured from the first fillable price after t (doc 08 fill model): *continuation* = return to t+4h ≥ +20% before a -15% drawdown; *failure* = the reverse. Splits by time; test period touched once. Significance at α = 0.05 after Bonferroni across the variants tried for that hypothesis.

| ID | Hypothesis | Test | Supported if | Killed if |
|---|---|---|---|---|
| H1 | Large moves with accelerating *independent* wallet participation continue more often than moves driven by concentrated wallets | Split events by terciles of `independence_ratio × buyer_growth`; compare continuation rates top vs bottom; logistic regression controlling for move size, liquidity, token age | top tercile continuation rate exceeds bottom by a significant margin in test and in ≥ 2 regimes | difference not significant, or reverses in any regime with ≥ 100 events |
| H2 | Volume acceleration with liquidity expansion beats volume acceleration alone | Among events with 15m volume z ≥ 2, compare Δliquidity ≥ 0 vs < 0 | continuation higher and drawdown lower for liquidity-expanding group | no difference after controlling for move size |
| H3 | Social acceleration helps more when it coincides with independent on-chain participation | 2×2: effective-author velocity high/low × independence high/low; interaction term | positive, significant interaction | interaction null; social adds nothing beyond on-chain |
| H4 | Extreme social acceleration without wallet growth marks manufactured attention or late speculation | Events with mention velocity ≥ 5 and buyer growth ≤ 1.2 vs others | higher failure rate and higher 24h drawdown | failure rate no different from baseline |
| H5 | Narrative-level acceleration precedes secondary-token acceleration | For narratives entering ACCELERATING at t, compare subsequent 1h abnormal-move rate of non-moving members vs matched non-members | members' rate significantly higher out of sample | no difference, or effect vanishes after removing the leader token's own news |
| H6 | Creator-wallet distribution raises continuation failure | Events with `creator_distribution` flag in the prior hour vs without | failure rate materially higher (pre-set: ≥ 1.5x) | ratio < 1.2 or not significant |
| H7 | Liquidity deterioration is a better exit than a fixed % drawdown in extreme-volatility tokens | Same entries, two exit rules: doc 04 liquidity triggers vs fixed -15% / -25% stops; compare net return, drawdown, failed-exit rate | liquidity rule improves drawdown and failed-exit rate without worse net return | fixed stop dominates on the primary metrics |
| H8 | News-confirmed moves continue differently from unexplained moves | Continuation, time-to-peak, and drawdown by timing class: NEWS_FIRST (confirmed), MOVE_FIRST, NO_IDENTIFIED_CATALYST | distributions differ significantly (KS test) with a stable sign | no difference; catalyst labelling adds nothing |
| H9 | Cross-venue confirmation improves signal quality | Events with ≥ 2 venues: agreement ≥ 0.8 vs lower | higher continuation, lower slippage-adjusted loss | no difference (note: arbitrage may make agreement near-universal, which would also kill the feature) |
| H10 | A combined market + on-chain + news + social model beats any single class out of sample | Walk-forward logistic regression: each feature class alone vs combined; Brier score per fold | combined beats every single-class model on every fold and the base rate | any single class matches it; drop the other classes' weight |

## Auxiliary questions

| ID | Question |
|---|---|
| H-aux-1 | Does a same-age cohort baseline classify young-token moves as well as each coin's own baseline does for mature tokens? |
| H-aux-2 | Which manipulation detectors separate outcome proxies (creator LP removal, -90% in 48h) from controls, and at what thresholds? |
| H-aux-3 | What is the p95 ingestion latency per provider, and how much of the NEWS_FIRST edge survives it? |
| H-aux-4 | How often do wallet labels (SKILLED under the Wilson-bound rule) persist from one quarter to the next? |

## Process rules

* Hypotheses and their criteria are fixed before the test period is opened. Changing a criterion after seeing results is logged as a new hypothesis.
* A killed hypothesis stays in this file with its result. Negative results shape the weights as much as positive ones.
* No rule or weight changes automatically from journal outcomes. Changes are proposed from research, validated per doc 08, and shipped as a versioned config.
