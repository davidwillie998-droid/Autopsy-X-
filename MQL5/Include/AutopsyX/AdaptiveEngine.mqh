//+------------------------------------------------------------------+
//| AdaptiveEngine.mqh                                                |
//| Nudges a handful of operating parameters toward recent conditions.|
//| Every parameter is clamped to a hard, never-crossed [min,max] -   |
//| this is tuning, not unrestricted self-modification.               |
//+------------------------------------------------------------------+
#pragma once
#include <AutopsyX/Defines.mqh>

class CAXAdaptive
{
private:
   double m_entryThreshold;
   double m_exitThreshold;
   int    m_tickWindow;
   int    m_holdTimeSec;
   double m_trailDistancePoints;
   int    m_cooldownSec;
   int    m_maxFlipsPerMinute;

   double m_baseEntryThreshold;
   int    m_baseHoldTimeSec;
   double m_baseTrailDistancePoints;

public:
   CAXAdaptive(void) : m_entryThreshold(65.0), m_exitThreshold(50.0), m_tickWindow(80),
      m_holdTimeSec(300), m_trailDistancePoints(25.0), m_cooldownSec(15), m_maxFlipsPerMinute(4),
      m_baseEntryThreshold(65.0), m_baseHoldTimeSec(300), m_baseTrailDistancePoints(25.0) {}

   void Init(const double entryThreshold, const double exitThreshold, const int tickWindow,
             const int holdTimeSec, const double trailDistancePoints, const int cooldownSec,
             const int maxFlipsPerMinute)
   {
      m_entryThreshold        = AXClamp(entryThreshold, AX_ADAPT_ENTRY_THRESH_MIN, AX_ADAPT_ENTRY_THRESH_MAX);
      m_exitThreshold          = AXClamp(exitThreshold, AX_ADAPT_EXIT_THRESH_MIN, AX_ADAPT_EXIT_THRESH_MAX);
      m_tickWindow              = AXClampInt(tickWindow, (int)AX_ADAPT_TICKWINDOW_MIN, (int)AX_ADAPT_TICKWINDOW_MAX);
      m_holdTimeSec             = AXClampInt(holdTimeSec, (int)AX_ADAPT_HOLDTIME_MIN_SEC, (int)AX_ADAPT_HOLDTIME_MAX_SEC);
      m_trailDistancePoints     = AXClamp(trailDistancePoints, AX_ADAPT_TRAIL_MIN_POINTS, AX_ADAPT_TRAIL_MAX_POINTS);
      m_cooldownSec             = AXClampInt(cooldownSec, (int)AX_ADAPT_COOLDOWN_MIN_SEC, (int)AX_ADAPT_COOLDOWN_MAX_SEC);
      m_maxFlipsPerMinute       = AXClampInt(maxFlipsPerMinute, (int)AX_ADAPT_MAXFLIPS_MIN, (int)AX_ADAPT_MAXFLIPS_MAX);

      m_baseEntryThreshold       = m_entryThreshold;
      m_baseHoldTimeSec          = m_holdTimeSec;
      m_baseTrailDistancePoints  = m_trailDistancePoints;
   }

   // call periodically (e.g. every N closed trades), not every tick
   void Update(const double recentWinRatePct, const int sampleSize, const ENUM_AX_REGIME regime)
   {
      if(sampleSize >= 10)
      {
         if(recentWinRatePct >= 60.0)
            m_entryThreshold -= 1.0;   // conditions favorable - allow slightly more trades
         else if(recentWinRatePct <= 40.0)
            m_entryThreshold += 2.0;   // underperforming - demand a cleaner edge
      }

      if(regime == AX_REGIME_CHAOTIC || regime == AX_REGIME_UNSAFE)
      {
         m_entryThreshold = AX_ADAPT_ENTRY_THRESH_MAX;
         m_cooldownSec += 5;
      }
      else if(regime == AX_REGIME_LOWVOL)
      {
         m_tickWindow += 10;
         m_holdTimeSec += 15;
      }
      else if(regime == AX_REGIME_HIGHVOL)
      {
         m_holdTimeSec -= 15;
         m_trailDistancePoints += 5.0;
      }
      else
      {
         // relax back toward baseline when conditions are unremarkable
         m_tickWindow       += (m_tickWindow > 80) ? -5 : 0;
         m_holdTimeSec       += (m_holdTimeSec > m_baseHoldTimeSec) ? -5 : (m_holdTimeSec < m_baseHoldTimeSec ? 5 : 0);
         m_trailDistancePoints += (m_trailDistancePoints > m_baseTrailDistancePoints) ? -1.0 : 0.0;
         m_cooldownSec       += (m_cooldownSec > 15) ? -1 : 0;
      }

      ClampAll();
   }

   double EntryThreshold(void)      const { return m_entryThreshold; }
   double ExitThreshold(void)       const { return m_exitThreshold; }
   int    TickWindow(void)          const { return m_tickWindow; }
   int    HoldTimeSec(void)         const { return m_holdTimeSec; }
   double TrailDistancePoints(void) const { return m_trailDistancePoints; }
   int    CooldownSec(void)         const { return m_cooldownSec; }
   int    MaxFlipsPerMinute(void)   const { return m_maxFlipsPerMinute; }

private:
   void ClampAll(void)
   {
      m_entryThreshold      = AXClamp(m_entryThreshold, AX_ADAPT_ENTRY_THRESH_MIN, AX_ADAPT_ENTRY_THRESH_MAX);
      m_exitThreshold        = AXClamp(m_exitThreshold, AX_ADAPT_EXIT_THRESH_MIN, AX_ADAPT_EXIT_THRESH_MAX);
      m_tickWindow            = AXClampInt(m_tickWindow, (int)AX_ADAPT_TICKWINDOW_MIN, (int)AX_ADAPT_TICKWINDOW_MAX);
      m_holdTimeSec           = AXClampInt(m_holdTimeSec, (int)AX_ADAPT_HOLDTIME_MIN_SEC, (int)AX_ADAPT_HOLDTIME_MAX_SEC);
      m_trailDistancePoints   = AXClamp(m_trailDistancePoints, AX_ADAPT_TRAIL_MIN_POINTS, AX_ADAPT_TRAIL_MAX_POINTS);
      m_cooldownSec           = AXClampInt(m_cooldownSec, (int)AX_ADAPT_COOLDOWN_MIN_SEC, (int)AX_ADAPT_COOLDOWN_MAX_SEC);
      m_maxFlipsPerMinute     = AXClampInt(m_maxFlipsPerMinute, (int)AX_ADAPT_MAXFLIPS_MIN, (int)AX_ADAPT_MAXFLIPS_MAX);
   }
};
