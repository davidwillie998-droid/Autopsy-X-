# MT5 Snapshot Export and Replay Gate

## Snapshot export

The EA's optional `InpEnableMarketSnapshots` input enables a buffered CSV recorder.
It captures every valid tick accepted by the EA's market-data layer before downstream
integrity/risk gates can return early. When that tick reaches score evaluation, the
recorder attaches the same-tick blended BUY/SELL score, confidence, action and regime.
Rows also carry engine/pending/position state, account equity and margin fields, and
the symbol's execution/volume specifications. The `score_updated` field distinguishes
a same-tick decision from a raw tick that was rejected before scoring.

The recorder is observational only. It does not grant execution authority, change
risk calculations, or participate in entry eligibility. Rows are buffered in memory
and flushed by `OnTimer`, outside the tick handler. The buffer holds 4,096 rows;
overflow is counted in `dropped_before` on the next accepted tick and in a final
`SUMMARY` footer, including drops after the last accepted tick. Any nonzero dropped
count makes a file ineligible for replay import.

Files are written under the terminal's `MQL5/Files` directory with a unique
recording-session timestamp in the filename. They are not written to the Common
Files directory.

## Snapshot integrity preflight

Run from the `intel` package environment:

```bash
python -m autopsyx.mt5_snapshot MQL5/Files/AutopsyX_MarketSnapshots_<symbol>_<magic>_<session>.csv
```

The validator checks required schema, numeric integrity, symbol/magic consistency,
quote validity, timestamp regressions, sequence gaps and recorder-reported drops.
Equal-millisecond timestamps are reported but allowed because multiple valid ticks
can share the same millisecond timestamp.

A passing validator means only that the CSV is structurally eligible for import.
It does not mean the strategy was replayed, compiled, or profitable.

## Actual EA replay and performance claims

The Python validator does not execute MQL5. Actual strategy replay must run the
compiled Expert Advisor in MT5 Strategy Tester using broker-quality historical
ticks or a separately verified custom-symbol tick import. The test report must
identify the symbol, broker/server, date range, tick model, spread/commission/
slippage assumptions, terminal build, EA commit and tester report artifact.

No historical performance claim is permitted until that actual MT5 run exists.
