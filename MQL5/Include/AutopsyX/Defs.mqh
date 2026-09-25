//+------------------------------------------------------------------+
//|                                                        Defs.mqh |
//|                        AUTOPSY X FLIPDEMON EXTREME - Core Types |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_DEFS_MQH
#define AX_DEFS_MQH

//--- Risk / aggression mode ------------------------------------------------
enum ENUM_AX_MODE
  {
   AX_MODE_NORMAL = 0,      // 0.5% risk per trade
   AX_MODE_AGGRESSIVE = 1,  // 1.0% risk per trade
   AX_MODE_EXTREME = 2      // up to 2.0% risk per trade (configurable)
  };

//--- Trade direction ---------------------------------------------------------
enum ENUM_AX_DIR
  {
   AX_DIR_NONE = 0,
   AX_DIR_BUY  = 1,
   AX_DIR_SELL = -1
  };

//--- Market regime classification --------------------------------------------
enum ENUM_AX_REGIME
  {
   AX_REGIME_TREND = 0,
   AX_REGIME_STRONG_TREND,
   AX_REGIME_BREAKOUT,
   AX_REGIME_RANGE,
   AX_REGIME_MEAN_REVERSION,
   AX_REGIME_HIGH_VOL,
   AX_REGIME_LOW_VOL,
   AX_REGIME_CHAOTIC,
   AX_REGIME_UNSAFE
  };

//--- Engine state shown on dashboard ------------------------------------------
enum ENUM_AX_ENGINE_STATE
  {
   AX_ENGINE_ACTIVE = 0,
   AX_ENGINE_ATTACKING,
   AX_ENGINE_MANAGING,
   AX_ENGINE_COOLDOWN,
   AX_ENGINE_PAUSED,
   AX_ENGINE_KILLED
  };

//--- Exit reasons ---------------------------------------------------------
enum ENUM_AX_EXIT_REASON
  {
   AX_EXIT_NONE = 0,
   AX_EXIT_TP,
   AX_EXIT_SL,
   AX_EXIT_MOMENTUM_COLLAPSE,
   AX_EXIT_OPPOSITE_SIGNAL,
   AX_EXIT_MICROSTRUCTURE_REVERSAL,
   AX_EXIT_MAX_HOLD_TIME,
   AX_EXIT_SPREAD_ABNORMAL,
   AX_EXIT_EXECUTION_QUALITY,
   AX_EXIT_RISK_SHUTDOWN,
   AX_EXIT_FLIP,
   AX_EXIT_MANUAL_KILL,
   AX_EXIT_BREAKEVEN_STOP,
   AX_EXIT_TRAIL_STOP,
   AX_EXIT_VWAP_TREND_FLIP    // mechanical VWAP exit (Zarattini & Aziz 2023) - a bar closed on the
                               // wrong side of VWAP from the position's own direction; only armed
                               // when InpUseVWAPExit is on AND the position agreed with VWAP at entry
  };

//--- VWAP Trend Engine anchoring mode - see VWAPEngine.mqh ---------------------
enum ENUM_AX_VWAP_MODE
  {
   AX_VWAP_ROLLING = 0,        // trailing window, no session-boundary assumption
   AX_VWAP_SESSION_ANCHORED    // resets at the most recent of 4 configurable FX session opens
  };

//--- VWAP mechanical exit mode (FLIPDEMON EXTREME upgrade, spec section 9) - replaces the         ---
//--- previously-unconditional (whenever armed) VWAP exit with an explicit, configurable trigger.   ---
enum ENUM_AX_VWAP_EXIT_MODE
  {
   AX_VWAP_EXIT_OFF = 0,
   AX_VWAP_EXIT_IMMEDIATE,                       // any tick where live price crosses to the wrong side
   AX_VWAP_EXIT_CONFIRMED_CROSS,                  // requires a closed bar on the wrong side (the
                                                    // original behavior, and still the default -
                                                    // respects VWAPEngine's own ATR deadband since
                                                    // ClassifyVWAPTrend already builds that in)
   AX_VWAP_EXIT_CONFIRMED_CROSS_PLUS_STRUCTURE    // confirmed cross AND the structure engine agrees
                                                    // a reversal is underway (BOS/CHoCH/MSS against
                                                    // the position's direction) - the strictest mode,
                                                    // avoids exiting on a VWAP cross that structure
                                                    // itself hasn't corroborated
  };

//--- Trade permission verdict (institutional engine upgrade, spec section 18/28) - ENGINEERING       ---
//--- DESIGN. Deliberately five states, not a boolean: the pipeline must be able to say "conditions    ---
//--- don't justify full size right now" without collapsing that into the same TRADE/NO-TRADE binary  ---
//--- everything else already has. ---
enum ENUM_AX_FINAL_DECISION
  {
   AX_DECISION_TRADE = 0,
   AX_DECISION_REDUCE_RISK,
   AX_DECISION_WAIT,
   AX_DECISION_NO_TRADE,
   AX_DECISION_HALT
  };

