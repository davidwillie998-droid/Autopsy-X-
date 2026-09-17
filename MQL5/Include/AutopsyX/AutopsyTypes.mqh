//+------------------------------------------------------------------+
//| AutopsyTypes.mqh                                                    |
//| Shared enums/structs for the AUTOPSY X QQQ/TQQQ Regime Engine.    |
//| This module is a gatekeeper/risk layer, not another entry signal: |
//| every other AutopsyX*.mqh file includes this first, and an        |
//| existing EA that wires in the engine only ever needs to read an   |
//| AXRPermission snapshot back - it never needs to know how any of   |
//| these numbers were computed.                                      |
//+------------------------------------------------------------------+
#property strict
#ifndef AUTOPSYX_TYPES_MQH
#define AUTOPSYX_TYPES_MQH

//--- the six regime states from section 3 of the spec
enum ENUM_AXR_REGIME
  {
   AXR_R1_PERSISTENT_BULLISH,
   AXR_R2_BULLISH_UNSTABLE,
   AXR_R3_RANGE_CHOP,
   AXR_R4_BEARISH_TRANSITION,
   AXR_R5_PERSISTENT_BEARISH,
   AXR_R6_VOLATILITY_SHOCK
  };

enum ENUM_AXR_BIAS
  {
   AXR_BIAS_BULLISH,
   AXR_BIAS_BEARISH,
   AXR_BIAS_NEUTRAL
  };

enum ENUM_AXR_VOL_STATE
  {
   AXR_VOL_LOW,
   AXR_VOL_NORMAL,
   AXR_VOL_ELEVATED,
   AXR_VOL_HIGH,
   AXR_VOL_EXTREME
  };

//--- OK: everything configured resolved and is fresh. DEGRADED: something optional is missing/stale -
//--- risk is capped, never raised. CRITICAL: something the classifier cannot honestly run without is
//--- missing - new trades are blocked outright. See section 20 (fail-safe) - missing data is NEVER
//--- interpreted as bullish confirmation.
enum ENUM_AXR_DATA_STATUS
  {
   AXR_DATA_OK,
   AXR_DATA_DEGRADED,
   AXR_DATA_CRITICAL
  };

string AXRRegimeToString(ENUM_AXR_REGIME r)
  {
   switch(r)
     {
      case AXR_R1_PERSISTENT_BULLISH: return "R1 PERSISTENT BULLISH TREND";
      case AXR_R2_BULLISH_UNSTABLE:   return "R2 BULLISH BUT UNSTABLE";
      case AXR_R3_RANGE_CHOP:         return "R3 RANGE / CHOP";
      case AXR_R4_BEARISH_TRANSITION: return "R4 BEARISH TRANSITION";
      case AXR_R5_PERSISTENT_BEARISH: return "R5 PERSISTENT BEARISH TREND";
      case AXR_R6_VOLATILITY_SHOCK:   return "R6 VOLATILITY SHOCK";
     }
   return "UNKNOWN";
  }

string AXRBiasToString(ENUM_AXR_BIAS b)
  {
   if(b==AXR_BIAS_BULLISH) return "BULLISH";
   if(b==AXR_BIAS_BEARISH) return "BEARISH";
   return "NEUTRAL";
  }

string AXRVolStateToString(ENUM_AXR_VOL_STATE v)
  {
   switch(v)
     {
      case AXR_VOL_LOW:      return "LOW";
      case AXR_VOL_NORMAL:   return "NORMAL";
      case AXR_VOL_ELEVATED: return "ELEVATED";
      case AXR_VOL_HIGH:     return "HIGH";
      case AXR_VOL_EXTREME:  return "EXTREME";
     }
   return "UNKNOWN";
  }

string AXRDataStatusToString(ENUM_AXR_DATA_STATUS s)
  {
   if(s==AXR_DATA_OK) return "OK";
   if(s==AXR_DATA_DEGRADED) return "DEGRADED";
   return "CRITICAL";
  }

//--- the complete entry-permission API from sections 17/18 - the only thing an existing EA ever reads
struct AXRPermission
  {
   ENUM_AXR_REGIME      regime;
   ENUM_AXR_BIAS        bias;
   double               confidence;        // 0..100, CONFIDENCE_SCORE
   double               directionScore;    // -100..100
   double               trendEfficiency;   // 0..1
   ENUM_AXR_VOL_STATE   volState;
   double               volatilityScore;   // 0..100 (higher = more volatile)
   double               macroScore;        // -100..100
   double               macroReliability;  // 0..1 - how much real macro data actually fed macroScore
   double               breadthScore;      // -100..100
   double               liquidityScore;    // 0..100
   double               aggregateExposurePct; // % of equity, Nasdaq-correlated, across ALL open positions
   bool                 allowLong;
   bool                 allowShort;
   bool                 allowNewTrade;
   double               riskMultiplier;    // final composite multiplier (section 18 style, e.g. 1.25)
   double               finalRiskPercent;  // the same composite expressed as an absolute risk% (section 13 style)
   bool                 aggressiveMode;
   bool                 shockMode;
   bool                 preEventMode;
   bool                 waitForReprice;
   ENUM_AXR_DATA_STATUS dataStatus;
   string               reason;            // human-readable justification, for the log/audit trail
  };

