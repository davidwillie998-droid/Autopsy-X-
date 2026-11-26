//+------------------------------------------------------------------+
//| PurePriceAction.mqh                                               |
//| OHLC-only candle behaviour and impulse/pullback diagnostics.      |
//| Does not duplicate StructureEngine or LiquidityEngine.            |
//| Observational only: no score, entry, sizing, stop or exit authority.|
//+------------------------------------------------------------------+
#property strict
#ifndef AX_PUREPRICEACTION_MQH
#define AX_PUREPRICEACTION_MQH
#include "Defs.mqh"

enum ENUM_AX_PA_CANDLE_STATE
  {
   AX_PA_CANDLE_UNAVAILABLE=0,
   AX_PA_CANDLE_BALANCED,
   AX_PA_CANDLE_BULL_BODY,
   AX_PA_CANDLE_BEAR_BODY,
   AX_PA_CANDLE_LOWER_REJECTION,
   AX_PA_CANDLE_UPPER_REJECTION,
   AX_PA_CANDLE_EXPANSION_BULL,
   AX_PA_CANDLE_EXPANSION_BEAR
  };

struct SAxPurePriceActionSnapshot
  {
   bool available;
   datetime barTime;
   double range;
   double bodyRatio;
   double upperWickRatio;
   double lowerWickRatio;
   double closeLocation;
   double priorImpulseDirection; // +1 bullish, -1 bearish, 0 unresolved
   double priorImpulseEfficiency; // absolute net displacement / summed true ranges
   double pullbackDepth;          // fraction of prior impulse range retraced by latest closed bar
   ENUM_AX_PA_CANDLE_STATE candleState;
   string reason;
  };

