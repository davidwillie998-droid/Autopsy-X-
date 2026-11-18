//+------------------------------------------------------------------+
//| H4TrendBreakoutEngine.mqh                                        |
//| Boxxocode-derived trend filter and closed-bar range breakout.     |
//| Signal-only: no order, sizing, or execution authority.             |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_H4_TREND_BREAKOUT_ENGINE_MQH
#define AX_H4_TREND_BREAKOUT_ENGINE_MQH

#include "Defs.mqh"

class CH4TrendBreakoutEngine
  {
private:
   string          m_symbol;
   ENUM_TIMEFRAMES m_timeframe;
   int             m_emaPeriod;
   int             m_rangeLookback;
   int             m_emaHandle;
   int             m_atrHandle;
   datetime        m_lastClosedBar;
   ENUM_AX_DIR     m_bias;
   bool            m_bullishBreakout;
   bool            m_bearishBreakout;
   double          m_emaValue;
   double          m_atrValue;
   double          m_rangeHigh;
   double          m_rangeLow;
   string          m_reason;
   bool            m_ready;

   void ResetReadings(void)
     {
      m_bias=AX_DIR_NONE;
      m_bullishBreakout=false;
      m_bearishBreakout=false;
      m_emaValue=0.0;
      m_atrValue=0.0;
      m_rangeHigh=0.0;
      m_rangeLow=0.0;
      m_reason="H4_DATA_UNAVAILABLE";
     }

public:
                     CH4TrendBreakoutEngine(void)
     {
      m_symbol="";
      m_timeframe=PERIOD_H4;
      m_emaPeriod=400;
      m_rangeLookback=20;
      m_emaHandle=INVALID_HANDLE;
      m_atrHandle=INVALID_HANDLE;
      m_lastClosedBar=0;
      m_ready=false;
      ResetReadings();
     }

                    ~CH4TrendBreakoutEngine(void) { Release(); }

   bool Init(const string symbol,const ENUM_TIMEFRAMES timeframe=PERIOD_H4,
             const int emaPeriod=400,const int rangeLookback=20)
     {
      Release();
      if(StringLen(symbol)==0 || emaPeriod<2 || rangeLookback<2)
         return(false);
      m_symbol=symbol;
      m_timeframe=timeframe;
      m_emaPeriod=emaPeriod;
      m_rangeLookback=rangeLookback;
      ResetLastError();
      m_emaHandle=iMA(m_symbol,m_timeframe,m_emaPeriod,0,MODE_EMA,PRICE_CLOSE);
      if(m_emaHandle==INVALID_HANDLE)
        {
         m_reason=StringFormat("H4_EMA_HANDLE_FAILED error=%d",GetLastError());
         return(false);
        }
      ResetLastError();
      m_atrHandle=iATR(m_symbol,m_timeframe,14);
      if(m_atrHandle==INVALID_HANDLE)
        {
         m_reason=StringFormat("H4_ATR_HANDLE_FAILED error=%d",GetLastError());
         Release();
         return(false);
        }
      m_ready=true;
      return(Update(true));
     }

   void Release(void)
     {
      if(m_emaHandle!=INVALID_HANDLE) IndicatorRelease(m_emaHandle);
      if(m_atrHandle!=INVALID_HANDLE) IndicatorRelease(m_atrHandle);
      m_emaHandle=INVALID_HANDLE;
      m_atrHandle=INVALID_HANDLE;
      m_ready=false;
      m_lastClosedBar=0;
     }

   bool Update(const bool force=false)
     {
      if(!m_ready || m_emaHandle==INVALID_HANDLE || m_atrHandle==INVALID_HANDLE)
        {
         ResetReadings();
         return(false);
        }
      datetime closedBar=iTime(m_symbol,m_timeframe,1);
      if(closedBar<=0)
        {
         ResetReadings();
         m_reason="H4_CLOSED_BAR_TIME_UNAVAILABLE";
         return(false);
        }
      if(!force && closedBar==m_lastClosedBar)
         return(m_bias!=AX_DIR_NONE);

      // Throttle failed as well as successful reads to one attempt per completed H4 bar.
      // Otherwise a missing history block would trigger CopyRates/CopyBuffer on every tick.
      m_lastClosedBar=closedBar;
      ResetReadings();
      MqlRates rates[];
      ArraySetAsSeries(rates,true);
      int copied=CopyRates(m_symbol,m_timeframe,1,m_rangeLookback+1,rates);
      if(copied!=m_rangeLookback+1)
        {
         m_reason=StringFormat("H4_RANGE_HISTORY_INSUFFICIENT copied=%d required=%d",
                               copied,m_rangeLookback+1);
         return(false);
        }

      double ema[];
      double atr[];
      ArraySetAsSeries(ema,true);
      ArraySetAsSeries(atr,true);
      if(CopyBuffer(m_emaHandle,0,1,2,ema)!=2 ||
         CopyBuffer(m_atrHandle,0,1,1,atr)!=1 ||
         !MathIsValidNumber(ema[0]) || !MathIsValidNumber(ema[1]) ||
         !MathIsValidNumber(atr[0]) || ema[0]<=0.0 || ema[1]<=0.0 || atr[0]<=0.0)
        {
         m_reason="H4_INDICATOR_HISTORY_UNAVAILABLE";
         return(false);
        }

      m_emaValue=ema[0];
      m_atrValue=atr[0];
      double priorHigh=-1.0e100;
      double priorLow=1.0e100;
      for(int i=1;i<=m_rangeLookback;i++)
        {
         priorHigh=MathMax(priorHigh,rates[i].high);
         priorLow=MathMin(priorLow,rates[i].low);
        }
      if(priorHigh<=0.0 || priorLow<=0.0 || priorHigh<=priorLow)
        {
         ResetReadings();
         m_reason="H4_REFERENCE_RANGE_INVALID";
         return(false);
        }
      m_rangeHigh=priorHigh;
      m_rangeLow=priorLow;

      const double close=rates[0].close;
      const double candleRange=rates[0].high-rates[0].low;
      const double body=MathAbs(rates[0].close-rates[0].open);
      const double bodyRatio=(candleRange>0.0)?body/candleRange:0.0;
      const bool bullishRegime=(close>ema[0] && ema[0]>ema[1]);
      const bool bearishRegime=(close<ema[0] && ema[0]<ema[1]);
      m_bias=bullishRegime?AX_DIR_BUY:(bearishRegime?AX_DIR_SELL:AX_DIR_NONE);

      // The breakout candle is the latest completed H4 bar. Its reference
      // range excludes that candle, preventing the signal from moving itself.
      // A close beyond the prior range plus a strong body filters wick-only breaks.
      m_bullishBreakout=(bullishRegime && close>priorHigh &&
                         bodyRatio>=0.60 && close>=rates[0].low+candleRange*0.80);
      m_bearishBreakout=(bearishRegime && close<priorLow &&
                         bodyRatio>=0.60 && close<=rates[0].low+candleRange*0.20);

      m_reason=StringFormat("H4 EMA%d bias=%s close=%.5f ema=%.5f priorHigh=%.5f priorLow=%.5f breakout=%s",
                            m_emaPeriod,
                            m_bias==AX_DIR_BUY?"BUY":(m_bias==AX_DIR_SELL?"SELL":"NEUTRAL"),
                            close,m_emaValue,m_rangeHigh,m_rangeLow,
                            m_bullishBreakout?"BUY":(m_bearishBreakout?"SELL":"NONE"));
      return(true);
     }

   ENUM_AX_DIR Bias(void) const { return(m_bias); }
   bool AllowsDirection(const ENUM_AX_DIR direction) const
     {
      return(m_bias!=AX_DIR_NONE && direction==m_bias);
     }
   bool BullishBreakout(void) const { return(m_bullishBreakout); }
   bool BearishBreakout(void) const { return(m_bearishBreakout); }
   double EmaValue(void) const { return(m_emaValue); }
   double AtrValue(void) const { return(m_atrValue); }
   double ReferenceHigh(void) const { return(m_rangeHigh); }
   double ReferenceLow(void) const { return(m_rangeLow); }
   string Summary(void) const { return(m_reason); }
  };

#endif // AX_H4_TREND_BREAKOUT_ENGINE_MQH
