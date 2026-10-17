# VWAP Holy Grail replication (research-only)

This package implements a separate, non-executing backtest harness for the rule in Carlo Zarattini and Andrew Aziz, *Volume Weighted Average Price (VWAP): The Holy Grail for Day Trading Systems*, SSRN 4631351: https://ssrn.com/abstract=4631351.

## What is replicated

- Regular US equity session only: 09:30–16:00 America/New_York, including daylight-saving transitions through the IANA timezone database.
- Session VWAP resets each day at 09:30 ET and is calculated from each in-session bar's typical price, `(high + low + close) / 3`, weighted by reported volume.
- First directional position is selected after the first 1-minute bar closes; long above VWAP and short below VWAP.
- A close on the opposite side reverses direction; all positions are flattened at the end of the regular session and never carried overnight.
- Starting capital defaults to $25,000; position fraction defaults to 100% of available cash (no additional leverage); commission defaults to $0.0005 per share per side, as reported in the paper.

## Two fill models — do not confuse them

- `paper_close` (default) applies the paper-style same-bar close fill and zero slippage assumption. This is a benchmark mode, not a claim that a live order can be filled at that exact price.
- `next_open` waits until the next bar's open after a closed-bar signal. This avoids same-bar signal/fill lookahead but is a different execution assumption; compare both.

No fill model should be described as a verified reproduction of the paper's reported performance until the supplied historical data, market calendar, split/dividend adjustments, and full trade accounting are independently reconciled with the paper.

## CSV input contract

Required headers: `timestamp,open,high,low,close,volume`. Timestamps must be ISO-8601 with an explicit UTC offset or `Z`; ambiguous naive timestamps are rejected. Bars must be sorted and unique, with valid positive prices and a valid OHLC envelope. Only bars whose start time falls within 09:30–15:59 ET are used.

Example:

```bash
python -m research.vwap_holy_grail.replica qqq_1m.csv --fill-model paper_close --output qqq_paper_close.json
python -m research.vwap_holy_grail.replica qqq_1m.csv --fill-model next_open --output qqq_next_open.json
python -m unittest tests.test_vwap_holy_grail_replica -v
```

The report flags sessions without both a 09:30 bar and a 15:59 bar as incomplete. Do not compare an incomplete-data result with the paper's full-period headline. Run QQQ first across 2018-01-02 through 2023-09-28, then TQQQ with its own data, before making any XAUUSD/FX adaptation. The published QQQ/TQQQ performance is a paper-reported result, not a guarantee or evidence of transferability to gold or forex.

## Relationship to FLIPDEMON EXTREME

This harness is intentionally separate from `MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5`. It does not replace the live EA's rolling/session-anchored VWAP engine, alter its risk rules, or send orders. The live EA's current VWAP implementation is an adaptation for 24-hour instruments, not a faithful copy of the paper's NYSE-session strategy. No live execution is authorized by this research implementation.
