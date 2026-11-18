# AX IQ200: SSRN Execution Research Extraction and Telemetry Gap Analysis

**Status:** Research synthesis and engineering recommendations. No trading logic or execution code changed by this document.  
**Target branch:** claude/autopsy-flipdemon-extreme-l4ei3d  
**Scope:** Execution of an already-approved order. No directional signal authority, sizing authority, stop authority, or risk permission.

## 1. Executive finding

The research supports a constrained execution optimiser built around four distinct estimates:

1. Probability and time-to-fill for a passive order.
2. Expected implementation cost for immediate execution.
3. Adverse-selection cost conditional on a fill.
4. Opportunity cost of waiting or failing to execute before the setup expires.

The router should minimise expected total execution cost subject to hard strategy, broker, reservation, and account-risk constraints. It must not generate or reverse the W1-authorised direction.

The papers do not justify deploying deep reinforcement learning directly into the live MT5 tick path. The practical sequence is reliable event telemetry, supervised and survival-model baselines, broker-specific calibration, shadow decisions, and only then controlled demo routing.

## 2. Source verification and paper-by-paper extraction

The following records were checked against their SSRN pages or accessible author/institutional copies. SSRN abstracts and metadata establish the stated research problem and headline method. Where full paper text was not accessible, this document does not invent unreported equations, feature lists, datasets, or performance numbers.

### 2.1 Fabre and Ragel (2023), state-dependent execution probability

**Paper:** Timothée Fabre and Vincent Ragel, *Tackling the Problem of State Dependent Execution Probability: Empirical Evidence and Order Placement*, SSRN 4509063.  
**Source:** https://ssrn.com/abstract=4509063

**Problem addressed:** Estimate the probability that a passive limit order executes, conditional on the evolving market state and the price distance at which the order is posted.

**Method disclosed in the SSRN abstract:**
- High-frequency data from centralised digital-asset exchanges and stock markets.
- Survival-analysis framing for fill probability.
- Microstructure features mapped through a multilayer perceptron.
- Loss weighting to handle censored observations.
- Fixed-horizon choice between posting a limit order and immediately executing.
- Explicit modelling of clean-up cost when the passive order does not execute.
- Backtesting approach designed to avoid inserting hypothetical orders that distort price formation.

**Engineering extraction:**
- Treat fill as a time-to-event outcome, not merely a binary label detached from the waiting horizon.
- An order still unfilled at the end of the observation window is right-censored, not automatically a failed trade.
- A cancelled order needs a cancellation reason and observation history. Policy cancellation, broker rejection, expiry, and missing data are different outcomes.
- Estimate fill probability jointly with quote distance, side, state and a fixed horizon.
- Compare passive execution against immediate execution using the cost of the non-fill path, not just the price improvement.

**IQ200 mapping:** First candidate for the passive fill-probability model and limit-versus-market decision. Start with a calibrated logistic/survival baseline before reproducing an MLP.

**Transfer limitation:** The paper uses centralised exchange and stock-market data. It does not prove that the same coefficients or queue assumptions apply to OTC retail FX/CFDs or Deriv synthetic indices.

### 2.2 Arroyo, Cartea, Moreno-Pino and Zohren (2023), deep attentive survival analysis

**Paper:** *Deep Attentive Survival Analysis in Limit Order Books: Estimating Fill Probabilities with Convolutional-Transformers*, SSRN 4432087.  
**Source:** https://ssrn.com/abstract=4432087  
**Institutional copy:** https://ora.ox.ac.uk/objects/uuid:03367c56-81e6-4fea-b51e-18885e3f6680

**Problem addressed:** Estimate the distribution of limit-order fill times at different order-book levels, supporting the choice between passive liquidity provision and aggressive liquidity taking.

**Method disclosed:**
- Time-varying limit-order-book features.
- Convolutional Transformer encoder.
- Monotonic neural-network decoder for survival/fill-time predictions.
- Proper scoring rules for comparison with survival-analysis alternatives.
- Interpretability analysis of feature informativeness.
- Analysis across assets with different queue dynamics and trading activity.

