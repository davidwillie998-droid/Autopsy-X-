# New York IPDA Session Clock

The daily-extreme projection engine now defines its session boundaries in
America/New_York wall-clock time. It converts those boundaries to the broker's
server timestamps before reading M1 bars.

## Default session windows

| Model | New York time | Use |
|---|---:|---|
| Asia range | 20:00 previous evening to 00:00 | Establish the overnight range before the NY trading day |
| CBDR | 14:00 to 20:00 | Six-hour Central Bank Dealers Range |
| IPDA daily range | 00:00 to current time | Daily high/low and ADR usage context |

The engine calculates US daylight-saving transitions using the second Sunday
in March and first Sunday in November. Session boundaries are not hard-coded
to UTC-4 or UTC-5.

## Broker clock conversion

In live operation, the engine estimates the current broker-server UTC offset
from `TimeTradeServer() - TimeGMT()`. It then translates New York session
boundaries into broker-server timestamps for `CopyRates()`.

For Strategy Tester or historical replay, set
`InpDailyExtremeBrokerUtcOffsetMinutes` to the broker server's UTC offset in
minutes. Examples: UTC+2 = 120, UTC+3 = 180, UTC = 0. The sentinel 9999 means
automatic live detection and is deliberately rejected in Strategy Tester.

A single fixed offset is only valid for test data where the broker's server
offset did not change. If the broker changed its UTC offset seasonally during
the replay period, split the replay into offset-consistent periods or extend
the configuration to a dated broker-offset schedule before treating session
statistics as valid.

## Important boundaries

- The Asia range belongs to the prior New York evening and ends at current
  New York midnight. It is not 00:00-07:00 broker time.
- CBDR remains 14:00-20:00 New York time.
- The engine uses completed M1 bars for session extrema.
- ADR20 still uses the prior 20 broker D1 candles. Its daily boundary may not
  coincide exactly with New York midnight on every broker.
- These levels are projections and context, not independent entry signals.
- Python source-contract and DST reference tests do not constitute an MQL5
  compile, MT5 Strategy Tester result, or evidence of trading profitability.
