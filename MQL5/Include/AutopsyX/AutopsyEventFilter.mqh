//+------------------------------------------------------------------+
//| AutopsyEventFilter.mqh                                              |
//| Real MT5 Economic Calendar (CalendarValueHistory/CalendarEventById)|
//| governor for curated high-impact USD releases: FOMC/CPI/PCE/NFP/  |
//| GDP/Fed speeches/major employment data. Three states around any   |
//| matching event: PRE_EVENT_MODE (reduced risk), an in-event hard   |
//| block, and a post-event WAIT_FOR_REPRICE window - the initial     |
//| spike after a release is never assumed to be the final direction. |
//+------------------------------------------------------------------+
#property strict
#ifndef AUTOPSYX_EVENTFILTER_MQH
#define AUTOPSYX_EVENTFILTER_MQH
#include "AutopsyTypes.mqh"

class CAutopsyEventFilter
  {
private:
   int    m_preEventBlackoutMinutes;
   int    m_inEventBlockMinutes;
   int    m_postEventRepriceMinutes;
   double m_preEventRiskMultiplier;

   bool IsCuratedHighImpactUSD(const MqlCalendarEvent &ev) const
     {
      if(ev.importance != CALENDAR_IMPORTANCE_HIGH) return false;
      if(StringFind(ev.name,"CPI")>=0) return true;
      if(StringFind(ev.name,"PCE")>=0) return true;
      if(StringFind(ev.name,"Non-Farm")>=0 || StringFind(ev.name,"Nonfarm")>=0 || StringFind(ev.name,"Payrolls")>=0) return true;
      if(StringFind(ev.name,"GDP")>=0) return true;
      if(StringFind(ev.name,"Fed")>=0 || StringFind(ev.name,"FOMC")>=0 || StringFind(ev.name,"Interest Rate")>=0) return true;
      if(StringFind(ev.name,"Powell")>=0) return true;
      if(StringFind(ev.name,"Unemployment")>=0 || StringFind(ev.name,"Employment")>=0) return true;
      return false;
     }

public:
   void Init(int preEventBlackoutMinutes=30, int inEventBlockMinutes=5, int postEventRepriceMinutes=30,
             double preEventRiskMultiplier=0.35)
     {
      m_preEventBlackoutMinutes = MathMax(0, preEventBlackoutMinutes);
      m_inEventBlockMinutes     = MathMax(1, inEventBlockMinutes);
      m_postEventRepriceMinutes = MathMax(0, postEventRepriceMinutes);
      m_preEventRiskMultiplier  = MathMax(0.0, MathMin(1.0, preEventRiskMultiplier));
     }

   double PreEventRiskMultiplier() const { return m_preEventRiskMultiplier; }

   //--- scans the window around "now" for curated events and reports the most restrictive state found.
   //--- inEventBlock and waitForReprice/preEventMode are not mutually exclusive across DIFFERENT events
   //--- inside the same window - the caller treats inEventBlock as the hardest stop regardless.
   void Evaluate(bool &preEventMode, bool &inEventBlock, bool &waitForReprice, string &eventNameOut) const
     {
      preEventMode=false; inEventBlock=false; waitForReprice=false; eventNameOut="";

      datetime from = TimeCurrent() - (datetime)(m_inEventBlockMinutes+m_postEventRepriceMinutes)*60 - 60;
      datetime to   = TimeCurrent() + (datetime)m_preEventBlackoutMinutes*60 + 60;
      MqlCalendarValue values[];
      if(!CalendarValueHistory(values, from, to, "US")) return;

      for(int i=0;i<ArraySize(values);i++)
        {
         MqlCalendarEvent ev;
         if(!CalendarEventById(values[i].event_id, ev)) continue;
         if(!IsCuratedHighImpactUSD(ev)) continue;

         long secsUntil = (long)(values[i].time - TimeCurrent());

         if(MathAbs((double)secsUntil) <= m_inEventBlockMinutes*60)
           {
            inEventBlock = true; eventNameOut = ev.name;
           }
         else if(secsUntil>0 && secsUntil<=m_preEventBlackoutMinutes*60)
           {
            preEventMode = true; if(eventNameOut=="") eventNameOut = ev.name;
           }
         else if(secsUntil<0 && -secsUntil<=(m_inEventBlockMinutes+m_postEventRepriceMinutes)*60)
           {
            waitForReprice = true; if(eventNameOut=="") eventNameOut = ev.name;
           }
        }
     }
  };
#endif // AUTOPSYX_EVENTFILTER_MQH