//--- Inferred tick-direction classification (Layer 4, institutional engine upgrade) - PAPER-SOURCED: ---
//--- Lee, C. and Ready, M. "Inferring Trade Direction from Intraday Data", Journal of Finance, 46    ---
//--- (1991), 733-746 - reference [11] in Malhotra SSRN 3306817, and explicitly named there ("Tick    ---
//--- test T and quote test Q are used to infer trade direction... from TAQ trade"). This is an       ---
//--- INFERENCE from price/quote behavior, never a claim of seeing a real trade-aggressor flag - see  ---
//--- Microstructure2.mqh for the exact same honest caveat OrderFlow.mqh already carries. ---
enum ENUM_AX_TICK_DIRECTION
  {
   AX_TICKDIR_BUY = 1,
   AX_TICKDIR_SELL = -1,
   AX_TICKDIR_UNCLASSIFIED = 0   // only the very first tick with no prior reference is genuinely
                                  // unclassifiable by this method - never guessed
  };

//--- Volatility regime (Layer 2, institutional engine upgrade) - ENGINEERING DESIGN, not paper-     ---
//--- sourced. Distinct from ENUM_AX_REGIME (which is a trend/breakout/range classification that     ---
//--- happens to use ATR as one input) - this is purely about how much price is moving right now,    ---
//--- independent of direction or trend structure. ---
enum ENUM_AX_VOLATILITY_STATE
  {
   AX_VOL_NORMAL = 0,
   AX_VOL_LOW,
   AX_VOL_HIGH,
   AX_VOL_EXTREME,
   AX_VOL_SHOCK        // a sudden, sharp spike distinct from a sustained HIGH/EXTREME regime -
                        // see CVolatilityEngine for the exact acceleration-based trigger
  };

//--- Macro input bias read (Layer 1, institutional engine upgrade) - ENGINEERING DESIGN, not       ---
//--- paper-sourced. DATA_UNAVAILABLE is distinct from NEUTRAL: NEUTRAL means the symbol was read    ---
//--- successfully and showed no clear short-term bias; DATA_UNAVAILABLE means it couldn't be read   ---
//--- (not configured, not selectable on this broker, or confidence decayed below the usable floor). ---
enum ENUM_AX_MACRO_BIAS
  {
   AX_MACRO_BULLISH = 0,
   AX_MACRO_BEARISH,
   AX_MACRO_NEUTRAL,
   AX_MACRO_DATA_UNAVAILABLE
  };

//--- Execution mode (spec section 37) - governs whether the EA sends real orders at all. Default  ---
//--- is ANALYSIS_ONLY: generate signals/decisions but send no orders. Never switches silently -     ---
//--- this is a single input, set once, read at OnInit. ---
enum ENUM_AX_EXECUTION_MODE
  {
   AX_EXEC_ANALYSIS_ONLY = 0,   // signals/decisions generated and logged, no orders of any kind sent
   AX_EXEC_PAPER,               // simulates the order lifecycle and journals it, no real broker orders
   AX_EXEC_LIVE                 // sends real MT5 orders via CExecutionEngine
  };

//--- Trade autopsy classification ------------------------------------------
enum ENUM_AX_TRADE_CLASS
  {
   AX_CLASS_CORRECT_MOMENTUM = 0,
   AX_CLASS_FALSE_BREAKOUT,
   AX_CLASS_LIQUIDITY_TRAP,
   AX_CLASS_LATE_ENTRY,
   AX_CLASS_PREMATURE_EXIT,
   AX_CLASS_MOMENTUM_FAILURE,
   AX_CLASS_CORRECT_FLIP,
   AX_CLASS_FALSE_FLIP,
   AX_CLASS_SPREAD_FAILURE,
   AX_CLASS_SLIPPAGE_FAILURE,
   AX_CLASS_STOP_LOSS,
   AX_CLASS_TAKE_PROFIT,
   AX_CLASS_RISK_SHUTDOWN
  };

//--- Profitability gate classification (section 20) --------------------------
enum ENUM_AX_GATE
  {
   AX_GATE_FAIL = 0,
   AX_GATE_WEAK,
   AX_GATE_PROMISING,
   AX_GATE_VALIDATED,
   AX_GATE_INSUFFICIENT_DATA
  };

//--- which real dataset a journal record belongs to (spec section 29) - detected from actual        ---
//--- account/terminal state at journal-write time, never inferred or guessed after the fact. ---
enum ENUM_AX_DATASET_PROVENANCE
  {
   AX_PROVENANCE_UNKNOWN = 0,
   AX_PROVENANCE_BACKTEST,       // MQLInfoInteger(MQL_TESTER) was true
   AX_PROVENANCE_FORWARD_DEMO,   // live terminal, ACCOUNT_TRADE_MODE_DEMO
   AX_PROVENANCE_LIVE            // live terminal, ACCOUNT_TRADE_MODE_REAL (or CONTEST, tagged the same -
                                  // a contest account is not this EA's own capital either way, and
                                  // README already documents the live/demo distinction as REAL vs not-REAL)
  };

//--- Kelly ruin-bound state (spec section 31) - REPORT ONLY, never authorizes risk directly. ---
enum ENUM_AX_KELLY_STATE
  {
   AX_KELLY_VALID = 0,
   AX_KELLY_INSUFFICIENT_SAMPLE,
   AX_KELLY_BOUND_FAILED,
   AX_KELLY_INVALID_INPUT,
   AX_KELLY_RUIN_CONDITION
  };

