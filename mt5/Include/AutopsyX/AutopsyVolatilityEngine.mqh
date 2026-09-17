//+------------------------------------------------------------------+
//|                                    AutopsyVolatilityEngine.mqh    |
//|  AUTOPSY X — Volatility Engine + Volatility Shock Detector         |
//|  Spec sections 6 and 7.                                            |
//|                                                                     |
//|  Distinguishes LOW/NORMAL/ELEVATED/HIGH/EXTREME volatility and      |
//|  flags a shock state (R6) when several independent conditions      |
//|  deteriorate together. High volatility is a RISK-STATE change, not |
//|  an automatic bearish call — the caller (regime engine) decides    |
//|  direction; this engine only decides how much conviction the      |
//|  environment currently deserves.                                   |
//+------------------------------------------------------------------+
#property strict
#include "AutopsyXCommon.mqh"

struct AxVolatilityState
  {
   double              atr;                 // current ATR, price units
   double              atrPercentile;        // 0..1, current ATR vs its own trailing history
   double              realizedVolAnnualPct; // stdev of daily log returns, annualized, in %
   double              vixLevel;             // last VIX read, or -1 if unavailable
   double              vixChangePct;         // 1-day % change in VIX, or 0 if unavailable
   ENUM_AX_VOL_STATE   state;
   double              volatilityScore;      // 0 (calmest) .. 100 (most extreme)
   bool                shockActive;          // R6 trigger
   string              shockReasons;         // human-readable, for logging
   ENUM_AX_DATA_STATUS dataStatus;
  };