//--- every configurable number in the engine, in one place, so nothing here is ever hard-coded
//--- permanently (the spec's own explicit requirement for the confidence weights extends to every
//--- other threshold too). Build one with AXRDefaultConfig(), then override only what you need.
struct AXRConfig
  {
   string          idPrefix;             // unique per instance - namespaces GlobalVariables/log files
   string          referenceSymbol;      // primary Nasdaq reference the classifier runs on (e.g. broker's NAS100/USTEC/QQQ)
   ENUM_TIMEFRAMES referenceTf;
   string          qqqSymbol;
   string          tqqqSymbol;           // informational only - sizing is the caller's own RiskEngine's job
   string          vixSymbol;            // "" = not configured, degrades cleanly
   string          dxySymbol;
   string          y2Symbol;
   string          y10Symbol;
   string          realYieldSymbol;
   string          breadthBasketCsv;     // "" = breadth degrades to zero reliability
   string          correlatedListCsv;    // "SYMBOL:beta,SYMBOL2:beta2,..." - see AutopsyCorrelationEngine

   //--- direction engine
   int    emaFast, emaMed, emaSlow;
   int    breakoutLookback, momentumLookback, swingLookback, fractalWing;

   //--- trend efficiency
   int    trendEfficiencyLookback;

   //--- volatility engine
   int    atrPeriod, percentileLookback, realizedVolLookback;
   double volLowThresh, volNormalThresh, volElevatedThresh, volHighThresh;
   double vixLowRef, vixHighRef;
   double shockVixChangePct, shockRvolPercentile, shockDailyMovePct, shockAtrExpansionRatio, shockVolumeRatio;
   int    shockMinConditions;

   //--- macro engine
   int    macroTrendLookbackDays, macroCalendarLookbackHours;
   double wMacroDxy, wMacro2y, wMacro10y, wMacroRealYield, wMacroCalendar;

   //--- breadth/liquidity
   int    breadthMaPeriod;
   double minBreadthReliability;

   //--- correlation
   double maxAggregateExposurePct;

   //--- event filter
   int    preEventBlackoutMinutes, inEventBlockMinutes, postEventRepriceMinutes;
   double preEventRiskMultiplier;

   //--- risk governor / drawdown bands
   double ddThresh1, ddThresh2, ddThresh3, ddThresh4;
   double ddMult1, ddMult2, ddMult3, ddMult4;
   double baseRiskPercent, maxRiskPercentPerTrade;

   //--- regime-classification thresholds
   double neutralDirectionBand;   // |directionScore| below this = "near neutral" (feeds R3)
   double strongDirectionThresh;  // |directionScore| at/above this = "strongly" bullish/bearish (feeds R1/R5)
   double highEfficiencyThresh;
   double lowEfficiencyThresh;
   double macroConflictThresh;    // |macroScore| against direction beyond this, when reliable, = conflict
   bool   hasDedicatedRangeStrategy; // section 12: allows a reduced 0.25x multiplier to trade R3 at all

   //--- composite confidence weights (must sum to ~100, but are normalized defensively either way)
   double wConfDirection, wConfTrendEff, wConfVolatility, wConfMacro, wConfBreadth, wConfLiquidity;
  };

AXRConfig AXRDefaultConfig(const string idPrefix, const string referenceSymbol)
  {
   AXRConfig c;
   c.idPrefix = idPrefix;
   c.referenceSymbol = referenceSymbol;
   c.referenceTf = PERIOD_D1;
   c.qqqSymbol = "QQQ"; c.tqqqSymbol = "TQQQ";
   c.vixSymbol=""; c.dxySymbol=""; c.y2Symbol=""; c.y10Symbol=""; c.realYieldSymbol="";
   c.breadthBasketCsv=""; c.correlatedListCsv="QQQ,TQQQ:3.0,US100:1.0,NAS100:1.0";

   c.emaFast=20; c.emaMed=50; c.emaSlow=200;
   c.breakoutLookback=20; c.momentumLookback=10; c.swingLookback=80; c.fractalWing=2;

   c.trendEfficiencyLookback=20;

   c.atrPeriod=14; c.percentileLookback=252; c.realizedVolLookback=20;
   c.volLowThresh=20.0; c.volNormalThresh=45.0; c.volElevatedThresh=65.0; c.volHighThresh=85.0;
   c.vixLowRef=12.0; c.vixHighRef=40.0;
   c.shockVixChangePct=15.0; c.shockRvolPercentile=90.0; c.shockDailyMovePct=3.0;
   c.shockAtrExpansionRatio=1.8; c.shockVolumeRatio=2.0; c.shockMinConditions=2;

   c.macroTrendLookbackDays=10; c.macroCalendarLookbackHours=48;
   c.wMacroDxy=25.0; c.wMacro2y=25.0; c.wMacro10y=15.0; c.wMacroRealYield=20.0; c.wMacroCalendar=15.0;

   c.breadthMaPeriod=50; c.minBreadthReliability=0.5;

   c.maxAggregateExposurePct=8.0;

   c.preEventBlackoutMinutes=30; c.inEventBlockMinutes=5; c.postEventRepriceMinutes=30;
   c.preEventRiskMultiplier=0.35;

   c.ddThresh1=3.0; c.ddThresh2=5.0; c.ddThresh3=8.0; c.ddThresh4=10.0;
   c.ddMult1=1.00;  c.ddMult2=0.75;  c.ddMult3=0.50;  c.ddMult4=0.25;
   c.baseRiskPercent=1.0; c.maxRiskPercentPerTrade=1.5;

   c.neutralDirectionBand=35.0; c.strongDirectionThresh=55.0;
   c.highEfficiencyThresh=0.60; c.lowEfficiencyThresh=0.35;
   c.macroConflictThresh=25.0;
   c.hasDedicatedRangeStrategy=false;

   c.wConfDirection=30.0; c.wConfTrendEff=20.0; c.wConfVolatility=20.0;
   c.wConfMacro=15.0; c.wConfBreadth=10.0; c.wConfLiquidity=5.0;
   return c;
  }
#endif // AUTOPSYX_TYPES_MQH