//--- Adaptive Flip Engine capital state - a graduated de-risking ladder driven by continuous
//--- peak-equity drawdown, distinct from CRiskEngine's binary day-anchored daily loss limit ---
enum ENUM_AX_CAPITAL_STATE
  {
   AX_CAPITAL_NORMAL = 0,     // full configured risk
   AX_CAPITAL_CAUTION,        // scaled-down risk, drawdown-from-peak is building
   AX_CAPITAL_DEFENSIVE,      // heavily scaled-down risk, drawdown-from-peak is serious
   AX_CAPITAL_LOCKED          // AFE hard-blocks new risk entirely until conditions recover
  };

//--- Composite direction state (FLIPDEMON EXTREME upgrade, spec section 4) - the output of
//--- weighing every directional engine (HTF, regime, liquidity, momentum, microstructure,
//--- order flow, VWAP, VP-MACD) against each other. Deliberately NOT a binary BUY/SELL - a
//--- reduced vote count would hide exactly the "not enough evidence" and "something is actively
//--- wrong" cases the rest of the pipeline needs to tell apart. ---
enum ENUM_AX_COMPOSITE_DIRECTION
  {
   AX_COMPOSITE_BULLISH = 0,
   AX_COMPOSITE_BEARISH,
   AX_COMPOSITE_NEUTRAL,              // evidence was evaluated and genuinely doesn't favor a side
   AX_COMPOSITE_BLOCKED,              // a hard defensive condition overrides any directional read
   AX_COMPOSITE_DATA_UNAVAILABLE,     // a required input couldn't be computed (e.g. regime has
                                       // insufficient ATR history) - distinct from NEUTRAL, which
                                       // means the data WAS available and said "no edge"
   AX_COMPOSITE_INSUFFICIENT_EVIDENCE // data was available but too few engines produced a usable
                                       // directional read to justify acting on any of them
  };

//--- Execution eligibility state (spec section 13) - CheckExecutionEligibility()'s verdict. ---
enum ENUM_AX_ELIGIBILITY
  {
   AX_ELIGIBLE_LONG = 0,
   AX_ELIGIBLE_SHORT,
   AX_NOT_ELIGIBLE,          // evaluated, conditions simply don't clear the bar (EV/R:R/etc.)
   AX_ELIGIBILITY_BLOCKED,   // a hard defensive/risk condition vetoes entry outright
   AX_ELIGIBILITY_DATA_UNAVAILABLE,
   AX_ELIGIBILITY_INSUFFICIENT_EVIDENCE
  };

//--- Structure Engine (FLIPDEMON EXTREME upgrade, spec section 5) - BOS/CHoCH/MSS. NOTE: none of
//--- these three terms has one universally agreed formal definition across retail market-structure
//--- education - the exact operational definitions used here are documented in StructureEngine.mqh
//--- itself, stated plainly rather than presented as if they were the single correct reading. ---
enum ENUM_AX_STRUCTURE_EVENT
  {
   AX_STRUCT_NONE = 0,
   AX_STRUCT_BOS_BULLISH,     // Break of Structure: close beyond the most recent swing high, WITH
                               // the prevailing trend (continuation)
   AX_STRUCT_BOS_BEARISH,
   AX_STRUCT_CHOCH_BULLISH,   // Change of Character: close beyond the most recent swing high
                               // AGAINST a prevailing bearish structure (first sign of reversal)
   AX_STRUCT_CHOCH_BEARISH,
   AX_STRUCT_MSS_BULLISH,     // Market Structure Shift: a CHoCH that a subsequent swing has
                               // confirmed by making a genuine new higher low in the new direction
   AX_STRUCT_MSS_BEARISH
  };

//--- prevailing structural trend read, from the most recent two confirmed swings of each type ---
enum ENUM_AX_STRUCT_TREND
  {
   AX_STRUCT_TREND_BULLISH = 0,   // most recent swing high is HH, most recent swing low is HL
   AX_STRUCT_TREND_BEARISH,       // most recent swing high is LH, most recent swing low is LL
   AX_STRUCT_TREND_UNDEFINED      // mixed read, or too few confirmed swings yet to tell
  };

//--- Trade lifecycle state (FLIPDEMON EXTREME upgrade, spec section 21). Strictly linear/forward -
//--- CTradeLifecycle enforces that a setup can only advance to the next state in this exact order,
//--- or drop to CANCELLED/FAILED from any non-terminal state. Nothing is ever assumed complete -
//--- ORDER_FILLED is only reached after a real broker confirmation, never after ORDER_SUBMITTED alone.
enum ENUM_AX_LIFECYCLE_STATE
  {
   AX_LIFECYCLE_SIGNAL_DETECTED = 0,
   AX_LIFECYCLE_THESIS_CREATED,
   AX_LIFECYCLE_VALIDATING,
   AX_LIFECYCLE_RISK_CHECK,
   AX_LIFECYCLE_ORDER_READY,
   AX_LIFECYCLE_ORDER_SUBMITTED,
   AX_LIFECYCLE_ORDER_FILLED,
   AX_LIFECYCLE_POSITION_ACTIVE,
   AX_LIFECYCLE_POSITION_MANAGED,
   AX_LIFECYCLE_EXIT_TRIGGERED,
   AX_LIFECYCLE_POSITION_CLOSED,
   AX_LIFECYCLE_JOURNALED,
   AX_LIFECYCLE_AUTOPSIED,
   AX_LIFECYCLE_CANCELLED,   // dropped out before any order reached the market (failed validation/risk/data)
   AX_LIFECYCLE_FAILED       // dropped out after an order attempt (rejected, broker error, etc.)
  };

