//+------------------------------------------------------------------+
//| IPDAEngine.mqh                                                    |
//| Models price as a delivery process across a dealing range:        |
//| premium, discount, equilibrium, and where price is most likely    |
//| being delivered next given the prevailing bias.                   |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_CORE_IPDAENGINE_MQH
#define AX_CORE_IPDAENGINE_MQH
#include "Types.mqh"
#include "MarketState.mqh"

enum ENUM_AX_DELIVERY { DELIVERY_EXPANSION, DELIVERY_RETRACEMENT, DELIVERY_REBALANCING, DELIVERY_UNCLEAR };

class CIPDAEngine
  {
private:
   CMarketState *m_market;

public:
   void Init(CMarketState *market) { m_market = market; }

   //--- dealing range = highest high / lowest low over the lookback window on the given timeframe
   AXDealingRange GetDealingRange(ENUM_TIMEFRAMES tf, int lookback=40) const
     {
      AXDealingRange dr;
      double hi=-DBL_MAX, lo=DBL_MAX;
      int bars = MathMin(lookback, m_market.Bars(tf));
      for(int i=0;i<bars;i++)
        {
         hi = MathMax(hi, m_market.High(tf,i));
         lo = MathMin(lo, m_market.Low(tf,i));
        }
      dr.rangeHigh = hi;
      dr.rangeLow  = lo;
      dr.equilibrium = (hi+lo)/2.0;
      double price = m_market.Mid();
      double span = hi-lo;
      dr.currentPricePct = span>0.0 ? (price-lo)/span : 0.5;
      dr.inPremium  = dr.currentPricePct > 0.5;
      dr.inDiscount = dr.currentPricePct <= 0.5;
      return dr;
     }

   //--- given a directional bias and the current dealing range, judge the likely next delivery phase
   ENUM_AX_DELIVERY JudgeDelivery(int biasDirection, const AXDealingRange &dr) const
     {
      if(biasDirection>0)
        {
         if(dr.currentPricePct < 0.35) return DELIVERY_EXPANSION;    // deep discount, bullish bias -> room to expand up
         if(dr.currentPricePct > 0.75) return DELIVERY_RETRACEMENT;  // already in premium -> expect pullback before continuation
         return DELIVERY_REBALANCING;
        }
      if(biasDirection<0)
        {
         if(dr.currentPricePct > 0.65) return DELIVERY_EXPANSION;
         if(dr.currentPricePct < 0.25) return DELIVERY_RETRACEMENT;
         return DELIVERY_REBALANCING;
        }
      return DELIVERY_UNCLEAR;
     }

   //--- an entry is well-located only when it aligns direction with discount(buy)/premium(sell)
   bool IsWellLocated(int direction, const AXDealingRange &dr) const
     {
      if(direction>0) return dr.inDiscount;
      if(direction<0) return dr.inPremium;
      return false;
     }
  };
#endif // AX_CORE_IPDAENGINE_MQH