**Engineering extraction:**
- A single scalar fill probability is less useful than a calibrated fill-time distribution.
- IQ200 should query probabilities at explicit horizons, for example P(fill within 1s), P(fill within 5s), and P(fill within 30s), where the instrument's quote cadence supports those horizons.
- Predictions must be monotonic in time: cumulative probability of fill should not fall as the horizon increases.
- The model should be evaluated with survival-appropriate scoring and calibration, not accuracy alone.
- Different symbols and liquidity regimes require separate validation. Pooling them without symbol/regime controls can hide poor calibration.

**IQ200 mapping:** Later advanced fill-time model. Do not start with a Transformer. First establish reliable timestamps, order lifecycle, fill/censor labels and a simpler baseline.

**Transfer limitation:** The architecture assumes an observable limit order book and queue dynamics. Retail MT5 market depth may be broker-specific, partial, or unavailable. The EA must not fabricate queue position from snapshots.

### 2.3 Moallemi and Wang (2021/2022), reinforcement learning for optimal execution

**Paper:** Ciamac C. Moallemi and Muye Wang, *A Reinforcement Learning Approach to Optimal Execution*, SSRN 3897442; subsequently published in *Quantitative Finance* (2022).  
**Sources:** https://ssrn.com/abstract=3897442  
https://doi.org/10.1080/14697688.2022.2039403

**Problem addressed:** Decide when to execute an infinitesimal order, formulated as an optimal-stopping problem.

**Method disclosed:**
- Data-driven neural-network methods.
- A supervised-learning version and a reinforcement-learning version.
- Temporal-difference learning for extensions.
- Numerical experiments on historical market data, with reported execution-cost reductions and analysis of convergence, data efficiency, and bias/variance trade-offs.

**Engineering extraction:**
- Execution timing can be expressed as a repeated stop-or-continue decision.
- Waiting is an action with both potential price benefit and a cost: exposure to adverse movement, missed opportunity, and deadline expiry.
- Reward must be based on implementation shortfall or another explicit execution-cost objective, not directional trading P&L.
- The policy requires a defined terminal condition. It cannot wait indefinitely.
- Compare learned decisions against a simple, reproducible baseline and report costs out of sample.

**IQ200 mapping:** A later execution timing policy for MARKET versus WAIT, after reliable state and outcome labels exist.

**Transfer limitation:** The paper's infinitesimal-order formulation does not directly solve MT5 broker execution, partial fills, margin reservations, or multi-tier campaign risk. Its policy must be wrapped by deterministic broker and risk controls.

### 2.4 Kwan and Philip (2020), machine learning in a dynamic limit-order market

**Paper:** Amy Kwan and Richard Philip, *Machine Learning in a Dynamic Limit Order Market*, SSRN 3630018.  
**Source:** https://ssrn.com/abstract=3630018

**Problem addressed:** Estimate the expected value of limit orders and study order-management decisions in a dynamic limit-order market.

**Headline findings disclosed in the SSRN abstract:**
- Queue position matters: being nearer the front of the queue improves limit-order value.
- A large queue behind an order can also increase its value.
- The relationship between volatility and limit-order value depends on tick-size constraints.
- The option to cancel contributes approximately 19% of the order's total expected value in the studied setting.

**Engineering extraction:**
- Price improvement alone is not sufficient to value a passive order.
- Cancellation is part of the policy, not an operational afterthought.
- A resting order should be reassessed as state changes, but cancellation/replacement must be bounded to avoid uncontrolled order churn.
- Queue position is a first-class variable only where the venue exposes credible queue data. If MT5 broker DOM does not expose queue priority, mark the feature unavailable.
- Volatility effects are conditional. Do not hard-code “high volatility means passive” or “high volatility means aggressive.”

