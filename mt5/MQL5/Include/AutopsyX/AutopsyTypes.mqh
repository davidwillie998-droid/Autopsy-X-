//+------------------------------------------------------------------+
//|                                               AutopsyTypes.mqh   |
//|  AUTOPSY X — QQQ/TQQQ Regime Engine                              |
//|  Shared enums and structs used by every AutopsyX module.         |
//|                                                                    |
//|  This file has no logic — it only defines the vocabulary the     |
//|  other modules and the host EA share, so none of them need to    |
//|  agree on magic numbers or string literals.                      |
//+------------------------------------------------------------------+
#property strict

// Six-state market regime classifier (spec section 3).
enum ENUM_AX_REGIME
  {
   AX_REGIME_R1_PERSISTENT_BULLISH = 0, // strong trend, efficient, low/normal vol, breadth supportive
   AX_REGIME_R2_BULLISH_UNSTABLE   = 1, // bullish direction but something (vol/macro/breadth/efficiency) is off
   AX_REGIME_R3_RANGE_CHOP         = 2, // near-neutral direction, low efficiency, frequent reversals
   AX_REGIME_R4_BEARISH_TRANSITION = 3, // bullish structure breaking down, momentum fading, vol waking up
   AX_REGIME_R5_PERSISTENT_BEARISH = 4, // strong bearish trend, efficient, breadth weak, vol controlled
   AX_REGIME_R6_VOLATILITY_SHOCK   = 5  // capital-preservation mode — overrides everything else
  };

// Directional bias, independent of regime label (a regime can be
// bullish-but-unstable, which is still a bullish bias).
enum ENUM_AX_BIAS
  {
   AX_BIAS_BEARISH = -1,
   AX_BIAS_NEUTRAL =  0,
   AX_BIAS_BULLISH =  1
  };

// Volatility classification (spec section 6).
enum ENUM_AX_VOL_STATE
  {
   AX_VOL_LOW      = 0,
   AX_VOL_NORMAL   = 1,
   AX_VOL_ELEVATED = 2,
   AX_VOL_HIGH     = 3,
   AX_VOL_EXTREME  = 4
  };

// Data-feed health (spec section 20). Never let DEGRADED/CRITICAL
// be silently treated as bullish confirmation — every engine that
// can't source a real number must raise this instead of guessing.
enum ENUM_AX_DATA_STATUS
  {
   AX_DATA_OK       = 0,
   AX_DATA_DEGRADED = 1, // one or more non-critical inputs missing/stale
   AX_DATA_CRITICAL = 2  // a critical input (price, VIX, DXY) missing/stale
  };

// Trade-permission decision, logged verbatim each run (spec section 23).
enum ENUM_AX_DECISION
  {
   AX_DECISION_APPROVE = 0,
   AX_DECISION_REDUCE  = 1,
   AX_DECISION_BLOCK   = 2
  };

//+------------------------------------------------------------------+
//| Composite-confidence weights (spec section 11). Configurable —   |
//| never hard-coded permanently. Values are fractions that should   |
//| sum to ~1.0; the engine renormalizes defensively if they don't.  |
//+------------------------------------------------------------------+
struct AxWeights
  {
   double w_direction;
   double w_trend_efficiency;
   double w_volatility;
   double w_macro;
   double w_breadth;
   double w_liquidity;

   void Defaults()
     {
      w_direction        = 0.30;
      w_trend_efficiency = 0.20;
      w_volatility       = 0.20;
      w_macro            = 0.15;
      w_breadth          = 0.10;
      w_liquidity        = 0.05;
     }
  };

//+------------------------------------------------------------------+
//| Drawdown governor bands (spec section 14). Configurable.         |
//+------------------------------------------------------------------+
struct AxDrawdownBand
  {
   double drawdown_from_pct; // inclusive lower bound
   double drawdown_to_pct;   // exclusive upper bound, 0 means "no upper bound / halt"
   double risk_multiplier;   // 0 => halt
  };

