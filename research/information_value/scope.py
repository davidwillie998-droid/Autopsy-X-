"""Phase 5 scope declarations - read this before interpreting ANY result in
this package. Two distinct scope limitations apply, and every downstream
module/report references these constants rather than restating them.

============================================================================
1. DAILY DATA != M15 EXECUTION TIMEFRAME
============================================================================
The only real historical data obtained (docs/PHASE5_DATA_PROVENANCE.md) is
DAILY. AUTOPSY X FLIPDEMON EXTREME is primarily an intraday MT5 system
(engines default to PERIOD_M1/PERIOD_M5/PERIOD_H1 depending on the specific
engine - there is no single "the" execution timeframe, but none of them is
daily).

DAILY_SCOPE_DISCLAIMER (attach verbatim to every real-data finding this
phase produces):

    "This result is empirical evidence about XAUUSD/EURUSD behaviour at
    DAILY granularity. It is NOT evidence that the corresponding intraday
    (M1/M5/M15/H1) feature has predictive value in the live system. Daily
    and intraday return dynamics are not assumed to share the same
    statistical properties, and no extrapolation from one to the other is
    made anywhere in this phase."

============================================================================
2. WHICH OF THE 5 ARCHITECTURE LAYERS ARE ACTUALLY TESTABLE ON THIS DATA
============================================================================
The available real XAUUSD series is close-price-only (no open/high/low -
see the provenance doc). Auditing what each layer's OWN authoritative MQL5
implementation actually requires (not assumed - read directly from each
engine's own source):

  MarketStateEngine.mqh   - almost every field needs either true range/ATR
                             (gapPts, rangePts, atrPts) or TICK-LEVEL data
                             this dataset was never going to have anyway
                             (structure/liquidity/volume/microstructure, all
                             reused from tick-driven engines). Only
                             `returnPct`/`logReturn` (close & priorClose
                             only) are faithfully reconstructible.
                             -> REDUCED to raw return only.

  Regime.mqh / RegimeClassifierEngine.mqh
                           - `m_volRatio = currentATR/avgATR` gates the
                             CHAOTIC/erratic branch and feeds the R6/R8
                             classification paths directly. Cannot be
                             faithfully reconstructed without true range.
                             -> NOT tested against real data this phase.
                             Carried forward as INSUFFICIENT EVIDENCE
                             (real-data), same disposition as Shock DNA.

  VolatilityEngine.mqh (5-state ATR/percentile/acceleration classification)
                           - needs real ATR (iATR, true range).
                             -> NOT tested against real data this phase.

  VolatilitySerialityEngine.mqh
                           - its own header already distinguishes what it
                             reuses (CVolatilityEngine's ATR-based fields)
                             from what it genuinely computes NEW: lag-1
                             return autocorrelation, directional
                             persistence, and reversal frequency - ALL
                             computed purely from closed-bar LOG RETURNS,
                             no high/low needed. -> THE SAME FORMULAS are
                             faithfully reusable here, computed on real
                             XAU close-to-close returns. This is the one
                             sub-component of the Volatility/Seriality
                             layer this phase can honestly test for real.

  InformationTransmissionEngine.mqh / lead_lag.py
                           - needs only two aligned return series (leader,
                             receiver). Fully reconstructible: the actual
                             `lead_lag.py` functions are imported and run
                             directly against real XAU/EUR log returns, not
                             reimplemented.

  ShockDNAEngine.mqh      - onset detection and range_expansion_atr are
                             both true-range-based by definition (Phase 4B's
                             own primary formula). Cannot be faithfully
                             reconstructed. -> NOT tested against real data
                             this phase (per explicit standing instruction).

CONSEQUENCE: the real-data ablation matrix in this phase is NOT the full
five-layer A->E hierarchy from the authorization. It is a REDUCED matrix
over what the data can actually support honestly:

    Model A' : naive baseline (raw log-return persistence only)
    Model B' : + Volatility/Seriality's genuinely-new return-based
               sub-metrics (autocorrelation, directional persistence,
               reversal frequency) - the SAME formulas as
               VolatilitySerialityEngine.mqh, not a reimplementation
    Model C' : + Information Transmission (real lag-correlation via
               lead_lag.py, EUR<->XAU)

Regime's ATR-gated classification, CVolatilityEngine's own state taxonomy,
and Shock DNA all remain OUT of the real-data ablation and receive an
explicit INSUFFICIENT EVIDENCE (real-data) disposition in the final report,
carried forward pending a genuine OHLC XAUUSD source - never silently
dropped from the report, never approximated under the engine's real name.

============================================================================
3. EUR/USD IS AN EXPLORATORY PROXY, NOT DXY, NOT "THE" GOLD/USD RELATIONSHIP
============================================================================
EUR/USD was chosen only because the live EA has no hardcoded Information
Transmission pair and it is the most liquid FX pair available through this
connector. Any transmission finding involving EUR/USD is scoped to
"EUR/USD specifically", never generalized to "USD strength" or "DXY" or
"the gold/dollar relationship" as an established fact.
"""

DAILY_SCOPE_DISCLAIMER = (
    "This result is empirical evidence about XAUUSD/EURUSD behaviour at DAILY "
    "granularity. It is NOT evidence that the corresponding intraday (M1/M5/M15/H1) "
    "feature has predictive value in the live system. Daily and intraday return "
    "dynamics are not assumed to share the same statistical properties, and no "
    "extrapolation from one to the other is made anywhere in this phase."
)

REAL_DATA_TESTABLE_LAYERS = ("market_state_return_only", "volatility_seriality_return_metrics",
                             "information_transmission")
REAL_DATA_EXCLUDED_LAYERS = ("regime_atr_classification", "volatility_engine_state_taxonomy",
                             "shock_dna")

EUR_USD_PROXY_DISCLAIMER = (
    "EUR/USD is used here as an exploratory cross-asset proxy only. It is not DXY, "
    "not a USD-strength index, and not asserted to be the canonical gold/USD "
    "relationship - any finding is scoped to EUR/USD specifically."
)