**IQ200 mapping:** Cancellation and order-age management policy. Use the research as evidence that cancellation optionality matters, not as a justification to copy the reported 19% into a CFD strategy.

**Transfer limitation:** The reported value is specific to the study's market, tick-size and queue assumptions. It is not a universal cancellation benefit.

### 2.5 Barzykin, Boyce, Neuman and Tuschmann (2026), optimal execution with passive market impact

**Paper:** *Optimal Execution with Passive Market Impact*, SSRN 7147361.  
**Source:** https://ssrn.com/abstract=7147361

**Problem addressed:** Model the market impact and non-execution trade-off of passive limit orders.

**Method and empirical foundations disclosed:**
- Approximate exponential decay of limit-order fill probability with distance from midprice.
- Short-term linear response of price changes to order-flow imbalance.
- A reduced-form passive impact rate that decays exponentially with quote distance.
- Tactical quote adjustment balancing fill intensity, adverse selection and opportunity cost.
- Empirical calibration using NASDAQ equities and public FX.
- Extensions include heterogeneous decay rates, transient impact and target execution schedules.

**Engineering extraction:**
- Quote distance is a control variable that changes both fill intensity and expected passive impact.
- Order-flow imbalance should inform passive quote aggressiveness, but must be measured from available, valid data.
- A passive order can impose a cost through its interaction with the market even when it does not cross the spread.
- Calibrate quote-distance decay per instrument and execution venue. Do not transfer a NASDAQ parameter into XAUUSD.m or a synthetic index.
- Distinguish market impact from broker spread and realised slippage. For small retail sizes, market impact may be negligible or unidentifiable, and must not be invented.

**IQ200 mapping:** Expected passive execution cost and quote-distance calibration. This is the strongest bridge between fill probability and order-flow imbalance in the selected papers.

**Transfer limitation:** The empirical foundations include public FX and equities, not the user's specific broker feed or synthetic-index venue. The paper's model is an execution framework, not evidence that a retail EA can observe the full market.

### 2.6 ter Braak and van der Schans (2023), optimal order routing with reinforcement learning

**Paper:** Lars ter Braak and Martin van der Schans, *Optimal Order Routing with Reinforcement Learning*, SSRN 4611420.  
**Source:** https://ssrn.com/abstract=4611420

**Problem addressed:** Allocate institutional equity orders across multiple sell-side brokers using an algo wheel.

**Method disclosed:**
- Reinforcement learning / multi-armed-bandit framing.
- Balance exploitation of the best-performing broker with exploration of other brokers.
- Evaluate broker execution quality over time.

**Engineering extraction:**
- Broker execution quality should be measured empirically by symbol, session, order type and market condition.
- A broker score must be based on confirmed fills, costs, rejection rates and outcome quality, with sample counts and uncertainty.
- Exploration must never mean sending live risk to an unapproved or unsafe route.
- For a single MT5 account, this is not an order-book routing algorithm. It is a possible future broker-quality analytics module across separately authorised broker accounts.

**IQ200 mapping:** Broker-quality intelligence, low priority for the current single-terminal execution router.

**Transfer limitation:** The paper addresses institutional broker allocation for equities. It does not demonstrate venue selection inside one retail MT5 account.

## 3. Consolidated mathematical specification for IQ200

The equations below are an engineering synthesis of the research themes, not verbatim equations claimed to appear in every paper.

### 3.1 Fill-time distribution

For a passive order at quote distance d, side s, and current state x:

S(t | x,s,d) = P(T_fill > t | x,s,d)

P_fill(H | x,s,d) = 1 - S(H | x,s,d)

The survival model must handle right-censoring. A limit order that remains unfilled when the observation ends is not automatically a negative label.

### 3.2 Expected cost of immediate execution

C_market = spread_cost + realised_slippage + commission + estimated_impact

Use broker-confirmed fills and actual charges wherever available. Do not infer one-way network latency from terminal-local elapsed timers.

### 3.3 Expected cost of passive execution

C_limit = P_fill(H) * C_filled + (1 - P_fill(H)) * C_nonfill

