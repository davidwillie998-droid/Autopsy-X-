# Flipdemon Extreme: broker-adaptive symbol universe

## Scope of this increment

This increment adds a reusable MQL5 discovery layer at
`MQL5/Include/AutopsyX/BrokerUniverse.mqh`. It reads the symbol catalogue
provided by the currently connected MT5 terminal, classifies symbols into
conservative market families, and captures broker-reported contract metadata.

It does **not** claim universal compatibility with every broker, and it does
not yet make the EA a multi-symbol execution engine. Broker symbol names and
available synthetic families differ; the terminal's actual symbol catalogue
is the source of truth.

## Discovery and classification

The module can enumerate visible Market Watch symbols or attempt to select all
symbols exposed by the terminal. For each symbol it records selection state,
trade mode, point, tick size/value, and volume minimum/maximum/step.

Families currently recognised include:

- Forex, using a conservative recognised-currency-code prefix check
- Gold
- Volatility synthetic indices
- Boom and Crash
- Jump
- Step
- Range Break
- Drift / switching
- Hybrid
- Other synthetic families, including names containing Trek, Skew, DEX,
  Multi Step, Daily Reset, or a generic Synthetic marker
- Unknown / other symbols

Name matching is a discovery heuristic, not proof of a product's mechanics.
A broker can use arbitrary prefixes, suffixes, abbreviations, or proprietary
names. Unknown instruments must remain unqualified until a provider-specific
mapping and contract review is added.

## Fail-closed contract checks

A symbol is marked non-tradeable by this discovery layer if the terminal
reports disabled trading or critical metadata is absent/invalid: point,
tick size, minimum/maximum volume, or volume step. Downstream execution must
also verify current session/trade mode, stop/freeze levels, margin, spread,
price freshness, supported order filling, and a valid stop-loss calculation.

## Required next integration stages

1. Wire the universe into an explicit scanner without changing the existing
   single-symbol execution path accidentally.
2. Add symbol-specific market-data, regime, and strategy state; do not share
   indicator handles or cached prices across symbols.
3. Add a central account-level risk coordinator and enforce the one-position
   policy across the whole account, not separately per chart.
4. Add broker-specific synthetic mappings and contract-aware stop/volume
   calculations. Do not assume forex/gold indicator logic transfers to
   synthetic products.
5. Add unit/static tests and broker demo tests for symbol discovery, market
   sessions, volume rounding, stop distances, rejected orders, reconnects,
   and position reconciliation.
6. Compile in MetaEditor and run Strategy Tester plus demo forward tests before
   considering any live mode.

The EA must remain in `ANALYSIS_ONLY` during development. This module itself
does not send orders and cannot activate live trading.
