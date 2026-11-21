//+------------------------------------------------------------------+
//| FairValueGapEngine.mqh                                           |
//| Closed-bar FVG lifecycle and retracement evidence.               |
//| This module is advisory only. It cannot authorize an order.       |
//+------------------------------------------------------------------+
#ifndef AX_FAIRVALUEGAPENGINE_MQH
#define AX_FAIRVALUEGAPENGINE_MQH
#property strict
#include "Defs.mqh"

struct SAxFvgReading
  {
   bool available;
   bool touched;
   bool priceInside;
   ENUM_AX_DIR direction;
   double lower;
   double upper;
   double consequentEncroachment;
   double gapAtr;
   double displacementBodyRatio;
   datetime formed;
   int ageBars;
   string reason;
  };

class CFairValueGapEngine
  {
private:
   string m_symbol;
   ENUM_TIMEFRAMES m_timeframe;
   int m_lookbackBars;
   int m_maxAgeBars;
   double m_minGapAtr;
   double m_minBodyRatio;
   datetime m_lastClosedBar;
   SAxFvgReading m_bullish;
   SAxFvgReading m_bearish;
   bool m_initialized;

   void ResetReading(SAxFvgReading &s,const ENUM_AX_DIR dir,const string reason) const
     {
      ZeroMemory(s);
      s.available=false;
      s.touched=false;
      s.priceInside=false;
      s.direction=dir;
      s.reason=reason;
     }

   double PriorAverageTrueRange(const MqlRates &rates[],const int count,const int firstIndex) const
     {
      const int period=14;
      if(firstIndex+period>=count) return(0.0);
      double sum=0.0;
      for(int k=0;k<period;k++)
        {
         int index=firstIndex+k;
         double range=rates[index].high-rates[index].low;
         range=MathMax(range,MathAbs(rates[index].high-rates[index+1].close));
         range=MathMax(range,MathAbs(rates[index].low-rates[index+1].close));
         if(range<=0.0 || !MathIsValidNumber(range)) return(0.0);
         sum+=range;
        }
      return(sum/(double)period);
     }

   bool BuildLatest(const MqlRates &rates[],const int count,const ENUM_AX_DIR dir,
                    const double point,const double tickSize,SAxFvgReading &out) const
     {
      ResetReading(out,dir,"NO_QUALIFYING_FVG");
      if(count<20 || point<=0.0) return(false);

      // Series arrays: [0] is the latest CLOSED candle. Scan newest to oldest.
      for(int i=0;i<=count-18;i++)
        {
         const MqlRates newer=rates[i];
         const MqlRates middle=rates[i+1];
         const MqlRates older=rates[i+2];
         double candleRange=middle.high-middle.low;
         if(candleRange<=0.0) continue;
         double bodyRatio=MathAbs(middle.close-middle.open)/candleRange;
         if(bodyRatio<m_minBodyRatio) continue;
         if(dir==AX_DIR_BUY && middle.close<=middle.open) continue;
         if(dir==AX_DIR_SELL && middle.close>=middle.open) continue;

         double lower=0.0,upper=0.0;
         if(dir==AX_DIR_BUY)
           {
            if(newer.low<=older.high) continue;
            lower=older.high;
            upper=newer.low;
           }
         else if(dir==AX_DIR_SELL)
           {
            if(newer.high>=older.low) continue;
            lower=newer.high;
            upper=older.low;
           }
         else continue;

         double gap=upper-lower;
         double atr=PriorAverageTrueRange(rates,count,i+3);
         if(gap<=MathMax(point*2.0,tickSize) || atr<=0.0) continue;
         double gapAtr=gap/atr;
         if(gapAtr<m_minGapAtr) continue;

         bool touched=false;
         bool invalid=false;
         int age=i;
         for(int j=i-1;j>=0;j--)
           {
            if(dir==AX_DIR_BUY)
              {
               if(rates[j].close<lower || rates[j].low<=lower)
                 { invalid=true; break; }
               if(rates[j].low<=upper) touched=true;
              }
            else
              {
               if(rates[j].close>upper || rates[j].high>=upper)
                 { invalid=true; break; }
               if(rates[j].high>=lower) touched=true;
              }
           }
         if(invalid || age>m_maxAgeBars) continue;

         out.available=true;
         out.touched=touched;
         out.priceInside=false;
         out.direction=dir;
         out.lower=lower;
         out.upper=upper;
         out.consequentEncroachment=(lower+upper)*0.5;
         out.gapAtr=gapAtr;
         out.displacementBodyRatio=bodyRatio;
         out.formed=newer.time;
         out.ageBars=age;
         out.reason=touched ? "VALID_RETRACED_FVG" : "VALID_UNMITIGATED_FVG";
         return(true);
        }
      return(false);
     }

public:
                     CFairValueGapEngine(void)
     {
      m_symbol="";
      m_timeframe=PERIOD_M5;
      m_lookbackBars=120;
      m_maxAgeBars=36;
      m_minGapAtr=0.05;
      m_minBodyRatio=0.55;
      m_lastClosedBar=0;
      m_initialized=false;
      ResetReading(m_bullish,AX_DIR_BUY,"NOT_INITIALIZED");
      ResetReading(m_bearish,AX_DIR_SELL,"NOT_INITIALIZED");
     }

   bool Init(const string symbol,const ENUM_TIMEFRAMES timeframe=PERIOD_M5,
             const int lookbackBars=120,const int maxAgeBars=36,
             const double minGapAtr=0.05,const double minBodyRatio=0.55)
     {
      if(StringLen(symbol)==0 || timeframe<=PERIOD_CURRENT ||
         lookbackBars<20 || lookbackBars>2000 || maxAgeBars<1 ||
         maxAgeBars>=lookbackBars || minGapAtr<0.0 || minGapAtr>2.0 ||
         minBodyRatio<0.0 || minBodyRatio>1.0)
        {
         ResetReading(m_bullish,AX_DIR_BUY,"INVALID_CONFIGURATION");
         ResetReading(m_bearish,AX_DIR_SELL,"INVALID_CONFIGURATION");
         return(false);
        }
      m_symbol=symbol;
      m_timeframe=timeframe;
      m_lookbackBars=lookbackBars;
      m_maxAgeBars=maxAgeBars;
      m_minGapAtr=minGapAtr;
      m_minBodyRatio=minBodyRatio;
      m_initialized=true;
      return(Update(0.0,true));
     }

   bool Update(const double currentPrice=0.0,const bool force=false)
     {
      if(!m_initialized) return(false);
      datetime closedBar=iTime(m_symbol,m_timeframe,1);
      if(closedBar<=0)
        {
         ResetReading(m_bullish,AX_DIR_BUY,"CLOSED_BAR_UNAVAILABLE");
         ResetReading(m_bearish,AX_DIR_SELL,"CLOSED_BAR_UNAVAILABLE");
         return(false);
        }

      if(force || closedBar!=m_lastClosedBar)
        {
         m_lastClosedBar=closedBar;
         MqlRates rates[];
         ArraySetAsSeries(rates,true);
         int copied=CopyRates(m_symbol,m_timeframe,1,m_lookbackBars,rates);
         if(copied<20)
           {
            ResetReading(m_bullish,AX_DIR_BUY,"INSUFFICIENT_CLOSED_HISTORY");
            ResetReading(m_bearish,AX_DIR_SELL,"INSUFFICIENT_CLOSED_HISTORY");
            return(false);
           }
         double point=SymbolInfoDouble(m_symbol,SYMBOL_POINT);
         double tickSize=SymbolInfoDouble(m_symbol,SYMBOL_TRADE_TICK_SIZE);
         if(tickSize<=0.0) tickSize=point;
         BuildLatest(rates,copied,AX_DIR_BUY,point,tickSize,m_bullish);
         BuildLatest(rates,copied,AX_DIR_SELL,point,tickSize,m_bearish);
        }

      // Current quote is used only to detect a live retracement into a zone.
      // Formation, age and invalidation are derived exclusively from closed bars.
      if(currentPrice>0.0)
        {
         if(m_bullish.available && currentPrice>=m_bullish.lower &&
            currentPrice<=m_bullish.upper)
           {
            m_bullish.priceInside=true;
            m_bullish.touched=true;
            m_bullish.reason="PRICE_INSIDE_BULLISH_FVG";
           }
         else if(m_bullish.available) m_bullish.priceInside=false;

         if(m_bearish.available && currentPrice>=m_bearish.lower &&
            currentPrice<=m_bearish.upper)
           {
            m_bearish.priceInside=true;
            m_bearish.touched=true;
            m_bearish.reason="PRICE_INSIDE_BEARISH_FVG";
           }
         else if(m_bearish.available) m_bearish.priceInside=false;
        }
      return(m_bullish.available || m_bearish.available);
     }

   bool Read(const ENUM_AX_DIR dir,SAxFvgReading &out) const
     {
      if(dir==AX_DIR_BUY) { out=m_bullish; return(m_bullish.available); }
      if(dir==AX_DIR_SELL) { out=m_bearish; return(m_bearish.available); }
      ResetReading(out,AX_DIR_NONE,"INVALID_DIRECTION");
      return(false);
     }

   double BullishScoreComponent(void) const
     {
      if(!m_bullish.available || !m_bullish.touched || !m_bullish.priceInside) return(0.0);
      return(AxClampD(50.0+MathMin(50.0,m_bullish.gapAtr*25.0),0.0,100.0));
     }

   double BearishScoreComponent(void) const
     {
      if(!m_bearish.available || !m_bearish.touched || !m_bearish.priceInside) return(0.0);
      return(AxClampD(50.0+MathMin(50.0,m_bearish.gapAtr*25.0),0.0,100.0));
     }

   string Summary(void) const
     {
      string b=m_bullish.available ?
         StringFormat("BULL[%.5f-%.5f CE=%.5f age=%d touched=%s inside=%s]",
            m_bullish.lower,m_bullish.upper,m_bullish.consequentEncroachment,
            m_bullish.ageBars,m_bullish.touched?"Y":"N",m_bullish.priceInside?"Y":"N") :
         "BULL[N/A]";
      string s=m_bearish.available ?
         StringFormat("BEAR[%.5f-%.5f CE=%.5f age=%d touched=%s inside=%s]",
            m_bearish.lower,m_bearish.upper,m_bearish.consequentEncroachment,
            m_bearish.ageBars,m_bearish.touched?"Y":"N",m_bearish.priceInside?"Y":"N") :
         "BEAR[N/A]";
      return("FVG "+EnumToString(m_timeframe)+" "+b+" "+s);
     }
  };
#endif // AX_FAIRVALUEGAPENGINE_MQH
