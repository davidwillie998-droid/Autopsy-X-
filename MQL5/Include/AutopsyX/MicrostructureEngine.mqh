//+------------------------------------------------------------------+
//| MicrostructureEngine.mqh                                          |
//| Lightweight tick-analysis layer: direction, velocity,             |
//| acceleration, displacement, spread dynamics, short-term            |
//| volatility, momentum persistence/exhaustion. Rolling-window only, |
//| no expensive recalculation.                                       |
//+------------------------------------------------------------------+
#pragma once
#include <AutopsyX/Defines.mqh>
#include <AutopsyX/SymbolProfile.mqh>
#include <AutopsyX/TickBuffer.mqh>

class CAXMicrostructure
{
private:
   const CAXSymbolProfile *m_profile;
   int      m_window;          // number of ticks considered "recent"

   int      m_tickDirection;
   int      m_consecutive;     // signed
   double   m_velocity;        // ticks per second
   double   m_prevVelocity;
   double   m_acceleration;
   double   m_displacementPts;
   double   m_spreadCurrentPts;
   double   m_spreadAvgPts;
   double   m_spreadExpansion;
   double   m_volatilityPts;
   double   m_persistence;     // 0..1
   double   m_imbalance;       // -1..1
   bool     m_exhausted;

public:
   CAXMicrostructure(void) : m_profile(NULL), m_window(80),
      m_tickDirection(0), m_consecutive(0), m_velocity(0), m_prevVelocity(0),
      m_acceleration(0), m_displacementPts(0), m_spreadCurrentPts(0),
      m_spreadAvgPts(0), m_spreadExpansion(1.0), m_volatilityPts(0),
      m_persistence(0), m_imbalance(0), m_exhausted(false) {}

   void Init(const CAXSymbolProfile &profile, const int tickWindow)
   {
      m_profile = GetPointer(profile);
      m_window  = AXClampInt(tickWindow, (int)AX_ADAPT_TICKWINDOW_MIN, (int)AX_ADAPT_TICKWINDOW_MAX);
   }

   void SetWindow(const int tickWindow)
   {
      m_window = AXClampInt(tickWindow, (int)AX_ADAPT_TICKWINDOW_MIN, (int)AX_ADAPT_TICKWINDOW_MAX);
   }

   // recompute all metrics from the tick ring buffer; call once per OnTick
   void Update(const CAXTickBuffer &buf)
   {
      int n = MathMin(buf.Count(), m_window);
      if(n < 3)
      {
         m_tickDirection = 0; m_consecutive = 0; m_velocity = 0; m_acceleration = 0;
         m_displacementPts = 0; m_persistence = 0; m_imbalance = 0; m_exhausted = false;
         return;
      }

      AXTickSample cur, prev;
      buf.Get(0, cur);

      //--- direction of the very last tick
      buf.Get(1, prev);
      double d0 = cur.mid - prev.mid;
      m_tickDirection = (d0 > 0.0) ? 1 : (d0 < 0.0 ? -1 : 0);

      //--- consecutive same-direction ticks (signed)
      int consec = 0;
      for(int i = 0; i < n - 1; i++)
      {
         AXTickSample a, b;
         buf.Get(i, a);
         buf.Get(i + 1, b);
         double diff = a.mid - b.mid;
         int dir = (diff > 0.0) ? 1 : (diff < 0.0 ? -1 : 0);
         if(i == 0) { consec = dir; continue; }
         if(dir == 0) break;
         if(dir == (consec > 0 ? 1 : -1)) consec += dir; else break;
      }
      m_consecutive = consec;

      //--- tick velocity: ticks per second across the window
      AXTickSample oldest;
      buf.Get(n - 1, oldest);
      double spanSec = (double)(cur.time_msc - oldest.time_msc) / 1000.0;
      m_prevVelocity = m_velocity;
      m_velocity = (spanSec > 0.0) ? (n / spanSec) : 0.0;
      m_acceleration = m_velocity - m_prevVelocity;

      //--- displacement over the window, in points
      double moveDelta = cur.mid - oldest.mid;
      m_displacementPts = (m_profile != NULL) ? m_profile.PriceToPoints(moveDelta) : 0.0;

      //--- spread stats
      double spreadNow = cur.ask - cur.bid;
      m_spreadCurrentPts = (m_profile != NULL) ? m_profile.PriceToPoints(spreadNow) : 0.0;
      double spreadSum = 0.0;
      for(int i = 0; i < n; i++)
      {
         AXTickSample s;
         buf.Get(i, s);
         spreadSum += (s.ask - s.bid);
      }
      double spreadAvgPrice = spreadSum / n;
      m_spreadAvgPts = (m_profile != NULL) ? m_profile.PriceToPoints(spreadAvgPrice) : 0.0;
      m_spreadExpansion = (m_spreadAvgPts > 0.0) ? (m_spreadCurrentPts / m_spreadAvgPts) : 1.0;

      //--- short-term volatility: stdev of tick-to-tick mid deltas (points)
      double sum = 0.0, sumSq = 0.0;
      int upTicks = 0, downTicks = 0;
      for(int i = 0; i < n - 1; i++)
      {
         AXTickSample a, b;
         buf.Get(i, a);
         buf.Get(i + 1, b);
         double diffPts = (m_profile != NULL) ? m_profile.PriceToPoints(a.mid - b.mid) : 0.0;
         sum += diffPts;
         sumSq += diffPts * diffPts;
         if(diffPts > 0) upTicks++;
         else if(diffPts < 0) downTicks++;
      }
      int m = n - 1;
      double mean = (m > 0) ? sum / m : 0.0;
      double variance = (m > 0) ? MathMax(0.0, sumSq / m - mean * mean) : 0.0;
      m_volatilityPts = MathSqrt(variance);

      int total = upTicks + downTicks;
      m_imbalance = (total > 0) ? ((double)(upTicks - downTicks) / total) : 0.0;

      //--- momentum persistence: fraction of ticks aligned with dominant direction
      int dominant = (upTicks >= downTicks) ? 1 : -1;
      m_persistence = (total > 0) ? ((double)MathMax(upTicks, downTicks) / total) : 0.0;

      //--- exhaustion heuristic: long consecutive run but decelerating velocity
      m_exhausted = (MathAbs(m_consecutive) >= 5 && m_acceleration < 0.0 && m_persistence < 0.65);
   }

   int    TickDirection(void)          const { return m_tickDirection; }
   int    ConsecutiveDirectionalTicks(void) const { return m_consecutive; }
   double TickVelocity(void)           const { return m_velocity; }
   double TickAcceleration(void)       const { return m_acceleration; }
   double PriceDisplacementPts(void)   const { return m_displacementPts; }
   double SpreadCurrentPts(void)       const { return m_spreadCurrentPts; }
   double SpreadAveragePts(void)       const { return m_spreadAvgPts; }
   double SpreadExpansionRatio(void)   const { return m_spreadExpansion; }
   double ShortTermVolatilityPts(void) const { return m_volatilityPts; }
   double MomentumPersistence(void)    const { return m_persistence; }
   double TickImbalance(void)          const { return m_imbalance; }
   double BidAskPressure(void)         const { return m_imbalance; }
   bool   MomentumExhausted(void)      const { return m_exhausted; }
};
