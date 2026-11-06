//+------------------------------------------------------------------+
//|                                                   PyramidEngine.mqh|
//|  Trend-following anti-martingale campaign signal and sizing rules |
//|  Calculation layer only. Execution remains owned by FlipDemon.    |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_PYRAMIDENGINE_MQH
#define AX_PYRAMIDENGINE_MQH
#include "Defs.mqh"

enum ENUM_AX_PYRAMID_TRIGGER
  {
   AX_PYRAMID_FIXED_GAP=0,
   AX_PYRAMID_ATR_GAP=1,
   AX_PYRAMID_CLOSED_BAR=2
  };

enum ENUM_AX_PYRAMID_LOT_MODE
  {
   AX_PYRAMID_MULTIPLIER=0,
   AX_PYRAMID_INCREMENT=1,
   AX_PYRAMID_CUSTOM=2
  };

class CPyramidEngine
  {
private:
   string          m_symbol;
   ENUM_TIMEFRAMES m_timeframe;
   ENUM_MA_METHOD  m_maMethod;
   int             m_period;
   int             m_maHandle;
   int             m_atrHandle;
   bool            m_ready;

   double ClampShrink(const double value) const
     {
      return(MathMax(0.0,MathMin(90.0,value)));
     }

   double PipSize(const string symbol) const
     {
      double point=SymbolInfoDouble(symbol,SYMBOL_POINT);
      int digits=(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
      if(point<=0.0) return(0.0);
      if(digits==3 || digits==5) return(point*10.0);
      return(point);
     }

   bool ParsePreset(const string symbol,const string presetList,
                    double &minimum,double &maximum,bool &priceUnits) const
     {
      minimum=0.0;
      maximum=0.0;
      priceUnits=false;
      string rows[];
      ushort rowSep=StringGetCharacter(";",0);
      int rowCount=StringSplit(presetList,rowSep,rows);
      for(int i=0;i<rowCount;i++)
        {
         string fields[];
         ushort fieldSep=StringGetCharacter(":",0);
         int count=StringSplit(rows[i],fieldSep,fields);
         if(count!=4 || fields[0]!=symbol) continue;
         string unit=fields[1];
         double low=StringToDouble(fields[2]);
         double high=StringToDouble(fields[3]);
         if((unit!="PIPS" && unit!="PRICE") || low<=0.0 || high<low)
            return(false);
         minimum=low;
         maximum=high;
         priceUnits=(unit=="PRICE");
         return(true);
        }
      return(false);
     }

public:
                     CPyramidEngine(void)
     {
      m_symbol="";
      m_timeframe=PERIOD_H1;
      m_maMethod=MODE_EMA;
      m_period=100;
      m_maHandle=INVALID_HANDLE;
      m_atrHandle=INVALID_HANDLE;
      m_ready=false;
     }

                    ~CPyramidEngine(void)
     {
      Release();
     }

   bool              Init(const string symbol,const ENUM_TIMEFRAMES timeframe,
                          const ENUM_MA_METHOD method,const int period)
     {
      Release();
      if(StringLen(symbol)==0 || period<2) return(false);
      m_symbol=symbol;
      m_timeframe=timeframe;
      m_maMethod=method;
      m_period=period;
      ResetLastError();
      m_maHandle=iMA(symbol,timeframe,period,0,method,PRICE_CLOSE);
      if(m_maHandle==INVALID_HANDLE)
        {
         PrintFormat("FLIPDEMON PYRAMID: MA handle creation failed symbol=%s error=%d",
                     symbol,GetLastError());
         return(false);
        }
      ResetLastError();
      m_atrHandle=iATR(symbol,timeframe,14);
      if(m_atrHandle==INVALID_HANDLE)
        {
         PrintFormat("FLIPDEMON PYRAMID: ATR handle creation failed symbol=%s timeframe=%d error=%d",
                     symbol,(int)timeframe,GetLastError());
         Release();
         return(false);
        }
      m_ready=true;
      return(true);
     }

   void              Release(void)
     {
      if(m_maHandle!=INVALID_HANDLE)
         IndicatorRelease(m_maHandle);
      if(m_atrHandle!=INVALID_HANDLE)
         IndicatorRelease(m_atrHandle);
      m_maHandle=INVALID_HANDLE;
      m_atrHandle=INVALID_HANDLE;
      m_ready=false;
     }

   bool              Ready(void) const
     {
      return(m_ready && m_maHandle!=INVALID_HANDLE && m_atrHandle!=INVALID_HANDLE);
     }

   // ATR is read from the last completed bar on the same timeframe as the
   // campaign trend filter. Never mix the M1 regime ATR with the H1 trend.
   bool              ReadClosedAtr(double &atrOut) const
     {
      atrOut=0.0;
      if(!Ready()) return(false);
      double values[];
      ArraySetAsSeries(values,true);
      if(CopyBuffer(m_atrHandle,0,1,1,values)!=1) return(false);
      if(!MathIsValidNumber(values[0]) || values[0]<=0.0) return(false);
      atrOut=values[0];
      return(true);
     }

   // Uses completed bars only. Index 0 is shift 3, index 1 is shift 2,
   // and index 2 is shift 1 after CopyBuffer(start=1,count=3).
   bool              ReadClosedTrend(const string symbol,ENUM_AX_DIR &direction,
                                     bool &crossed) const
     {
      direction=AX_DIR_NONE;
      crossed=false;
      if(!Ready() || symbol!=m_symbol) return(false);
      double ma[];
      ArraySetAsSeries(ma,false);
      if(CopyBuffer(m_maHandle,0,1,3,ma)!=3) return(false);
      double close1=iClose(symbol,m_timeframe,1);
      double close2=iClose(symbol,m_timeframe,2);
      if(close1<=0.0 || close2<=0.0 ||
         !MathIsValidNumber(ma[1]) || !MathIsValidNumber(ma[2]) ||
         ma[1]<=0.0 || ma[2]<=0.0)
         return(false);

      bool slopeUp=ma[2]>ma[1];
      bool slopeDown=ma[2]<ma[1];
      bool buyCross=(close2<=ma[1] && close1>ma[2] && slopeUp);
      bool sellCross=(close2>=ma[1] && close1<ma[2] && slopeDown);
      if(buyCross)
        {
         direction=AX_DIR_BUY;
         crossed=true;
        }
      else if(sellCross)
        {
         direction=AX_DIR_SELL;
         crossed=true;
        }
      else if(close1>ma[2] && slopeUp)
         direction=AX_DIR_BUY;
      else if(close1<ma[2] && slopeDown)
         direction=AX_DIR_SELL;
      return(true);
     }

   bool              TrendStillValid(const ENUM_AX_DIR direction) const
     {
      ENUM_AX_DIR current=AX_DIR_NONE;
      bool crossed=false;
      if(!ReadClosedTrend(m_symbol,current,crossed)) return(false);
      return(current==direction);
     }

   // Preset syntax: SYMBOL:PIPS:MIN:MAX;SYMBOL:PRICE:MIN:MAX
   // Example: AUDCHF:PIPS:5:11;GBPCAD:PIPS:20:65;XAUUSD:PRICE:20:30
   // A range resolves to its midpoint. No broker symbol or unit is guessed.
   double            ResolveFixedGapPrice(const string symbol,const string presetList,
                                          const double fallbackGapPips,
                                          const int tier,const double shrinkPercent) const
     {
      if(tier<1 || fallbackGapPips<=0.0) return(0.0);
      double low=0.0,high=0.0;
      bool priceUnits=false;
      double gap=0.0;
      if(ParsePreset(symbol,presetList,low,high,priceUnits))
         gap=0.5*(low+high)*(priceUnits?1.0:PipSize(symbol));
      else
         gap=fallbackGapPips*PipSize(symbol);
      if(gap<=0.0 || !MathIsValidNumber(gap)) return(0.0);
      double shrink=ClampShrink(shrinkPercent)/100.0;
      if(tier>1 && shrink>0.0)
         gap*=MathPow(1.0-shrink,tier-1);
      return(gap);
     }

   double            TierGapPrice(const string symbol,const int tier,
                                  const ENUM_AX_PYRAMID_TRIGGER trigger,
                                  const string presetList,const double fallbackGapPips,
                                  const double atr,const double atrMultiple,
                                  const double shrinkPercent) const
     {
      if(trigger==AX_PYRAMID_ATR_GAP)
        {
         if(atr<=0.0 || atrMultiple<=0.0) return(0.0);
         double gap=atr*atrMultiple;
         if(tier>1)
            gap*=MathPow(1.0-ClampShrink(shrinkPercent)/100.0,tier-1);
         return(gap);
        }
      if(trigger==AX_PYRAMID_FIXED_GAP)
         return(ResolveFixedGapPrice(symbol,presetList,fallbackGapPips,tier,shrinkPercent));
      return(0.0); // closed-bar mode has no distance threshold
     }

   bool              TierTriggerReached(const ENUM_AX_DIR direction,
                                        const ENUM_AX_PYRAMID_TRIGGER trigger,
                                        const double lastTierEntry,const double currentBid,
                                        const double currentAsk,const double requiredGap,
                                        const double lastClosedBarClose) const
     {
      if(direction==AX_DIR_NONE || lastTierEntry<=0.0) return(false);
      double executable=(direction==AX_DIR_BUY)?currentBid:currentAsk;
      if(executable<=0.0) return(false);
      if(trigger==AX_PYRAMID_CLOSED_BAR)
        {
         if(lastClosedBarClose<=0.0) return(false);
         return((direction==AX_DIR_BUY)?(lastClosedBarClose>lastTierEntry)
                                       :(lastClosedBarClose<lastTierEntry));
        }
      if(requiredGap<=0.0) return(false);
      return((direction==AX_DIR_BUY)?(executable>=lastTierEntry+requiredGap)
                                    :(executable<=lastTierEntry-requiredGap));
     }

   // Custom values are multipliers of the risk-engine-approved first-tier volume.
   // For example, 1,1.5,2 means 1.0x, 1.5x, 2.0x the base tier.
   double            CalculateTierVolume(const double firstTierLots,const int tier,
                                         const ENUM_AX_PYRAMID_LOT_MODE mode,
                                         const double multiplier,const double incrementLots,
                                         const string customMultipliers) const
     {
      if(firstTierLots<=0.0 || tier<1) return(0.0);
      if(mode==AX_PYRAMID_MULTIPLIER)
        {
         if(multiplier<=1.0 || multiplier>5.0) return(0.0);
         return(firstTierLots*MathPow(multiplier,tier-1));
        }
      if(mode==AX_PYRAMID_INCREMENT)
        {
         if(incrementLots<=0.0) return(0.0);
         return(firstTierLots+incrementLots*(tier-1));
        }
      if(mode==AX_PYRAMID_CUSTOM)
        {
         string values[];
         ushort sep=StringGetCharacter(",",0);
         int count=StringSplit(customMultipliers,sep,values);
         if(count<=0 || tier>count) return(0.0);
         double factor=StringToDouble(values[tier-1]);
         if(factor<=0.0 || factor>100.0) return(0.0);
         if(tier>1)
           {
            double previous=StringToDouble(values[tier-2]);
            if(previous<=0.0 || factor<=previous) return(0.0);
           }
         return(firstTierLots*factor);
        }
      return(0.0);
     }
  };

#endif // AX_PYRAMIDENGINE_MQH
