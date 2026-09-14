//+------------------------------------------------------------------+
//| OrderFlowEngine.mqh                                               |
//| PROXY order-flow / footprint engine, not real executed-trade tape.|
//| MT5 does not expose aggressor-side trade prints for OTC forex/CFD |
//| symbols the way an exchange feed does, so buy/sell pressure here  |
//| is estimated with the classic tick rule (uptick = buy pressure,   |
//| downtick = sell pressure, unchanged = carry forward). This is a   |
//| standard academic/industry approximation when true trade-side     |
//| data isn't available - useful, but it is not a real footprint.    |
//+------------------------------------------------------------------+
#pragma once
#include <AutopsyX/Defines.mqh>
#include <AutopsyX/SymbolProfile.mqh>

#define AX_OF_HISTORY 64

class CAXOrderFlow
{
private:
   const CAXSymbolProfile *m_profile;
   double   m_prevMid;
   int      m_lastTickDir;      // carried forward on unchanged ticks
   bool     m_haveMid;

   double   m_curBuyVol, m_curSellVol;
   double   m_curHigh, m_curLow;
   bool     m_curBarStarted;

   double   m_histDelta[AX_OF_HISTORY];
   double   m_histVolume[AX_OF_HISTORY];
   double   m_histRangePts[AX_OF_HISTORY];
   double   m_histClose[AX_OF_HISTORY];
   int      m_histCount;

   double   m_cumulativeDelta;
   double   m_lastBarDelta;
   int      m_divergence;        // -1 bearish, 0 none, +1 bullish
   bool     m_absorption;
   int      m_absorptionSide;    // 1 = buy side absorbed, -1 = sell side absorbed

   int      m_divergenceWindow;

public:
   CAXOrderFlow(void) : m_profile(NULL), m_prevMid(0), m_lastTickDir(0), m_haveMid(false),
      m_curBuyVol(0), m_curSellVol(0), m_curHigh(-DBL_MAX), m_curLow(DBL_MAX), m_curBarStarted(false),
      m_histCount(0), m_cumulativeDelta(0), m_lastBarDelta(0), m_divergence(0),
      m_absorption(false), m_absorptionSide(0), m_divergenceWindow(10)
   {
      ArrayInitialize(m_histDelta, 0.0);
      ArrayInitialize(m_histVolume, 0.0);
      ArrayInitialize(m_histRangePts, 0.0);
      ArrayInitialize(m_histClose, 0.0);
   }

   void Init(const CAXSymbolProfile &profile, const int divergenceWindow)
   {
      m_profile = GetPointer(profile);
      m_divergenceWindow = AXClampInt(divergenceWindow, 3, AX_OF_HISTORY / 2);
   }

   // call every tick; weight is real tick volume when the broker provides
   // it, otherwise pass 1.0 to treat each tick as a unit of pressure
   void OnTick(const double mid, const double weight)
   {
      if(!m_haveMid) { m_prevMid = mid; m_haveMid = true; return; }

      int dir;
      if(mid > m_prevMid) dir = 1;
      else if(mid < m_prevMid) dir = -1;
      else dir = m_lastTickDir;

      if(dir != 0)
      {
         if(dir > 0) m_curBuyVol += weight; else m_curSellVol += weight;
         m_lastTickDir = dir;
      }

      m_curHigh = MathMax(m_curHigh, mid);
      m_curLow  = MathMin(m_curLow, mid);
      m_curBarStarted = true;
      m_prevMid = mid;
   }

   void OnNewBar(void)
   {
      m_divergence = 0;
      m_absorption = false;
      m_absorptionSide = 0;

      if(m_curBarStarted)
      {
         double delta = m_curBuyVol - m_curSellVol;
         double volume = m_curBuyVol + m_curSellVol;
         double rangePts = (m_profile != NULL && m_curHigh > m_curLow) ? m_profile.PriceToPoints(m_curHigh - m_curLow) : 0.0;

         PushHistory(delta, volume, rangePts, m_prevMid);
         m_cumulativeDelta += delta;
         m_lastBarDelta = delta;

         DetectDivergence();
         DetectAbsorption();
      }

      m_curBuyVol = 0; m_curSellVol = 0;
      m_curHigh = -DBL_MAX; m_curLow = DBL_MAX;
      m_curBarStarted = false;
   }

