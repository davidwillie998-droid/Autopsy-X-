//+------------------------------------------------------------------+
//| Types.mqh                                                        |
//| Shared enums and structs for AUTOPSY X SWINGDEMON X15.           |
//| Every other module includes this first.                          |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_CORE_TYPES_MQH
#define AX_CORE_TYPES_MQH

enum ENUM_AX_REGIME
  {
   REGIME_STRONG_BULL,
   REGIME_WEAK_BULL,
   REGIME_STRONG_BEAR,
   REGIME_WEAK_BEAR,
   REGIME_RANGE,
   REGIME_EXPANSION,
   REGIME_CONTRACTION,
   REGIME_ACCUMULATION,
   REGIME_DISTRIBUTION,
   REGIME_VOL_EXPANSION,
   REGIME_VOL_COMPRESSION,
   REGIME_TRANSITIONAL,
   REGIME_CHAOTIC
  };

enum ENUM_AX_BIAS
  {
   BIAS_BULLISH,
   BIAS_BEARISH,
   BIAS_NEUTRAL
  };

enum ENUM_AX_LIQ_TYPE
  {
   LIQ_INTERNAL,
   LIQ_EXTERNAL,
   LIQ_RESTING,
   LIQ_ENGINEERED,
   LIQ_SWEPT,
   LIQ_PROTECTED,
   LIQ_VULNERABLE
  };

enum ENUM_AX_STRUCT_EVENT
  {
   STRUCT_NONE,
   STRUCT_BOS_BULL,
   STRUCT_BOS_BEAR,
   STRUCT_CHOCH_BULL,
   STRUCT_CHOCH_BEAR,
   STRUCT_MSS_BULL,
   STRUCT_MSS_BEAR
  };

enum ENUM_AX_SETUP
  {
   SETUP_NONE,
   SETUP_A_SWEEP_MSS,
   SETUP_B_HTF_CONTINUATION,
   SETUP_C_BREAKOUT_RETEST,
   SETUP_D_RANGE_REVERSAL,
   SETUP_E_HTF_IMBALANCE,
   SETUP_F_MACRO_REPRICING
  };

enum ENUM_AX_QUALITY
  {
   QUALITY_D = 0,
   QUALITY_C = 1,
   QUALITY_B = 2,
   QUALITY_A = 3,
   QUALITY_A_PLUS = 4
  };

enum ENUM_AX_ENTRY_MODEL
  {
   ENTRY_MARKET,
   ENTRY_LIMIT,
   ENTRY_CONFIRMATION
  };

enum ENUM_AX_PHASE
  {
   PHASE_1_INITIAL,
   PHASE_2_PROVEN,
   PHASE_3_RISK_REDUCED,
   PHASE_4_PARTIAL,
   PHASE_5_TRAILING,
   PHASE_6_FINAL
  };

enum ENUM_AX_EXIT_REASON
  {
   EXIT_NONE,
   EXIT_TP_FINAL,
   EXIT_TP_PARTIAL,
   EXIT_SL,
   EXIT_BREAKEVEN,
   EXIT_THESIS_INVALID,
   EXIT_STRUCTURAL_FAILURE,
   EXIT_MANUAL,
   EXIT_FAILSAFE,
   EXIT_TIME_STOP,
   EXIT_TRAIL,
   EXIT_WEEKEND
  };

enum ENUM_AX_OUTCOME
  {
   OUT_UNKNOWN,
   OUT_APLUS_WIN,
   OUT_A_WIN,
   OUT_B_WIN,
   OUT_APLUS_LOSS,
   OUT_A_LOSS,
   OUT_STRUCTURAL_FAILURE,
   OUT_LIQUIDITY_FAILURE,
   OUT_MACRO_FAILURE,
   OUT_EXECUTION_FAILURE,
   OUT_REGIME_FAILURE,
   OUT_PREMATURE_EXIT,
   OUT_LATE_EXIT
  };

//--- swing point on a given timeframe
struct AXSwingPoint
  {
   datetime time;
   double   price;
   bool     isHigh;
   int      barShift;
   bool     taken;      // liquidity resting here already swept
  };

