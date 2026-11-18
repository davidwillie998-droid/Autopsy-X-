//+------------------------------------------------------------------+
//| D1InstitutionalLevels.mqh                                        |
//| Closed-bar daily structure, liquidity and dealing-range map       |
//| D1 confirms the non-bypassable W1 institutional direction.        |
//| Forming-day prices are context only, never structural proof.      |
//+------------------------------------------------------------------+
#ifndef AX_D1_INSTITUTIONAL_LEVELS_MQH
#define AX_D1_INSTITUTIONAL_LEVELS_MQH

#include <AutopsyX/Defs.mqh>
#include <AutopsyX/StructureEngine.mqh>

enum ENUM_AX_D1_BIAS
  {
   AX_D1_DATA_UNAVAILABLE=0,
   AX_D1_NEUTRAL=1,
   AX_D1_BULLISH=2,
   AX_D1_BEARISH=3,
   AX_D1_REVERSAL_PENDING=4
  };

struct SAxD1Snapshot
  {
   ENUM_AX_D1_BIAS bias;
   ENUM_AX_STRUCT_TREND structureTrend;
   ENUM_AX_STRUCTURE_EVENT structureEvent;
   datetime lastClosedDayTime;
   double previousDayHigh;
   double previousDayLow;
   double previousDayClose;
   double currentDayOpen;
   double currentPrice;
   double lastSwingHigh;
   double lastSwingLow;
   double equalHighLevel;
   double equalLowLevel;
   double bullishFvgLow;
   double bullishFvgHigh;
   double bearishFvgLow;
   double bearishFvgHigh;
   double dealingRangeMid;
   bool buySideSweep;
   bool sellSideSweep;
   bool bullishDisplacement;
   bool bearishDisplacement;
   bool acceptedAboveDayOpen;
   bool acceptedBelowDayOpen;
   int bullishEvidence;
   int bearishEvidence;
   string reason;
  };

