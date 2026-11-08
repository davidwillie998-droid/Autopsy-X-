//+------------------------------------------------------------------+
//|                                                NewsDefense.mqh   |
//| High-impact MT5 economic-calendar blackout for traded currencies. |
//| Unknown calendar data is never reported as a clean news window.   |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_NEWSDEFENSE_MQH
#define AX_NEWSDEFENSE_MQH

class CNewsDefenseEngine
  {
private:
   string   m_symbol;
   string   m_currencies[2];
   int      m_currencyCount;
   int      m_beforeMinutes;
   int      m_afterMinutes;
   int      m_refreshSeconds;
   datetime m_lastRefresh;
   bool     m_available;
   bool     m_blocked;
   string   m_state;
   string   m_reason;

   bool IsFiatCurrency(const string code) const
     {
      string known="|USD|EUR|GBP|JPY|CHF|CAD|AUD|NZD|CNY|CNH|HKD|SGD|SEK|NOK|DKK|PLN|CZK|HUF|TRY|MXN|ZAR|BRL|INR|KRW|TWD|ILS|";
      return(StringFind(known,"|"+code+"|")>=0);
     }

   void AddCurrency(const string code)
     {
      if(!IsFiatCurrency(code) || m_currencyCount>=2) return;
      for(int i=0;i<m_currencyCount;i++) if(m_currencies[i]==code) return;
      m_currencies[m_currencyCount++]=code;
     }

public:
                     CNewsDefenseEngine(void)
     {
      m_symbol=""; m_currencyCount=0; m_beforeMinutes=20; m_afterMinutes=15;
      m_refreshSeconds=30; m_lastRefresh=0; m_available=false; m_blocked=false;
      m_state="DATA_UNAVAILABLE"; m_reason="NOT_INITIALIZED";
      m_currencies[0]=""; m_currencies[1]="";
     }

   bool              Init(const string symbol,const int minutesBefore=20,
                          const int minutesAfter=15,const int refreshSeconds=30)
     {
      m_symbol=symbol;
      m_beforeMinutes=MathMax(0,minutesBefore);
      m_afterMinutes=MathMax(0,minutesAfter);
      m_refreshSeconds=MathMax(5,refreshSeconds);
      m_currencyCount=0;
      AddCurrency(SymbolInfoString(symbol,SYMBOL_CURRENCY_BASE));
      AddCurrency(SymbolInfoString(symbol,SYMBOL_CURRENCY_PROFIT));
      m_lastRefresh=0; m_available=false; m_blocked=false;
      if(m_currencyCount==0)
        {
         // Synthetic instruments without an underlying fiat currency have no
         // applicable country-currency calendar filter.
         m_available=true; m_state="NOT_APPLICABLE"; m_reason="NO_FIAT_CURRENCY_EXPOSURE";
         return(true);
        }
      m_state="DATA_UNAVAILABLE"; m_reason="CALENDAR_NOT_QUERIED";
      return(true);
     }

   bool              Update(const bool force=false)
     {
      if(m_currencyCount==0 && m_available) return(true);
      datetime now=TimeTradeServer();
      if(now<=0)
        {
         m_available=false; m_blocked=false; m_state="DATA_UNAVAILABLE";
         m_reason="TRADE_SERVER_TIME_UNAVAILABLE";
         return(false);
        }
      if(!force && m_lastRefresh>0 && (now-m_lastRefresh)<m_refreshSeconds)
         return(m_available);
      m_lastRefresh=now;
      m_available=false; m_blocked=false; m_state="DATA_UNAVAILABLE";
      m_reason="CALENDAR_QUERY_FAILED";

      datetime from=now-m_beforeMinutes*60;
      datetime to=now+m_afterMinutes*60;
      bool allQueriesOk=true;
      string highImpactReason="";
      for(int c=0;c<m_currencyCount;c++)
        {
         MqlCalendarValue values[];
         ResetLastError();
         int count=CalendarValueHistory(values,from,to,NULL,m_currencies[c]);
         if(count<0)
           {
            allQueriesOk=false;
            m_reason=StringFormat("CALENDAR_QUERY_FAILED currency=%s error=%d",m_currencies[c],GetLastError());
            continue;
           }
         for(int i=0;i<count;i++)
           {
            MqlCalendarEvent eventInfo;
            if(!CalendarEventById(values[i].event_id,eventInfo))
              {
               allQueriesOk=false;
               m_reason=StringFormat("CALENDAR_EVENT_METADATA_UNAVAILABLE event=%I64u",values[i].event_id);
               continue;
              }
            if(eventInfo.importance!=CALENDAR_IMPORTANCE_HIGH) continue;
            if(values[i].time>=from && values[i].time<=to)
              {
               m_blocked=true;
               highImpactReason=StringFormat("HIGH_IMPACT_NEWS currency=%s event=%s event_time=%s",
                                              m_currencies[c],eventInfo.name,
                                              TimeToString(values[i].time,TIME_DATE|TIME_MINUTES));
              }
           }
        }

      if(!allQueriesOk)
        {
         // Partial calendar data cannot prove that every relevant currency is clear.
         m_available=false; m_blocked=false; m_state="DATA_UNAVAILABLE";
         return(false);
        }
      m_available=true;
      if(m_blocked)
        {
         m_state="BLOCK";
         m_reason=highImpactReason;
        }
      else
        {
         m_state="CLEAR";
         m_reason="NO_HIGH_IMPACT_EVENT_IN_CONFIGURED_WINDOW";
        }
      return(true);
     }

   bool              IsAvailable(void) const { return(m_available); }
   bool              IsBlocked(void) const { return(m_blocked); }
   string            State(void) const { return(m_state); }
   string            Reason(void) const { return(m_reason); }
   int               CurrencyCount(void) const { return(m_currencyCount); }
  };
#endif // AX_NEWSDEFENSE_MQH