class CPurePriceAction
  {
private:
   string m_symbol;
   ENUM_TIMEFRAMES m_timeframe;
   int m_lookback;
   datetime m_lastBar;
   datetime m_lastJournalBar;
   int m_journalFailures;
   bool m_journalEnabled;
   SAxPurePriceActionSnapshot m_snapshot;

   string JournalFileName(void) const
     {
      return("AutopsyX_PurePriceAction_"+m_symbol+"_"+EnumToString(m_timeframe)+".csv");
     }

   bool AppendJournal(void)
     {
      if(!m_journalEnabled || !m_snapshot.available || m_snapshot.barTime<=0 ||
         m_snapshot.barTime==m_lastJournalBar)
         return(false);
      int handle=FileOpen(JournalFileName(),
                          FILE_READ|FILE_WRITE|FILE_CSV|FILE_SHARE_READ|FILE_SHARE_WRITE,
                          ';');
      if(handle==INVALID_HANDLE)
        {
         m_journalFailures++;
         return(false);
        }
      bool header=(FileSize(handle)==0);
      FileSeek(handle,0,SEEK_END);
      if(header)
         FileWrite(handle,"bar_time","symbol","timeframe","candle_range",
                   "body_ratio","upper_wick_ratio","lower_wick_ratio",
                   "close_location","prior_impulse_direction",
                   "prior_impulse_efficiency","pullback_depth",
                   "candle_state","reason");
      FileWrite(handle,TimeToString(m_snapshot.barTime,TIME_DATE|TIME_MINUTES),
                m_symbol,EnumToString(m_timeframe),DoubleToString(m_snapshot.range,(int)SymbolInfoInteger(m_symbol,SYMBOL_DIGITS)),
                DoubleToString(m_snapshot.bodyRatio,6),
                DoubleToString(m_snapshot.upperWickRatio,6),
                DoubleToString(m_snapshot.lowerWickRatio,6),
                DoubleToString(m_snapshot.closeLocation,6),
                DoubleToString(m_snapshot.priorImpulseDirection,0),
                DoubleToString(m_snapshot.priorImpulseEfficiency,6),
                DoubleToString(m_snapshot.pullbackDepth,6),
                IntegerToString((int)m_snapshot.candleState),m_snapshot.reason);
      FileFlush(handle);
      FileClose(handle);
      m_lastJournalBar=m_snapshot.barTime;
      return(true);
     }

   void Reset(const string reason)
     {
      m_snapshot.available=false;
      m_snapshot.barTime=0;
      m_snapshot.range=0.0;
      m_snapshot.bodyRatio=0.0;
      m_snapshot.upperWickRatio=0.0;
      m_snapshot.lowerWickRatio=0.0;
      m_snapshot.closeLocation=0.5;
      m_snapshot.priorImpulseDirection=0.0;
      m_snapshot.priorImpulseEfficiency=0.0;
      m_snapshot.pullbackDepth=0.0;
      m_snapshot.candleState=AX_PA_CANDLE_UNAVAILABLE;
      m_snapshot.reason=reason;
     }

public:
                     CPurePriceAction(void)
     {
      m_timeframe=PERIOD_CURRENT;
      m_lookback=5;
      m_lastBar=0;
      m_lastJournalBar=0;
      m_journalFailures=0;
      m_journalEnabled=true;
      Reset("NOT_INITIALIZED");
     }

   bool Init(const string symbol,const ENUM_TIMEFRAMES timeframe,const int lookback=5,const bool journalEnabled=true)
     {
      m_symbol=symbol;
      m_timeframe=timeframe;
      m_lookback=(int)AxClampD(lookback,3,20);
      m_lastBar=0;
      m_lastJournalBar=0;
      m_journalFailures=0;
      m_journalEnabled=journalEnabled;
      Reset("WAITING_FOR_CLOSED_BARS");
      return(symbol!="" && PeriodSeconds(timeframe)>0);
     }

   bool Update(const bool force=false)
     {
      datetime closedTime=iTime(m_symbol,m_timeframe,1);
      if(closedTime<=0)
        {
         Reset("CLOSED_BAR_TIME_UNAVAILABLE");
         return(false);
        }
      if(!force && closedTime==m_lastBar) return(false);

      MqlRates rates[];
      ArraySetAsSeries(rates,true);
      int needed=m_lookback+1;
      int copied=CopyRates(m_symbol,m_timeframe,1,needed,rates);
      if(copied<needed)
        {
         Reset("INSUFFICIENT_CLOSED_OHLC_HISTORY");
         return(false);
        }

      MqlRates latest=rates[0];
      double candleRange=latest.high-latest.low;
      if(!MathIsValidNumber(candleRange) || candleRange<=0.0 ||
         latest.open<=0.0 || latest.close<=0.0 ||
         latest.high<MathMax(latest.open,latest.close) ||
         latest.low>MathMin(latest.open,latest.close))
        {
         Reset("INVALID_CLOSED_OHLC");
         return(false);
        }

      double body=MathAbs(latest.close-latest.open);
      double upper=latest.high-MathMax(latest.open,latest.close);
      double lower=MathMin(latest.open,latest.close)-latest.low;
      double bodyRatio=body/candleRange;
      double upperRatio=upper/candleRange;
      double lowerRatio=lower/candleRange;
      double closeLocation=(latest.close-latest.low)/candleRange;

      // The latest closed candle is excluded from the preceding impulse.
      // This prevents the candle being classified from defining its own context.
      double impulseOpen=rates[m_lookback-1].open;
      double impulseClose=rates[1].close;
      double impulseHigh=-DBL_MAX;
      double impulseLow=DBL_MAX;
      double summedRanges=0.0;
      for(int i=1;i<m_lookback;i++)
        {
         impulseHigh=MathMax(impulseHigh,rates[i].high);
         impulseLow=MathMin(impulseLow,rates[i].low);
         double r=rates[i].high-rates[i].low;
         if(!MathIsValidNumber(r) || r<0.0)
           {
            Reset("INVALID_PRIOR_IMPULSE_OHLC");
            return(false);
           }
         summedRanges+=r;
        }

      double impulseRange=impulseHigh-impulseLow;
      double impulseNet=impulseClose-impulseOpen;
      double impulseEfficiency=(summedRanges>0.0 ? MathAbs(impulseNet)/summedRanges : 0.0);
      double impulseDirection=0.0;
      if(impulseRange>0.0 && MathAbs(impulseNet)/impulseRange>=0.35)
         impulseDirection=(impulseNet>0.0 ? 1.0 : -1.0);

      double pullbackDepth=0.0;
      if(impulseDirection>0.0 && impulseRange>0.0)
         pullbackDepth=AxClampD((impulseHigh-latest.close)/impulseRange,0.0,2.0);
      else if(impulseDirection<0.0 && impulseRange>0.0)
         pullbackDepth=AxClampD((latest.close-impulseLow)/impulseRange,0.0,2.0);

      ENUM_AX_PA_CANDLE_STATE state=AX_PA_CANDLE_BALANCED;
      if(bodyRatio>=0.70 && closeLocation>=0.80)
         state=AX_PA_CANDLE_EXPANSION_BULL;
      else if(bodyRatio>=0.70 && closeLocation<=0.20)
         state=AX_PA_CANDLE_EXPANSION_BEAR;
      else if(bodyRatio>=0.60 && latest.close>latest.open)
         state=AX_PA_CANDLE_BULL_BODY;
      else if(bodyRatio>=0.60 && latest.close<latest.open)
         state=AX_PA_CANDLE_BEAR_BODY;
      else if(lowerRatio>=0.55 && closeLocation>=0.55)
         state=AX_PA_CANDLE_LOWER_REJECTION;
      else if(upperRatio>=0.55 && closeLocation<=0.45)
         state=AX_PA_CANDLE_UPPER_REJECTION;

      m_snapshot.available=true;
      m_snapshot.barTime=closedTime;
      m_snapshot.range=candleRange;
      m_snapshot.bodyRatio=AxClampD(bodyRatio,0.0,1.0);
      m_snapshot.upperWickRatio=AxClampD(upperRatio,0.0,1.0);
      m_snapshot.lowerWickRatio=AxClampD(lowerRatio,0.0,1.0);
      m_snapshot.closeLocation=AxClampD(closeLocation,0.0,1.0);
      m_snapshot.priorImpulseDirection=impulseDirection;
      m_snapshot.priorImpulseEfficiency=AxClampD(impulseEfficiency,0.0,1.0);
      m_snapshot.pullbackDepth=pullbackDepth;
      m_snapshot.candleState=state;
      m_snapshot.reason="CLOSED_OHLC_ONLY";
      m_lastBar=closedTime;
      AppendJournal();
      return(true);
     }

   SAxPurePriceActionSnapshot Read(void) const { return(m_snapshot); }
   int JournalFailureCount(void) const { return(m_journalFailures); }
   string JournalFile(void) const { return(JournalFileName()); }

   string Summary(void) const
     {
      if(!m_snapshot.available) return("PURE_PA=UNAVAILABLE reason="+m_snapshot.reason);
      string state="BALANCED";
      switch(m_snapshot.candleState)
        {
         case AX_PA_CANDLE_BULL_BODY: state="BULL_BODY"; break;
         case AX_PA_CANDLE_BEAR_BODY: state="BEAR_BODY"; break;
         case AX_PA_CANDLE_LOWER_REJECTION: state="LOWER_REJECTION"; break;
         case AX_PA_CANDLE_UPPER_REJECTION: state="UPPER_REJECTION"; break;
         case AX_PA_CANDLE_EXPANSION_BULL: state="BULL_EXPANSION"; break;
         case AX_PA_CANDLE_EXPANSION_BEAR: state="BEAR_EXPANSION"; break;
         default: state="BALANCED"; break;
        }
      return(StringFormat("PURE_PA=%s body=%.3f upperWick=%.3f lowerWick=%.3f CLV=%.3f priorImpulse=%.0f efficiency=%.3f pullback=%.3f journalFailures=%d",
                          state,m_snapshot.bodyRatio,m_snapshot.upperWickRatio,
                          m_snapshot.lowerWickRatio,m_snapshot.closeLocation,
                          m_snapshot.priorImpulseDirection,m_snapshot.priorImpulseEfficiency,
                          m_snapshot.pullbackDepth,m_journalFailures));
     }
  };
#endif
