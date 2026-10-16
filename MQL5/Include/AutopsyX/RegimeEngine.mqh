//+------------------------------------------------------------------+
//| RegimeEngine.mqh                                                  |
//| Classifies the current market environment so downstream engines   |
//| can adapt strategy automatically. One ATR indicator handle only,  |
//| updated once per new bar.                                         |
//+------------------------------------------------------------------+
#pragma once
#include <AutopsyX/Defines.mqh>
#include <AutopsyX/SymbolProfile.mqh>

class CAXRegime
{
private:
   const CAXSymbolProfile *m_profile;
   int      m_lookback;
   int      m_atrHandle;
   double   m_atrBuf[];

   ENUM_AX_REGIME m_regime;
   double   m_atrPts;
   double   m_atrAvgPts;
   double   m_volRatio;
   double   m_trendStrength;
   double   m_chaosRatio;
   bool     m_breakout;
   bool     m_valid;

public:
   CAXRegime(void) : m_profile(NULL), m_lookback(30), m_atrHandle(INVALID_HANDLE),
      m_regime(AX_REGIME_RANGE), m_atrPts(0), m_atrAvgPts(0), m_volRatio(1.0),
      m_trendStrength(0), m_chaosRatio(0), m_breakout(false), m_valid(false) {}

   bool Init(const CAXSymbolProfile &profile, const string symbol, const ENUM_TIMEFRAMES tf, const int lookback)
   {
      m_profile = GetPointer(profile);
      m_lookback = MathMax(10, lookback);
      m_atrHandle = iATR(symbol, tf, 14);
      ArraySetAsSeries(m_atrBuf, true);
      return (m_atrHandle != INVALID_HANDLE);
   }

   void Deinit(void)
   {
      if(m_atrHandle != INVALID_HANDLE) IndicatorRelease(m_atrHandle);
   }

   void OnNewBar(const MqlRates &rates[], const int count)
   {
      m_valid = false;
      if(m_profile == NULL || count < m_lookback + 2) { m_regime = AX_REGIME_UNSAFE; return; }

      int need = m_lookback + 2;
      if(CopyBuffer(m_atrHandle, 0, 1, need, m_atrBuf) < need)
      {
         m_regime = AX_REGIME_UNSAFE;
         return;
      }

      m_atrPts = m_profile.PriceToPoints(m_atrBuf[0]);
      double atrSum = 0.0;
      for(int i = 0; i < m_lookback; i++) atrSum += m_atrBuf[i];
      m_atrAvgPts = m_profile.PriceToPoints(atrSum / m_lookback);
      m_volRatio = (m_atrAvgPts > 0.0) ? (m_atrPts / m_atrAvgPts) : 1.0;

      //--- linear regression slope of closes over lookback closed bars
      double sumX = 0, sumY = 0, sumXY = 0, sumXX = 0;
      for(int i = 0; i < m_lookback; i++)
      {
         double x = (double)i;
         double y = rates[i + 1].close;
         sumX += x; sumY += y; sumXY += x * y; sumXX += x * x;
      }
      double n = (double)m_lookback;
      double denom = (n * sumXX - sumX * sumX);
      double slope = (denom != 0.0) ? (n * sumXY - sumX * sumY) / denom : 0.0;
      // slope is price-per-bar (newest-to-oldest indexing is reversed, so sign flips)
      slope = -slope;
      double slopePts = m_profile.PriceToPoints(slope);
      // total displacement across the lookback window, expressed in ATRs
      m_trendStrength = (m_atrPts > 0.0) ? MathAbs(slopePts * m_lookback) / m_atrPts : 0.0;
      int trendDir = (slopePts > 0) ? 1 : (slopePts < 0 ? -1 : 0);

      //--- chaos ratio: fraction of directional sign flips among consecutive closes
      int flips = 0, samples = 0;
      int lastDir = 0;
      for(int i = 0; i < m_lookback - 1; i++)
      {
         double d = rates[i + 1].close - rates[i + 2].close;
         int dir = (d > 0) ? 1 : (d < 0 ? -1 : 0);
         if(dir == 0) continue;
         if(lastDir != 0 && dir != lastDir) flips++;
         if(lastDir != 0) samples++;
         lastDir = dir;
      }
      m_chaosRatio = (samples > 0) ? ((double)flips / samples) : 0.0;

      //--- breakout: last closed bar exceeds recent range with an outsized range
      double hh = -DBL_MAX, ll = DBL_MAX;
      for(int i = 2; i < 2 + m_lookback; i++)
      {
         if(rates[i].high > hh) hh = rates[i].high;
         if(rates[i].low  < ll) ll = rates[i].low;
      }
      double lastRangePts = m_profile.PriceToPoints(rates[1].high - rates[1].low);
      m_breakout = (rates[1].close > hh || rates[1].close < ll) && (lastRangePts > m_atrPts * 1.5);

      m_valid = true;

      //--- decision tree -------------------------------------------------
      if(m_volRatio > 3.0 || m_atrPts <= 0.0)
      {
         m_regime = AX_REGIME_UNSAFE;
      }
      else if(m_chaosRatio > 0.65 && m_volRatio > 1.15)
      {
         m_regime = AX_REGIME_CHAOTIC;
      }
      else if(m_breakout)
      {
         m_regime = AX_REGIME_BREAKOUT;
      }
      else if(m_volRatio > 1.6)
      {
         m_regime = AX_REGIME_HIGHVOL;
      }
      else if(m_volRatio < 0.55)
      {
         m_regime = AX_REGIME_LOWVOL;
      }
      else if(m_trendStrength > 1.1 && trendDir != 0)
      {
         m_regime = AX_REGIME_TRENDING;
      }
      else if(m_chaosRatio < 0.45 && m_trendStrength < 0.5)
      {
         m_regime = AX_REGIME_RANGE;
      }
      else
      {
         m_regime = AX_REGIME_MEANREV;
      }
   }

   ENUM_AX_REGIME CurrentRegime(void) const { return m_regime; }
   double AtrPts(void)         const { return m_atrPts; }
   double VolatilityRatio(void) const { return m_volRatio; }
   double TrendStrength(void)  const { return m_trendStrength; }
   double ChaosRatio(void)     const { return m_chaosRatio; }
   bool   IsBreakoutBar(void)  const { return m_breakout; }
   bool   IsValid(void)        const { return m_valid; }
   bool   IsSafe(void)         const { return m_valid && m_regime != AX_REGIME_UNSAFE && m_regime != AX_REGIME_CHAOTIC; }
};