//--- a mapped liquidity level (PDH/PDL/equal highs/etc.)
struct AXLiquidityLevel
  {
   double         price;
   ENUM_AX_LIQ_TYPE ltype;
   string         label;
   datetime       formedTime;
   bool           swept;
   datetime       sweptTime;
  };

//--- fair value gap / imbalance
struct AXFairValueGap
  {
   double   top;
   double   bottom;
   datetime time;
   bool     bullish;
   bool     mitigated;
   double   mitigationPct;
  };

//--- order block / breaker / mitigation block
struct AXOrderBlock
  {
   double           top;
   double           bottom;
   datetime         time;
   bool             bullish;
   bool             mitigated;
   double           qualityScore; // 0..100
   ENUM_TIMEFRAMES  tf;
  };

//--- structural snapshot for one timeframe
struct AXStructureSnapshot
  {
   ENUM_AX_STRUCT_EVENT lastEvent;
   datetime             lastEventTime;
   double               lastEventPrice;
   bool                 bullishStructure;
   double               lastSwingHigh;
   double               lastSwingLow;
  };

//--- dealing range / IPDA snapshot
struct AXDealingRange
  {
   double rangeHigh;
   double rangeLow;
   double equilibrium;
   double currentPricePct;   // 0 = range low, 1 = range high
   bool   inPremium;
   bool   inDiscount;
  };

//--- one candidate signal produced by the setup engine
struct AXSignal
  {
   ENUM_AX_SETUP setup;
   int           direction;       // +1 buy, -1 sell
   double        entryPrice;
   double        stopLoss;
   double        tp1, tp2, tpFinal;
   ENUM_AX_ENTRY_MODEL entryModel;
   double        rawScore;        // pre-fusion component score 0..100
   string        rationaleWhyNow;
   string        rationaleWhyHere;
   double        liquidityTarget;
  };

//--- fully fused, scored trade candidate
struct AXFusedSignal
  {
   AXSignal        signal;
   double          confidence;     // 0..100
   ENUM_AX_QUALITY quality;
   double          probContinuation;
   double          probReversal;
   double          probTp1, probTp2, probFinal;
   double          expectedValueR;
   bool            passesFilters;
   string          rejectReason;
  };

//--- live trade thesis attached to an open position
struct AXTradeThesis
  {
   ulong           ticket;
   int             direction;
   string          whyNow;
   string          whyHere;
   double          liquidityTarget;
   double          structuralInvalidation;
   int             expectedHoldingBars;
   double          expectedR;
   string          macroContext;
   ENUM_AX_REGIME  regime;
   double          confidence;
   ENUM_AX_SETUP   setup;
   ENUM_AX_QUALITY quality;
   datetime        openTime;
   double          entryPrice, stopLoss, tp1, tp2, tpFinal, initialStopDistance;
   double          initialRiskMoney;
   double          equityAtEntry;
   double          volumeOriginal, volumeRemaining;
   ENUM_AX_PHASE   phase;
   bool            partial1Done, partial2Done, movedToBreakeven;
   double          mfe, mae; // in R multiples
   double          highestPrice, lowestPrice;
  };

//--- closed-trade forensic record
struct AXAutopsy
  {
   ulong            ticket;
   string           setupType;
   string           regime;
   string           htfBias;
   string           liquidityObjective;
   string           poi;
   string           entryTF;
   double           entryPrice, stopLoss, tp1, tp2, tpFinal;
   double           riskPercent, rMultiple, mfeR, maeR;
   long             holdingSeconds;
   double           spreadAtEntry, commission, swapTotal, slippagePoints;
   string           newsEnvironment, macroContext, correlationNote, executionQuality;
   ENUM_AX_EXIT_REASON exitReason;
   ENUM_AX_OUTCOME  outcome;
   datetime         openTime, closeTime;
   double           netProfit;
  };

