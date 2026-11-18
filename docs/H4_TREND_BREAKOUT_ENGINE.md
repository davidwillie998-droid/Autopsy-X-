# H4 EMA400 Trend and Range-Breakout Integration

## Purpose

This change adds the Boxxocode-derived H4 trend-continuation concept to the existing AUTOPSY X directional stack. It does not replace the W1 institutional authority or D1 confirmation.

## Signal definition

- Timeframe: H4.
- Trend filter: closed H4 close above EMA(400) with EMA(400) rising for BUY; closed H4 close below EMA(400) with EMA(400) falling for SELL.
- Dynamic range: highest high and lowest low of the preceding 20 completed H4 candles, excluding the candidate breakout candle.
- Breakout confirmation: the latest completed H4 candle must close beyond the preceding 20-bar range and have a body/range ratio of at least 0.60. A BUY close must finish in the upper 20% of its candle; a SELL close must finish in the lower 20%.
- No-lookahead: EMA, ATR and OHLC inputs use completed bars only. The current forming H4 candle is not used to confirm a breakout.
- Efficiency: the engine recalculates once per newly completed H4 bar. Failed data reads are throttled too, rather than retrying CopyRates/CopyBuffer on every tick.

## Integration boundary

- W1 remains the non-bypassable institutional directional authority.
- D1 remains the structural/liquidity confirmation layer.
- H4 EMA400 is an additional directional regime filter when `InpRequireH4TrendFilter=true`.
- A confirmed H4 range breakout adds the bounded `InpH4BreakoutScoreBonus` to the matching side's existing score. It is not a standalone entry signal and cannot override a neutral/contradictory W1, D1 or H4 direction.
- The engine contains no order submission, position sizing, stop modification or risk authority.
- Existing risk controls and the account-wide 2% ceiling are not modified.
- Existing pyramid decision/registry code is not activated or altered by this change. Pyramiding execution remains separately gated.

## Defaults

| Input | Default | Meaning |
|---|---:|---|
| `InpRequireH4TrendFilter` | `true` | Require H4 EMA400 direction to agree with the candidate direction |
| `InpH4BreakoutScoreBonus` | `8.0` | Maximum raw-score bonus on a confirmed breakout |
| EMA period | `400` | H4 trend filter |
| Range lookback | `20` | Prior completed H4 candles used for dynamic high/low |
| Body/range ratio | `0.60` | Minimum breakout candle body strength |

## Validation still required

This repository environment has no MetaEditor/MT5 compiler or Strategy Tester. The MQL5 source therefore remains uncompiled and untested in MT5. Before any demo or live use:

1. Compile the full EA with the new include path in MetaEditor.
2. Resolve every compiler warning/error.
3. Run Strategy Tester with real-tick modelling where available.
4. Inspect H4 EMA alignment, prior-20-bar levels, breakout timestamps, W1/D1 vetoes and score changes in the journal.
5. Test insufficient H4 history, market gaps, symbol suffixes, weekend transitions and EMA warm-up.
6. Confirm that the existing risk coordinator still rejects any reservation that would breach the account-wide ceiling.

A source-level integration is not evidence of profitability, execution quality or live readiness.
