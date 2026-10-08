//+------------------------------------------------------------------+
//| Inputs.mqh                                                        |
//| All configurable inputs in one place. Every threshold mentioned   |
//| in the spec is exposed here rather than buried in engine code.    |
//+------------------------------------------------------------------+
#ifndef AXF_INPUTS_MQH
#define AXF_INPUTS_MQH

input group "=== IDENTITY & SAFETY ==="
input ulong   Inp_MagicNumber            = 15150015;   // Magic number (position isolation)
input bool    Inp_LiveTradingEnabled     = false;      // Master switch — must be explicitly true to send orders
input bool    Inp_AllowNewTrades         = true;       // Allow new entries (existing positions always managed)

input group "=== ACCOUNT RISK GOVERNOR ==="
input double  Inp_BaseRiskPct            = 0.50;       // Base risk % of equity per trade
input double  Inp_MaxRiskPct             = 2.50;       // Ceiling after all multipliers (<= hard ceiling)
input double  Inp_MaxPortfolioRiskPct    = 6.00;       // Ceiling on combined open risk across all symbols
input double  Inp_DailyMaxDrawdownPct    = 4.00;       // Halt new trades for the day beyond this
input double  Inp_WeeklyMaxDrawdownPct   = 8.00;       // Halt new trades for the week beyond this
input double  Inp_MaxAccountDrawdownPct  = 20.00;      // Full trading halt beyond this, manual reset required

input group "=== RISK OF RUIN GOVERNOR ==="
input double  Inp_RuinThreshold_Elevated = 15.0;       // P(50% DD) %, above this -> ELEVATED
input double  Inp_RuinThreshold_Defensive= 30.0;       // P(50% DD) %, above this -> DEFENSIVE
input double  Inp_RuinThreshold_Halt     = 50.0;       // P(50% DD) %, above this -> HALT
input int     Inp_MonteCarloPaths        = 2000;       // Simulated equity paths for ruin estimate
input int     Inp_MonteCarloTrades       = 200;        // Trades per simulated path

input group "=== LOSS / WIN STREAK DEFENSE ==="
input int     Inp_LossStreak_Reduce1     = 2;          // Consecutive losses -> first risk cut
input int     Inp_LossStreak_Reduce2     = 3;          // Consecutive losses -> defensive mode
input int     Inp_LossStreak_Halt        = 5;          // Consecutive losses -> halt, manual review
input double  Inp_LossStreak_CutFactor   = 0.50;       // Multiplier applied at each successive cut
input int     Inp_WinStreak_ReviewAt     = 4;          // Consecutive wins -> force exposure review (cap growth)
input double  Inp_WinStreak_CapFactor    = 1.50;       // Max multiplier growth allowed from a win streak alone

input group "=== EDGE-DECAY PROTECTION (Drift) ==="
// DriftEngine compares a recent window of closed trades against an older
// baseline from this EA's own journal. Previously this was recommend-only
// (logged, never enforced) — AdaptiveFlipEngine now actually applies it.
input int     Inp_Drift_RecentTrades     = 20;          // recent window size (closed trades)
input int     Inp_Drift_BaselineTrades   = 60;           // older baseline window size
input double  Inp_Drift_ReduceFactor     = 0.50;         // risk multiplier applied on DRIFT_REDUCE_RISK
input bool    Inp_Drift_HaltOnRecommendation = true;      // DRIFT_HALT_RECOMMENDED -> reject new trades (never auto-resumes; log and review)

input group "=== FLIP MODE ==="
input bool    Inp_FlipModeEnabled        = true;       // Allow FLIP mode to ever activate
input double  Inp_FlipScore_Elite        = 90.0;
input double  Inp_FlipScore_APlus        = 80.0;
input double  Inp_FlipScore_A            = 70.0;
input double  Inp_FlipScore_B            = 60.0;       // below this: NO TRADE
input double  Inp_FlipRiskMultiplier     = 2.00;       // Extra multiplier applied only in FLIP mode (bounded)

input group "=== VOLATILITY ==="
input int     Inp_ATR_Period             = 14;
input ENUM_TIMEFRAMES Inp_ATR_Timeframe  = PERIOD_H1;
input int     Inp_VolLookback            = 100;        // bars used to build volatility distribution

input group "=== REGIME ==="
input ENUM_TIMEFRAMES Inp_HTF            = PERIOD_H4;  // higher timeframe for bias/regime
input ENUM_TIMEFRAMES Inp_LTF            = PERIOD_M15; // execution timeframe
input int     Inp_ADX_Period             = 14;
input double  Inp_ADX_StrongTrend        = 35.0;

input group "=== STRUCTURE / LIQUIDITY ==="
input int     Inp_SwingLookback          = 5;          // bars each side for swing pivot detection
input int     Inp_StructureBars          = 300;        // bars scanned for structure/liquidity mapping
input double  Inp_FVG_MinAtrFraction     = 0.15;       // minimum gap size as fraction of ATR to count as FVG

input group "=== EXPECTED VALUE / EXECUTION COST ==="
input double  Inp_CommissionPerLot       = 0.0;        // account currency per 1.0 lot round turn
input double  Inp_AssumedSlippagePoints  = 3.0;        // points, floor used until enough LIVE fills exist to measure real slippage
input double  Inp_MaxSpreadPoints        = 35.0;       // absolute reject ceiling regardless of the symbol's own normal spread
input double  Inp_MinRR_Required         = 1.5;        // minimum reward:risk to accept a setup

