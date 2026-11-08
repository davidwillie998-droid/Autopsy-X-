//+------------------------------------------------------------------+
//|                                                     VPMACD.mqh   |
//| Volume-weighted MACD calculated from completed broker bars.       |
//| Uses tick_volume because most retail FX/CFD feeds have no tape.   |
//| This is a VWMA-MACD, not exchange-traded bid/ask volume delta.     |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_VPMACD_MQH
#define AX_VPMACD_MQH
#include "Defs.mqh"

class CVPMACDEngine
  {
private:
   string          m_symbol;
   ENUM_TIMEFRAMES m_timeframe;
   int             m_fast;
   int             m_slow;
   int             m_signal;
   datetime        m_lastBar;
   bool            m_available;
   string          m_state;
   double          m_macd;
   double          m_signalLine;
   double          m_histogram;

   bool VWMA(const MqlRates &rates[],const int shift,const int period,double &value) const
     {
      value=0.0;
      double weighted=0.0,volume=0.0;
      int total=ArraySize(rates);
      if(period<2 || shift<0 || shift+period>total) return(false);
      for(int i=shift;i<shift+period;i++)
        {
         double v=(double)rates[i].tick_volume;
         if(v<=0.0) continue;
         double typical=(rates[i].high+rates[i].low+rates[i].close)/3.0;
         if(typical<=0.0 || !MathIsValidNumber(typical)) return(false);
         weighted+=typical*v;
         volume+=v;
        }
      if(volume<=0.0 || !MathIsValidNumber(weighted)) return(false);
      value=weighted/volume;
      return(value>0.0 && MathIsValidNumber(value));
     }

public:
                     CVPMACDEngine(void)
     {
      m_symbol=""; m_timeframe=PERIOD_M1;
      m_fast=12; m_slow=26; m_signal=9; m_lastBar=0;
      m_available=false; m_state="DATA_UNAVAILABLE";
      m_macd=0.0; m_signalLine=0.0; m_histogram=0.0;
     }

   bool              Init(const string symbol,const ENUM_TIMEFRAMES timeframe,
                          const int fastPeriod=12,const int slowPeriod=26,const int signalPeriod=9)
     {
      m_symbol=symbol; m_timeframe=timeframe;
      m_fast=MathMax(2,fastPeriod);
      m_slow=MathMax(m_fast+1,slowPeriod);
      m_signal=MathMax(2,signalPeriod);
      m_lastBar=0; m_available=false; m_state="DATA_UNAVAILABLE";
      return(StringLen(m_symbol)>0);
     }

   bool              Update(void)
     {
      datetime bar=iTime(m_symbol,m_timeframe,0);
      if(bar<=0) { m_available=false; m_state="DATA_UNAVAILABLE"; return(false); }
      if(bar==m_lastBar && m_available) return(true);
      m_lastBar=bar;
      m_available=false; m_state="DATA_UNAVAILABLE";
      int needed=m_slow+m_signal+3;
      MqlRates rates[];
      ArraySetAsSeries(rates,true);
      int copied=CopyRates(m_symbol,m_timeframe,0,needed,rates);
      if(copied<needed) return(false);

      // macdSeries[0] is the latest completed bar (shift 1), then older bars.
      double macdSeries[];
      ArrayResize(macdSeries,m_signal+2);
      for(int i=0;i<m_signal+2;i++)
        {
         int shift=1+i;
         double fastValue=0.0,slowValue=0.0;
         if(!VWMA(rates,shift,m_fast,fastValue) ||
            !VWMA(rates,shift,m_slow,slowValue))
            return(false);
         macdSeries[i]=fastValue-slowValue;
         if(!MathIsValidNumber(macdSeries[i])) return(false);
        }

      double alpha=2.0/(m_signal+1.0);
      double ema=macdSeries[m_signal+1];
      for(int i=m_signal;i>=0;i--)
         ema=alpha*macdSeries[i]+(1.0-alpha)*ema;

      m_macd=macdSeries[0];
      m_signalLine=ema;
      m_histogram=m_macd-m_signalLine;
      double priorHistogram=macdSeries[1]-ema;
      if(!MathIsValidNumber(m_macd) || !MathIsValidNumber(m_signalLine) ||
         !MathIsValidNumber(m_histogram)) return(false);

      if(m_histogram>0.0 && m_histogram>priorHistogram && m_macd>macdSeries[1])
         m_state="BULLISH";
      else if(m_histogram<0.0 && m_histogram<priorHistogram && m_macd<macdSeries[1])
         m_state="BEARISH";
      else
         m_state="NEUTRAL";
      m_available=true;
      return(true);
     }

   bool              IsAvailable(void) const { return(m_available); }
   string            State(void) const { return(m_available?m_state:"DATA_UNAVAILABLE"); }
   double            MACD(void) const { return(m_macd); }
   double            SignalLine(void) const { return(m_signalLine); }
   double            Histogram(void) const { return(m_histogram); }
  };
#endif // AX_VPMACD_MQH
