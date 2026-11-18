# Advanced Trend and Execution Feedback Suite

## Branch and scope

Implemented on `claude/autopsy-flipdemon-extreme-l4ei3d` as an additive, analysis-only suite. It does not replace the W1/D1/H4 direction engines, alter existing order scoring, modify position sizing, submit orders, or change account risk controls.

## Components

- **Shadow River:** existing directional-change engine, now configured and sampled from the EA's mid-price stream. Sensitivity is expressed in broker points and converted using the symbol's actual point size.
- **AlphaTrend:** completed-bar ATR/MFI trailing trend line. Uses ATR bands and MFI's 50-line state; no forming-bar input.
- **MFI:** native MT5 Money Flow Index, using tick volume as the applied-volume source.
- **Slingshot EMA 38/62:** completed-bar trend pullback/reclaim observation. BUY requires EMA38 above EMA62, bar low reaching EMA38 and close reclaiming EMA38. SELL is symmetric.
- **Chandelier Exit:** completed-bar highest-high/lowest-low over the configured lookback, offset by ATR multiple. The stop ratchets only in the favourable direction. At this stage it is diagnostic only and does not modify broker stops.
- **Ultimate Trend Alpha:** bounded 0-100 confluence score from AlphaTrend, MFI, EMA 38/62, Shadow River and H4 bias. It reports a directional result only when W1 and D1 both permit that same direction. It is not yet applied to the live signal score.
- **Adaptive Market Regime:** consumes the existing R1-R8 classification instead of duplicating its classifier. It maps the classification to an observational posture and research multiplier. It does not alter risk or entry permissions.
- **Execution Feedback:** maintains in-memory EWMA observations for adverse fill slippage, post-fill markout and adverse-markout rate. Fill samples are accepted only when the broker history order exposes a valid requested price. Markout samples are accepted only when the scheduled executable-side quote is valid.

## EA integration

The main EA now:
- includes and initializes the suite when `InpEnableAdvancedTrendSuite=true`;
- samples Shadow River on valid ticks;
- updates AlphaTrend, MFI and Slingshot once per completed bar on `InpAdvancedSignalTimeframe`;
- refreshes Chandelier only for an existing managed position;
- evaluates Ultimate Trend Alpha using W1/D1 permissions and H4 bias;
- updates adaptive regime posture whenever a classifier sample arrives, including unavailable samples so stale posture is cleared;
- feeds measured fill slippage and valid 1s/5s/30s markouts into Execution Feedback;
- releases all indicator handles on deinitialization.

## Default configuration

- Advanced signal timeframe: H1
- AlphaTrend: period 14, ATR multiplier 1.0
- MFI: period 14
- Slingshot: EMA 38 / EMA 62
- Chandelier: lookback 22, ATR period 22, multiplier 3.0
- Shadow River: sensitivity 100 broker points, reversal multiplier 2.0
- Execution feedback EWMA smoothing: 0.10

These are engineering defaults, not optimized or proven profitable parameters.

## Deliberate limits

1. The new suite is observational. It does not yet change entry score, campaign direction, exit decisions or broker stops. This avoids introducing untested trading behaviour into the protected W1/D1/H4 and risk architecture.
2. Chandelier is calculated and logged, not yet passed to the stop-modification lifecycle.
3. Execution Feedback's in-memory statistics are not yet persisted as a calibrated model artifact. IQ200's event journal remains the durable raw-observation source.
4. Adaptive Market Regime reuses the current R1-R8 classifier. It is not a second market-regime classifier.
5. No native MetaEditor compile or MT5 Strategy Tester result is claimed. CI source-contract tests are not an MQL5 compiler.

## Next validation gate

Run the new source-contract tests in GitHub Actions, then compile in MetaEditor and run Strategy Tester with visual inspection and a chronological out-of-sample period. Only after indicator outputs and missing-data behaviour are validated should a separate, measured ablation authorize Ultimate Trend Alpha score weighting or Chandelier stop integration.
