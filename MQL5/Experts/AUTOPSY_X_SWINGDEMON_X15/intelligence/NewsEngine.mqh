//+------------------------------------------------------------------+
//| NewsEngine.mqh                                                     |
//| Wraps MT5's native Economic Calendar (MqlCalendarEvent/Value) -   |
//| a real terminal feature, not a WebRequest hack. If the terminal's |
//| calendar isn't populated (calendar disabled or no history yet)    |
//| this degrades to "no event data" rather than inventing a schedule.|
//+------------------------------------------------------------------+
#property strict
#ifndef AX_INTELLIGENCE_NEWSENGINE_MQH
#define AX_INTELLIGENCE_NEWSENGINE_MQH
#include "../core/Types.mqh"

class CNewsEngine
  {
private:
   string m_currencies[4];
   int    m_currencyCount;
   bool   m_dataAvailable;

public:
   void Init(const string symbol)
     {
      m_currencyCount = 0;
      string base = SymbolInfoString(symbol, SYMBOL_CURRENCY_BASE);
      string profit = SymbolInfoString(symbol, SYMBOL_CURRENCY_PROFIT);
      if(base!="")   m_currencies[m_currencyCount++] = base;
      if(profit!="" && profit!=base) m_currencies[m_currencyCount++] = profit;
      // metals/indices are USD-event sensitive even when base currency is XAU/XAG etc.
      bool hasUsd=false;
      for(int i=0;i<m_currencyCount;i++) if(m_currencies[i]=="USD") hasUsd=true;
      if(!hasUsd && m_currencyCount<4) m_currencies[m_currencyCount++]="USD";

      // probe availability once
      MqlCalendarValue values[];
      datetime probeFrom = TimeCurrent()-86400;
      datetime probeTo   = TimeCurrent()+86400;
      m_dataAvailable = CalendarValueHistory(values, probeFrom, probeTo, NULL, NULL);
     }

   bool DataAvailable() const { return m_dataAvailable; }

   //--- true if a HIGH importance event for a relevant currency falls inside [from,to]
   bool HasHighImpactEvent(datetime from, datetime to, string &eventName, datetime &eventTime) const
     {
      eventName=""; eventTime=0;
      if(!m_dataAvailable) return false;

      MqlCalendarValue values[];
      int total = CalendarValueHistory(values, from, to, NULL, NULL);
      if(total<=0) return false;

      for(int i=0;i<total;i++)
        {
         MqlCalendarEvent ev;
         if(!CalendarEventById(values[i].event_id, ev)) continue;
         if(ev.importance != CALENDAR_IMPORTANCE_HIGH) continue;

         MqlCalendarCountry country;
         if(!CalendarCountryById(ev.country_id, country)) continue;
         bool relevant=false;
         for(int c=0;c<m_currencyCount;c++)
            if(country.currency==m_currencies[c]) { relevant=true; break; }
         if(!relevant) continue;

         eventName = ev.name;
         eventTime = values[i].time;
         return true;
        }
      return false;
     }

   //--- pre-event blackout: no new entries inside preMinutes of a scheduled high-impact release
   bool InPreEventWindow(int preMinutes, string &eventName) const
     {
      datetime eventTime;
      return HasHighImpactEvent(TimeCurrent(), TimeCurrent()+preMinutes*60, eventName, eventTime);
     }

   //--- post-event confirmation window: wait postMinutes after the last high-impact release before trusting price discovery
   bool InPostEventWindow(int postMinutes, string &eventName) const
     {
      datetime eventTime;
      bool found = HasHighImpactEvent(TimeCurrent()-postMinutes*60, TimeCurrent(), eventName, eventTime);
      if(!found) return false;
      return (TimeCurrent()-eventTime) < postMinutes*60;
     }
  };
#endif // AX_INTELLIGENCE_NEWSENGINE_MQH
