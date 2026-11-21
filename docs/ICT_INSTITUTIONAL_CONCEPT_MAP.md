# ICT Institutional-Price-Delivery Concept Map

## Source boundary

The supplied reference is the original theinnercircletrader.com domain. Its homepage identifies Michael J. Huddleston and links to the official ICT YouTube channel and the 2016 ICT Mentorship Core Content playlist. It names an "ICT Compendium Library", but the inspected homepage does not expose a working compendium URL or a searchable concept index.

Primary source links:
- Original website: https://www.theinnercircletrader.com/
- Official ICT channel: https://www.youtube.com/@InnerCircleTrader
- 2016 Mentorship Core Content, Month 1: https://www.youtube.com/playlist?list=PLVgHx4Z63paYzh3KwUFX0UHQUf31CAEXk
- 2016 Mentorship Core Content, Month 2: https://www.youtube.com/playlist?list=PLVgHx4Z63paZvjqerfbn320myZ06L1MOB
- 2022 ICT Mentorship, 41 episodes: https://www.youtube.com/playlist?list=PLVgHx4Z63paYiFGQ56PjTF1PGePL3r69s

The inventory below is a working engineering taxonomy of ICT price-delivery concepts. It is not a claim that every term appears on the homepage, nor that every popular SMC label is an original ICT term. Validate detailed definitions against the linked lectures before treating any label as canonical.

## Concept inventory

### 1. Price delivery and market state

- Interbank Algo, as ICT's explanatory model of price delivery
- Hold Pattern
- Expansion
- Retracement
- Reversal
- Consolidation
- Displacement
- Institutional Order Flow
- Change in State of Delivery (CISD)
- Market Structure Shift (MSS)
- Break of Structure (BOS)
- Change of Character (CHoCH)
- Swing highs and swing lows
- Higher highs, higher lows, lower highs, lower lows
- Internal and external range structure

### 2. Liquidity and price targets

- Buy-Side Liquidity (BSL)
- Sell-Side Liquidity (SSL)
- Equal highs and equal lows
- Relative equal highs and relative equal lows
- Internal Range Liquidity (IRL)
- External Range Liquidity (ERL)
- Short-, intermediate- and long-term liquidity
- Time-based liquidity
- Low-Resistance Liquidity
- Draw on Liquidity (DOL)
- Liquidity pools and resting stops
- Liquidity sweep / stop run / stop hunt
- Judas Swing
- Turtle Soup / false-breakout reversal
- Previous Day High / Low
- Previous Week High / Low
- Prior session highs and lows
- Asian range highs and lows
- Double-sided liquidity purge

### 3. Imbalance and Premium/Discount arrays

- Fair Value Gap (FVG)
- Inversion Fair Value Gap (IFVG)
- Balanced Price Range (BPR)
- Consequent Encroachment (50% of an imbalance)
- Liquidity Void
- Volume Imbalance
- Breakaway Gap
- Immediate Rebalance
- Order Block (OB)
- Breaker Block
- Mitigation Block
- Rejection Block
- Propulsion Block
- Vacuum Block
- Hidden Order Block
- First Presented FVG
- Premium
- Discount
- Equilibrium
- Dealing Range
- Optimal Trade Entry (OTE)
- Standard-deviation / range-deviation projections

### 4. Time, sessions and daily/weekly framing

- Asian session and Asian Range
- London Kill Zone
- New York Kill Zone
- Kill Zones generally
- Macro time windows
- Silver Bullet time window
- New York midnight reference
- Daily and weekly opening prices
- Session opening ranges
- Power of Three (PO3) / Accumulation-Manipulation-Distribution (AMD)
- Accumulation
- Manipulation
- Distribution
- Session range expansion and session liquidity raids

### 5. Named models and relative-market confirmation

- Market Maker Buy Model
- Market Maker Sell Model
- Market Maker Buy/Sell Model (MMXM)
- 2022 Model
- Candle Range Theory (CRT)
- Reference Candle
- Seek & Destroy
- CRT Delivery
- Silver Bullet model
- Turtle Soup
- Three Drives
- Unicorn model (Order Block + FVG overlap)
- SMT Divergence (correlated-market non-confirmation)
- Relative strength / weakness between correlated instruments