//--- One microstructure/momentum tick sample ---------------------------------
struct SAxTick
  {
   datetime time;
   double   bid;
   double   ask;
   double   mid;
   double   spreadPts;
   int      dir;          // +1 up, -1 down, 0 flat (vs previous mid)
   long     volume;        // broker tick volume for this sample (>=1 - most feeds report at least
                            // a tick-count proxy even without real traded size); used to weight
                            // order-flow/footprint/volume-profile calculations rather than treating
                            // every tick as equal
  };

//--- Independent BUY/SELL score bundle ---------------------------------------
struct SAxScore
  {
   double        buyScore;     // 0..100
   double        sellScore;    // 0..100
   double        confidence;   // 0..100
   ENUM_AX_DIR   action;
   ENUM_AX_REGIME regime;
   datetime      time;
  };

//--- Pending directional-accuracy snapshot (section 18) ----------------------
struct SAxAccuracySnapshot
  {
   datetime time;
   double   priceAtSignal;
   int      predictedDir;    // +1 / -1
   bool     done[5];         // 1s,3s,5s,10s,30s resolved flags
   bool     correct[5];
  };

//--- Completed trade autopsy record (section 17) ------------------------------
struct SAxTradeRecord
  {
   string              setupId;          // links this record back to the SAxTradeThesis that
                                          // produced it - empty for records predating this field
                                          // or for untracked/restart-recovered positions
   ulong               ticket;
   ulong               dealIdIn;         // 0 if not yet known/recorded from a real deal ticket
   ulong               dealIdOut;
   datetime            entryTime;
   datetime            exitTime;
   ENUM_AX_DIR         direction;
   double              entryPrice;
   double              exitPrice;
   double              lots;
   double              spreadAtEntry;
   double              slippagePts;
   int                 holdSeconds;
   double              buyScore;
   double              sellScore;
   double              confidence;
   ENUM_AX_REGIME      regime;
   string              entryReason;
   ENUM_AX_EXIT_REASON exitReason;
   double              mfe;              // max favorable excursion, in account currency
   double              mae;              // max adverse excursion, in account currency
   double              grossProfit;
   double              commission;
   double              swap;
   double              netProfit;
   ENUM_AX_TRADE_CLASS tradeClass;
   int                 flipSeq;          // 0 = not a flip result, >0 = flip generation number
   bool                isPartial;        // true = a scale-out slice, not a full trade outcome -
                                          // excluded from win/loss and adaptive-tuning statistics

   //--- Adaptive Flip Engine readings AT ENTRY TIME - carried through so the autopsy CSV shows ---
   //--- why AFE allowed/scaled this specific trade, not just what happened to it afterward ---
   ENUM_AX_CAPITAL_STATE afeCapitalState;
   double                afeRiskOfRuinPct;
   double                afeExpectedValueR;
   double                afeWinProbability;
   double                afeRiskMultiplier;

   //--- order-book impact cost estimated at entry, for the size originally intended before any  ---
   //--- AFE/impact-cost capping (Patnaik & Thomas 2004) - 0 when depth was unavailable to measure it ---
   double                impactCostPct;

   //--- R-multiple: netProfit expressed as a multiple of the ORIGINAL risk (entryPrice to          ---
   //--- originalSlPrice, in currency) - the unit Monte Carlo/Kelly both operate on. 0 for a record  ---
   //--- where original risk couldn't be computed (never fabricated as a made-up ratio). ---
   double                rMultiple;

   //--- engine states AT ENTRY TIME, journaled as their own columns (not just folded into the free- ---
   //--- text entryReason string) so they can be queried/filtered directly (spec section 27) ---
   string                vwapStateAtEntry;
   string                vpMacdStateAtEntry;
   string                orderFlowStateAtEntry;
   string                structureStateAtEntry;
   string                liquidityStateAtEntry;
   string                newsStateAtEntry;
   string                sessionAtEntry;

   //--- which real dataset this record belongs to - detected from actual account/terminal state    ---
   //--- (AccountInfoInteger(ACCOUNT_TRADE_MODE), MQLInfoInteger(MQL_TESTER)) at journal-write time,  ---
   //--- never guessed. This is what lets adaptive learning (spec section 29) separate historical/    ---
   //--- forward-demo/live data instead of silently mixing them. ---
   ENUM_AX_DATASET_PROVENANCE provenance;
  };