C_nonfill must include the actual fallback policy: abandon, re-enter aggressively if the thesis remains valid, or allow the setup to expire. Those are distinct outcomes and should be labelled separately.

### 3.4 Adverse selection

For a BUY fill:

M_h = (Mid at t+h - FillPrice) / Point

For a SELL fill:

M_h = (FillPrice - Mid at t+h) / Point

Negative direction-adjusted markout means the market moved against the fill. Calculate only from a confirmed deal price and a valid later quote. Store 1s/5s/30s horizons only where the instrument's data cadence makes them meaningful.

### 3.5 Constrained action selection

a* = argmin_a E[C_total | x,a]

Allowed actions: MARKET, LIMIT, WAIT, REPRICE, CANCEL, BLOCK.

The optimiser is subordinate to hard constraints:
- Existing W1 direction and approved strategy candidate remain unchanged.
- D1/H4 structural gates remain authoritative.
- No order action may bypass execution eligibility or broker compatibility checks.
- Existing account-wide 2% risk ceiling and distributed reservation lifecycle remain authoritative.
- A pending order must remain covered by risk accounting until confirmed cancellation, expiry, fill, or reconciliation.
- Uncertain broker outcomes remain locked and reconciled, never blindly resubmitted.
- No averaging down, martingale, or unapproved pyramid add.
- No live AI inference or routing activation without explicit approval.

## 4. Comparison with the current IQ200 telemetry contract

The branch contract is docs/iq200/IQ200_00_01_EXECUTION_TELEMETRY_CONTRACT.md. It already specifies a versioned event stream, bounded buffer, explicit missingness, fill/censor labels, markouts, baseline metrics, and no execution authority.

The inspected implementation is at:
- MQL5/Include/AutopsyX/IQ200Telemetry.mqh
- MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5

### 4.1 Existing strengths

- Separate IQ200 schema, leaving the legacy 13-column execution journal untouched.
- Fixed 256-event queue and controlled timer flush.
- Event vocabulary already reserves DECISION, ROUTE_PLAN, ORDER_SUBMITTED, BROKER_ACK, DEAL_PARTIAL, DEAL_FILLED, cancellation, expiry, ambiguity, closure and markout.
- Telemetry module has no direct order-send or risk-authority calls.
- Broker transaction observer captures request responses, deal additions and terminal order-state history.
- Local elapsed timing is explicitly not labelled network latency.
- Persistence health is latched independently of trading permission.

### 4.2 Gaps confirmed by source inspection

| Contract requirement | Current source observation | Required next action |
|---|---|---|
| DECISION event | Enum exists; no DECISION enqueue was found in the main EA. | Instrument after all strategy/risk approvals and before the execution request path. |
| ROUTE_PLAN | Enum exists; no route-plan enqueue was found. | Record the existing method selected, without changing it. |
| ORDER_SUBMITTED | Enum exists; no submission event enqueue was found. | Record at the actual request boundary, distinct from broker acknowledgement. |
| Partial-fill classification | Each TRADE_TRANSACTION_DEAL_ADD currently emits DEAL_FILLED. | Correlate deals to order and classify partial versus cumulative full fill from reconciled order/deal history. |
| Cumulative fill volume | Current deal event stores that deal's volume. | Maintain order-level cumulative volume and prevent duplicate callback double-counting. |
| Stable decision/intent/campaign correlation | Schema has fields, but transaction capture alone does not populate the complete chain. | Reuse existing lifecycle setup ID and durable intent/campaign IDs at the execution boundary. |
| Feature snapshot | Current event struct has quote, ATR, spread percentile and some masks, but no explicit regime, volatility state, quote age, tick rate, tick imbalance, OFI, DOM age or urgency/deadline fields. | Extend schema only after confirming each field is available and its source/units are defined. |
| Fill-time labels | No passive-order lifecycle/model labels yet. | Implement only after actual order submission, partial fills, cancellation and reconciliation are reliably correlated. |
| Markout | Event type and fields exist; no markout scheduler confirmed. | Defer until deal correlation and quote validity are proven. |
| Session/restart continuity | Session ID is generated at init; in-memory queue is not crash durable. | Preserve the documented limitation; use broker-history reconciliation for lifecycle reconstruction. |

