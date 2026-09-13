//+------------------------------------------------------------------+
//| LiquidityEngine.mqh                                               |
//| Short-term liquidity-flip model: sweep -> rejection ->            |
//| displacement -> directional confirmation. A sweep alone never     |
//| triggers an entry; confirmation is mandatory.                     |
//+------------------------------------------------------------------+
#pragma once
#include <AutopsyX/Defines.mqh>
#include <AutopsyX/SymbolProfile.mqh>

class CAXLiquidity
{
private:
   const CAXSymbolProfile *m_profile;
   int      m_lookback;          // bars used to define "prior" high/low
   int      m_confirmWindow;     // bars allowed for displacement confirmation
   double   m_equalTolerancePts;

   double   m_priorHigh, m_priorLow;
   double   m_sessionHigh, m_sessionLow;
   bool     m_equalHighs, m_equalLows;
   double   m_avgRangePts;

   bool     m_pending;
   ENUM_AX_DIRECTION m_pendingDir;   // direction we expect to trade once confirmed
   double   m_pendingRefClose;
   int      m_pendingBarsWaited;

   ENUM_AX_DIRECTION m_flipSignal;   // armed for the bar it fires on
   int      m_sweepSide;             // -1 low swept, 1 high swept, 0 none (most recent)

public:
   CAXLiquidity(void) : m_profile(NULL), m_lookback(20), m_confirmWindow(3),
      m_equalTolerancePts(3.0), m_priorHigh(0), m_priorLow(0), m_sessionHigh(0),
      m_sessionLow(0), m_equalHighs(false), m_equalLows(false), m_avgRangePts(0),
      m_pending(false), m_pendingDir(AX_DIR_NONE), m_pendingRefClose(0),
      m_pendingBarsWaited(0), m_flipSignal(AX_DIR_NONE), m_sweepSide(0) {}

   void Init(const CAXSymbolProfile &profile, const int lookback, const int confirmWindow)
   {
      m_profile = GetPointer(profile);
      m_lookback = MathMax(5, lookback);
      m_confirmWindow = MathMax(1, confirmWindow);
   }

   // rates[] must be series-ordered (idx0 = current forming bar)
   void OnNewBar(const MqlRates &rates[], const int count)
   {
      m_flipSignal = AX_DIR_NONE;
      if(count < m_lookback + 2 || m_profile == NULL) return;

      //--- prior high/low computed from CLOSED bars, excluding the just-closed one
      double ph = -DBL_MAX, pl = DBL_MAX, rangeSum = 0.0;
      for(int i = 2; i < 2 + m_lookback; i++)
      {
         if(rates[i].high > ph) ph = rates[i].high;
         if(rates[i].low  < pl) pl = rates[i].low;
         rangeSum += (rates[i].high - rates[i].low);
      }
      m_priorHigh = ph;
      m_priorLow  = pl;
      m_avgRangePts = m_profile.PriceToPoints(rangeSum / m_lookback);

      //--- session high/low: bars belonging to the current trading day
      MqlDateTime dNow; TimeToStruct(rates[1].time, dNow);
      double sh = rates[1].high, sl = rates[1].low;
      for(int i = 1; i < count; i++)
      {
         MqlDateTime d; TimeToStruct(rates[i].time, d);
         if(d.day != dNow.day || d.mon != dNow.mon || d.year != dNow.year) break;
         if(rates[i].high > sh) sh = rates[i].high;
         if(rates[i].low  < sl) sl = rates[i].low;
      }
      m_sessionHigh = sh;
      m_sessionLow  = sl;

      //--- equal highs / equal lows over lookback (cluster within tolerance)
      m_equalHighs = DetectEqual(rates, count, true);
      m_equalLows  = DetectEqual(rates, count, false);

      //--- the bar that just closed is rates[1]
      double closeBar = rates[1].close;
      double openBar  = rates[1].open;
      double highBar  = rates[1].high;
      double lowBar   = rates[1].low;
      double body     = MathAbs(closeBar - openBar);
      double margin   = MathMax(m_profile.PointsToPrice(m_avgRangePts * 0.15), m_profile.point * 2);

      m_sweepSide = 0;
      //--- bearish sweep: wicked below prior low, closed back above it (bullish rejection)
      if(lowBar < m_priorLow - m_profile.point && closeBar > m_priorLow + margin && closeBar > openBar)
      {
         m_sweepSide = -1;
         ArmPending(AX_DIR_BUY, closeBar);
      }
      //--- bullish sweep: wicked above prior high, closed back below it (bearish rejection)
      else if(highBar > m_priorHigh + m_profile.point && closeBar < m_priorHigh - margin && closeBar < openBar)
      {
         m_sweepSide = 1;
         ArmPending(AX_DIR_SELL, closeBar);
      }

      //--- evaluate any pending displacement confirmation
      if(m_pending)
      {
         m_pendingBarsWaited++;
         double displacementPts = m_profile.PriceToPoints(closeBar - m_pendingRefClose);
         double neededPts = MathMax(m_avgRangePts * 0.35, 3.0);

         bool confirmed = (m_pendingDir == AX_DIR_BUY  && displacementPts >=  neededPts) ||
                           (m_pendingDir == AX_DIR_SELL && displacementPts <= -neededPts);

         if(confirmed)
         {
            m_flipSignal = m_pendingDir;
            m_pending = false;
         }
         else if(m_pendingBarsWaited >= m_confirmWindow)
         {
            m_pending = false; // window expired, discard - never chase a stale sweep
         }
      }
   }

   double PriorHigh(void)   const { return m_priorHigh; }
   double PriorLow(void)    const { return m_priorLow; }
   double SessionHigh(void) const { return m_sessionHigh; }
   double SessionLow(void)  const { return m_sessionLow; }
   bool   EqualHighs(void)  const { return m_equalHighs; }
   bool   EqualLows(void)   const { return m_equalLows; }
   int    LastSweepSide(void) const { return m_sweepSide; }
   bool   HasPendingSweep(void) const { return m_pending; }

   // non-zero only on the bar the full sequence confirms
   ENUM_AX_DIRECTION LiquidityFlipSignal(void) const { return m_flipSignal; }

private:
   void ArmPending(const ENUM_AX_DIRECTION dir, const double refClose)
   {
      m_pending = true;
      m_pendingDir = dir;
      m_pendingRefClose = refClose;
      m_pendingBarsWaited = 0;
   }

   bool DetectEqual(const MqlRates &rates[], const int count, const bool highs) const
   {
      int n = MathMin(count - 1, m_lookback);
      if(n < 3) return false;
      double tol = m_profile.PointsToPrice(m_equalTolerancePts);
      int clusterHits = 0;
      for(int i = 1; i < n; i++)
      {
         for(int j = i + 1; j < n; j++)
         {
            double a = highs ? rates[i].high : rates[i].low;
            double b = highs ? rates[j].high : rates[j].low;
            if(MathAbs(a - b) <= tol) { clusterHits++; break; }
         }
      }
      return clusterHits >= 2;
   }
};
