//+------------------------------------------------------------------+
//| OrderBlockEngine.mqh                                             |
//| Structure-confirmed order-block and breaker lifecycle.           |
//| Advisory evidence only. No order or position functions.           |
//+------------------------------------------------------------------+
#ifndef AX_ORDERBLOCKENGINE_MQH
#define AX_ORDERBLOCKENGINE_MQH
#property strict
#include "Defs.mqh"

enum ENUM_AX_OB_STATE
  {
   AX_OB_NONE=0,
   AX_OB_ACTIVE,
   AX_OB_MITIGATED,
   AX_OB_BREAKER
  };

struct SAxOrderBlockReading
  {
   bool available;
   bool priceInside;
   bool retested;
   bool breaker;
   ENUM_AX_DIR direction;
   ENUM_AX_OB_STATE state;
   double lower;
   double upper;
   double midpoint;
   datetime originTime;
   datetime confirmationTime;
   int ageBars;
   string reason;
  };

class COrderBlockEngine
  {
private:
   string m_symbol;
   ENUM_TIMEFRAMES m_timeframe;
   int m_lookbackBars;
   int m_maxAgeBars;
   int m_originSearchBars;
   double m_minBodyRatio;
   datetime m_lastProcessedEvent;
   SAxOrderBlockReading m_zone;
   bool m_initialized;

   void Reset(void)
     {
      ZeroMemory(m_zone);
      m_zone.available=false;
      m_zone.direction=AX_DIR_NONE;
      m_zone.state=AX_OB_NONE;
      m_zone.reason="NO_CONFIRMED_ORDER_BLOCK";
     }

   bool IsBullEvent(const ENUM_AX_STRUCTURE_EVENT event) const
     {
      return(event==AX_STRUCT_BOS_BULLISH ||
             event==AX_STRUCT_CHOCH_BULLISH ||
             event==AX_STRUCT_MSS_BULLISH);
     }

   bool IsBearEvent(const ENUM_AX_STRUCTURE_EVENT event) const
     {
      return(event==AX_STRUCT_BOS_BEARISH ||
             event==AX_STRUCT_CHOCH_BEARISH ||
             event==AX_STRUCT_MSS_BEARISH);
     }

   bool BuildFromEvent(const MqlRates &rates[],const int count,
                       const ENUM_AX_STRUCTURE_EVENT event,
                       const datetime eventTime,const bool displacement)
     {
      if(!displacement || count<4 || eventTime<=0)
         return(false);
      bool bullish=IsBullEvent(event);
      bool bearish=IsBearEvent(event);
      if(!bullish && !bearish) return(false);
      if(rates[0].time!=eventTime) return(false);

      double signalRange=rates[0].high-rates[0].low;
      if(signalRange<=0.0) return(false);
      double signalBody=MathAbs(rates[0].close-rates[0].open)/signalRange;
      if(signalBody<m_minBodyRatio) return(false);
      if(bullish && rates[0].close<=rates[0].open) return(false);
      if(bearish && rates[0].close>=rates[0].open) return(false);

      int scan=MathMin(m_originSearchBars,count-1);
      for(int i=1;i<=scan;i++)
        {
         bool opposing=bullish ? (rates[i].close<rates[i].open) :
                                 (rates[i].close>rates[i].open);
         if(!opposing) continue;

         double lower=bullish ? rates[i].low : rates[i].open;
         double upper=bullish ? rates[i].open : rates[i].high;
         if(lower<=0.0 || upper<=lower) continue;

         // A bullish OB is the final bearish candle before confirmed upward
         // displacement. A bearish OB is the final bullish candle before
         // confirmed downward displacement. No unconfirmed candle is used.
         Reset();
         m_zone.available=true;
         m_zone.direction=bullish ? AX_DIR_BUY : AX_DIR_SELL;
         m_zone.state=AX_OB_ACTIVE;
         m_zone.lower=lower;
         m_zone.upper=upper;
         m_zone.midpoint=(lower+upper)*0.5;
         m_zone.originTime=rates[i].time;
         m_zone.confirmationTime=eventTime;
         m_zone.ageBars=0;
         m_zone.reason=bullish ? "BULLISH_OB_CONFIRMED_BY_STRUCTURE" :
                                 "BEARISH_OB_CONFIRMED_BY_STRUCTURE";
         return(true);
        }
      return(false);
     }

public:
                     COrderBlockEngine(void)
     {
      m_symbol="";
      m_timeframe=PERIOD_M5;
      m_lookbackBars=160;
      m_maxAgeBars=48;
      m_originSearchBars=8;
      m_minBodyRatio=0.55;
      m_lastProcessedEvent=0;
      m_initialized=false;
      Reset();
     }

   bool Init(const string symbol,const ENUM_TIMEFRAMES timeframe=PERIOD_M5,
             const int lookbackBars=160,const int maxAgeBars=48,
             const int originSearchBars=8,const double minBodyRatio=0.55)
     {
      if(StringLen(symbol)==0 || timeframe<=PERIOD_CURRENT ||
         lookbackBars<20 || lookbackBars>2000 || maxAgeBars<1 ||
         maxAgeBars>=lookbackBars || originSearchBars<1 ||
         originSearchBars>32 || minBodyRatio<0.0 || minBodyRatio>1.0)
        {
         Reset();
         return(false);
        }
      m_symbol=symbol;
      m_timeframe=timeframe;
      m_lookbackBars=lookbackBars;
      m_maxAgeBars=maxAgeBars;
      m_originSearchBars=originSearchBars;
      m_minBodyRatio=minBodyRatio;
      m_initialized=true;
      Reset();
      return(true);
     }

   bool Update(const double currentPrice,const ENUM_AX_STRUCTURE_EVENT event,
               const datetime eventTime,const bool displacement)
     {
      if(!m_initialized) return(false);
      datetime closedBar=iTime(m_symbol,m_timeframe,1);
      if(closedBar<=0) { Reset(); return(false); }

      if(eventTime>0 && eventTime!=m_lastProcessedEvent &&
         (IsBullEvent(event) || IsBearEvent(event)))
        {
         m_lastProcessedEvent=eventTime;
         MqlRates rates[];
         ArraySetAsSeries(rates,true);
         int copied=CopyRates(m_symbol,m_timeframe,1,m_lookbackBars,rates);
         if(copied<20) { Reset(); m_zone.reason="INSUFFICIENT_CLOSED_HISTORY"; return(false); }
         BuildFromEvent(rates,copied,event,eventTime,displacement);
        }

      if(m_zone.available)
        {
         int shift=iBarShift(m_symbol,m_timeframe,m_zone.confirmationTime,true);
         if(shift<0) shift=iBarShift(m_symbol,m_timeframe,m_zone.confirmationTime,false);
         m_zone.ageBars=(shift>=0 ? shift-1 : m_maxAgeBars+1);
         if(m_zone.ageBars>m_maxAgeBars)
           {
            Reset();
            m_zone.reason="ORDER_BLOCK_EXPIRED";
            return(false);
           }

         MqlRates latest[];
         ArraySetAsSeries(latest,true);
         if(CopyRates(m_symbol,m_timeframe,1,1,latest)==1)
           {
            bool broken=m_zone.direction==AX_DIR_BUY ?
                        latest[0].close<m_zone.lower :
                        latest[0].close>m_zone.upper;
            if(broken && m_zone.state!=AX_OB_BREAKER)
              {
               m_zone.direction=(m_zone.direction==AX_DIR_BUY ? AX_DIR_SELL : AX_DIR_BUY);
               m_zone.state=AX_OB_BREAKER;
               m_zone.breaker=true;
               m_zone.retested=false;
               m_zone.reason="ORDER_BLOCK_FAILED_BECAME_BREAKER";
              }
            else if(!broken && m_zone.state!=AX_OB_BREAKER)
              {
               bool touched=m_zone.direction==AX_DIR_BUY ?
                            latest[0].low<=m_zone.upper :
                            latest[0].high>=m_zone.lower;
               if(touched)
                 {
                  m_zone.retested=true;
                  m_zone.state=AX_OB_MITIGATED;
                  m_zone.reason="ORDER_BLOCK_RETESTED";
                 }
              }
           }

         m_zone.priceInside=(currentPrice>=m_zone.lower &&
                             currentPrice<=m_zone.upper);
         if(m_zone.priceInside)
            m_zone.reason=(m_zone.state==AX_OB_BREAKER ?
                           "PRICE_INSIDE_BREAKER" : "PRICE_INSIDE_ORDER_BLOCK");
        }
      return(m_zone.available);
     }

   bool Read(SAxOrderBlockReading &out) const
     {
      out=m_zone;
      return(m_zone.available);
     }

   double BullishScoreComponent(void) const
     {
      if(!m_zone.available || !m_zone.priceInside || m_zone.direction!=AX_DIR_BUY)
         return(0.0);
      return(m_zone.state==AX_OB_BREAKER ? 45.0 : (m_zone.retested ? 85.0 : 70.0));
     }

   double BearishScoreComponent(void) const
     {
      if(!m_zone.available || !m_zone.priceInside || m_zone.direction!=AX_DIR_SELL)
         return(0.0);
      return(m_zone.state==AX_OB_BREAKER ? 45.0 : (m_zone.retested ? 85.0 : 70.0));
     }

   string Summary(void) const
     {
      if(!m_zone.available) return("ORDER_BLOCK "+m_zone.reason);
      return(StringFormat("ORDER_BLOCK dir=%s state=%s zone=%.5f-%.5f age=%d retested=%s inside=%s origin=%s",
         m_zone.direction==AX_DIR_BUY?"BUY":"SELL",
         m_zone.state==AX_OB_BREAKER?"BREAKER":
         (m_zone.state==AX_OB_MITIGATED?"MITIGATED":"ACTIVE"),
         m_zone.lower,m_zone.upper,m_zone.ageBars,
         m_zone.retested?"Y":"N",m_zone.priceInside?"Y":"N",
         TimeToString(m_zone.originTime,TIME_DATE|TIME_MINUTES)));
     }
  };
#endif // AX_ORDERBLOCKENGINE_MQH
