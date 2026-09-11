//+------------------------------------------------------------------+
//| RegimeEngine.mqh                                                   |
//| Classifies the market into one of the regimes the spec requires,  |
//| from measurable inputs: ADX trend strength/direction, structure,  |
//| ATR ratio and recent structural-event recency.                    |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_CORE_REGIMEENGINE_MQH
#define AX_CORE_REGIMEENGINE_MQH
#include "Types.mqh"
#include "MarketState.mqh"
#include "StructureEngine.mqh"
#include "../intelligence/VolatilityEngine.mqh"

class CRegimeEngine
  {
private:
   CMarketState     *m_market;
   CStructureEngine *m_structure;
   CVolatilityEngine *m_vol;
   int               m_adxHandle[8];
   ENUM_TIMEFRAMES   m_adxTfs[8];
   int               m_adxCount;

   int AdxHandleFor(ENUM_TIMEFRAMES tf)
     {
      for(int i=0;i<m_adxCount;i++)
         if(m_adxTfs[i]==tf) return m_adxHandle[i];
      if(m_adxCount<8)
        {
         int h = iADX(m_market.Symbol(), tf, 14);
         m_adxTfs[m_adxCount]=tf; m_adxHandle[m_adxCount]=h; m_adxCount++;
         return h;
        }
      return INVALID_HANDLE;
     }

public:
   void Init(CMarketState *market, CStructureEngine *structure, CVolatilityEngine *vol)
     {
      m_market=market; m_structure=structure; m_vol=vol; m_adxCount=0;
     }

   void Deinit()
     {
      for(int i=0;i<m_adxCount;i++)
         if(m_adxHandle[i]!=INVALID_HANDLE) IndicatorRelease(m_adxHandle[i]);
     }

   bool GetAdx(ENUM_TIMEFRAMES tf, double &main, double &plusDi, double &minusDi)
     {
      int handle = AdxHandleFor(tf);
      if(handle==INVALID_HANDLE) return false;
      double bufMain[], bufPlus[], bufMinus[];
      ArraySetAsSeries(bufMain,true); ArraySetAsSeries(bufPlus,true); ArraySetAsSeries(bufMinus,true);
      if(CopyBuffer(handle,0,0,1,bufMain)<=0) return false;
      if(CopyBuffer(handle,1,0,1,bufPlus)<=0) return false;
      if(CopyBuffer(handle,2,0,1,bufMinus)<=0) return false;
      main=bufMain[0]; plusDi=bufPlus[0]; minusDi=bufMinus[0];
      return true;
     }

   ENUM_AX_REGIME Classify(ENUM_TIMEFRAMES tf)
     {
      double adx, plusDi, minusDi;
      bool haveAdx = GetAdx(tf, adx, plusDi, minusDi);
      AXStructureSnapshot snap = m_structure.GetSnapshot(tf);
      ENUM_AX_VOL_REGIME volRegime = m_vol.Classify(tf);
      double atrRatio = m_vol.AtrRatio(tf);

      bool recentStructShift = (snap.lastEvent==STRUCT_CHOCH_BULL || snap.lastEvent==STRUCT_CHOCH_BEAR ||
                                 snap.lastEvent==STRUCT_MSS_BULL  || snap.lastEvent==STRUCT_MSS_BEAR);

      if(!haveAdx)
         return REGIME_CHAOTIC; // cannot classify without data -> treat as uncertain, never invent

      if(recentStructShift)
         return REGIME_TRANSITIONAL;

      if(adx < 15.0 && volRegime==VOL_COMPRESSED)
         return REGIME_CONTRACTION;

      if(adx < 18.0)
        {
         // range-bound: decide accumulation vs distribution vs plain range from the forming structural bias
         if(snap.bullishStructure && plusDi>minusDi) return REGIME_ACCUMULATION;
         if(!snap.bullishStructure && minusDi>plusDi) return REGIME_DISTRIBUTION;
         return REGIME_RANGE;
        }

      if(volRegime==VOL_ABNORMAL && adx<25.0)
         return REGIME_CHAOTIC;

      if(volRegime==VOL_EXPANDED && atrRatio>1.6)
         return REGIME_VOL_EXPANSION;

      if(volRegime==VOL_COMPRESSED)
         return REGIME_VOL_COMPRESSION;

      bool bullDirection = plusDi>minusDi && snap.bullishStructure;
      bool bearDirection = minusDi>plusDi && !snap.bullishStructure;

      if(bullDirection)
         return (adx>=30.0) ? REGIME_STRONG_BULL : REGIME_WEAK_BULL;
      if(bearDirection)
         return (adx>=30.0) ? REGIME_STRONG_BEAR : REGIME_WEAK_BEAR;

      return (adx>=25.0) ? REGIME_EXPANSION : REGIME_TRANSITIONAL;
     }
  };
#endif // AX_CORE_REGIMEENGINE_MQH