**Important:** This source inspection is not a test run. It does not establish native MQL5 compilation, runtime correctness, or CI success.

## 5. Model development order

### IQ200-02A: Data quality and labels
- Complete DECISION, ROUTE_PLAN and ORDER_SUBMITTED instrumentation.
- Correlate request, order, multiple deals, partial fills, cancellations and history updates.
- Add duplicate-event protection and order-level cumulative fill state.
- Validate quote timestamps, symbol point/tick units and missingness.
- Keep all execution decisions observational.

### IQ200-02B: Interpretable baseline models
- Fill probability: logistic regression or discrete-time survival baseline.
- Fill time: survival model with right-censoring.
- Slippage: median and upper-quantile regression, conditioned on spread, volatility, side, symbol and session.
- Adverse selection: direction-adjusted markout regression/classification.
- Cost comparison: explicit market-versus-limit expected-cost calculator.

### IQ200-02C: Shadow execution decisions
- Generate hypothetical MARKET/LIMIT/WAIT/CANCEL recommendations.
- Do not submit or modify orders.
- Record model version, feature schema, predicted fill probabilities, predicted costs, selected action and reason.
- Compare every recommendation with actual broker outcomes and the existing execution method.

### IQ200-02D: Broker-specific demo validation
- Separate XAUUSD/metal, FX and synthetic-index datasets.
- Do not pool instruments until calibration equivalence is demonstrated.
- Use chronological walk-forward evaluation and purge overlapping outcome windows.
- Include variable spreads, commissions, slippage, delays, rejects, partial fills and missed opportunities.
- Require minimum sample sizes and confidence intervals before interpreting differences.

### IQ200-02E: Controlled routing proposal
Only after the preceding gates:
- Add native MQL5 inference for a validated, versioned model.
- Keep Python offline for training and artifact validation.
- Add persistent pending-order reservation lifecycle before any resting limit orders.
- Preserve idempotency, fail-closed recovery, and the immutable account-wide risk ceiling.
- Keep live routing disabled pending explicit approval.

## 6. Acceptance criteria before any AI execution model is trusted

1. No missing or duplicate order/deal correlation in the tested lifecycle set.
2. Partial and full fills are correctly distinguished and cumulative volume reconciles to broker history.
3. Censored, cancelled, expired, rejected and ambiguous outcomes remain distinct.
4. Fill probabilities are calibrated by symbol and horizon, with sample counts and reliability plots.
5. Slippage and adverse-selection models beat simple baselines on chronological out-of-sample data.
6. Expected-cost comparisons include missed-opportunity and non-fill fallback costs.
7. Shadow recommendations improve net execution cost without worsening missed-entry rate beyond an approved bound.
8. Existing W1/D1/H4, pyramid eligibility, reservation, recovery and 2% risk tests remain intact.
9. CI results are recorded. Native MetaEditor compile and MT5 Strategy Tester evidence are reported separately.

## 7. Research references

1. Fabre and Ragel (2023), https://ssrn.com/abstract=4509063
2. Arroyo et al. (2023), https://ssrn.com/abstract=4432087
3. Moallemi and Wang (2021/2022), https://ssrn.com/abstract=3897442
4. Kwan and Philip (2020), https://ssrn.com/abstract=3630018
5. Barzykin et al. (2026), https://ssrn.com/abstract=7147361
6. ter Braak and van der Schans (2023), https://ssrn.com/abstract=4611420

---
**Engineering decision:** Complete and validate IQ200-01 event correlation before building any model. The next code milestone is execution-boundary instrumentation and partial-fill reconciliation, not a neural network, RL agent, or adaptive limit router.
