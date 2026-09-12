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
input double  Inp_AssumedSlippagePoints  = 3.0;        // points, used in EV cost model
input double  Inp_MaxSpreadPoints        = 35.0;       // reject setups when spread exceeds this
input double  Inp_MinRR_Required         = 1.5;        // minimum reward:risk to accept a setup

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
