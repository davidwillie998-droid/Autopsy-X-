//+------------------------------------------------------------------+
//| ExpectedValue.mqh                                                    |
//| Layer 09 — EXPECTED VALUE ENGINE (Hidden Mechanic #11).              |
//| Net expectancy in R, after spread/commission/swap/slippage. This is |
//| the single gate that decides whether a statistically fine setup is  |
//| still worth paying the broker to take.                              |
//+------------------------------------------------------------------+
#ifndef AXF_EXPECTEDVALUE_MQH
#define AXF_EXPECTEDVALUE_MQH

#include "../Common/Defines.mqh"

class CAxfExpectedValue
  {
public:
   //--- all cost terms are converted into R (fractions of the stop distance) so
   //--- they can be netted directly against probability-weighted reward.
   SAxfExpectedValue Compute(const SAxfProbability &prob,
                              const double reward_r_tp1,
                              const double reward_r_tp2,
                              const double risk_price_distance,
                              const double spread_price,
                              const double commission_per_lot,
                              const double lots,
                              const double contract_size,
                              const double tick_value,
                              const double tick_size,
                              const double assumed_slippage_points,
                              const double point)
     {
      SAxfExpectedValue ev; ZeroMemory(ev); ev.valid=false;
      if(!prob.valid || risk_price_distance<=0) return ev;

      // gross expected R, using whatever probability confidence we actually have —
      // low-confidence probabilities pull expectancy toward zero (unknown edge),
      // not toward an optimistic assumption.
      double p1 = prob.p_tp1 * prob.confidence;
      double p2 = prob.p_tp2 * prob.confidence;
      double gross_r = (p1*reward_r_tp1) + (p2*(reward_r_tp2-reward_r_tp1)) - (prob.p_sl*prob.confidence)*1.0;
      // if we have no confidence at all, gross expectancy is explicitly unknown -> 0
      if(prob.confidence<=0) gross_r = 0.0;

      double spread_r = (risk_price_distance>0) ? spread_price/risk_price_distance : 0;

      double commission_price_equiv = 0;
      if(tick_value>0 && tick_size>0 && lots>0)
        {
         double commission_money = commission_per_lot*lots;
         double money_per_price_unit = (tick_value/tick_size)*lots;
         commission_price_equiv = (money_per_price_unit>0) ? commission_money/money_per_price_unit : 0;
        }
      double commission_r = (risk_price_distance>0) ? commission_price_equiv/risk_price_distance : 0;

      double slippage_price = assumed_slippage_points*point;
      double slippage_r = (risk_price_distance>0) ? slippage_price/risk_price_distance : 0;

      ev.cost_r = spread_r + commission_r + slippage_r;
      ev.gross_expected_r = gross_r;
      ev.net_expected_r = gross_r - ev.cost_r;
      ev.positive = (ev.net_expected_r > 0.0) && (prob.confidence>0);
      ev.valid = true;
      return ev;
     }
  };

#endif // AXF_EXPECTEDVALUE_MQH
