//+------------------------------------------------------------------+
//| RegimeEngine.mqh                                                    |
//| Layer 03 — MARKET REGIME ENGINE (Hidden Mechanic #5).               |
//| Classifies TREND / STRONG TREND / RANGE / EXPANSION / CONTRACTION / |
//| REVERSAL / CHAOS / UNKNOWN from ADX + directional movement + a      |
//| Bollinger-width proxy for expansion/contraction, cross-checked      |
//| against the Volatility engine's character read.                    |
//+------------------------------------------------------------------+
#ifndef AXF_REGIMEENGINE_MQH
#define AXF_REGIMEENGINE_MQH

#include "../Common/Defines.mqh"
#include "VolatilityEngine.mqh"

class CAxfRegimeEngine
  {
private:
   int               m_adx_handle;
   int               m_bb_handle;
   ENUM_TIMEFRAMES   m_tf;
   double            m_strong_trend_adx;

public:
                     CAxfRegimeEngine(void) { m_adx_handle=INVALID_HANDLE; m_bb_handle=INVALID_HANDLE; }
                    ~CAxfRegimeEngine(void)
     {
      if(m_adx_handle!=INVALID_HANDLE) IndicatorRelease(m_adx_handle);
      if(m_bb_handle!=INVALID_HANDLE)  IndicatorRelease(m_bb_handle);
     }

   bool              Init(const string symbol,const ENUM_TIMEFRAMES tf,const int adx_period,
                           const double strong_trend_adx)
     {
      m_tf = tf;
      m_strong_trend_adx = strong_trend_adx;
      m_adx_handle = iADX(symbol,tf,adx_period);
      m_bb_handle  = iBands(symbol,tf,20,0,2.0,PRICE_CLOSE);
      return (m_adx_handle!=INVALID_HANDLE && m_bb_handle!=INVALID_HANDLE);
     }

   //--- 'vol' should be a freshly-computed SAxfVolatility for the same symbol —
   //--- the regime engine never re-derives volatility itself (single source of truth).
   SAxfRegime        Compute(const string symbol,const SAxfVolatility &vol)
     {
      SAxfRegime out; ZeroMemory(out); out.valid=false;
      if(m_adx_handle==INVALID_HANDLE || m_bb_handle==INVALID_HANDLE) return out;

      double adx[], plus_di[], minus_di[];
      ArraySetAsSeries(adx,true); ArraySetAsSeries(plus_di,true); ArraySetAsSeries(minus_di,true);
      if(CopyBuffer(m_adx_handle,0,1,5,adx)<5)     return out;
      if(CopyBuffer(m_adx_handle,1,1,5,plus_di)<5) return out;
      if(CopyBuffer(m_adx_handle,2,1,5,minus_di)<5)return out;

      double bb_upper[], bb_lower[], bb_mid[];
      ArraySetAsSeries(bb_upper,true); ArraySetAsSeries(bb_lower,true); ArraySetAsSeries(bb_mid,true);
      int bb_n = 60;
      if(CopyBuffer(m_bb_handle,1,1,bb_n,bb_upper)<bb_n) return out;
      if(CopyBuffer(m_bb_handle,2,1,bb_n,bb_lower)<bb_n) return out;
      if(CopyBuffer(m_bb_handle,0,1,bb_n,bb_mid)<bb_n)   return out;

      double width_now = bb_upper[0]-bb_lower[0];
      double width_sum=0; for(int i=0;i<bb_n;i++) width_sum += (bb_upper[i]-bb_lower[i]);
      double width_avg = width_sum/bb_n;
      double width_ratio = (width_avg>0) ? width_now/width_avg : 1.0;

      out.trend_strength = adx[0];
      out.slope = (bb_mid[0]-bb_mid[MathMin(9,bb_n-1)]);

      bool bullish_di = plus_di[0]>minus_di[0];
      bool adx_rising = adx[0] > adx[2];

      // --- chaos overrides everything: extreme volatility with no directional
      // persistence is the one condition where we refuse to call a regime at all.
      if(vol.valid && vol.classification==VOL_EXTREME && vol.character==VOLCHAR_CHAOTIC)
        {
         out.regime = REGIME_CHAOS;
         out.valid = true;
         return out;
        }

      if(adx[0] >= m_strong_trend_adx)
        {
         out.regime = bullish_di ? REGIME_STRONG_TREND_BULL : REGIME_STRONG_TREND_BEAR;
        }
      else if(adx[0] >= 20.0)
        {
         // a DI flip against an established trend while ADX is still elevated
         // reads as a reversal-in-progress rather than a clean trend continuation
         bool di_just_flipped = (plus_di[0]>minus_di[0]) != (plus_di[3]>minus_di[3]);
         if(di_just_flipped && adx[0]>adx[3])
            out.regime = REGIME_REVERSAL;
         else
            out.regime = bullish_di ? REGIME_TREND_BULL : REGIME_TREND_BEAR;
        }
      else
        {
         // low ADX: distinguish range from expansion/contraction via BB width trend
         if(width_ratio >= 1.35 && vol.valid && vol.classification>=VOL_HIGH)
            out.regime = REGIME_EXPANSION;
         else if(width_ratio <= 0.70)
            out.regime = REGIME_CONTRACTION;
         else
            out.regime = REGIME_RANGE;
        }

      out.valid = true;
      return out;
     }

   //--- per Hidden Mechanic #5: what each regime permits. Used by OpportunityEngine
   //--- and the decision hierarchy so regime policy lives in exactly one place.
   static bool       PermitsAggression(const ENUM_AXF_REGIME r)
     {
      return (r==REGIME_STRONG_TREND_BULL || r==REGIME_STRONG_TREND_BEAR || r==REGIME_EXPANSION);
     }

   static bool       PermitsNormalTrading(const ENUM_AXF_REGIME r)
     {
      return (r==REGIME_TREND_BULL || r==REGIME_TREND_BEAR || r==REGIME_RANGE);
     }

   static bool       ForcesCapitalPreservation(const ENUM_AXF_REGIME r)
     {
      return (r==REGIME_CHAOS || r==REGIME_UNKNOWN || r==REGIME_REVERSAL || r==REGIME_CONTRACTION);
     }
  };

#endif // AXF_REGIMEENGINE_MQH