input group "=== LIVE EXECUTION REALISM ==="
// Demo fills are not representative of a live account: live spreads widen at
// rollover/news/thin liquidity in ways demo servers usually don't reproduce,
// and live slippage/rejections are broker- and time-of-day-dependent. These
// inputs make the EA react to what THIS account's own live executions show
// it, rather than trusting a fixed assumption.
input double  Inp_SpreadAnomalyMultiple  = 1.8;        // reject if current spread > this x the symbol's own rolling median spread
input int     Inp_SpreadHistorySamples   = 300;        // rolling spread samples kept per symbol (fed by the timer, ~1/cycle)
input int     Inp_MinSpreadSamplesToJudge= 30;          // below this many samples, fall back to the absolute ceiling only
input bool    Inp_RolloverBlackoutEnabled= true;        // block new entries around the broker's daily rollover
input int     Inp_RolloverHourServer     = 23;          // server-time hour rollover typically starts
input int     Inp_RolloverBlackoutMins   = 20;          // minutes blocked before AND after that hour boundary
input int     Inp_MinSlippageSamplesToUse= 15;          // below this many live fills, use Inp_AssumedSlippagePoints instead
input int     Inp_SlippageHistorySamples = 50;          // rolling realised-slippage samples kept per symbol

input group "=== SNIPER ENTRY ENGINE ==="
// Priority feature: do not chase the breakout candle with a market order.
// Wait for price to retrace into the order block / FVG that produced the
// break of structure and fill there with a pending limit order — a precise,
// pre-planned price instead of whatever the market hands you on the way out.
input bool    Inp_SniperEntryMode        = true;        // true = ONLY take setups with a real retracement zone (no market chase)
input double  Inp_SniperZoneFraction     = 0.55;        // 0=zone's near edge (fills easily, worse price) .. 1=far edge (best price, may never fill)
input double  Inp_SniperMaxDistanceATR   = 2.0;         // reject the zone if it is farther than this many ATRs from current price
input double  Inp_SniperMinDistancePoints= 20;          // reject the zone if it is basically at the current price already (not a real retracement)
input int     Inp_SniperExpiryMinutes    = 180;         // cancel an unfilled sniper order after this long
input bool    Inp_SniperCancelOnInvalidation = true;    // cancel a pending sniper order the moment a CHOCH forms against it

input group "=== ORDER FLOW / MICROSTRUCTURE ==="
// Volume profile is always real (built from tick/bar volume). Cumulative
// delta, pulse and footprint use the TICK RULE (uptick=buy-side,
// downtick=sell-side) unless the broker's ticks are flagged as real trades
// (SYMBOL_TICKS_MODE_TRADE) — most retail FX/CFD feeds are quote-based, not
// an aggressor-tagged tape, so treat these as a useful approximation, not
// exchange-grade order flow. DOM/heatmap needs the broker to actually expose
// Level 2 depth (MarketBookAdd) — most FX symbols do not; it reads UNKNOWN
// rather than fabricating a heatmap when unsupported.
input bool    Inp_OrderFlowEnabled       = true;        // master switch for this module
input int     Inp_OrderFlowRecalcSeconds = 10;          // recompute cadence per symbol (tick fetch is not free)
input int     Inp_OrderFlowTickLookbackMinutes = 30;    // ticks fetched go back at most this far
input int     Inp_OrderFlowMaxTicks      = 20000;       // hard cap on ticks fetched per recompute
input int     Inp_VolumeProfileBins      = 40;          // price buckets across the lookback range
input double  Inp_ValueAreaPct           = 70.0;        // % of volume that defines VAH/VAL around the POC
input int     Inp_PulseWindowSeconds     = 60;          // short window used for the Pulse oscillator
input int     Inp_FootprintBarsLookback  = 5;           // closed bars scanned for stacked-imbalance
input double  Inp_FootprintImbalanceRatio= 2.0;         // one side must beat the other by this multiple to count
input bool    Inp_DOMHeatmapEnabled      = true;        // try MarketBookAdd; degrades to unavailable if unsupported
input int     Inp_DOMWallDistancePoints  = 100;         // "nearby" range (points) used for the DOM imbalance ratio
input bool    Inp_OrderFlowConfirmationRequired = false; // HARD gate: require flow support before a sniper fill is even placed
input double  Inp_OrderFlowConfirmPulseMin = -20.0;      // for a LONG, pulse must be >= this (mirrored for SHORT)

input group "=== EXECUTION SAFETY ==="
input int     Inp_MaxSlippagePoints      = 20;         // OrderSend deviation
input int     Inp_MaxOrderRetries        = 3;
input int     Inp_ExecutionScoreFloor    = 40;         // below this (0-100), throttle trading

input group "=== NEWS / SESSION DEFENSE ==="
input bool    Inp_NewsDefenseEnabled     = true;
input int     Inp_NewsBlackoutMinsBefore = 30;
input int     Inp_NewsBlackoutMinsAfter  = 30;

input group "=== PYRAMIDING ==="
input bool    Inp_PyramidingEnabled      = false;
input int     Inp_MaxAddsPerPosition     = 2;

input group "=== SYMBOLS ==="
input string  Inp_TradedSymbols          = "XAUUSD,EURUSD,GBPUSD,USDJPY,GBPJPY,NAS100,US30,BTCUSD";
input string  Inp_DXY_Symbol             = "";          // leave blank if broker has no DXY symbol -> UNKNOWN macro bias

input group "=== BRIDGE (optional web dashboard telemetry) ==="
input bool    Inp_BridgeEnabled          = false;       // POST snapshots to the AUTOPSY X bridge server
input string  Inp_BridgeURL              = "http://127.0.0.1:8787"; // must be present in Tools->Options->Expert Advisors->WebRequest
input string  Inp_BridgeKey              = "";
input int     Inp_BridgePostSeconds      = 5;

input group "=== MISC ==="
input int     Inp_TimerSeconds           = 1;
input bool    Inp_VerboseLogging         = false;

#endif // AXF_INPUTS_MQH
