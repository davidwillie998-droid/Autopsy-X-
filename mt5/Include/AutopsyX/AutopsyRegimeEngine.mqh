//+------------------------------------------------------------------+
//|                                        AutopsyRegimeEngine.mqh    |
//|  AUTOPSY X — Direction, Trend-Efficiency, Breadth & Liquidity      |
//|  engines, plus the six-state Regime Classifier and Composite       |
//|  Confidence. Spec sections 3, 4, 5, 9, 10, 11.                     |
//|                                                                     |
//|  BREADTH: MT5 has no native advance/decline or %-above-MA feed.    |
//|  Like the macro engine's yields, breadth is read from a            |
//|  GlobalVariable an external feeder maintains (Ax_Breadth_Score).   |
//|  If nothing is writing it, breadth degrades to "unavailable" and   |
//|  drops out of the composite rather than being guessed at.          |
//|                                                                     |
//|  DIRECTION and TREND-EFFICIENCY are fully self-contained — they    |
//|  only need the price history MT5 already has for the instrument.   |
//|  LIQUIDITY uses MT5 volume (tick volume on most CFD/forex-style    |
//|  feeds, real volume where the broker provides equities data —      |
//|  treat it as a participation proxy, not literal share volume,      |
//|  unless you've confirmed your feed carries SYMBOL_VOLUME_REAL).    |
//+------------------------------------------------------------------+
#property strict
#include "AutopsyXCommon.mqh"

#define AX_GV_BREADTH_SCORE       "Ax_Breadth_Score"        // -100..100, externally computed
#define AX_GV_BREADTH_LAST_UPDATE "Ax_Breadth_LastUpdateUnix"

struct AxDirectionState
  {
   double directionScore;   // -100..100
   double ema20, ema50, ema200;
   bool   structureBullish; // price>EMA20>EMA50>EMA200
   bool   structureBearish; // price<EMA20<EMA50<EMA200
   int    swingStructure;   // +1 HH/HL, -1 LH/LL, 0 mixed/unclear
   int    breakoutState;    // +1 20-bar breakout, -1 20-bar breakdown, 0 neither
   double momentumPct;      // % change over the momentum lookback
   ENUM_AX_DATA_STATUS dataStatus;
  };

struct AxTrendEfficiencyState
  {
   double efficiencyShort;  // e.g. 10-bar
   double efficiencyLong;   // e.g. 20-bar
   double efficiencyScore;  // 0..1, blended
   ENUM_AX_DATA_STATUS dataStatus;
  };

struct AxBreadthState
  {
   double breadthScore;     // -100..100
   bool   available;
   ENUM_AX_DATA_STATUS dataStatus;
  };

struct AxLiquidityState
  {
   double relativeVolume;   // current bar volume / trailing average
   double liquidityScore;   // 0..100, higher = healthier participation
   bool   healthy;          // convenience flag, liquidityScore >= 50
   ENUM_AX_DATA_STATUS dataStatus;
  };

struct AxRegimeSnapshot
  {
   ENUM_AX_REGIME regime;
   double         confidenceScore; // 0..100
   AxDirectionState direction;
   AxTrendEfficiencyState efficiency;
   AxBreadthState breadth;
   AxLiquidityState liquidity;
  };