//--- Formal Trade Thesis (FLIPDEMON EXTREME upgrade, spec section 3) - the frozen, auditable
//--- record of WHY a specific setup was (or wasn't) taken. "Frozen at entry" means: every field
//--- below is set exactly once, at thesis-creation time, from what was actually known at that
//--- moment - never rewritten afterward using information that only became available later.
//--- The one exception is invalidationReason, which starts empty and is populated exactly once,
//--- if and when the thesis is later judged invalid - that population event itself is a real,
//--- timestamped fact (ExitEngine/management logic reacting to new information), not a rewrite
//--- of what the thesis originally claimed at entry.
struct SAxTradeThesis
  {
   string                     setupId;
   string                     symbol;
   ENUM_AX_DIR                direction;
   datetime                   timestamp;

   ENUM_AX_COMPOSITE_DIRECTION htfBias;          // higher-timeframe structural bias at thesis time
   ENUM_AX_COMPOSITE_DIRECTION executionBias;     // execution-timeframe composite direction
   ENUM_AX_REGIME             marketRegime;

   double                     liquidityTargetPrice; // 0 if no specific target identified - never
                                                     // fabricated just to fill the field
   string                     liquidityCondition;   // free-text description of the liquidity
                                                     // hypothesis this setup is trading against
   string                     structureState;       // BOS/MSS/CHoCH label from the structure
                                                     // engine, or "UNAVAILABLE" until Phase 3 wires it
   string                     entryModel;

   string                     vwapState;            // "BULLISH"/"BEARISH"/"NEUTRAL"/"DATA_UNAVAILABLE"
   string                     vpMacdState;          // same convention; "DATA_UNAVAILABLE" until built
   string                     orderFlowState;
   string                     momentumState;

   SAxScore                   signalScore;          // the full buy/sell/confidence bundle at entry

   double                     expectedEntry;
   double                     stopLoss;
   double                     takeProfit;
   double                     initialRR;
   double                     spreadPts;
   double                     estimatedImpactCostPct;
   double                     expectedValueR;

   string                     newsState;            // "ALLOW"/"BLOCK"/"DATA_UNAVAILABLE"
   string                     session;
   string                     volatilityState;

   double                     riskPercent;
   double                     riskMultiplier;

   int                        flipSeq;              // 0 = not a flip result
   string                     eligibilityStatus;     // string form of ENUM_AX_ELIGIBILITY at the
                                                      // moment execution eligibility was checked
   string                     entryReason;
   string                     invalidationReason;    // empty until/unless the thesis is invalidated
  };

//--- one confirmed swing point from CStructureEngine - built ONLY from closed bars (see
//--- StructureEngine.mqh for the no-lookahead guarantee this implies) ---
struct SAxSwingPoint
  {
   double   price;
   datetime time;
   bool     isHigh;    // true = swing high, false = swing low
   bool     isHH;       // meaningful only when isHigh - higher than the prior swing high
   bool     isLH;       // meaningful only when isHigh - lower than the prior swing high
   bool     isHL;       // meaningful only when !isHigh - higher than the prior swing low
   bool     isLL;       // meaningful only when !isHigh - lower than the prior swing low
  };

//--- one macro/cross-asset input read (Layer 1, institutional engine upgrade) - carries its own    ---
//--- provenance so a caller can never mistake a stale or unavailable read for a fresh, trustworthy  ---
//--- one. "available" false means value/timestamp are meaningless (0), never a fabricated number. ---
struct SAxMacroInput
  {
   string   source;           // the symbol name this reading came from, e.g. "EURUSD"
   double   value;             // last read price; 0 when !available
   datetime timestamp;         // broker-reported time of that price; 0 when !available
   double   freshnessSeconds;  // TimeCurrent() - timestamp; 0 when !available
   double   confidence;        // 0..100, decays with freshness - see MacroRegime.mqh
   bool     available;
  };

//--- helpers -----------------------------------------------------------------
string AxDirToString(const ENUM_AX_DIR d)
  {
   if(d==AX_DIR_BUY)  return("BUY");
   if(d==AX_DIR_SELL) return("SELL");
   return("NONE");
  }

string AxRegimeToString(const ENUM_AX_REGIME r)
  {
   switch(r)
     {
      case AX_REGIME_TREND:           return("TREND");
      case AX_REGIME_STRONG_TREND:    return("STRONG TREND");
      case AX_REGIME_BREAKOUT:        return("BREAKOUT");
      case AX_REGIME_RANGE:           return("RANGE");
      case AX_REGIME_MEAN_REVERSION:  return("MEAN REVERSION");
      case AX_REGIME_HIGH_VOL:        return("HIGH VOLATILITY");
      case AX_REGIME_LOW_VOL:         return("LOW VOLATILITY");
      case AX_REGIME_CHAOTIC:         return("CHAOTIC");
      case AX_REGIME_UNSAFE:          return("UNSAFE");
     }
   return("UNKNOWN");
  }

