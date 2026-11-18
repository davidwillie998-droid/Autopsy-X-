//+------------------------------------------------------------------+
//|                                      PrecisionEntryEngine.mqh     |
//| Closed-bar M15 displacement confirmation for precision entries. |
//| This is a confirmation gate, not an independent trade signal.   |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_PRECISION_ENTRY_ENGINE_MQH
#define AX_PRECISION_ENTRY_ENGINE_MQH

#include "Defs.mqh"

class CPrecisionEntryEngine
  {
private:
   string          m_symbol;
   ENUM_TIMEFRAMES m_timeframe;
   int             m_fastPeriod;
   int             m_slowPeriod;
   int             m_atrPeriod;
   int             m_fastHandle;
   int             m_slowHandle;
   int             m_atrHandle;
   double          m_minBodyRatio;
   double          m_minRangeAtr;
   double          m_closeLocation;
   bool            m_ready;

public:
                     CPrecisionEntryEngine(void)
     {
      m_symbol="";
      m_timeframe=PERIOD_M15;
      m_fastPeriod=20;
      m_slowPeriod=50;
      m_atrPeriod=14;
      m_fastHandle=INVALID_HANDLE;
      m_slowHandle=INVALID_HANDLE;
      m_atrHandle=INVALID_HANDLE;
      m_minBodyRatio=0.45;
      m_minRangeAtr=0.35;
      m_closeLocation=0.72;
      m_ready=false;
     }

                    ~CPrecisionEntryEngine(void)
     {
      Release();
     }

   bool Init(const string symbol,const ENUM_TIMEFRAMES timeframe,
             const int fastPeriod,const int slowPeriod,const int atrPeriod,
             const double minBodyRatio,const double minRangeAtr,
             const double closeLocation)
     {
      Release();
      if(StringLen(symbol)==0 || fastPeriod<2 || slowPeriod<=fastPeriod ||
         atrPeriod<2 || minBodyRatio<=0.0 || minBodyRatio>1.0 ||
         minRangeAtr<=0.0 || closeLocation<=0.5 || closeLocation>=1.0)
         return(false);

      m_symbol=symbol;
      m_timeframe=timeframe;
      m_fastPeriod=fastPeriod;
      m_slowPeriod=slowPeriod;
      m_atrPeriod=atrPeriod;
      m_minBodyRatio=minBodyRatio;
      m_minRangeAtr=minRangeAtr;
      m_closeLocation=closeLocation;

      m_fastHandle=iMA(symbol,timeframe,fastPeriod,0,MODE_EMA,PRICE_CLOSE);
      if(m_fastHandle==INVALID_HANDLE)
        {
         Release();
         return(false);
        }
      m_slowHandle=iMA(symbol,timeframe,slowPeriod,0,MODE_EMA,PRICE_CLOSE);
      if(m_slowHandle==INVALID_HANDLE)
        {
         Release();
         return(false);
        }
      m_atrHandle=iATR(symbol,timeframe,atrPeriod);
      if(m_atrHandle==INVALID_HANDLE)
        {
         Release();
         return(false);
        }
      m_ready=true;
      return(true);
     }

   void Release(void)
     {
      if(m_fastHandle!=INVALID_HANDLE) IndicatorRelease(m_fastHandle);
      if(m_slowHandle!=INVALID_HANDLE) IndicatorRelease(m_slowHandle);
      if(m_atrHandle!=INVALID_HANDLE) IndicatorRelease(m_atrHandle);
      m_fastHandle=INVALID_HANDLE;
      m_slowHandle=INVALID_HANDLE;
      m_atrHandle=INVALID_HANDLE;
      m_ready=false;
     }

   bool Ready(void) const
     {
      return(m_ready && m_fastHandle!=INVALID_HANDLE &&
             m_slowHandle!=INVALID_HANDLE && m_atrHandle!=INVALID_HANDLE);
     }

   // Requires the last completed candle to show directional displacement,
   // EMA alignment and a close near the directional extreme. The forming
   // candle is never used, preventing intrabar confirmation repainting.
   bool AllowsDirection(const ENUM_AX_DIR direction) const
     {
      if(!Ready() || (direction!=AX_DIR_BUY && direction!=AX_DIR_SELL))
         return(false);

      MqlRates rates[];
      double fast[],slow[],atr[];
      ArraySetAsSeries(rates,true);
      ArraySetAsSeries(fast,true);
      ArraySetAsSeries(slow,true);
      ArraySetAsSeries(atr,true);

      if(CopyRates(m_symbol,m_timeframe,1,2,rates)!=2 ||
         CopyBuffer(m_fastHandle,0,1,2,fast)!=2 ||
         CopyBuffer(m_slowHandle,0,1,2,slow)!=2 ||
         CopyBuffer(m_atrHandle,0,1,1,atr)!=1)
         return(false);

      double range=rates[0].high-rates[0].low;
      if(range<=0.0 || atr[0]<=0.0 ||
         !MathIsValidNumber(range) || !MathIsValidNumber(atr[0]) ||
         !MathIsValidNumber(fast[0]) || !MathIsValidNumber(fast[1]) ||
         !MathIsValidNumber(slow[0]))
         return(false);

      double body=MathAbs(rates[0].close-rates[0].open);
      double bodyRatio=body/range;
      double closePosition=(rates[0].close-rates[0].low)/range;
      if(bodyRatio<m_minBodyRatio || range<atr[0]*m_minRangeAtr)
         return(false);

      if(direction==AX_DIR_BUY)
         return(rates[0].close>rates[0].open &&
                closePosition>=m_closeLocation &&
                rates[0].close>fast[0] && fast[0]>slow[0] &&
                fast[0]>=fast[1]);

      return(rates[0].close<rates[0].open &&
             closePosition<=(1.0-m_closeLocation) &&
             rates[0].close<fast[0] && fast[0]<slow[0] &&
             fast[0]<=fast[1]);
     }
  };

#endif // AX_PRECISION_ENTRY_ENGINE_MQH