class CAxRegimeEngine
  {
private:
   string          m_symbol;
   ENUM_TIMEFRAMES m_tf;

   int m_emaFast, m_emaMedium, m_emaSlow;
   int m_momentumLookback;
   int m_breakoutLookback;
   int m_swingSearchBars;
   int m_effShortLookback, m_effLongLookback;
   int m_liquidityAvgBars;
   int m_staleAfterSeconds;

   //--- regime-classification thresholds (spec section 12's per-regime
   //    requirements, reused here to decide which regime we're *in*)
   double m_strongDirThreshold;   // |directionScore| >= this = "strong" band
   double m_persistTrendEffMin;   // trend efficiency required for R1/R5 (persistent) vs R2/R4 (unstable/transition)
   double m_breadthWeakThreshold; // breadthScore <= this counts as "weak" for R5's requirement

   //--- composite confidence weights (spec section 11, all configurable)
   double m_wDirection, m_wEfficiency, m_wVolatility, m_wMacro, m_wBreadth, m_wLiquidity;

   int m_emaFastHandle, m_emaMediumHandle, m_emaSlowHandle;
   bool m_initialized;

   double HandleLast(int handle)
     {
      double buf[];
      if(CopyBuffer(handle, 0, 0, 1, buf) < 1)
         return 0.0;
      return buf[0];
     }

   //--- last two confirmed 5-bar fractal highs/lows within a search window,
   //    oldest first. Returns how many were found (0, 1 or 2).
   int LastTwoFractalHighs(double &out[])
     {
      ArrayResize(out, 2);
      int found = 0;
      for(int shift = 2; shift < m_swingSearchBars - 2 && found < 2; shift++)
        {
         double h = iHigh(m_symbol, m_tf, shift);
         bool isFractal = true;
         for(int k = 1; k <= 2; k++)
            if(h <= iHigh(m_symbol, m_tf, shift - k) || h <= iHigh(m_symbol, m_tf, shift + k))
              { isFractal = false; break; }
         if(isFractal)
           {
            out[found] = h; // filled newest-first, reversed below
            found++;
           }
        }
      if(found == 2) { double t = out[0]; out[0] = out[1]; out[1] = t; } // oldest first
      return found;
     }

   int LastTwoFractalLows(double &out[])
     {
      ArrayResize(out, 2);
      int found = 0;
      for(int shift = 2; shift < m_swingSearchBars - 2 && found < 2; shift++)
        {
         double l = iLow(m_symbol, m_tf, shift);
         bool isFractal = true;
         for(int k = 1; k <= 2; k++)
            if(l >= iLow(m_symbol, m_tf, shift - k) || l >= iLow(m_symbol, m_tf, shift + k))
              { isFractal = false; break; }
         if(isFractal)
           {
            out[found] = l;
            found++;
           }
        }
      if(found == 2) { double t = out[0]; out[0] = out[1]; out[1] = t; }
      return found;
     }

public:
   CAxRegimeEngine()
     {
      m_symbol = ""; m_tf = PERIOD_D1;
      m_emaFast = 20; m_emaMedium = 50; m_emaSlow = 200;
      m_momentumLookback = 10;
      m_breakoutLookback = 20;
      m_swingSearchBars  = 60;
      m_effShortLookback = 10; m_effLongLookback = 20;
      m_liquidityAvgBars = 20;
      m_staleAfterSeconds = 24 * 3600;

      m_strongDirThreshold   = 70.0;
      m_persistTrendEffMin   = 0.55;
      m_breadthWeakThreshold = -10.0;

      m_wDirection = 0.30; m_wEfficiency = 0.20; m_wVolatility = 0.20;
      m_wMacro = 0.15; m_wBreadth = 0.10; m_wLiquidity = 0.05;

      m_emaFastHandle = m_emaMediumHandle = m_emaSlowHandle = INVALID_HANDLE;
      m_initialized = false;
     }

   void SetInstrument(string symbol, ENUM_TIMEFRAMES tf) { m_symbol = symbol; m_tf = tf; }

   void SetEmaPeriods(int fastP, int medP, int slowP) { m_emaFast = fastP; m_emaMedium = medP; m_emaSlow = slowP; }

   void SetLookbacks(int momentumBars, int breakoutBars, int swingSearchBars,
                      int effShortBars, int effLongBars, int liquidityAvgBars)
     {
      m_momentumLookback = momentumBars; m_breakoutLookback = breakoutBars;
      m_swingSearchBars  = swingSearchBars;
      m_effShortLookback = effShortBars; m_effLongLookback = effLongBars;
      m_liquidityAvgBars = liquidityAvgBars;
     }

   void SetRegimeThresholds(double strongDirThreshold, double persistTrendEffMin, double breadthWeakThreshold)
     {
      m_strongDirThreshold   = strongDirThreshold;
      m_persistTrendEffMin   = persistTrendEffMin;
      m_breadthWeakThreshold = breadthWeakThreshold;
     }

   void SetConfidenceWeights(double wDirection, double wEfficiency, double wVolatility,
                              double wMacro, double wBreadth, double wLiquidity)
     {
      double sum = wDirection + wEfficiency + wVolatility + wMacro + wBreadth + wLiquidity;
      if(sum <= 0.0) return; // keep prior weights rather than divide by zero
      m_wDirection = wDirection / sum; m_wEfficiency = wEfficiency / sum; m_wVolatility = wVolatility / sum;
      m_wMacro = wMacro / sum; m_wBreadth = wBreadth / sum; m_wLiquidity = wLiquidity / sum;
     }

   void SetBreadthStaleness(int seconds) { m_staleAfterSeconds = MathMax(60, seconds); }

   bool Init()
     {
      if(StringLen(m_symbol) == 0) return false;
      m_emaFastHandle   = iMA(m_symbol, m_tf, m_emaFast,   0, MODE_EMA, PRICE_CLOSE);
      m_emaMediumHandle = iMA(m_symbol, m_tf, m_emaMedium, 0, MODE_EMA, PRICE_CLOSE);
      m_emaSlowHandle   = iMA(m_symbol, m_tf, m_emaSlow,   0, MODE_EMA, PRICE_CLOSE);
      m_initialized = (m_emaFastHandle != INVALID_HANDLE && m_emaMediumHandle != INVALID_HANDLE && m_emaSlowHandle != INVALID_HANDLE);
      return m_initialized;
     }

   //--- Section 4: Direction Engine
   AxDirectionState UpdateDirection()
     {
      AxDirectionState d;
      d.directionScore = 0.0; d.ema20 = 0.0; d.ema50 = 0.0; d.ema200 = 0.0;
      d.structureBullish = false; d.structureBearish = false;
      d.swingStructure = 0; d.breakoutState = 0; d.momentumPct = 0.0;
      d.dataStatus = AX_DATA_OK;

      if(!m_initialized && !Init())
        { d.dataStatus = AX_DATA_UNAVAILABLE; return d; }

      d.ema20  = HandleLast(m_emaFastHandle);
      d.ema50  = HandleLast(m_emaMediumHandle);
      d.ema200 = HandleLast(m_emaSlowHandle);
      double price = iClose(m_symbol, m_tf, 0);

      if(d.ema20 <= 0.0 || d.ema50 <= 0.0 || d.ema200 <= 0.0 || price <= 0.0)
        { d.dataStatus = AX_DATA_DEGRADED; return d; }

      d.structureBullish = (price > d.ema20 && d.ema20 > d.ema50 && d.ema50 > d.ema200);
      d.structureBearish = (price < d.ema20 && d.ema20 < d.ema50 && d.ema50 < d.ema200);

      //--- structural leg score: each of the three comparisons contributes
      //    independently so a partial alignment still reads as partial,
      //    not as a hard bull/bear flip (spec: "no single indicator overrides").
      double legScore = 0.0;
      legScore += (price > d.ema20) ? 1.0 : -1.0;
      legScore += (d.ema20 > d.ema50) ? 1.0 : -1.0;
      legScore += (d.ema50 > d.ema200) ? 1.0 : -1.0;
      double structureComponent = (legScore / 3.0) * 40.0; // ±40 max

      double highs[]; double lows[];
      int hFound = LastTwoFractalHighs(highs);
      int lFound = LastTwoFractalLows(lows);
      double swingComponent = 0.0;
      if(hFound == 2 && lFound == 2)
        {
         double highDir = (highs[1] > highs[0]) ? 1.0 : ((highs[1] < highs[0]) ? -1.0 : 0.0);
         double lowDir  = (lows[1]  > lows[0])  ? 1.0 : ((lows[1]  < lows[0])  ? -1.0 : 0.0);
         double avgDir  = (highDir + lowDir) / 2.0; // +1 HH+HL, -1 LH+LL, 0 mixed
         d.swingStructure = (int)MathRound(avgDir);
         swingComponent = avgDir * 20.0; // ±20 max
        }

      double highestPrior = iHigh(m_symbol, m_tf, iHighest(m_symbol, m_tf, MODE_HIGH, m_breakoutLookback, 1));
      double lowestPrior  = iLow(m_symbol,  m_tf, iLowest(m_symbol,  m_tf, MODE_LOW,  m_breakoutLookback, 1));
      double breakoutComponent = 0.0;
      if(highestPrior > 0.0 && price > highestPrior) { d.breakoutState = 1;  breakoutComponent = 15.0; }
      else if(lowestPrior > 0.0 && price < lowestPrior) { d.breakoutState = -1; breakoutComponent = -15.0; }

      double priceThen = iClose(m_symbol, m_tf, m_momentumLookback);
      double momentumComponent = 0.0;
      if(priceThen > 0.0)
        {
         d.momentumPct = (price - priceThen) / priceThen * 100.0;
         momentumComponent = AxClamp(d.momentumPct / 8.0, -1.0, 1.0) * 25.0; // ±8% move treated as full-scale momentum
        }

      d.directionScore = AxClamp(structureComponent + swingComponent + breakoutComponent + momentumComponent, -100.0, 100.0);
      return d;
     }

   //--- Section 5: Trend-Efficiency Engine
   AxTrendEfficiencyState UpdateTrendEfficiency()
     {
      AxTrendEfficiencyState e;
      e.efficiencyShort = 0.0; e.efficiencyLong = 0.0; e.efficiencyScore = 0.0;
      e.dataStatus = AX_DATA_OK;

      int needBars = MathMax(m_effShortLookback, m_effLongLookback) + 1;
      double closes[];
      ArrayResize(closes, needBars);
      bool ok = true;
      for(int i = 0; i < needBars; i++)
        {
         double c = iClose(m_symbol, m_tf, needBars - 1 - i); // oldest -> newest
         if(c <= 0.0) { ok = false; break; }
         closes[i] = c;
        }
      if(!ok) { e.dataStatus = AX_DATA_DEGRADED; return e; }

      e.efficiencyShort = AxTrendEfficiency(closes, m_effShortLookback);
      e.efficiencyLong  = AxTrendEfficiency(closes, m_effLongLookback);
      e.efficiencyScore = (e.efficiencyShort + e.efficiencyLong) / 2.0;
      return e;
     }

   //--- Section 9: Breadth Engine (external feed — see file header)
   AxBreadthState UpdateBreadth()
     {
      AxBreadthState b;
      b.breadthScore = 0.0; b.available = false; b.dataStatus = AX_DATA_UNAVAILABLE;

      if(!GlobalVariableCheck(AX_GV_BREADTH_SCORE))
         return b;

      double lastUpdate = 0.0;
      bool haveTs = GlobalVariableCheck(AX_GV_BREADTH_LAST_UPDATE);
      if(haveTs) lastUpdate = GlobalVariableGet(AX_GV_BREADTH_LAST_UPDATE);
      bool fresh = haveTs && (TimeCurrent() - (datetime)lastUpdate) <= m_staleAfterSeconds;

      b.breadthScore = AxClamp(GlobalVariableGet(AX_GV_BREADTH_SCORE), -100.0, 100.0);
      b.available = true;
      b.dataStatus = (haveTs && !fresh) ? AX_DATA_DEGRADED : AX_DATA_OK;
      return b;
     }

   //--- Section 10: Liquidity / Volume Engine
   AxLiquidityState UpdateLiquidity()
     {
      AxLiquidityState l;
      l.relativeVolume = 1.0; l.liquidityScore = 50.0; l.healthy = true; l.dataStatus = AX_DATA_OK;

      long volNow = iVolume(m_symbol, m_tf, 0);
      double sum = 0.0;
      for(int i = 1; i <= m_liquidityAvgBars; i++)
         sum += (double)iVolume(m_symbol, m_tf, i);
      double avg = (m_liquidityAvgBars > 0) ? sum / m_liquidityAvgBars : 0.0;
      if(avg <= 0.0) { l.dataStatus = AX_DATA_DEGRADED; return l; }

      l.relativeVolume = (double)volNow / avg;

      double c0 = iClose(m_symbol, m_tf, 0), c1 = iClose(m_symbol, m_tf, 1);
      double dayMovePct = (c0 > 0.0 && c1 > 0.0) ? MathAbs(c0 - c1) / c1 * 100.0 : 0.0;

      double participationScore = AxClamp(l.relativeVolume / 2.0, 0.0, 1.0) * 100.0; // 2x avg volume = full scale
      //--- a big price move on thin relative volume is the specific pattern
      //    the spec calls out as dangerous for adding leverage — penalize it
      //    directly rather than only scoring volume in isolation.
      if(dayMovePct >= 1.0 && l.relativeVolume < 0.8)
         participationScore *= 0.5;

      l.liquidityScore = participationScore;
      l.healthy = (l.liquidityScore >= 50.0);
      return l;
     }

   //--- Section 3 + 12: classify the regime from everything computed above,
   //    plus the volatility state this engine doesn't own (passed in).
   ENUM_AX_REGIME ClassifyRegime(const AxDirectionState &d, const AxTrendEfficiencyState &e,
                                  const AxBreadthState &b, ENUM_AX_VOL_STATE volState, bool shockActive)
     {
      if(shockActive)
         return AX_R6_VOL_SHOCK;

      double dir = d.directionScore;
      bool breadthOkForBull = (!b.available) || (b.breadthScore > m_breadthWeakThreshold);
      bool breadthWeakForBear = (!b.available) || (b.breadthScore <= m_breadthWeakThreshold);
      bool volControlled = (volState == AX_VOL_LOW || volState == AX_VOL_NORMAL);
      bool volControlledLoose = (volState == AX_VOL_LOW || volState == AX_VOL_NORMAL || volState == AX_VOL_ELEVATED);

      if(dir >= m_strongDirThreshold)
        {
         if(e.efficiencyScore >= m_persistTrendEffMin && volControlled && breadthOkForBull)
            return AX_R1_PERSISTENT_BULL;
         return AX_R2_BULL_UNSTABLE;
        }
      if(dir >= 40.0)
         return AX_R2_BULL_UNSTABLE;
      if(dir > -40.0)
         return AX_R3_RANGE_CHOP;
      if(dir > -m_strongDirThreshold)
         return AX_R4_BEAR_TRANSITION;

      // dir <= -m_strongDirThreshold: strongly bearish
      if(e.efficiencyScore >= m_persistTrendEffMin && breadthWeakForBear && volControlledLoose)
         return AX_R5_PERSISTENT_BEAR;
      return AX_R4_BEAR_TRANSITION;
     }

   //--- Section 11: Composite Confidence. `volatilityScore` is 0(calm)..100(extreme)
   //    from the volatility engine; `macroScore` is -100..100 from the macro engine.
   double ComputeConfidence(const AxDirectionState &d, const AxTrendEfficiencyState &e,
                             double volatilityScore, bool volatilityAvailable,
                             double macroScore, int macroComponentsAvailable,
                             const AxBreadthState &b, const AxLiquidityState &l)
     {
      double sign = (d.directionScore > 0.0) ? 1.0 : ((d.directionScore < 0.0) ? -1.0 : 0.0);

      double weightedSum = 0.0, weightUsed = 0.0;

      double directionComponent = MathAbs(d.directionScore); // conviction strength, sign-agnostic
      weightedSum += directionComponent * m_wDirection; weightUsed += m_wDirection;

      double efficiencyComponent = e.efficiencyScore * 100.0;
      weightedSum += efficiencyComponent * m_wEfficiency; weightUsed += m_wEfficiency;

      if(volatilityAvailable)
        {
         double volatilityComponent = 100.0 - AxClamp(volatilityScore, 0.0, 100.0);
         weightedSum += volatilityComponent * m_wVolatility; weightUsed += m_wVolatility;
        }

      if(macroComponentsAvailable > 0)
        {
         double macroComponent = AxClamp(50.0 + (sign * macroScore) / 2.0, 0.0, 100.0);
         weightedSum += macroComponent * m_wMacro; weightUsed += m_wMacro;
        }

      if(b.available)
        {
         double breadthComponent = AxClamp(50.0 + (sign * b.breadthScore) / 2.0, 0.0, 100.0);
         weightedSum += breadthComponent * m_wBreadth; weightUsed += m_wBreadth;
        }

      weightedSum += l.liquidityScore * m_wLiquidity; weightUsed += m_wLiquidity;

      if(weightUsed <= 0.0)
         return 0.0;
      return AxClamp(weightedSum / weightUsed, 0.0, 100.0);
     }
  };