string AxExitReasonToString(const ENUM_AX_EXIT_REASON r)
  {
   switch(r)
     {
      case AX_EXIT_TP:                     return("TAKE_PROFIT");
      case AX_EXIT_SL:                     return("STOP_LOSS");
      case AX_EXIT_MOMENTUM_COLLAPSE:       return("MOMENTUM_COLLAPSE");
      case AX_EXIT_OPPOSITE_SIGNAL:         return("OPPOSITE_SIGNAL");
      case AX_EXIT_MICROSTRUCTURE_REVERSAL: return("MICROSTRUCTURE_REVERSAL");
      case AX_EXIT_MAX_HOLD_TIME:           return("MAX_HOLD_TIME");
      case AX_EXIT_SPREAD_ABNORMAL:         return("SPREAD_ABNORMAL");
      case AX_EXIT_EXECUTION_QUALITY:       return("EXECUTION_QUALITY");
      case AX_EXIT_RISK_SHUTDOWN:           return("RISK_SHUTDOWN");
      case AX_EXIT_FLIP:                    return("FLIP");
      case AX_EXIT_MANUAL_KILL:             return("MANUAL_KILL");
      case AX_EXIT_BREAKEVEN_STOP:          return("BREAKEVEN_STOP");
      case AX_EXIT_TRAIL_STOP:              return("TRAIL_STOP");
      case AX_EXIT_VWAP_TREND_FLIP:         return("VWAP_TREND_FLIP");
     }
   return("NONE");
  }

string AxTradeClassToString(const ENUM_AX_TRADE_CLASS c)
  {
   switch(c)
     {
      case AX_CLASS_CORRECT_MOMENTUM: return("CORRECT_MOMENTUM");
      case AX_CLASS_FALSE_BREAKOUT:   return("FALSE_BREAKOUT");
      case AX_CLASS_LIQUIDITY_TRAP:   return("LIQUIDITY_TRAP");
      case AX_CLASS_LATE_ENTRY:       return("LATE_ENTRY");
      case AX_CLASS_PREMATURE_EXIT:   return("PREMATURE_EXIT");
      case AX_CLASS_MOMENTUM_FAILURE: return("MOMENTUM_FAILURE");
      case AX_CLASS_CORRECT_FLIP:     return("CORRECT_FLIP");
      case AX_CLASS_FALSE_FLIP:       return("FALSE_FLIP");
      case AX_CLASS_SPREAD_FAILURE:   return("SPREAD_FAILURE");
      case AX_CLASS_SLIPPAGE_FAILURE: return("SLIPPAGE_FAILURE");
      case AX_CLASS_STOP_LOSS:        return("STOP_LOSS");
      case AX_CLASS_TAKE_PROFIT:      return("TAKE_PROFIT");
      case AX_CLASS_RISK_SHUTDOWN:    return("RISK_SHUTDOWN");
     }
   return("UNKNOWN");
  }

string AxCapitalStateToString(const ENUM_AX_CAPITAL_STATE s)
  {
   switch(s)
     {
      case AX_CAPITAL_NORMAL:     return("NORMAL");
      case AX_CAPITAL_CAUTION:    return("CAUTION");
      case AX_CAPITAL_DEFENSIVE:  return("DEFENSIVE");
      case AX_CAPITAL_LOCKED:     return("LOCKED");
     }
   return("UNKNOWN");
  }

string AxGateToString(const ENUM_AX_GATE g)
  {
   switch(g)
     {
      case AX_GATE_FAIL:              return("FAIL");
      case AX_GATE_WEAK:               return("WEAK");
      case AX_GATE_PROMISING:          return("PROMISING");
      case AX_GATE_VALIDATED:          return("VALIDATED");
      case AX_GATE_INSUFFICIENT_DATA:  return("INSUFFICIENT DATA");
     }
   return("UNKNOWN");
  }

string AxCompositeDirectionToString(const ENUM_AX_COMPOSITE_DIRECTION d)
  {
   switch(d)
     {
      case AX_COMPOSITE_BULLISH:               return("BULLISH");
      case AX_COMPOSITE_BEARISH:               return("BEARISH");
      case AX_COMPOSITE_NEUTRAL:               return("NEUTRAL");
      case AX_COMPOSITE_BLOCKED:               return("BLOCKED");
      case AX_COMPOSITE_DATA_UNAVAILABLE:      return("DATA_UNAVAILABLE");
      case AX_COMPOSITE_INSUFFICIENT_EVIDENCE: return("INSUFFICIENT_EVIDENCE");
     }
   return("UNKNOWN");
  }

string AxEligibilityToString(const ENUM_AX_ELIGIBILITY e)
  {
   switch(e)
     {
      case AX_ELIGIBLE_LONG:                     return("ELIGIBLE_LONG");
      case AX_ELIGIBLE_SHORT:                    return("ELIGIBLE_SHORT");
      case AX_NOT_ELIGIBLE:                      return("NOT_ELIGIBLE");
      case AX_ELIGIBILITY_BLOCKED:               return("BLOCKED");
      case AX_ELIGIBILITY_DATA_UNAVAILABLE:      return("DATA_UNAVAILABLE");
      case AX_ELIGIBILITY_INSUFFICIENT_EVIDENCE: return("INSUFFICIENT_EVIDENCE");
     }
   return("UNKNOWN");
  }

string AxStructureEventToString(const ENUM_AX_STRUCTURE_EVENT e)
  {
   switch(e)
     {
      case AX_STRUCT_NONE:           return("NONE");
      case AX_STRUCT_BOS_BULLISH:    return("BOS_BULLISH");
      case AX_STRUCT_BOS_BEARISH:    return("BOS_BEARISH");
      case AX_STRUCT_CHOCH_BULLISH:  return("CHOCH_BULLISH");
      case AX_STRUCT_CHOCH_BEARISH:  return("CHOCH_BEARISH");
      case AX_STRUCT_MSS_BULLISH:    return("MSS_BULLISH");
      case AX_STRUCT_MSS_BEARISH:    return("MSS_BEARISH");
     }
   return("UNKNOWN");
  }