class CAxVolatilityEngine
  {
private:
   string   m_symbol;              // the instrument the engine is watching, e.g. "QQQ" or "US100"
   string   m_vixSymbol;           // "" disables the VIX read entirely
   ENUM_TIMEFRAMES m_tf;
   int      m_atrPeriod;
   int      m_atrHistoryBars;      // lookback used to build the ATR percentile
   int      m_realizedVolLookback; // days used for realized-vol stdev

   //--- shock-detector thresholds (all configurable via setters, sane defaults below)
   double   m_vixExpansionPct;     // VIX 1-day % move considered "rapidly expanding"
   double   m_realizedVolShockPct; // percentile (0..1) of realized-vol history considered extreme
   double   m_dailyMoveShockPct;   // abnormal single-day % move on the watched symbol
   double   m_atrExpansionRatio;   // current ATR / trailing-average ATR considered "expanding"
   double   m_relVolumeShockRatio; // relative volume considered abnormal alongside a big move
   int      m_minShockConditions;  // how many of the above must fire together to trigger R6

   int      m_atrHandle;
   bool     m_initialized;

   double CurrentRelativeVolume()
     {
      long volNow = iVolume(m_symbol, m_tf, 0);
      double sum = 0.0;
      int n = 20;
      for(int i = 1; i <= n; i++)
         sum += (double)iVolume(m_symbol, m_tf, i);
      double avg = (n > 0) ? sum / n : 0.0;
      if(avg <= 0.0)
         return 1.0;
      return (double)volNow / avg;
     }

public:
   CAxVolatilityEngine()
     {
      m_symbol              = "";
      m_vixSymbol           = "";
      m_tf                  = PERIOD_D1;
      m_atrPeriod           = 14;
      m_atrHistoryBars      = 100;
      m_realizedVolLookback = 20;

      m_vixExpansionPct     = 15.0;   // VIX up >=15% in a day
      m_realizedVolShockPct = 0.95;   // realized vol above its own 95th percentile
      m_dailyMoveShockPct   = 3.5;    // QQQ/TQQQ moving >=3.5% in a session
      m_atrExpansionRatio   = 1.8;    // ATR 1.8x its trailing average
      m_relVolumeShockRatio = 2.0;    // 2x average volume
      m_minShockConditions  = 2;      // require at least two independent conditions

      m_atrHandle  = INVALID_HANDLE;
      m_initialized = false;
     }

   void SetInstrument(string symbol, ENUM_TIMEFRAMES tf, string vixSymbol = "")
     {
      m_symbol    = symbol;
      m_tf        = tf;
      m_vixSymbol = vixSymbol;
     }

   void SetShockThresholds(double vixExpansionPct, double realizedVolShockPct,
                            double dailyMoveShockPct, double atrExpansionRatio,
                            double relVolumeShockRatio, int minShockConditions)
     {
      m_vixExpansionPct     = vixExpansionPct;
      m_realizedVolShockPct = AxClamp(realizedVolShockPct, 0.0, 1.0);
      m_dailyMoveShockPct   = dailyMoveShockPct;
      m_atrExpansionRatio   = atrExpansionRatio;
      m_relVolumeShockRatio = relVolumeShockRatio;
      m_minShockConditions  = MathMax(1, minShockConditions);
     }

   bool Init()
     {
      if(StringLen(m_symbol) == 0)
         return false;
      m_atrHandle = iATR(m_symbol, m_tf, m_atrPeriod);
      m_initialized = (m_atrHandle != INVALID_HANDLE);
      if(StringLen(m_vixSymbol) > 0)
         SymbolSelect(m_vixSymbol, true); // best-effort; failure just degrades the VIX read
      return m_initialized;
     }

   //--- Recomputes everything from current terminal data. Call once per bar
   //    (or once per tick if you like — it's cheap) before reading state.
   AxVolatilityState Update()
     {
      AxVolatilityState s;
      s.atr = 0.0; s.atrPercentile = 0.5; s.realizedVolAnnualPct = 0.0;
      s.vixLevel = -1.0; s.vixChangePct = 0.0;
      s.state = AX_VOL_UNKNOWN; s.volatilityScore = 50.0;
      s.shockActive = false; s.shockReasons = "";
      s.dataStatus = AX_DATA_OK;

      if(!m_initialized && !Init())
        {
         s.dataStatus = AX_DATA_UNAVAILABLE;
         return s;
        }

      //--- ATR + its own percentile. ArraySetAsSeries MUST be called before
      //    CopyBuffer — it's not just an indexing convenience applied after
      //    the fact, it changes the order CopyBuffer itself fills the array in.
      double atrBuf[];
      ArraySetAsSeries(atrBuf, true);
      int need = m_atrHistoryBars + 1;
      if(CopyBuffer(m_atrHandle, 0, 0, need, atrBuf) < need)
        {
         s.dataStatus = AX_DATA_DEGRADED; // not enough history yet, e.g. fresh chart
        }
      else
        {
         s.atr = atrBuf[0];
         double history[];
         ArrayResize(history, m_atrHistoryBars);
         for(int i = 0; i < m_atrHistoryBars; i++)
            history[i] = atrBuf[i + 1];
         s.atrPercentile = AxPercentileRank(history, s.atr);
        }

      //--- Realized volatility: stdev of daily log returns, annualized
      int rvNeed = m_realizedVolLookback + 1;
      double rets[];
      ArrayResize(rets, m_realizedVolLookback);
      bool haveRv = true;
      for(int i = 0; i < m_realizedVolLookback; i++)
        {
         double c0 = iClose(m_symbol, m_tf, i);
         double c1 = iClose(m_symbol, m_tf, i + 1);
         if(c0 <= 0.0 || c1 <= 0.0) { haveRv = false; break; }
         rets[i] = MathLog(c0 / c1);
        }
      if(haveRv)
         s.realizedVolAnnualPct = AxStdDev(rets) * MathSqrt(252.0) * 100.0;
      else
         s.dataStatus = AX_DATA_DEGRADED;

      //--- VIX (optional — many retail MT5 symbol lists don't carry it)
      bool vixOk = false;
      if(StringLen(m_vixSymbol) > 0 && SymbolSelect(m_vixSymbol, true))
        {
         double vNow  = iClose(m_vixSymbol, PERIOD_D1, 0);
         double vPrev = iClose(m_vixSymbol, PERIOD_D1, 1);
         if(vNow > 0.0 && vPrev > 0.0)
           {
            s.vixLevel = vNow;
            s.vixChangePct = (vNow - vPrev) / vPrev * 100.0;
            vixOk = true;
           }
        }
      if(!vixOk && StringLen(m_vixSymbol) > 0)
         s.dataStatus = AX_DATA_DEGRADED; // VIX was requested but unreadable — degrade, don't fake it

      //--- Blend into a single 0..100 volatility score.
      //    Three normalized components, equally weighted; VIX only contributes
      //    if it was actually readable, so its absence doesn't silently pull
      //    the score toward "calm".
      double atrComponent = s.atrPercentile * 100.0;
      double rvComponent  = AxClamp(s.realizedVolAnnualPct / 60.0, 0.0, 1.0) * 100.0; // ~60% ann. vol treated as top-of-scale for a leveraged QQQ product
      double parts = atrComponent + rvComponent;
      double weightSum = 2.0;
      if(vixOk)
        {
         double vixComponent = AxClamp((s.vixLevel - 12.0) / 30.0, 0.0, 1.0) * 100.0; // ~12 calm floor, ~42+ treated as top-of-scale
         parts += vixComponent;
         weightSum += 1.0;
        }
      s.volatilityScore = parts / weightSum;

      if(s.volatilityScore < 20.0)      s.state = AX_VOL_LOW;
      else if(s.volatilityScore < 45.0) s.state = AX_VOL_NORMAL;
      else if(s.volatilityScore < 65.0) s.state = AX_VOL_ELEVATED;
      else if(s.volatilityScore < 85.0) s.state = AX_VOL_HIGH;
      else                              s.state = AX_VOL_EXTREME;

      //--- Shock detector (spec section 7): count independent conditions, not
      //    just the composite score, so one noisy input can't single-handedly
      //    trigger — or single-handedly suppress — capital-preservation mode.
      int fired = 0;
      string reasons = "";

      if(vixOk && s.vixChangePct >= m_vixExpansionPct)
        { fired++; reasons += "VIX +" + DoubleToString(s.vixChangePct,1) + "% intraday; "; }

      if(s.realizedVolAnnualPct > 0.0)
        {
         double rvHistory[];
         ArrayResize(rvHistory, m_realizedVolLookback);
         bool rvHistOk = true;
         for(int i = 0; i < m_realizedVolLookback; i++)
           {
            double a[]; ArrayResize(a, m_realizedVolLookback);
            bool ok = true;
            for(int j = 0; j < m_realizedVolLookback; j++)
              {
               double c0 = iClose(m_symbol, m_tf, i + j);
               double c1 = iClose(m_symbol, m_tf, i + j + 1);
               if(c0 <= 0.0 || c1 <= 0.0) { ok = false; break; }
               a[j] = MathLog(c0 / c1);
              }
            if(!ok) { rvHistOk = false; break; }
            rvHistory[i] = AxStdDev(a) * MathSqrt(252.0) * 100.0;
           }
         if(rvHistOk)
           {
            double rvPct = AxPercentileRank(rvHistory, s.realizedVolAnnualPct);
            if(rvPct >= m_realizedVolShockPct)
              { fired++; reasons += "realized vol at " + DoubleToString(rvPct*100,0) + "th pct; "; }
           }
        }

      double c0 = iClose(m_symbol, m_tf, 0);
      double c1 = iClose(m_symbol, m_tf, 1);
      if(c0 > 0.0 && c1 > 0.0)
        {
         double dayMovePct = MathAbs(c0 - c1) / c1 * 100.0;
         if(dayMovePct >= m_dailyMoveShockPct)
           { fired++; reasons += "session move " + DoubleToString(dayMovePct,1) + "%; "; }

         double relVol = CurrentRelativeVolume();
         if(dayMovePct >= m_dailyMoveShockPct * 0.6 && relVol >= m_relVolumeShockRatio)
           { fired++; reasons += "large move on " + DoubleToString(relVol,1) + "x volume; "; }
        }

      if(s.atr > 0.0)
        {
         double atrHist[];
         int atrN = MathMin(m_atrHistoryBars, 20);
         double atrBuf2[];
         if(CopyBuffer(m_atrHandle, 0, 1, atrN, atrBuf2) == atrN)
           {
            double avg = 0.0;
            for(int i = 0; i < atrN; i++) avg += atrBuf2[i];
            avg /= atrN;
            if(avg > 0.0 && s.atr / avg >= m_atrExpansionRatio)
              { fired++; reasons += "ATR " + DoubleToString(s.atr/avg,1) + "x trailing average; "; }
           }
        }

      s.shockActive = (fired >= m_minShockConditions);
      s.shockReasons = reasons;

      return s;
     }
  };
