//+------------------------------------------------------------------+
//|                                            AutopsyXCommon.mqh     |
//|  AUTOPSY X — QQQ/TQQQ Regime Engine                                |
//|  Shared enums, structs and math helpers used by every sub-engine.  |
//|                                                                     |
//|  This is a modular INTELLIGENCE / RISK-GOVERNOR layer, not a       |
//|  trading strategy. It never places, modifies or closes an order    |
//|  itself. It only answers "can the existing EA trade, which side,   |
//|  and at what size" — see AutopsyRegimeEngineCore.mqh for the       |
//|  public API an existing EA is meant to call.                       |
//+------------------------------------------------------------------+
#property strict

//--- Six-state market regime classification (spec section 3)
enum ENUM_AX_REGIME
  {
   AX_REGIME_UNKNOWN = 0,   // not enough data yet / just initialized
   AX_R1_PERSISTENT_BULL,   // persistent bullish trend
   AX_R2_BULL_UNSTABLE,     // bullish but unstable
   AX_R3_RANGE_CHOP,        // range / chop
   AX_R4_BEAR_TRANSITION,   // bearish transition
   AX_R5_PERSISTENT_BEAR,   // persistent bearish trend
   AX_R6_VOL_SHOCK          // volatility shock — capital preservation
  };

//--- Volatility classification (spec section 6)
enum ENUM_AX_VOL_STATE
  {
   AX_VOL_UNKNOWN = 0,
   AX_VOL_LOW,
   AX_VOL_NORMAL,
   AX_VOL_ELEVATED,
   AX_VOL_HIGH,
   AX_VOL_EXTREME
  };

//--- Data-source health. A source in DEGRADED or UNAVAILABLE state must
//    never be silently treated as neutral-good — see the fail-safe rule
//    in spec section 20: missing data reduces risk, it never confirms it.
enum ENUM_AX_DATA_STATUS
  {
   AX_DATA_OK = 0,
   AX_DATA_DEGRADED,     // stale, or a soft read failure
   AX_DATA_UNAVAILABLE   // symbol/feed not present at all
  };

//--- Simple two-value score-with-health wrapper used by every sub-engine
//    so a caller can tell "score is -40" apart from "we don't actually know".
struct AxScore
  {
   double            value;     // engine-specific range, see each engine's header
   ENUM_AX_DATA_STATUS status;
  };

//+------------------------------------------------------------------+
//| Math helpers                                                      |
//+------------------------------------------------------------------+

//--- Population/sample standard deviation of a double array.
double AxStdDev(const double &arr[])
  {
   int n = ArraySize(arr);
   if(n < 2)
      return 0.0;
   double mean = 0.0;
   for(int i = 0; i < n; i++)
      mean += arr[i];
   mean /= n;
   double sumSq = 0.0;
   for(int i = 0; i < n; i++)
      sumSq += (arr[i] - mean) * (arr[i] - mean);
   return MathSqrt(sumSq / (n - 1));
  }

//--- Linear-interpolated percentile (0.0-1.0) of a double array, sorted internally.
//    q = 0.90 == "90th percentile", matching the VIX-dummy>90th-pct idea from
//    the FX liquidity literature this project's other engines are built on.
double AxPercentile(const double &arrIn[], double q)
  {
   int n = ArraySize(arrIn);
   if(n == 0)
      return 0.0;
   double sorted[];
   ArrayResize(sorted, n);
   ArrayCopy(sorted, arrIn);
   ArraySort(sorted);
   if(n == 1)
      return sorted[0];
   q = MathMax(0.0, MathMin(1.0, q));
   double pos  = (n - 1) * q;
   int    base = (int)MathFloor(pos);
   double rest = pos - base;
   if(base + 1 < n)
      return sorted[base] + rest * (sorted[base + 1] - sorted[base]);
   return sorted[base];
  }

//--- Where does `x` sit inside `arr`, expressed as a 0..1 percentile rank?
//    Used to turn "current ATR" into "current ATR's percentile vs its own
//    recent history" without needing a second, differently-scaled series.
double AxPercentileRank(const double &arr[], double x)
  {
   int n = ArraySize(arr);
   if(n == 0)
      return 0.5;
   int below = 0;
   for(int i = 0; i < n; i++)
      if(arr[i] <= x)
         below++;
   return (double)below / (double)n;
  }

//--- Kaufman-style efficiency ratio (spec section 5):
//    ABS(net change) / SUM(ABS(bar-to-bar changes)) over the lookback.
//    1.0 = pure directional move with no backtracking; near 0 = noisy chop.
//    `closes[]` must be ordered oldest(0) -> newest(size-1), length >= lookback+1.
double AxTrendEfficiency(const double &closes[], int lookback)
  {
   int n = ArraySize(closes);
   if(n < lookback + 1 || lookback < 1)
      return 0.0;
   double netChange = MathAbs(closes[n - 1] - closes[n - 1 - lookback]);
   double sumAbs = 0.0;
   for(int i = n - lookback; i < n; i++)
      sumAbs += MathAbs(closes[i] - closes[i - 1]);
   if(sumAbs <= 0.0)
      return 0.0;
   return netChange / sumAbs;
  }

//--- Clamp to [lo, hi].
double AxClamp(double x, double lo, double hi)
  {
   if(x < lo) return lo;
   if(x > hi) return hi;
   return x;
  }

//--- Linear interpolation of `t` (expected 0..1) between [a, b].
double AxLerp(double a, double b, double t)
  {
   t = AxClamp(t, 0.0, 1.0);
   return a + (b - a) * t;
  }

//--- Human-readable labels, used by logging and by any UI that reads the
//    engine's outputs.
string AxRegimeToString(ENUM_AX_REGIME r)
  {
   switch(r)
     {
      case AX_R1_PERSISTENT_BULL: return "R1 PERSISTENT BULLISH";
      case AX_R2_BULL_UNSTABLE:   return "R2 BULLISH BUT UNSTABLE";
      case AX_R3_RANGE_CHOP:      return "R3 RANGE / CHOP";
      case AX_R4_BEAR_TRANSITION: return "R4 BEARISH TRANSITION";
      case AX_R5_PERSISTENT_BEAR: return "R5 PERSISTENT BEARISH";
      case AX_R6_VOL_SHOCK:       return "R6 VOLATILITY SHOCK";
      default:                    return "UNKNOWN";
     }
  }

string AxVolStateToString(ENUM_AX_VOL_STATE v)
  {
   switch(v)
     {
      case AX_VOL_LOW:      return "LOW";
      case AX_VOL_NORMAL:   return "NORMAL";
      case AX_VOL_ELEVATED: return "ELEVATED";
      case AX_VOL_HIGH:     return "HIGH";
      case AX_VOL_EXTREME:  return "EXTREME";
      default:              return "UNKNOWN";
     }
  }

string AxDataStatusToString(ENUM_AX_DATA_STATUS s)
  {
   switch(s)
     {
      case AX_DATA_OK:          return "OK";
      case AX_DATA_DEGRADED:    return "DEGRADED";
      case AX_DATA_UNAVAILABLE: return "UNAVAILABLE";
      default:                  return "UNKNOWN";
     }
  }