string AxStructTrendToString(const ENUM_AX_STRUCT_TREND t)
  {
   switch(t)
     {
      case AX_STRUCT_TREND_BULLISH:   return("BULLISH");
      case AX_STRUCT_TREND_BEARISH:   return("BEARISH");
      case AX_STRUCT_TREND_UNDEFINED: return("UNDEFINED");
     }
   return("UNKNOWN");
  }

string AxLifecycleStateToString(const ENUM_AX_LIFECYCLE_STATE s)
  {
   switch(s)
     {
      case AX_LIFECYCLE_SIGNAL_DETECTED: return("SIGNAL_DETECTED");
      case AX_LIFECYCLE_THESIS_CREATED:  return("THESIS_CREATED");
      case AX_LIFECYCLE_VALIDATING:      return("VALIDATING");
      case AX_LIFECYCLE_RISK_CHECK:      return("RISK_CHECK");
      case AX_LIFECYCLE_ORDER_READY:     return("ORDER_READY");
      case AX_LIFECYCLE_ORDER_SUBMITTED: return("ORDER_SUBMITTED");
      case AX_LIFECYCLE_ORDER_FILLED:    return("ORDER_FILLED");
      case AX_LIFECYCLE_POSITION_ACTIVE: return("POSITION_ACTIVE");
      case AX_LIFECYCLE_POSITION_MANAGED:return("POSITION_MANAGED");
      case AX_LIFECYCLE_EXIT_TRIGGERED:  return("EXIT_TRIGGERED");
      case AX_LIFECYCLE_POSITION_CLOSED: return("POSITION_CLOSED");
      case AX_LIFECYCLE_JOURNALED:       return("JOURNALED");
      case AX_LIFECYCLE_AUTOPSIED:       return("AUTOPSIED");
      case AX_LIFECYCLE_CANCELLED:       return("CANCELLED");
      case AX_LIFECYCLE_FAILED:          return("FAILED");
     }
   return("UNKNOWN");
  }

string AxProvenanceToString(const ENUM_AX_DATASET_PROVENANCE p)
  {
   switch(p)
     {
      case AX_PROVENANCE_UNKNOWN:       return("UNKNOWN");
      case AX_PROVENANCE_BACKTEST:      return("BACKTEST");
      case AX_PROVENANCE_FORWARD_DEMO:  return("FORWARD_DEMO");
      case AX_PROVENANCE_LIVE:          return("LIVE");
     }
   return("UNKNOWN");
  }

string AxKellyStateToString(const ENUM_AX_KELLY_STATE k)
  {
   switch(k)
     {
      case AX_KELLY_VALID:                return("VALID");
      case AX_KELLY_INSUFFICIENT_SAMPLE:  return("INSUFFICIENT_SAMPLE");
      case AX_KELLY_BOUND_FAILED:         return("BOUND_FAILED");
      case AX_KELLY_INVALID_INPUT:        return("INVALID_INPUT");
      case AX_KELLY_RUIN_CONDITION:       return("RUIN_CONDITION");
     }
   return("UNKNOWN");
  }

//--- detects the real, current dataset provenance from actual account/terminal state - never ---
//--- inferred from anything the EA itself decided or remembered. Call at journal-write time. ---
ENUM_AX_DATASET_PROVENANCE AxDetectProvenance(void)
  {
   if(MQLInfoInteger(MQL_TESTER)) return(AX_PROVENANCE_BACKTEST);
   long tradeMode = AccountInfoInteger(ACCOUNT_TRADE_MODE);
   if(tradeMode==ACCOUNT_TRADE_MODE_DEMO) return(AX_PROVENANCE_FORWARD_DEMO);
   if(tradeMode==ACCOUNT_TRADE_MODE_REAL || tradeMode==ACCOUNT_TRADE_MODE_CONTEST) return(AX_PROVENANCE_LIVE);
   return(AX_PROVENANCE_UNKNOWN);
  }

string AxVwapExitModeToString(const ENUM_AX_VWAP_EXIT_MODE m)
  {
   switch(m)
     {
      case AX_VWAP_EXIT_OFF:                          return("OFF");
      case AX_VWAP_EXIT_IMMEDIATE:                     return("IMMEDIATE");
      case AX_VWAP_EXIT_CONFIRMED_CROSS:                return("CONFIRMED_CROSS");
      case AX_VWAP_EXIT_CONFIRMED_CROSS_PLUS_STRUCTURE: return("CONFIRMED_CROSS_PLUS_STRUCTURE");
     }
   return("UNKNOWN");
  }

string AxFinalDecisionToString(const ENUM_AX_FINAL_DECISION d)
  {
   switch(d)
     {
      case AX_DECISION_TRADE:        return("TRADE");
      case AX_DECISION_REDUCE_RISK:  return("REDUCE_RISK");
      case AX_DECISION_WAIT:         return("WAIT");
      case AX_DECISION_NO_TRADE:     return("NO_TRADE");
      case AX_DECISION_HALT:         return("HALT");
     }
   return("UNKNOWN");
  }