class CD1InstitutionalLevels
  {
private:
   string             m_symbol;
   int                m_lookback;
   int                m_equalTolerancePoints;
   CStructureEngine   m_structure;
   datetime           m_lastProcessedClosedDay;
   SAxD1Snapshot      m_state;
   bool               m_initialized;

   void ResetSnapshot(void)
     {
      ZeroMemory(m_state);
      m_state.bias=AX_D1_DATA_UNAVAILABLE;
      m_state.structureTrend=AX_STRUCT_TREND_UNDEFINED;
      m_state.structureEvent=AX_STRUCT_NONE;
      m_state.reason="D1_NOT_INITIALIZED";
     }

   bool IsSwingHigh(const MqlRates &rates[],const int i,const int wing,const int count) const
     {
      if(i<wing || i+wing>=count) return(false);
      for(int k=1;k<=wing;k++)
         if(rates[i].high<=rates[i-k].high || rates[i].high<rates[i+k].high) return(false);
      return(true);
     }

   bool IsSwingLow(const MqlRates &rates[],const int i,const int wing,const int count) const
     {
      if(i<wing || i+wing>=count) return(false);
      for(int k=1;k<=wing;k++)
         if(rates[i].low>=rates[i-k].low || rates[i].low>rates[i+k].low) return(false);
      return(true);
     }

   void ReadDailyLevels(const MqlRates &rates[],const int count)
     {
      const int wing=2;
      double highs[2],lows[2];
      int highCount=0,lowCount=0;
      for(int i=count-1-wing;i>=wing;i--)
        {
         if(IsSwingHigh(rates,i,wing,count))
           {
            if(highCount<2) highs[highCount++]=rates[i].high;
            else { highs[0]=highs[1]; highs[1]=rates[i].high; }
           }
         if(IsSwingLow(rates,i,wing,count))
           {
            if(lowCount<2) lows[lowCount++]=rates[i].low;
            else { lows[0]=lows[1]; lows[1]=rates[i].low; }
           }
        }
      if(highCount>0) m_state.lastSwingHigh=highs[highCount-1];
      if(lowCount>0) m_state.lastSwingLow=lows[lowCount-1];
      double point=SymbolInfoDouble(m_symbol,SYMBOL_POINT);
      double tolerance=point*m_equalTolerancePoints;
      if(highCount>=2 && tolerance>0.0 && MathAbs(highs[1]-highs[0])<=tolerance)
         m_state.equalHighLevel=(highs[1]+highs[0])*0.5;
      if(lowCount>=2 && tolerance>0.0 && MathAbs(lows[1]-lows[0])<=tolerance)
         m_state.equalLowLevel=(lows[1]+lows[0])*0.5;

      // Keep the nearest still-unmitigated three-candle imbalance in each direction.
      for(int i=0;i<MathMin(count-2,30);i++)
        {
         if(m_state.bullishFvgLow==0.0 && rates[i].low>rates[i+2].high)
           {
            double lo=rates[i+2].high,hi=rates[i].low;
            bool mitigated=false;
            for(int j=0;j<i;j++) if(rates[j].low<=lo) { mitigated=true; break; }
            if(!mitigated) { m_state.bullishFvgLow=lo; m_state.bullishFvgHigh=hi; }
           }
         if(m_state.bearishFvgLow==0.0 && rates[i].high<rates[i+2].low)
           {
            double lo=rates[i].high,hi=rates[i+2].low;
            bool mitigated=false;
            for(int j=0;j<i;j++) if(rates[j].high>=hi) { mitigated=true; break; }
            if(!mitigated) { m_state.bearishFvgLow=lo; m_state.bearishFvgHigh=hi; }
           }
        }
      if(m_state.lastSwingHigh>0.0 && m_state.lastSwingLow>0.0)
         m_state.dealingRangeMid=(m_state.lastSwingHigh+m_state.lastSwingLow)*0.5;
     }

   void EvaluateClosedDay(const MqlRates &rates[],const int count)
     {
      m_state.lastClosedDayTime=rates[0].time;
      m_state.previousDayHigh=rates[0].high;
      m_state.previousDayLow=rates[0].low;
      m_state.previousDayClose=rates[0].close;

      if(count>1)
        {
         // A high sweep that closes back below the prior high is buy-side liquidity taken.
         m_state.buySideSweep=(rates[0].high>rates[1].high && rates[0].close<rates[1].high);
         // A low sweep that closes back above the prior low is sell-side liquidity taken.
         m_state.sellSideSweep=(rates[0].low<rates[1].low && rates[0].close>rates[1].low);
        }

      double range=rates[0].high-rates[0].low;
      double body=MathAbs(rates[0].close-rates[0].open);
      double bodyRatio=(range>0.0 ? body/range : 0.0);
      m_state.bullishDisplacement=(rates[0].close>rates[0].open && range>0.0 &&
                                    bodyRatio>=0.60 && rates[0].close>=rates[0].low+range*0.80);
      m_state.bearishDisplacement=(rates[0].close<rates[0].open && range>0.0 &&
                                    bodyRatio>=0.60 && rates[0].close<=rates[0].low+range*0.20);

      ReadDailyLevels(rates,count);
      m_state.structureTrend=m_structure.Trend();
      m_state.structureEvent=m_structure.LastEvent();

      bool eventIsCurrent=(m_structure.LastEventTime()==rates[0].time);
      bool bullishChoch=(eventIsCurrent && m_state.structureEvent==AX_STRUCT_CHOCH_BULLISH);
      bool bearishChoch=(eventIsCurrent && m_state.structureEvent==AX_STRUCT_CHOCH_BEARISH);
      bool bullishMss=(eventIsCurrent && m_state.structureEvent==AX_STRUCT_MSS_BULLISH);
      bool bearishMss=(eventIsCurrent && m_state.structureEvent==AX_STRUCT_MSS_BEARISH);
      bool bullishBos=(eventIsCurrent && m_state.structureEvent==AX_STRUCT_BOS_BULLISH);
      bool bearishBos=(eventIsCurrent && m_state.structureEvent==AX_STRUCT_BOS_BEARISH);

      m_state.bullishEvidence=0;
      m_state.bearishEvidence=0;
      if(m_state.structureTrend==AX_STRUCT_TREND_BULLISH) m_state.bullishEvidence+=2;
      if(m_state.structureTrend==AX_STRUCT_TREND_BEARISH) m_state.bearishEvidence+=2;
      if(bullishBos || bullishMss) m_state.bullishEvidence+=2;
      if(bearishBos || bearishMss) m_state.bearishEvidence+=2;
      if(m_state.bullishDisplacement) m_state.bullishEvidence++;
      if(m_state.bearishDisplacement) m_state.bearishEvidence++;
      if(m_state.sellSideSweep) m_state.bullishEvidence++;
      if(m_state.buySideSweep) m_state.bearishEvidence++;
      if(m_state.currentDayOpen>0.0 && m_state.currentPrice>m_state.currentDayOpen)
         m_state.bullishEvidence++;
      if(m_state.currentDayOpen>0.0 && m_state.currentPrice<m_state.currentDayOpen)
         m_state.bearishEvidence++;

      m_state.acceptedAboveDayOpen=(m_state.currentDayOpen>0.0 && m_state.currentPrice>m_state.currentDayOpen);
      m_state.acceptedBelowDayOpen=(m_state.currentDayOpen>0.0 && m_state.currentPrice<m_state.currentDayOpen);

      // A sweep by itself never flips D1. An opposing CHoCH must mature into MSS/structure.
      if((bearishChoch || (m_state.buySideSweep && m_state.bearishDisplacement)) &&
         !bearishMss && m_state.structureTrend!=AX_STRUCT_TREND_BEARISH)
         m_state.bias=AX_D1_REVERSAL_PENDING;
      else if((bullishChoch || (m_state.sellSideSweep && m_state.bullishDisplacement)) &&
              !bullishMss && m_state.structureTrend!=AX_STRUCT_TREND_BULLISH)
         m_state.bias=AX_D1_REVERSAL_PENDING;
      else if(m_state.structureTrend==AX_STRUCT_TREND_BULLISH &&
              m_state.bullishEvidence>=3 && m_state.bullishEvidence>=m_state.bearishEvidence+1)
         m_state.bias=AX_D1_BULLISH;
      else if(m_state.structureTrend==AX_STRUCT_TREND_BEARISH &&
              m_state.bearishEvidence>=3 && m_state.bearishEvidence>=m_state.bullishEvidence+1)
         m_state.bias=AX_D1_BEARISH;
      else
         m_state.bias=AX_D1_NEUTRAL;

      m_state.reason=StringFormat("D1 bias=%d structure=%d event=%d bull=%d bear=%d PDH=%.5f PDL=%.5f EQH=%.5f EQL=%.5f",
                                  (int)m_state.bias,(int)m_state.structureTrend,(int)m_state.structureEvent,
                                  m_state.bullishEvidence,m_state.bearishEvidence,
                                  m_state.previousDayHigh,m_state.previousDayLow,
                                  m_state.equalHighLevel,m_state.equalLowLevel);
     }

public:
                     CD1InstitutionalLevels(void)
     {
      m_symbol="";
      m_lookback=180;
      m_equalTolerancePoints=30;
      m_lastProcessedClosedDay=0;
      m_initialized=false;
      ResetSnapshot();
     }

   bool Init(const string symbol,const int lookback=180,const int equalTolerancePoints=30)
     {
      m_symbol=symbol;
      m_lookback=MathMax(80,lookback);
      m_equalTolerancePoints=MathMax(1,equalTolerancePoints);
      m_initialized=m_structure.Init(symbol,PERIOD_D1,m_lookback);
      if(!m_initialized) { ResetSnapshot(); return(false); }
      return(Update(true));
     }

   bool Update(const bool force=false)
     {
      if(!m_initialized) { ResetSnapshot(); return(false); }
      datetime closedDay=iTime(m_symbol,PERIOD_D1,1);
      if(closedDay<=0) { ResetSnapshot(); m_state.reason="D1_CLOSED_BAR_TIME_UNAVAILABLE"; return(false); }
      if(!force && closedDay==m_lastProcessedClosedDay)
         return(m_state.bias!=AX_D1_DATA_UNAVAILABLE);

      MqlRates rates[];
      ArraySetAsSeries(rates,true);
      int copied=CopyRates(m_symbol,PERIOD_D1,1,m_lookback,rates);
      if(copied<30)
        {
         ResetSnapshot();
         m_state.reason=StringFormat("D1_HISTORY_INSUFFICIENT copied=%d required=30",copied);
         return(false);
        }

      m_structure.Update();
      ResetSnapshot();
      m_state.bias=AX_D1_NEUTRAL;
      m_state.currentDayOpen=iOpen(m_symbol,PERIOD_D1,0);
      MqlTick tick;
      if(SymbolInfoTick(m_symbol,tick))
         m_state.currentPrice=(tick.bid+tick.ask)*0.5;
      EvaluateClosedDay(rates,copied);
      m_lastProcessedClosedDay=closedDay;
      return(m_state.bias!=AX_D1_DATA_UNAVAILABLE);
     }

   ENUM_AX_D1_BIAS Bias(void) const { return(m_state.bias); }
   SAxD1Snapshot Snapshot(void) const { return(m_state); }
   bool AllowsDirection(const ENUM_AX_DIR direction) const
     {
      if(m_state.bias==AX_D1_BULLISH) return(direction==AX_DIR_BUY);
      if(m_state.bias==AX_D1_BEARISH) return(direction==AX_DIR_SELL);
      return(false); // neutral, reversal-pending and unavailable all fail closed
     }
   double NearestSwingLevel(const bool wantHigh,const double referencePrice) const
     {
      return(m_structure.NearestSwingLevel(wantHigh,referencePrice));
     }
   string Summary(void) const { return(m_state.reason); }
  };

#endif // AX_D1_INSTITUTIONAL_LEVELS_MQH
