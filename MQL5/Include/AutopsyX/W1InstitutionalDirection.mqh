//+------------------------------------------------------------------+
//|                                      W1InstitutionalDirection.mqh |
//| AUTOPSY X / FlipDemon Extreme                                    |
//| Weekly institutional direction authority.                        |
//| Closed W1 candles confirm structure; current W1 candle is context |
//| only and is never used to confirm BOS, CHOCH, MSS or displacement. |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_W1_INSTITUTIONAL_DIRECTION_MQH
#define AX_W1_INSTITUTIONAL_DIRECTION_MQH

#include "Defs.mqh"
#include "StructureEngine.mqh"

enum ENUM_AX_W1_BIAS
  {
   AX_W1_DATA_UNAVAILABLE = 0,
   AX_W1_NEUTRAL,
   AX_W1_BULLISH,
   AX_W1_BEARISH,
   AX_W1_REVERSAL_PENDING
  };

struct SAxW1Snapshot
  {
   ENUM_AX_W1_BIAS bias;
   ENUM_AX_STRUCT_TREND structureTrend;
   ENUM_AX_STRUCTURE_EVENT structureEvent;
   datetime lastClosedWeekTime;
   double previousWeekHigh;
   double previousWeekLow;
   double previousWeekClose;
   double currentWeekOpen;
   double currentPrice;
   double lastSwingHigh;
   double lastSwingLow;
   double equalHighLevel;
   double equalLowLevel;
   double bullishObLow;
   double bullishObHigh;
   double bearishObLow;
   double bearishObHigh;
   double bullishFvgLow;
   double bullishFvgHigh;
   double bearishFvgLow;
   double bearishFvgHigh;
   bool buySideSweep;
   bool sellSideSweep;
   bool bullishDisplacement;
   bool bearishDisplacement;
   bool bullishBos;
   bool bearishBos;
   bool bullishChoch;
   bool bearishChoch;
   bool bullishMss;
   bool bearishMss;
   bool weeklyOpenAcceptedAbove;
   bool weeklyOpenAcceptedBelow;
   bool previousCloseAcceptedAbove;
   bool previousCloseAcceptedBelow;
   int bullishEvidence;
   int bearishEvidence;
   string reason;
  };