string AxVolatilityStateToString(const ENUM_AX_VOLATILITY_STATE v)
  {
   switch(v)
     {
      case AX_VOL_NORMAL:  return("NORMAL");
      case AX_VOL_LOW:     return("LOW_VOLATILITY");
      case AX_VOL_HIGH:    return("HIGH_VOLATILITY");
      case AX_VOL_EXTREME: return("EXTREME_VOLATILITY");
      case AX_VOL_SHOCK:   return("VOLATILITY_SHOCK");
     }
   return("UNKNOWN");
  }

string AxMacroBiasToString(const ENUM_AX_MACRO_BIAS b)
  {
   switch(b)
     {
      case AX_MACRO_BULLISH:          return("BULLISH");
      case AX_MACRO_BEARISH:          return("BEARISH");
      case AX_MACRO_NEUTRAL:          return("NEUTRAL");
      case AX_MACRO_DATA_UNAVAILABLE: return("DATA_UNAVAILABLE");
     }
   return("UNKNOWN");
  }

string AxExecutionModeToString(const ENUM_AX_EXECUTION_MODE m)
  {
   switch(m)
     {
      case AX_EXEC_ANALYSIS_ONLY: return("ANALYSIS_ONLY");
      case AX_EXEC_PAPER:         return("PAPER_EXECUTION");
      case AX_EXEC_LIVE:          return("LIVE_EXECUTION");
     }
   return("UNKNOWN");
  }

//--- generates a SetupID with enough entropy to be practically unique across ticks, restarts and
//--- reconnects. NOTE: uniqueness of this string alone is NOT the EA's duplicate-order protection -
//--- that also requires checking existing positions/pending orders/magic number (spec section 20,
//--- phase 5). This function only guarantees the thesis gets a real, traceable identifier. ---
string AxGenerateSetupId(const string symbol,const ENUM_AX_DIR dir)
  {
   // (int) cast of TimeCurrent() is deliberate, not a precision cut corner - a unix timestamp fits
   // an int until year 2038, and this string only needs to be a traceable, practically-unique tag,
   // not a precise 64-bit epoch value. %I64d avoided here since its MQL5 StringFormat support is
   // not something this environment can verify without a compiler - %d on an (int) cast is not in doubt.
   return(StringFormat("%s-%s-%d-%u-%d",symbol,AxDirToString(dir),(int)TimeCurrent(),
                        GetTickCount(),MathRand()));
  }

//--- live per-position management state (used by ExitEngine + main EA) -------
struct SAxPositionState
  {
   ulong          ticket;
   datetime       entryTime;
   double         entryPrice;
   ENUM_AX_DIR    dir;
   double         lots;
   double         initialSlPrice;
   double         initialTpPrice;
   double         originalSlPrice;      // initialSlPrice as placed at entry - NEVER mutated by
                                         // break-even/trailing, so R-multiple triggers (partial
                                         // take-profit) always measure against the true original risk
   bool           breakEvenDone;
   double         bestFavorablePrice;   // best price reached in favor of the position
   double         mfeCurrency;
   double         maeCurrency;
   double         entryBuyScore;
   double         entrySellScore;
   double         entryConfidence;
   ENUM_AX_REGIME entryRegime;
   string         entryReason;
   double         entrySpreadPts;
   double         entrySlippagePts;
   int            flipSeq;
   bool           active;
   int            modifyFailCount;      // consecutive failed SL/TP modify attempts on this position -
                                         // forces an execution-quality exit past a threshold, since a
                                         // position whose stops can't be reliably managed is unsafe to hold
   bool           partialTaken;         // true once the scale-out partial close has fired
   ulong          lastAccountedDealTicket; // highest deal ticket already reflected in a recorded
                                            // trade (full or partial). Filtering by ticket rather
                                            // than time avoids same-second collisions - MT5 deal
                                            // time has only 1-second resolution, but deal tickets
                                            // are strictly increasing in chronological order.

   //--- Adaptive Flip Engine readings captured at entry, carried into the closed trade record ---
   ENUM_AX_CAPITAL_STATE afeCapitalState;
   double                afeRiskOfRuinPct;
   double                afeExpectedValueR;
   double                afeWinProbability;
   double                afeRiskMultiplier;

   double                impactCostPct;

   //--- true only if InpUseVWAPExit was on AND this position's own direction agreed with the VWAP  ---
   //--- trend classification at the moment of entry - arms CExitEngine's mechanical VWAP exit for   ---
   //--- this specific position. A position whose thesis was never about VWAP doesn't get a VWAP-    ---
   //--- based exit forced onto it after the fact. ---
   bool                  vwapAlignedAtEntry;
  };

//--- exit decision returned by CExitEngine::Evaluate --------------------------
struct SAxExitDecision
  {
   bool                shouldExit;
   ENUM_AX_EXIT_REASON reason;
  };

double AxClampD(const double v, const double lo, const double hi)
  {
   if(v<lo) return(lo);
   if(v>hi) return(hi);
   return(v);
  }
//+------------------------------------------------------------------+
#endif // AX_DEFS_MQH