### 6. Trade selection and management principles

- Context before entry
- Daily and higher-timeframe directional bias
- Low-risk trade framing
- Selecting high-reward setups
- Reward-to-risk selection
- Entry after confirmation, not at the sweep itself
- Stop placement beyond the invalidation point
- Mitigating losing trades
- One clear draw-on-liquidity target
- Avoiding late entries after the delivery leg has already expanded

## Existing AUTOPSY X coverage

| Area | Existing implementation | Engineering status |
|---|---|---|
| Swing structure, BOS/CHoCH/MSS | StructureEngine.mqh | Implemented as closed-bar classifications; continue auditing definitions and call-site use |
| BSL/SSL candidates, equal levels, PDH/PDL/PWH/PWL, sweeps | Liquidity.mqh | Implemented; sweep/rejection/displacement sequence exists |
| W1/D1 institutional direction and levels | W1InstitutionalDirection.mqh, D1InstitutionalLevels.mqh | Integrated directional authority |
| Premium/discount, equilibrium, OTE | PremiumDiscountEngine.mqh | Integrated as bounded location evidence |
| Asia, CBDR, FLOUT and ADR20 projections | DailyExtremeProjectionEngine.mqh | Observational only; NY-local clock with DST handling |
| Order flow, CVD proxy, footprint, volume profile, DOM heatmap | OrderFlow.mqh, Footprint.mqh, VolumeProfile.mqh, Heatmap.mqh | Existing evidence modules; feed quality and broker availability must be explicit |
| Session opening range | AdvancedSessionORBEngine.mqh | Optional, session-hour configuration requires broker validation |
| FVG lifecycle and retest | FairValueGapEngine.mqh | Newly integrated; closed-bar formation/invalidation, age cap, true-range size filter, middle-candle body/direction filter, CE and live retest location |
| Composite direction and risk | CompositeDirection.mqh, account-risk coordinator and execution eligibility modules | Existing independent direction/risk gates remain authoritative |

## Gaps worth implementing next

1. **Order Block / Breaker / Mitigation / Rejection lifecycle.** Detect an origin candle only when followed by a qualifying displacement and structural break. Track retest, invalidation and breaker conversion. Avoid drawing every opposite-colour candle as an order block.
2. **IFVG and BPR.** Add explicit failed-gap inversion and overlap detection. Reuse the FVG zone lifecycle rather than building a second inconsistent price-zone engine.
3. **AMD / Judas / CRT state machine.** Model range formation, one-sided liquidity raid, confirmation and delivery as a time-bounded sequence. Keep New York DST conversion separate from broker-server session inputs.
4. **Silver Bullet and macro windows.** Add as configurable time-context evidence, not a universal hard gate. Gold/FX and 24/7 synthetic indices need separate session calibration.
5. **SMT divergence.** Enable only when both instruments have valid, synchronized history and a defensible correlation relationship. Missing or stale comparison data must return unavailable, not fabricate divergence.
6. **Model-level outcome research.** Log setup identity, symbol, session, regime, target distance, spread, slippage and invalidation. Compare each model against a baseline using chronological out-of-sample replay and ablation tests.

## Non-negotiable interpretation limits

- The EA cannot see actual interbank client orders or prove that a specific bank is accumulating. It classifies observable price and broker-feed behaviour.
- Spot FX and many CFDs have fragmented or broker-specific volume. Tick-volume CVD and footprint estimates are proxies, not consolidated exchange order flow.
- Broker market depth is only useful when the broker supplies a reliable book. Do not label synthetic or missing depth as institutional liquidity.
- ICT labels are hypotheses and operational definitions. A named pattern is not evidence of a profitable edge.
- No projection, sweep, FVG, order block or session model may bypass the account-wide risk coordinator, fail-closed execution reservation, broker preflight, or the immutable 2% account-risk ceiling.
- ANALYSIS_ONLY remains the default. MetaEditor compilation, realistic MT5 tick testing, out-of-sample testing and demo forward validation are required before any live execution.