class CW1InstitutionalDirection
  {
private:
   string             m_symbol;
   int                m_lookback;
   int                m_equalLevelTolerancePoints;
   CStructureEngine   m_structure;
   datetime           m_lastProcessedClosedWeek;
   SAxW1Snapshot      m_state;
   bool               m_initialized;

   void ResetSnapshot(void)
     {
      ZeroMemory(m_state);
      m_state.bias=AX_W1_DATA_UNAVAILABLE;
      m_state.structureTrend=AX_STRUCT_TREND_UNDEFINED;
      m_state.structureEvent=AX_STRUCT_NONE;
      m_state.reason="W1_NOT_INITIALIZED";
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

   void ReadSwingLevels(const MqlRates &rates[],const int count)
     {
      const int wing=2;
      double highs[2]; double lows[2];
      datetime highTimes[2]; datetime lowTimes[2];
      int highCount=0,lowCount=0;
      for(int i=wing;i<count-wing;i++)
        {
         if(IsSwingHigh(rates,i,wing,count))
           {
            if(highCount<2)
              {
               highs[highCount]=rates[i].high;
               highTimes[highCount]=rates[i].time;
               highCount++;
              }
            else
              {
               highs[0]=highs[1]; highTimes[0]=highTimes[1];
               highs[1]=rates[i].high; highTimes[1]=rates[i].time;
              }
           }
         if(IsSwingLow(rates,i,wing,count))
           {
            if(lowCount<2)
              {
               lows[lowCount]=rates[i].low;
               lowTimes[lowCount]=rates[i].time;
               lowCount++;
              }
            else
              {
               lows[0]=lows[1]; lowTimes[0]=lowTimes[1];
               lows[1]=rates[i].low; lowTimes[1]=rates[i].time;
              }
           }
        }
      if(highCount>0) m_state.lastSwingHigh=highs[highCount-1];
      if(lowCount>0) m_state.lastSwingLow=lows[lowCount-1];

      if(highCount>=2 && lowCount>=2)
        {
         double tolerance=MathMax(_Point*m_equalLevelTolerancePoints,SymbolInfoDouble(m_symbol,SYMBOL_POINT)*m_equalLevelTolerancePoints);
         if(MathAbs(highs[1]-highs[0])<=tolerance)
            m_state.equalHighLevel=(highs[1]+highs[0])*0.5;
         if(MathAbs(lows[1]-lows[0])<=tolerance)
            m_state.equalLowLevel=(lows[1]+lows[0])*0.5;
        }
     }

   void ReadGapsAndOrderBlocks(const MqlRates &rates[],const int count)
     {
      // Series arrays: rates[0] is the latest completed week.
      // FVGs are three-candle displacement gaps, retained only while not fully mitigated.
      for(int i=0;i<MathMin(count-2,12);i++)
        {
         if(m_state.bullishFvgLow==0.0 && rates[i].low>rates[i+2].high)
           {
            double lo=rates[i+2].high, hi=rates[i].low;
            bool mitigated=false;
            for(int j=0;j<i;j++) if(rates[j].low<=lo) mitigated=true;
            if(!mitigated) { m_state.bullishFvgLow=lo; m_state.bullishFvgHigh=hi; }
           }
         if(m_state.bearishFvgLow==0.0 && rates[i].high<rates[i+2].low)
           {
            double lo=rates[i].high, hi=rates[i+2].low;
            bool mitigated=false;
            for(int j=0;j<i;j++) if(rates[j].high>=hi) mitigated=true;
            if(!mitigated) { m_state.bearishFvgLow=lo; m_state.bearishFvgHigh=hi; }
           }
        }

      // Operational OB definition: the nearest opposing candle in the 8 completed
      // weeks preceding a confirmed directional displacement. This is a zone candidate,
      // not proof of institutional order placement.
      for(int i=1;i<MathMin(count,10);i++)
        {
         if(m_state.bullishObLow==0.0 && rates[i].close<rates[i].open)
           {
            m_state.bullishObLow=rates[i].low;
            m_state.bullishObHigh=rates[i].high;
           }
         if(m_state.bearishObLow==0.0 && rates[i].close>rates[i].open)
           {
            m_state.bearishObLow=rates[i].low;
            m_state.bearishObHigh=rates[i].high;
           }
        }
     }

   void EvaluateClosedWeek(const MqlRates &rates[],const int count)
     {
      // PWH/PWL and previous close refer to the most recently completed week.
      m_state.lastClosedWeekTime=rates[0].time;
      m_state.previousWeekHigh=rates[0].high;
      m_state.previousWeekLow=rates[0].low;
      m_state.previousWeekClose=rates[0].close;

      // A completed-week sweep is measured against the immediately preceding
      // completed week's external high/low, never against the forming candle.
      if(count>1)
        {
         m_state.buySideSweep=(rates[0].high>rates[1].high && rates[0].close<rates[1].high);
         m_state.sellSideSweep=(rates[0].low<rates[1].low && rates[0].close>rates[1].low);
         m_state.previousCloseAcceptedAbove=(rates[0].close>rates[1].close);
         m_state.previousCloseAcceptedBelow=(rates[0].close<rates[1].close);
        }

      double range=rates[0].high-rates[0].low;
      double body=MathAbs(rates[0].close-rates[0].open);
      double bodyRatio=(range>0.0 ? body/range : 0.0);
      m_state.bullishDisplacement=(rates[0].close>rates[0].open && range>0.0 &&
                                    bodyRatio>=0.60 && rates[0].close>=rates[0].low+range*0.80);
      m_state.bearishDisplacement=(rates[0].close<rates[0].open && range>0.0 &&
                                    bodyRatio>=0.60 && rates[0].close<=rates[0].low+range*0.20);

      ReadSwingLevels(rates,count);
      ReadGapsAndOrderBlocks(rates,count);

      m_state.structureTrend=m_structure.Trend();
      m_state.structureEvent=m_structure.LastEvent();
      m_state.bullishBos=(m_state.structureEvent==AX_STRUCT_BOS_BULLISH);
      m_state.bearishBos=(m_state.structureEvent==AX_STRUCT_BOS_BEARISH);
      m_state.bullishChoch=(m_state.structureEvent==AX_STRUCT_CHOCH_BULLISH);
      m_state.bearishChoch=(m_state.structureEvent==AX_STRUCT_CHOCH_BEARISH);
      m_state.bullishMss=(m_state.structureEvent==AX_STRUCT_MSS_BULLISH);
      m_state.bearishMss=(m_state.structureEvent==AX_STRUCT_MSS_BEARISH);

      // A sweep alone never changes direction. An opposing CHOCH or sweep plus
      // displacement places the engine in REVERSAL_PENDING until MSS and structure agree.
      bool bullishStructure=(m_state.structureTrend==AX_STRUCT_TREND_BULLISH);
      bool bearishStructure=(m_state.structureTrend==AX_STRUCT_TREND_BEARISH);
      bool bullishReversal=m_state.bullishChoch || m_state.bullishMss ||
                           (m_state.sellSideSweep && m_state.bullishDisplacement);
      bool bearishReversal=m_state.bearishChoch || m_state.bearishMss ||
                           (m_state.buySideSweep && m_state.bearishDisplacement);

      m_state.bullishEvidence=0;
      m_state.bearishEvidence=0;
      if(bullishStructure) m_state.bullishEvidence+=2;
      if(bearishStructure) m_state.bearishEvidence+=2;
      if(m_state.bullishBos) m_state.bullishEvidence+=2;
      if(m_state.bearishBos) m_state.bearishEvidence+=2;
      if(m_state.bullishMss) m_state.bullishEvidence+=3;
      if(m_state.bearishMss) m_state.bearishEvidence+=3;
      if(m_state.bullishDisplacement) m_state.bullishEvidence++;
      if(m_state.bearishDisplacement) m_state.bearishEvidence++;
      if(m_state.sellSideSweep) m_state.bullishEvidence++;
      if(m_state.buySideSweep) m_state.bearishEvidence++;
      if(m_state.previousCloseAcceptedAbove) m_state.bullishEvidence++;
      if(m_state.previousCloseAcceptedBelow) m_state.bearishEvidence++;

      if(bullishReversal && !m_state.bullishMss && !bullishStructure)
         m_state.bias=AX_W1_REVERSAL_PENDING;
      else if(bearishReversal && !m_state.bearishMss && !bearishStructure)
         m_state.bias=AX_W1_REVERSAL_PENDING;
      else if(bullishStructure && m_state.bullishEvidence>=3 &&
              m_state.bullishEvidence>=m_state.bearishEvidence+2)
         m_state.bias=AX_W1_BULLISH;
      else if(bearishStructure && m_state.bearishEvidence>=3 &&
              m_state.bearishEvidence>=m_state.bullishEvidence+2)
         m_state.bias=AX_W1_BEARISH;
      else
         m_state.bias=AX_W1_NEUTRAL;

      m_state.reason=StringFormat("W1 bias=%d structure=%d event=%d bullEvidence=%d bearEvidence=%d sweep(BS/SS)=%s/%s",
                                  (int)m_state.bias,(int)m_state.structureTrend,(int)m_state.structureEvent,
                                  m_state.bullishEvidence,m_state.bearishEvidence,
                                  m_state.buySideSweep ? "Y" : "N",m_state.sellSideSweep ? "Y" : "N");
     }

public:
                     CW1InstitutionalDirection(void)
     {
      m_symbol="";
      m_lookback=260;
      m_equalLevelTolerancePoints=30;
      m_lastProcessedClosedWeek=0;
      m_initialized=false;
      ResetSnapshot();
     }

   bool Init(const string symbol,const int lookback=260,const int equalLevelTolerancePoints=30)
     {
      m_symbol=symbol;
      m_lookback=MathMax(80,lookback);
      m_equalLevelTolerancePoints=MathMax(1,equalLevelTolerancePoints);
      m_initialized=m_structure.Init(symbol,PERIOD_W1,m_lookback);
      if(!m_initialized) { ResetSnapshot(); return(false); }
      return(Update(true));
     }

   bool Update(const bool force=false)
     {
      if(!m_initialized) { ResetSnapshot(); return(false); }
      datetime closedWeek=iTime(m_symbol,PERIOD_W1,1);
      if(closedWeek<=0) { ResetSnapshot(); m_state.reason="W1_CLOSED_BAR_TIME_UNAVAILABLE"; return(false); }
      if(!force && closedWeek==m_lastProcessedClosedWeek) return(m_state.bias!=AX_W1_DATA_UNAVAILABLE);

      MqlRates rates[];
      ArraySetAsSeries(rates,true);
      int copied=CopyRates(m_symbol,PERIOD_W1,1,m_lookback,rates);
      if(copied<30)
        {
         ResetSnapshot();
         m_state.reason=StringFormat("W1_HISTORY_INSUFFICIENT copied=%d required=30",copied);
         return(false);
        }

      // StructureEngine also reads shift=1, so both engines evaluate the same
      // completed weekly candle and cannot disagree because of a forming bar.
      m_structure.Update();
      ResetSnapshot();
      m_state.bias=AX_W1_NEUTRAL;
      m_state.currentWeekOpen=iOpen(m_symbol,PERIOD_W1,0);
      MqlTick tick;
      if(SymbolInfoTick(m_symbol,tick))
         m_state.currentPrice=(tick.bid+tick.ask)*0.5;
      m_state.weeklyOpenAcceptedAbove=(m_state.currentWeekOpen>0.0 &&
                                        m_state.currentPrice>m_state.currentWeekOpen);
      m_state.weeklyOpenAcceptedBelow=(m_state.currentWeekOpen>0.0 &&
                                        m_state.currentPrice<m_state.currentWeekOpen);

      EvaluateClosedWeek(rates,copied);
      m_lastProcessedClosedWeek=closedWeek;
      return(m_state.bias!=AX_W1_DATA_UNAVAILABLE);
     }

   ENUM_AX_W1_BIAS Bias(void) const { return(m_state.bias); }
   const SAxW1Snapshot &Snapshot(void) const { return(m_state); }
   bool AllowsDirection(const ENUM_AX_DIR direction) const
     {
      if(m_state.bias==AX_W1_BULLISH) return(direction==AX_DIR_BUY);
      if(m_state.bias==AX_W1_BEARISH) return(direction==AX_DIR_SELL);
      return(false); // neutral, pending and unavailable are all fail-closed
     }
   string Summary(void) const { return(m_state.reason); }
  };

#endif // AX_W1_INSTITUTIONAL_DIRECTION_MQH
