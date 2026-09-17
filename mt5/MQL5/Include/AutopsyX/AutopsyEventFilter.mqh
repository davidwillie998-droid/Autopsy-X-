//+------------------------------------------------------------------+
//|                                          AutopsyEventFilter.mqh  |
//|  AUTOPSY X — News / Event Governor                               |
//|  Spec section 16.                                                |
//|                                                                    |
//|  MT5's Calendar API (CalendarValueHistory / CalendarEventById)    |
//|  only works when the broker's server actually feeds the terminal |
//|  calendar — many brokers, especially non-MetaQuotes-server or     |
//|  prop-firm setups, don't. This filter tries the live calendar     |
//|  first and falls back to a manually configured blackout list —   |
//|  it never assumes "no calendar data" means "no event risk".      |
//+------------------------------------------------------------------+
#property strict
#include "AutopsyTypes.mqh"

enum ENUM_AX_EVENT_STATE
  {
   AX_EVENT_NORMAL,
   AX_EVENT_PRE_EVENT,
   AX_EVENT_BLACKOUT,
   AX_EVENT_POST_EVENT_WAIT
  };

struct AxEventEntry
  {
   datetime event_time;
   string   label;
  };

struct AxEventState
  {
   ENUM_AX_EVENT_STATE state;
   double              risk_multiplier;
   bool                new_trades_allowed;
   bool                force_regime_recompute; // fires once, on the PRE/BLACKOUT -> NORMAL transition after cooldown
   string              nearest_event_label;
  };