//+------------------------------------------------------------------+
//| One full snapshot of everything AutopsyX knows right now. This   |
//| is what gets logged, and what the facade hands back to the EA.   |
//+------------------------------------------------------------------+
struct AxSnapshot
  {
   datetime            time;

   ENUM_AX_REGIME      regime;
   ENUM_AX_BIAS        bias;

   double              direction_score;      // -100..+100
   double              trend_efficiency;      // 0..1 raw ratio
   double              trend_efficiency_score;// 0..100 normalized for the composite

   ENUM_AX_VOL_STATE   vol_state;
   double              volatility_score;      // 0..100, favorable-conditions read for the composite
   double              volatility_multiplier; // 0..1, feeds the risk governor directly

   double              macro_score;           // -100..+100
   double              breadth_score;         // -100..+100
   double              liquidity_score;       // 0..100

   double              confidence_score;      // 0..100 composite

   double              regime_multiplier;     // risk governor input
   double              correlation_multiplier;
   double              drawdown_multiplier;
   double              risk_multiplier;       // final, after every governor and clamp

   bool                allow_long;
   bool                allow_short;
   bool                allow_new_trade;
   bool                aggressive_mode;
   bool                shock_mode;

   ENUM_AX_DATA_STATUS data_status;
   ENUM_AX_DECISION    decision;
   string              decision_note;

   void Clear()
     {
      time                    = 0;
      regime                  = AX_REGIME_R3_RANGE_CHOP;
      bias                    = AX_BIAS_NEUTRAL;
      direction_score         = 0.0;
      trend_efficiency        = 0.0;
      trend_efficiency_score  = 0.0;
      vol_state               = AX_VOL_NORMAL;
      volatility_score        = 50.0;
      volatility_multiplier   = 1.0;
      macro_score             = 0.0;
      breadth_score           = 0.0;
      liquidity_score         = 50.0;
      confidence_score        = 0.0;
      regime_multiplier       = 0.0;
      correlation_multiplier  = 1.0;
      drawdown_multiplier     = 1.0;
      risk_multiplier         = 0.0;
      allow_long              = false;
      allow_short             = false;
      allow_new_trade         = false;
      aggressive_mode         = false;
      shock_mode              = false;
      data_status             = AX_DATA_OK;
      decision                = AX_DECISION_BLOCK;
      decision_note           = "uninitialized";
     }
  };

//+------------------------------------------------------------------+
//| Small helpers shared by every engine.                            |
//+------------------------------------------------------------------+
double AxClamp(const double value, const double lo, const double hi)
  {
   if(value < lo) return lo;
   if(value > hi) return hi;
   return value;
  }

double AxLerp(const double a, const double b, const double t01)
  {
   const double t = AxClamp(t01, 0.0, 1.0);
   return a + (b - a) * t;
  }

string AxRegimeToString(const ENUM_AX_REGIME r)
  {
   switch(r)
     {
      case AX_REGIME_R1_PERSISTENT_BULLISH: return "R1_PERSISTENT_BULLISH";
      case AX_REGIME_R2_BULLISH_UNSTABLE:   return "R2_BULLISH_UNSTABLE";
      case AX_REGIME_R3_RANGE_CHOP:         return "R3_RANGE_CHOP";
      case AX_REGIME_R4_BEARISH_TRANSITION: return "R4_BEARISH_TRANSITION";
      case AX_REGIME_R5_PERSISTENT_BEARISH: return "R5_PERSISTENT_BEARISH";
      case AX_REGIME_R6_VOLATILITY_SHOCK:   return "R6_VOLATILITY_SHOCK";
     }
   return "UNKNOWN";
  }

string AxBiasToString(const ENUM_AX_BIAS b)
  {
   if(b == AX_BIAS_BULLISH) return "BULLISH";
   if(b == AX_BIAS_BEARISH) return "BEARISH";
   return "NEUTRAL";
  }

string AxVolStateToString(const ENUM_AX_VOL_STATE v)
  {
   switch(v)
     {
      case AX_VOL_LOW:      return "LOW";
      case AX_VOL_NORMAL:   return "NORMAL";
      case AX_VOL_ELEVATED: return "ELEVATED";
      case AX_VOL_HIGH:     return "HIGH";
      case AX_VOL_EXTREME:  return "EXTREME";
     }
   return "UNKNOWN";
  }

string AxDataStatusToString(const ENUM_AX_DATA_STATUS s)
  {
   if(s == AX_DATA_OK)       return "OK";
   if(s == AX_DATA_DEGRADED) return "DEGRADED";
   return "CRITICAL";
  }

string AxDecisionToString(const ENUM_AX_DECISION d)
  {
   if(d == AX_DECISION_APPROVE) return "APPROVE";
   if(d == AX_DECISION_REDUCE)  return "REDUCE";
   return "BLOCK";
  }
