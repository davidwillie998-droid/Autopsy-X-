//+------------------------------------------------------------------+
//|                                        AutopsyEventFilter.mqh     |
//|  AUTOPSY X — News / Event Governor (spec section 16)               |
//|                                                                     |
//|  Uses MT5's own built-in Economic Calendar API                     |
//|  (MqlCalendarEvent / MqlCalendarValue / CalendarValueHistory) —    |
//|  no external feed needed for this one, but two caveats:            |
//|   1. Calendar coverage/quality is the terminal's, not this code's; |
//|      if your broker restricts calendar access or hasn't synced it, |
//|      queries below return 0 rows or fail outright. That's surfaced |
//|      as a DEGRADED data status, not silently treated as "no news". |
//|   2. High-importance tagging in the calendar doesn't always catch  |
//|      every Fed speech — the keyword list below is a deliberate     |
//|      backstop on top of CALENDAR_IMPORTANCE_HIGH, not a replacement|
//|      for it.                                                       |
//+------------------------------------------------------------------+
#property strict
#include "AutopsyXCommon.mqh"

enum ENUM_AX_EVENT_STATE
  {
   AX_EVENT_NONE = 0,     // nothing high-impact nearby
   AX_EVENT_PRE_EVENT,    // inside the wide pre-event window
   AX_EVENT_BLACKOUT,     // inside the tight window immediately around release
   AX_EVENT_WAIT_REPRICE  // just past release, waiting before trusting the new price
  };

struct AxEventState
  {
   ENUM_AX_EVENT_STATE state;
   string              nearestEventName;
   double              minutesToNearestEvent; // negative if it already happened
   double              riskMultiplier;        // folds straight into the leverage model
   bool                newTradesAllowed;
   ENUM_AX_DATA_STATUS dataStatus;
  };

class CAxEventFilter
  {
private:
   string m_countryCode;         // ISO country code passed to CalendarValueHistory, e.g. "US"
   int    m_preEventWideMinutes; // PRE_EVENT_MODE window before release
   int    m_blackoutMinutes;     // hard block window either side of release
   int    m_postEventWaitMinutes;// WAIT_FOR_REPRICE window after the blackout ends
   double m_preEventRiskMultiplier;

   string m_keywords[8];
   int    m_keywordCount;

   bool MatchesKeyword(string nameLower)
     {
      for(int i = 0; i < m_keywordCount; i++)
         if(StringFind(nameLower, m_keywords[i]) >= 0)
            return true;
      return false;
     }

public:
   CAxEventFilter()
     {
      m_countryCode = "US";
      m_preEventWideMinutes = 60;
      m_blackoutMinutes = 5;
      m_postEventWaitMinutes = 15;
      m_preEventRiskMultiplier = 0.40; // spec band is 0.25-0.50

      m_keywords[0] = "fomc";
      m_keywords[1] = "federal funds";
      m_keywords[2] = "cpi";
      m_keywords[3] = "pce";
      m_keywords[4] = "nonfarm";
      m_keywords[5] = "non-farm";
      m_keywords[6] = "gdp";
      m_keywords[7] = "powell";
      m_keywordCount = 8;
     }

   void SetCountryCode(string code) { m_countryCode = code; }

   void SetWindows(int preEventWideMinutes, int blackoutMinutes, int postEventWaitMinutes, double preEventRiskMultiplier)
     {
      m_preEventWideMinutes  = MathMax(0, preEventWideMinutes);
      m_blackoutMinutes      = MathMax(0, blackoutMinutes);
      m_postEventWaitMinutes = MathMax(0, postEventWaitMinutes);
      m_preEventRiskMultiplier = AxClamp(preEventRiskMultiplier, 0.0, 1.0);
     }

   AxEventState Update()
     {
      AxEventState s;
      s.state = AX_EVENT_NONE;
      s.nearestEventName = "";
      s.minutesToNearestEvent = 1.0e9;
      s.riskMultiplier = 1.0;
      s.newTradesAllowed = true;
      s.dataStatus = AX_DATA_OK;

      datetime now  = TimeCurrent();
      datetime from = now - (m_blackoutMinutes + m_postEventWaitMinutes + 5) * 60;
      datetime to   = now + (m_preEventWideMinutes + 5) * 60;

      MqlCalendarValue values[];
      int n = CalendarValueHistory(values, from, to, m_countryCode, NULL);
      if(n < 0)
        {
         s.dataStatus = AX_DATA_DEGRADED; // calendar unavailable on this terminal/broker
         return s;
        }

      double bestAbsMinutes = 1.0e9;

      for(int i = 0; i < n; i++)
        {
         MqlCalendarEvent ev;
         if(!CalendarEventById(values[i].event_id, ev))
            continue;

         string nameLower = ev.name;
         StringToLower(nameLower);
         bool relevant = (ev.importance == CALENDAR_IMPORTANCE_HIGH) || MatchesKeyword(nameLower);
         if(!relevant)
            continue;

         double minutesTo = (double)(values[i].time - now) / 60.0;
         if(MathAbs(minutesTo) < bestAbsMinutes)
           {
            bestAbsMinutes = MathAbs(minutesTo);
            s.minutesToNearestEvent = minutesTo;
            s.nearestEventName = ev.name;
           }

         if(MathAbs(minutesTo) <= (double)m_blackoutMinutes)
           {
            s.state = AX_EVENT_BLACKOUT;
           }
         else if(minutesTo < 0 && MathAbs(minutesTo) <= (double)(m_blackoutMinutes + m_postEventWaitMinutes)
                 && s.state != AX_EVENT_BLACKOUT)
           {
            s.state = AX_EVENT_WAIT_REPRICE;
           }
         else if(minutesTo > 0 && minutesTo <= (double)m_preEventWideMinutes
                 && s.state == AX_EVENT_NONE)
           {
            s.state = AX_EVENT_PRE_EVENT;
           }
        }

      switch(s.state)
        {
         case AX_EVENT_BLACKOUT:
            s.riskMultiplier = 0.0;
            s.newTradesAllowed = false;
            break;
         case AX_EVENT_WAIT_REPRICE:
            //--- spec: "do not assume the initial spike is the final direction" —
            //    stay out of new trades until the wait window clears, then the
            //    regime engine gets a completely fresh read on the next call.
            s.riskMultiplier = 0.0;
            s.newTradesAllowed = false;
            break;
         case AX_EVENT_PRE_EVENT:
            s.riskMultiplier = m_preEventRiskMultiplier;
            s.newTradesAllowed = true;
            break;
         default:
            s.riskMultiplier = 1.0;
            s.newTradesAllowed = true;
        }

      return s;
     }
  };
