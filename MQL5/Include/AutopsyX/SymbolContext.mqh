//+------------------------------------------------------------------+
//|                                                  SymbolContext.mqh |
//| Independent quote/lifecycle state per registered symbol           |
//| Does not yet own strategy engines or authorize execution.          |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_SYMBOLCONTEXT_MQH
#define AX_SYMBOLCONTEXT_MQH
#include <AutopsyX/SymbolUniverse.mqh>

class CAxSymbolContext
  {
private:
   string   m_symbols[AX_MAX_UNIVERSE_SYMBOLS];
   MqlTick  m_ticks[AX_MAX_UNIVERSE_SYMBOLS];
   datetime m_lastProcessedBar[AX_MAX_UNIVERSE_SYMBOLS];
   datetime m_signalTime[AX_MAX_UNIVERSE_SYMBOLS];
   datetime m_cooldownUntil[AX_MAX_UNIVERSE_SYMBOLS];
   bool     m_quoteValid[AX_MAX_UNIVERSE_SYMBOLS];
   int      m_count;
   int      m_maxQuoteAgeSeconds;

   int Find(const string symbol) const
     {
      for(int i=0;i<m_count;i++)
         if(m_symbols[i]==symbol) return(i);
      return(-1);
     }

public:
                     CAxSymbolContext(void)
     {
      m_count=0;
      m_maxQuoteAgeSeconds=60;
      for(int i=0;i<AX_MAX_UNIVERSE_SYMBOLS;i++)
        {
         m_symbols[i]="";
         ZeroMemory(m_ticks[i]);
         m_lastProcessedBar[i]=0;
         m_signalTime[i]=0;
         m_cooldownUntil[i]=0;
         m_quoteValid[i]=false;
        }
     }

   void              Configure(const int maxQuoteAgeSeconds)
     {
      m_maxQuoteAgeSeconds=(int)MathMax(1,maxQuoteAgeSeconds);
     }

   bool              LoadUniverse(CAxSymbolUniverse &universe,const int maxQuoteAgeSeconds)
     {
      m_count=0;
      Configure(maxQuoteAgeSeconds);
      for(int i=0;i<universe.Count() && i<AX_MAX_UNIVERSE_SYMBOLS;i++)
        {
         string symbol=universe.At(i);
         if(symbol=="") continue;
         if(Find(symbol)>=0) continue;
         m_symbols[m_count]=symbol;
         m_count++;
        }
      return(m_count>0);
     }

   int               Count(void) const { return(m_count); }

   string            SymbolAt(const int index) const
     {
      if(index<0 || index>=m_count) return("");
      return(m_symbols[index]);
     }

   // Refresh every registered symbol independently. Invalid/stale quotes are
   // marked invalid and must not be used to rank or execute a candidate.
   void              RefreshQuotes(void)
     {
      for(int i=0;i<m_count;i++)
        {
         MqlTick tick;
         bool ok=SymbolInfoTick(m_symbols[i],tick);
         if(!ok || tick.bid<=0.0 || tick.ask<=0.0 || tick.ask<tick.bid || tick.time<=0)
           {
            m_quoteValid[i]=false;
            continue;
           }
         int age=(int)(TimeCurrent()-tick.time);
         if(age<0 || age>m_maxQuoteAgeSeconds)
           {
            m_quoteValid[i]=false;
            continue;
           }
         m_ticks[i]=tick;
         m_quoteValid[i]=true;
        }
     }

   bool              QuoteIsValid(const string symbol) const
     {
      int i=Find(symbol);
      if(i<0 || !m_quoteValid[i]) return(false);
      int age=(int)(TimeCurrent()-m_ticks[i].time);
      return(age>=0 && age<=m_maxQuoteAgeSeconds);
     }

   bool              GetTick(const string symbol,MqlTick &tick) const
     {
      int i=Find(symbol);
      if(i<0 || !QuoteIsValid(symbol)) return(false);
      tick=m_ticks[i];
      return(true);
     }

   double            Mid(const string symbol) const
     {
      int i=Find(symbol);
      if(i<0 || !QuoteIsValid(symbol)) return(0.0);
      return((m_ticks[i].bid+m_ticks[i].ask)*0.5);
     }

   double            SpreadPrice(const string symbol) const
     {
      int i=Find(symbol);
      if(i<0 || !QuoteIsValid(symbol)) return(0.0);
      return(m_ticks[i].ask-m_ticks[i].bid);
     }

   datetime          QuoteTime(const string symbol) const
     {
      int i=Find(symbol);
      if(i<0 || !QuoteIsValid(symbol)) return(0);
      return(m_ticks[i].time);
     }

   bool              IsNewBar(const string symbol,const ENUM_TIMEFRAMES timeframe)
     {
      int i=Find(symbol);
      if(i<0) return(false);
      datetime bar=iTime(m_symbols[i],timeframe,0);
      if(bar<=0 || bar==m_lastProcessedBar[i]) return(false);
      m_lastProcessedBar[i]=bar;
      return(true);
     }

   void              MarkSignal(const string symbol,const datetime signalTime)
     {
      int i=Find(symbol);
      if(i<0) return;
      m_signalTime[i]=signalTime;
     }

   datetime          SignalTime(const string symbol) const
     {
      int i=Find(symbol);
      if(i<0) return(0);
      return(m_signalTime[i]);
     }

   bool              SignalIsFresh(const string symbol,const int maxAgeSeconds) const
     {
      datetime stamp=SignalTime(symbol);
      if(stamp<=0 || maxAgeSeconds<1) return(false);
      int age=(int)(TimeCurrent()-stamp);
      return(age>=0 && age<=maxAgeSeconds);
     }

   void              SetCooldown(const string symbol,const datetime untilTime)
     {
      int i=Find(symbol);
      if(i<0) return;
      m_cooldownUntil[i]=untilTime;
     }

   bool              IsCoolingDown(const string symbol) const
     {
      int i=Find(symbol);
      if(i<0) return(true);
      return(TimeCurrent()<m_cooldownUntil[i]);
     }
  };

#endif // AX_SYMBOLCONTEXT_MQH
