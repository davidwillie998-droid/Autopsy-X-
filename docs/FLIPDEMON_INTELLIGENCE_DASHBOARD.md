# FLIPDEMON EXTREME Intelligence Architecture Dashboard

## Purpose

The dashboard observability layer makes the analysis pipeline visible without creating a new trading strategy.

The UI presents:

DATA → DATA QUALITY → MARKET STATE → EVIDENCE → SIGNAL → MODEL GATE → RISK → EXECUTION → SYSTEM HEALTH

## Important runtime boundary

This web client does not expose the MT5 CTradePermissionMatrix, account-level CRiskEngine, trade journal, or dormant MQL5 Layer 2 engines.

Therefore the dashboard deliberately labels those capabilities as UNAVAILABLE rather than fabricating live values.

The existing web synthesis gate is displayed as MODEL GATE. It must not be interpreted as MT5 execution permission.

## Evidence-family model

The UI groups observations into:

- Price / Structure
- Liquidity
- Macro / Positioning
- Microstructure
- Momentum
- Volatility
- Execution Quality

Unavailable families remain unavailable. The interface does not convert correlated observations into independent votes.

## Confidence separation

Signal Confidence uses the existing response field.

Data Confidence uses the existing data_integrity state. No artificial percentage is derived when the source does not provide one.

## Safety boundary

This feature does not:

- create orders
- modify order logic
- modify risk thresholds
- modify signal thresholds
- modify sizing
- override execution controls
- activate dormant trading modules

It is a read-only presentation layer.

## Verification note

The change is implemented in the web client (index.html). It does not constitute MT5 compilation, Strategy Tester validation, demo validation, or live-trading validation.