   double CurrentBuyVolume(void)  const { return m_curBuyVol; }
   double CurrentSellVolume(void) const { return m_curSellVol; }
   double LastBarDelta(void)      const { return m_lastBarDelta; }
   double CumulativeDelta(void)   const { return m_cumulativeDelta; }
   int    DivergenceSignal(void)  const { return m_divergence; }
   bool   AbsorptionDetected(void) const { return m_absorption; }
   int    AbsorptionSide(void)    const { return m_absorptionSide; }

   // -1..1, sign/strength of the recent cumulative-delta trend
   double DeltaBias(void) const
   {
      if(m_histCount < 2) return 0.0;
      int n = MathMin(m_histCount, m_divergenceWindow);
      double sum = 0.0, maxAbs = 0.0;
      for(int i = 0; i < n; i++)
      {
         sum += HistAt(m_histDelta, i);
         maxAbs += MathAbs(HistAt(m_histDelta, i));
      }
      if(maxAbs <= 0.0) return 0.0;
      return AXClamp(sum / maxAbs, -1.0, 1.0);
   }

private:
   // ring-buffer style push into fixed history arrays (index 0 = oldest logically via HistAt helper)
   void PushHistory(const double delta, const double volume, const double rangePts, const double closePrice)
   {
      for(int i = AX_OF_HISTORY - 1; i > 0; i--)
      {
         m_histDelta[i]     = m_histDelta[i - 1];
         m_histVolume[i]    = m_histVolume[i - 1];
         m_histRangePts[i]  = m_histRangePts[i - 1];
         m_histClose[i]     = m_histClose[i - 1];
      }
      m_histDelta[0] = delta;
      m_histVolume[0] = volume;
      m_histRangePts[0] = rangePts;
      m_histClose[0] = closePrice;
      if(m_histCount < AX_OF_HISTORY) m_histCount++;
   }

   // index 0 = most recent
   double HistAt(const double &arr[], const int idx) const { return arr[idx]; }

   void DetectDivergence(void)
   {
      int n = MathMin(m_histCount, m_divergenceWindow);
      if(n < 4) return;

      double priceNow = m_histClose[0];
      double priceThen = m_histClose[n - 1];
      double windowDelta = 0.0;
      for(int i = 0; i < n; i++) windowDelta += m_histDelta[i]; // net order-flow pressure across the window

      int priceTrend = (priceNow > priceThen) ? 1 : (priceNow < priceThen ? -1 : 0);
      int deltaTrend = (windowDelta > 0) ? 1 : (windowDelta < 0 ? -1 : 0);

      if(priceTrend > 0 && deltaTrend <= 0) m_divergence = -1;      // price up, flow not confirming -> bearish
      else if(priceTrend < 0 && deltaTrend >= 0) m_divergence = 1;  // price down, flow not confirming -> bullish
      else m_divergence = 0;
   }

   void DetectAbsorption(void)
   {
      int n = MathMin(m_histCount, AX_OF_HISTORY);
      if(n < 8) return;

      double volSum = 0.0, rangeSum = 0.0;
      for(int i = 1; i < n; i++) { volSum += m_histVolume[i]; rangeSum += m_histRangePts[i]; }
      double avgVol = volSum / (n - 1);
      double avgRange = rangeSum / (n - 1);
      if(avgVol <= 0.0 || avgRange <= 0.0) return;

      double lastVol = m_histVolume[0];
      double lastRange = m_histRangePts[0];

      if(lastVol > avgVol * 1.8 && lastRange < avgRange * 0.6)
      {
         m_absorption = true;
         m_absorptionSide = (m_histDelta[0] >= 0) ? 1 : -1;
      }
   }
};
