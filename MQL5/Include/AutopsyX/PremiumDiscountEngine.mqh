//+------------------------------------------------------------------+
//| PremiumDiscountEngine.mqh                                        |
//| Closed-bar multi-timeframe dealing-range location intelligence.  |
//| Location is advisory evidence, never an entry trigger by itself.  |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_PREMIUM_DISCOUNT_ENGINE_MQH
#define AX_PREMIUM_DISCOUNT_ENGINE_MQH

#include "Defs.mqh"

enum ENUM_AX_PD_ZONE
  {
   AX_PD_UNAVAILABLE=0,
   AX_PD_DISCOUNT,
   AX_PD_EQUILIBRIUM,
   AX_PD_PREMIUM
  };

struct SAxPremiumDiscountSnapshot
  {
   ENUM_TIMEFRAMES timeframe;
   ENUM_AX_PD_ZONE zone;
   bool available;
   bool bullishOte;
   bool bearishOte;
   double rangeHigh;
   double rangeLow;
   double equilibrium;
   double currentPrice;
   double positionPercent;
   datetime swingHighTime;
   datetime swingLowTime;
   datetime lastClosedBarTime;
   string reason;
  };

class CPremiumDiscountEngine
  {
private:
   string m_symbol;
   int m_lookback;
   int m_wing;
   ENUM_TIMEFRAMES m_timeframes[5];
   datetime m_lastClosedBar[5];
   SAxPremiumDiscountSnapshot m_state[5];
   bool m_initialized;

   int Slot(const ENUM_TIMEFRAMES timeframe) const
     {
      for(int i=0;i<5;i++)
         if(m_timeframes[i]==timeframe) return(i);
      return(-1);
     }

   void ResetSlot(const int slot,const string reason)
     {
      ZeroMemory(m_state[slot]);
      m_state[slot].timeframe=m_timeframes[slot];
      m_state[slot].zone=AX_PD_UNAVAILABLE;
      m_state[slot].available=false;
      m_state[slot].reason=reason;
     }

   bool IsSwingHigh(const MqlRates &rates[],const int i,const int count) const
     {
      if(i<m_wing || i+m_wing>=count) return(false);
      for(int k=1;k<=m_wing;k++)
         if(rates[i].high<=rates[i-k].high || rates[i].high<rates[i+k].high)
            return(false);
      return(true);
     }

   bool IsSwingLow(const MqlRates &rates[],const int i,const int count) const
     {
      if(i<m_wing || i+m_wing>=count) return(false);
      for(int k=1;k<=m_wing;k++)
         if(rates[i].low>=rates[i-k].low || rates[i].low>rates[i+k].low)
            return(false);
      return(true);
     }

   bool BuildRange(const int slot,const double price)
     {
      ENUM_TIMEFRAMES tf=m_timeframes[slot];
      datetime closedTime=iTime(m_symbol,tf,1);
      if(closedTime<=0)
        {
         ResetSlot(slot,"CLOSED_BAR_TIME_UNAVAILABLE");
         return(false);
        }

      MqlRates rates[];
      ArraySetAsSeries(rates,true);
      int copied=CopyRates(m_symbol,tf,1,m_lookback,rates);
      if(copied<m_wing*2+10)
        {
         ResetSlot(slot,StringFormat("INSUFFICIENT_HISTORY_%d",copied));
         return(false);
        }

      double swingHigh=0.0,swingLow=0.0;
      datetime swingHighTime=0,swingLowTime=0;
      // Series index 0 is the newest completed candle. The first confirmed
      // pivot found in each direction is therefore the most recent one.
      for(int i=m_wing;i<copied-m_wing;i++)
        {
         if(swingHighTime==0 && IsSwingHigh(rates,i,copied))
           {
            swingHigh=rates[i].high;
            swingHighTime=rates[i].time;
           }
         if(swingLowTime==0 && IsSwingLow(rates,i,copied))
           {
            swingLow=rates[i].low;
            swingLowTime=rates[i].time;
           }
         if(swingHighTime>0 && swingLowTime>0) break;
        }

      if(swingHighTime<=0 || swingLowTime<=0 || swingHigh<=swingLow ||
         price<=0.0 || !MathIsValidNumber(price))
        {
         ResetSlot(slot,"CONFIRMED_SWING_RANGE_UNAVAILABLE");
         return(false);
        }

      double range=swingHigh-swingLow;
      if(range<=SymbolInfoDouble(m_symbol,SYMBOL_TRADE_TICK_SIZE)*2.0)
        {
         ResetSlot(slot,"RANGE_TOO_NARROW");
         return(false);
        }

      double position=(price-swingLow)/range;
      SAxPremiumDiscountSnapshot s;
      ZeroMemory(s);
      s.timeframe=tf;
      s.available=true;
      s.rangeHigh=swingHigh;
      s.rangeLow=swingLow;
      s.equilibrium=(swingHigh+swingLow)*0.5;
      s.currentPrice=price;
      s.positionPercent=position*100.0;
      s.swingHighTime=swingHighTime;
      s.swingLowTime=swingLowTime;
      s.lastClosedBarTime=closedTime;

      if(position<0.50) s.zone=AX_PD_DISCOUNT;
      else if(position>0.50) s.zone=AX_PD_PREMIUM;
      else s.zone=AX_PD_EQUILIBRIUM;

      // Standard OTE retracement bands measured from the impulse extremes.
      // Bullish retracement sits in the lower 21.4%-38.2% of the range;
      // bearish retracement sits in the upper 61.8%-78.6% of the range.
      s.bullishOte=(position>=0.214 && position<=0.382);
      s.bearishOte=(position>=0.618 && position<=0.786);
      s.reason="CONFIRMED_SWING_RANGE";
      m_state[slot]=s;
      m_lastClosedBar[slot]=closedTime;
      return(true);
     }

public:
                     CPremiumDiscountEngine(void)
     {
      m_symbol="";
      m_lookback=180;
      m_wing=2;
      m_initialized=false;
      m_timeframes[0]=PERIOD_W1;
      m_timeframes[1]=PERIOD_D1;
      m_timeframes[2]=PERIOD_H4;
      m_timeframes[3]=PERIOD_H1;
      m_timeframes[4]=PERIOD_M15;
      for(int i=0;i<5;i++)
        {
         m_lastClosedBar[i]=0;
         ResetSlot(i,"NOT_INITIALIZED");
        }
     }

   bool Init(const string symbol,const int lookback=180,const int wing=2)
     {
      m_symbol=symbol;
      m_lookback=MathMax(60,lookback);
      m_wing=MathMax(2,wing);
      m_initialized=(StringLen(m_symbol)>0);
      if(!m_initialized) return(false);
      return(Update(true));
     }

   bool Update(const bool force=false)
     {
      if(!m_initialized) return(false);
      MqlTick tick;
      if(!SymbolInfoTick(m_symbol,tick) || tick.bid<=0.0 ||
         tick.ask<tick.bid || tick.ask<=0.0)
        {
         for(int i=0;i<5;i++) ResetSlot(i,"VALID_QUOTE_UNAVAILABLE");
         return(false);
        }
      double price=(tick.bid+tick.ask)*0.5;
      bool anyReady=false;
      for(int i=0;i<5;i++)
        {
         datetime closedTime=iTime(m_symbol,m_timeframes[i],1);
         if(closedTime<=0)
           {
            ResetSlot(i,"CLOSED_BAR_TIME_UNAVAILABLE");
            continue;
           }
         if(!force && closedTime==m_lastClosedBar[i])
           {
            // Range anchors stay frozen between completed bars, while the
            // live location is refreshed from the current valid quote.
            if(m_state[i].available)
              {
               double range=m_state[i].rangeHigh-m_state[i].rangeLow;
               m_state[i].currentPrice=price;
               m_state[i].positionPercent=(price-m_state[i].rangeLow)/range*100.0;
               double position=m_state[i].positionPercent/100.0;
               m_state[i].zone=(position<0.50 ? AX_PD_DISCOUNT :
                               (position>0.50 ? AX_PD_PREMIUM : AX_PD_EQUILIBRIUM));
               m_state[i].bullishOte=(position>=0.214 && position<=0.382);
               m_state[i].bearishOte=(position>=0.618 && position<=0.786);
               anyReady=true;
              }
            continue;
           }
         if(BuildRange(i,price)) anyReady=true;
        }
      return(anyReady);
     }

   bool Read(const ENUM_TIMEFRAMES timeframe,SAxPremiumDiscountSnapshot &out) const
     {
      int slot=Slot(timeframe);
      if(slot<0) return(false);
      out=m_state[slot];
      return(out.available);
     }

   double BullishScoreComponent(void) const
     {
      int h4=Slot(PERIOD_H4),h1=Slot(PERIOD_H1);
      if(h4<0 || !m_state[h4].available ||
         m_state[h4].zone!=AX_PD_DISCOUNT) return(0.0);
      double score=m_state[h4].bullishOte ? 90.0 : 70.0;
      if(h1>=0 && m_state[h1].available &&
         m_state[h1].zone==AX_PD_DISCOUNT) score+=10.0;
      return(MathMin(100.0,score));
     }

   double BearishScoreComponent(void) const
     {
      int h4=Slot(PERIOD_H4),h1=Slot(PERIOD_H1);
      if(h4<0 || !m_state[h4].available ||
         m_state[h4].zone!=AX_PD_PREMIUM) return(0.0);
      double score=m_state[h4].bearishOte ? 90.0 : 70.0;
      if(h1>=0 && m_state[h1].available &&
         m_state[h1].zone==AX_PD_PREMIUM) score+=10.0;
      return(MathMin(100.0,score));
     }

   string Summary(void) const
     {
      string result="PD";
      for(int i=0;i<5;i++)
        {
         string zone="N/A";
         if(m_state[i].available)
            zone=(m_state[i].zone==AX_PD_DISCOUNT ? "DISCOUNT" :
                  (m_state[i].zone==AX_PD_PREMIUM ? "PREMIUM" : "EQ"));
         result+=StringFormat(" %s=%s(%.1f%%)",EnumToString(m_timeframes[i]),
                              zone,m_state[i].positionPercent);
        }
      return(result);
     }
  };
//+------------------------------------------------------------------+
#endif // AX_PREMIUM_DISCOUNT_ENGINE_MQH