class CAxEventFilter
  {
private:
   AxEventEntry m_manual[];
   AxEventEntry m_calendar[];
   int          m_pre_event_minutes;
   int          m_blackout_minutes;
   int          m_post_event_cooldown_minutes;
   double       m_pre_event_risk_multiplier;
   bool         m_calendar_available;
   ENUM_AX_EVENT_STATE m_previous_state;

public:
   void Init(const int pre_event_minutes = 60, const int blackout_minutes = 15,
             const int post_event_cooldown_minutes = 30, const double pre_event_risk_multiplier = 0.375)
     {
      m_pre_event_minutes           = pre_event_minutes;
      m_blackout_minutes             = blackout_minutes;
      m_post_event_cooldown_minutes  = post_event_cooldown_minutes;
      m_pre_event_risk_multiplier    = AxClamp(pre_event_risk_multiplier, 0.25, 0.50);
      m_calendar_available           = false;
      m_previous_state               = AX_EVENT_NORMAL;
      ArrayResize(m_manual, 0);
      ArrayResize(m_calendar, 0);
     }

   //+---------------------------------------------------------------+
   //| Manually schedule a known high-impact event (FOMC, CPI, PCE,  |
   //| NFP, GDP, a Fed speech). Use this as the reliable baseline —  |
   //| the live calendar below is a bonus on top of it, not a         |
   //| replacement for it.                                             |
   //+---------------------------------------------------------------+
   void AddManualEvent(const datetime event_time, const string label)
     {
      const int n = ArraySize(m_manual);
      ArrayResize(m_manual, n + 1);
      m_manual[n].event_time = event_time;
      m_manual[n].label      = label;
     }

   void ClearManualEvents() { ArrayResize(m_manual, 0); }

   //+---------------------------------------------------------------+
   //| Attempt to pull high-importance US events from the terminal's |
   //| calendar feed. Safe to call every bar — it only replaces the   |
   //| cached calendar list, it never touches the manual list.        |
   //| Returns false (and leaves the manual list as the sole source) |
   //| if the calendar feed isn't available on this broker.           |
   //+---------------------------------------------------------------+
   bool RefreshCalendar(const datetime window_start, const datetime window_end)
     {
      MqlCalendarValue values[];
      const int got = CalendarValueHistory(values, window_start, window_end, "US");
      if(got < 0)
        {
         m_calendar_available = false;
         return false;
        }

      m_calendar_available = true;
      ArrayResize(m_calendar, 0);
      for(int i = 0; i < got; i++)
        {
         MqlCalendarEvent ev;
         if(!CalendarEventById(values[i].event_id, ev)) continue;
         if(ev.importance != CALENDAR_IMPORTANCE_HIGH) continue;

         const int n = ArraySize(m_calendar);
         ArrayResize(m_calendar, n + 1);
         m_calendar[n].event_time = values[i].time;
         m_calendar[n].label      = ev.name;
        }
      return true;
     }

   bool IsCalendarAvailable() const { return m_calendar_available; }

   //+---------------------------------------------------------------+
   //| Evaluate PRE_EVENT / BLACKOUT / POST_EVENT_WAIT / NORMAL       |
   //| against every known event (manual + calendar), and return the |
   //| most restrictive state across all of them.                     |
   //+---------------------------------------------------------------+
   AxEventState Evaluate(const datetime now)
     {
      AxEventState result;
      result.state                  = AX_EVENT_NORMAL;
      result.risk_multiplier        = 1.0;
      result.new_trades_allowed     = true;
      result.force_regime_recompute = false;
      result.nearest_event_label    = "";

      const int manual_count = ArraySize(m_manual);
      const int total = manual_count + ArraySize(m_calendar);
      for(int idx = 0; idx < total; idx++)
        {
         AxEventEntry entry;
         if(idx < manual_count) entry = m_manual[idx];
         else entry = m_calendar[idx - manual_count];
         const double delta_minutes = (double)(entry.event_time - now) / 60.0;

         ENUM_AX_EVENT_STATE this_state = AX_EVENT_NORMAL;
         if(MathAbs(delta_minutes) <= m_blackout_minutes)
            this_state = AX_EVENT_BLACKOUT;
         else if(delta_minutes > m_blackout_minutes && delta_minutes <= m_pre_event_minutes)
            this_state = AX_EVENT_PRE_EVENT;
         else if(delta_minutes < -m_blackout_minutes && delta_minutes >= -(m_blackout_minutes + m_post_event_cooldown_minutes))
            this_state = AX_EVENT_POST_EVENT_WAIT;

         // Restrictiveness order: BLACKOUT > POST_EVENT_WAIT > PRE_EVENT > NORMAL.
         if(Restrictiveness(this_state) > Restrictiveness(result.state))
           {
            result.state = this_state;
            result.nearest_event_label = entry.label;
           }
        }

      switch(result.state)
        {
         case AX_EVENT_BLACKOUT:
            result.risk_multiplier = 0.0; result.new_trades_allowed = false; break;
         case AX_EVENT_POST_EVENT_WAIT:
            result.risk_multiplier = 0.0; result.new_trades_allowed = false; break; // do not trust the initial spike direction
         case AX_EVENT_PRE_EVENT:
            result.risk_multiplier = m_pre_event_risk_multiplier; result.new_trades_allowed = true; break;
         case AX_EVENT_NORMAL:
         default:
            result.risk_multiplier = 1.0; result.new_trades_allowed = true; break;
        }

      // Edge-triggered: the moment we come out of a restricted state,
      // tell the caller to force a full regime recompute rather than
      // trusting whatever was cached going into the event.
      if(result.state == AX_EVENT_NORMAL &&
         (m_previous_state == AX_EVENT_BLACKOUT || m_previous_state == AX_EVENT_POST_EVENT_WAIT))
         result.force_regime_recompute = true;

      m_previous_state = result.state;
      return result;
     }

private:
   int Restrictiveness(const ENUM_AX_EVENT_STATE s) const
     {
      switch(s)
        {
         case AX_EVENT_BLACKOUT:         return 3;
         case AX_EVENT_POST_EVENT_WAIT:  return 2;
         case AX_EVENT_PRE_EVENT:        return 1;
         default:                        return 0;
        }
     }
  };
