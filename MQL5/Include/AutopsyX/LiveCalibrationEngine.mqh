//+------------------------------------------------------------------+
//| LiveCalibrationEngine.mqh                                         |
//| Demo and live execution are not the same animal - most brokers    |
//| simulate friendlier fills on a demo server, so a threshold tuned  |
//| on demo tells you nothing about the account it will actually run  |
//| on. This engine watches real ticks on whatever account the EA is  |
//| attached to (paper or live) for a warm-up window, places no       |
//| trades, and derives the spread/displacement/ATR/deviation gates   |
//| from what was actually measured on that broker+symbol+session -   |
//| never from a guessed constant.                                    |
//+------------------------------------------------------------------+
#pragma once
#include <AutopsyX/Defines.mqh>

#define AX_CALIB_MAX_SAMPLES 20000

class CAXCalibration
{
private:
   int      m_durationSec;
   int      m_minSamples;
   datetime m_startTime;
   bool     m_started;
   bool     m_complete;

   double   m_samples[];
   int      m_count;

   double Percentile(const double p) const
   {
      if(m_count <= 0) return 0.0;
      double sorted[];
      ArrayResize(sorted, m_count);
      for(int i = 0; i < m_count; i++) sorted[i] = m_samples[i];
      ArraySort(sorted);
      int idx = (int)MathRound(AXClamp(p, 0.0, 1.0) * (m_count - 1));
      return sorted[idx];
   }

public:
   CAXCalibration(void) : m_durationSec(1200), m_minSamples(300), m_startTime(0),
      m_started(false), m_complete(false), m_count(0) {}

   void Init(const int durationSec, const int minSamples)
   {
      m_durationSec = MathMax(30, durationSec);
      m_minSamples  = MathMax(10, minSamples);
      ArrayResize(m_samples, AX_CALIB_MAX_SAMPLES);
      m_count = 0;
      m_started = false;
      m_complete = false;
   }

   void Start(const datetime now)
   {
      m_startTime = now;
      m_started = true;
   }

   void Feed(const double spreadPts)
   {
      if(!m_started || m_complete) return;
      if(spreadPts <= 0.0) return;
      if(m_count < AX_CALIB_MAX_SAMPLES)
         m_samples[m_count++] = spreadPts;
   }

   // completes on time+sample quota, or force-completes after 3x the window
   // so an illiquid symbol can't stall trading forever
   bool CheckComplete(const datetime now)
   {
      if(m_complete) return true;
      if(!m_started) return false;
      int elapsed = (int)(now - m_startTime);
      if(elapsed >= m_durationSec && m_count >= m_minSamples) { m_complete = true; return true; }
      if(elapsed >= m_durationSec * 3) { m_complete = true; return true; } // safety net
      return false;
   }

   int RemainingSeconds(const datetime now) const
   {
      if(!m_started) return m_durationSec;
      int elapsed = (int)(now - m_startTime);
      return (int)MathMax(0, m_durationSec - elapsed);
   }

   int    SampleCount(void) const { return m_count; }
   bool   IsComplete(void)  const { return m_complete; }
   bool   HasEnoughData(void) const { return m_count >= m_minSamples; }

   double MedianSpreadPts(void)     const { return Percentile(0.50); }
   double P90SpreadPts(void)        const { return Percentile(0.90); }

   // gate = 90th-percentile live spread * tolerance, never below the median
   // (a broker whose typical spread already exceeds the guessed default is
   // telling you the truth about itself - trust the measurement)
   double EffectiveMaxSpreadPts(const double toleranceMultiplier, const double fallbackStatic) const
   {
      if(!HasEnoughData()) return fallbackStatic;
      double p90 = P90SpreadPts();
      double med = MedianSpreadPts();
      return MathMax(p90 * toleranceMultiplier, med * 1.2);
   }

   // a move must clear round-trip cost (spread) by a margin to carry any edge
   double EffectiveMinDisplacementPts(const double costMultiplier, const double fallbackStatic) const
   {
      if(!HasEnoughData()) return fallbackStatic;
      return MedianSpreadPts() * costMultiplier;
   }

   double EffectiveMinAtrPts(const double costMultiplier, const double fallbackStatic) const
   {
      if(!HasEnoughData()) return fallbackStatic;
      return MedianSpreadPts() * costMultiplier;
   }

   int EffectiveDeviationPoints(const double toleranceMultiplier, const int fallbackStatic) const
   {
      if(!HasEnoughData()) return fallbackStatic;
      return (int)MathCeil(MathMax(P90SpreadPts() * toleranceMultiplier, fallbackStatic));
   }
};
