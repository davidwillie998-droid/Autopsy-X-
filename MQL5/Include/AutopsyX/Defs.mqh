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
   AX_EXIT_TRAIL_STOP
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

//--- One microstructure/momentum tick sample ---------------------------------
struct SAxTick
  {
   datetime time;
   double   bid;
   double   ask;
   double   mid;
   double   spreadPts;
   int      dir;          // +1 up, -1 down, 0 flat (vs previous mid)
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
   ulong               ticket;
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
