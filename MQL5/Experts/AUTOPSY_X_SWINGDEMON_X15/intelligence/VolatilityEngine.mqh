//+------------------------------------------------------------------+
//| VolatilityEngine.mqh                                              |
//| Measures realized volatility and classifies its regime so stop    |
//| distance, sizing and entry thresholds can adapt to it.            |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_INTELLIGENCE_VOLATILITYENGINE_MQH
#define AX_INTELLIGENCE_VOLATILITYENGINE_MQH
#include "../core/Types.mqh"
#include "../core/MarketState.mqh"

enum ENUM_AX_VOL_REGIME { VOL_COMPRESSED, VOL_NORMAL, VOL_EXPANDED, VOL_ABNORMAL };

class CVolatilityEngine
  {
private:
   CMarketState *m_market;

public:
   void Init(CMarketState *market) { m_market = market; }

   //--- ATR now vs its own N-period average -> ratio > 1 means expanding
   double AtrRatio(ENUM_TIMEFRAMES tf, int lookback=50) const
     {
      double current = m_market.ATR(tf, 0);
      if(current<=0.0) return 1.0;
      double sum=0.0; int n=0;
      for(int i=1;i<=lookback;i++)
        {
         double a = m_market.ATR(tf, i);
         if(a>0.0) { sum+=a; n++; }
        }
      if(n==0) return 1.0;
      double avg = sum/n;
      if(avg<=0.0) return 1.0;
      return current/avg;
     }

   //--- realized volatility as stdev of log returns over lookback bars
   double RealizedVolatility(ENUM_TIMEFRAMES tf, int lookback=20) const
     {
      int bars = m_market.Bars(tf);
      int n = MathMin(lookback, bars-1);
      if(n<5) return 0.0;
      double returns[]; ArrayResize(returns, n);
      for(int i=0;i<n;i++)
        {
         double c0 = m_market.Close(tf, i);
         double c1 = m_market.Close(tf, i+1);
         if(c0<=0.0 || c1<=0.0) { returns[i]=0.0; continue; }
         returns[i] = MathLog(c0/c1);
        }
      double mean=0.0;
      for(int i=0;i<n;i++) mean+=returns[i];
      mean/=n;
      double var=0.0;
      for(int i=0;i<n;i++) var += MathPow(returns[i]-mean,2);
      var/=n;
      return MathSqrt(var);
     }

   //--- true range of the most recently closed bar vs ATR -> abnormal candle detector
   bool IsAbnormalCandle(ENUM_TIMEFRAMES tf, double multiple=2.5) const
     {
      double atr = m_market.ATR(tf, 1);
      if(atr<=0.0) return false;
      double high = m_market.High(tf,1), low = m_market.Low(tf,1);
      return (high-low) > multiple*atr;
     }

   ENUM_AX_VOL_REGIME Classify(ENUM_TIMEFRAMES tf) const
     {
      double ratio = AtrRatio(tf);
      if(IsAbnormalCandle(tf)) return VOL_ABNORMAL;
      if(ratio < 0.75) return VOL_COMPRESSED;
      if(ratio > 1.35) return VOL_EXPANDED;
      return VOL_NORMAL;
     }

   //--- suggested stop-distance multiplier applied on top of the base ATR stop
   double StopMultiplierFor(ENUM_AX_VOL_REGIME vr) const
     {
      switch(vr)
        {
         case VOL_COMPRESSED: return 1.1;  // tighter ranges need a little more room, not less
         case VOL_EXPANDED:   return 1.6;  // wide bars need wider invalidation
         case VOL_ABNORMAL:   return 2.0;  // don't trust a single spike bar's exact wick
         default:             return 1.3;
        }
     }

   //--- position-size multiplier: shrink size when volatility is abnormal/expanded
   double SizeMultiplierFor(ENUM_AX_VOL_REGIME vr) const
     {
      switch(vr)
        {
         case VOL_ABNORMAL:   return 0.5;
         case VOL_EXPANDED:   return 0.8;
         case VOL_COMPRESSED: return 1.0;
         default:             return 1.0;
        }
     }
  };
#endif // AX_INTELLIGENCE_VOLATILITYENGINE_MQH