//--- string helpers -------------------------------------------------
string AXRegimeToString(ENUM_AX_REGIME r)
  {
   switch(r)
     {
      case REGIME_STRONG_BULL:    return "Strong Bullish Trend";
      case REGIME_WEAK_BULL:      return "Weak Bullish Trend";
      case REGIME_STRONG_BEAR:    return "Strong Bearish Trend";
      case REGIME_WEAK_BEAR:      return "Weak Bearish Trend";
      case REGIME_RANGE:          return "Range";
      case REGIME_EXPANSION:      return "Expansion";
      case REGIME_CONTRACTION:    return "Contraction";
      case REGIME_ACCUMULATION:   return "Accumulation";
      case REGIME_DISTRIBUTION:   return "Distribution";
      case REGIME_VOL_EXPANSION:  return "Volatility Expansion";
      case REGIME_VOL_COMPRESSION:return "Volatility Compression";
      case REGIME_TRANSITIONAL:   return "Transitional";
      case REGIME_CHAOTIC:        return "Chaotic/Uncertain";
     }
   return "Unknown";
  }

string AXBiasToString(ENUM_AX_BIAS b)
  {
   if(b==BIAS_BULLISH) return "Bullish";
   if(b==BIAS_BEARISH) return "Bearish";
   return "Neutral";
  }

string AXQualityToString(ENUM_AX_QUALITY q)
  {
   switch(q)
     {
      case QUALITY_A_PLUS: return "A+";
      case QUALITY_A:       return "A";
      case QUALITY_B:       return "B";
      case QUALITY_C:       return "C";
      case QUALITY_D:       return "D";
     }
   return "?";
  }

string AXSetupToString(ENUM_AX_SETUP s)
  {
   switch(s)
     {
      case SETUP_A_SWEEP_MSS:        return "A: Sweep+Displacement+MSS";
      case SETUP_B_HTF_CONTINUATION: return "B: HTF Trend Continuation";
      case SETUP_C_BREAKOUT_RETEST:  return "C: Breakout+Retest";
      case SETUP_D_RANGE_REVERSAL:   return "D: Range Extreme Reversal";
      case SETUP_E_HTF_IMBALANCE:    return "E: HTF Imbalance+LTF Confirm";
      case SETUP_F_MACRO_REPRICING:  return "F: Macro Repricing";
      default: return "None";
     }
  }

string AXExitReasonToString(ENUM_AX_EXIT_REASON e)
  {
   switch(e)
     {
      case EXIT_TP_FINAL:           return "Final Target Hit";
      case EXIT_TP_PARTIAL:         return "Partial Target Hit";
      case EXIT_SL:                 return "Stop Loss";
      case EXIT_BREAKEVEN:          return "Breakeven Stop";
      case EXIT_THESIS_INVALID:     return "Thesis Invalidated";
      case EXIT_STRUCTURAL_FAILURE: return "Structural Failure";
      case EXIT_MANUAL:             return "Manual Close";
      case EXIT_FAILSAFE:           return "Failsafe Triggered";
      case EXIT_TIME_STOP:          return "Time Stop";
      case EXIT_TRAIL:              return "Structural Trail";
      case EXIT_WEEKEND:            return "Weekend Risk Close";
      default: return "None";
     }
  }

string AXOutcomeToString(ENUM_AX_OUTCOME o)
  {
   switch(o)
     {
      case OUT_APLUS_WIN:          return "A+ WIN";
      case OUT_A_WIN:               return "A WIN";
      case OUT_B_WIN:               return "B WIN";
      case OUT_APLUS_LOSS:          return "A+ LOSS";
      case OUT_A_LOSS:              return "A LOSS";
      case OUT_STRUCTURAL_FAILURE:  return "STRUCTURAL FAILURE";
      case OUT_LIQUIDITY_FAILURE:   return "LIQUIDITY FAILURE";
      case OUT_MACRO_FAILURE:       return "MACRO FAILURE";
      case OUT_EXECUTION_FAILURE:   return "EXECUTION FAILURE";
      case OUT_REGIME_FAILURE:      return "REGIME FAILURE";
      case OUT_PREMATURE_EXIT:      return "PREMATURE EXIT";
      case OUT_LATE_EXIT:           return "LATE EXIT";
      default: return "UNKNOWN";
     }
  }
#endif // AX_CORE_TYPES_MQH
