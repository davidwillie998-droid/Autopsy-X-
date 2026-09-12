//+------------------------------------------------------------------+
//| OpportunityEngine.mqh                                                |
//| Layer 07 — OPPORTUNITY ENGINE, fusing Hidden Mechanics #9           |
//| (Opportunity Magnitude) and #12 (Asymmetry).                        |
//|                                                                      |
//| Builds a concrete trade idea (entry/stop/targets) from structure +   |
//| liquidity, with the stop placed at a structurally valid point       |
//| (beyond the order block / last swing) — never widened or narrowed   |
//| just to manufacture a prettier R:R, per spec section 16.             |
//+------------------------------------------------------------------+
#ifndef AXF_OPPORTUNITYENGINE_MQH
#define AXF_OPPORTUNITYENGINE_MQH

#include "../Common/Defines.mqh"

class CAxfOpportunityEngine
  {
private:
   double            m_min_rr;

public:
                     CAxfOpportunityEngine(void) { m_min_rr=1.5; }

   void              Init(const double min_rr) { m_min_rr = MathMax(1.0,min_rr); }

   SAxfOpportunity   Build(const string symbol,
                            const SAxfStructure &structure,
                            const SAxfLiquidityMap &liquidity,
                            const SAxfRegime &regime,
                            const SAxfVolatility &vol,
                            const double point,
                            const int stops_level_points)
     {
      SAxfOpportunity o; ZeroMemory(o); o.valid=false; o.direction=DIR_NONE;

      if(!structure.valid || !liquidity.valid || !regime.valid || !vol.valid) return o;
      if(structure.bias==DIR_NONE) return o;
      if(CAxfStructureEngineForcesNoTrade(structure)) return o;

      double bid = SymbolInfoDouble(symbol,SYMBOL_BID);
      double ask = SymbolInfoDouble(symbol,SYMBOL_ASK);
      if(bid<=0 || ask<=0) return o;

      o.direction = structure.bias;
      double min_stop_dist = MathMax(stops_level_points*point, vol.atr*0.05);

      if(o.direction==DIR_LONG)
        {
         o.entry = ask;
         // stop: beyond the order block low if we have one, else beyond last swing low
         double structural_stop = (structure.ob_price_low>0) ? structure.ob_price_low : structure.last_swing_low;
         o.stop = structural_stop - min_stop_dist; // small buffer, not a manufactured shrink
         if(o.entry - o.stop < min_stop_dist) o.stop = o.entry - min_stop_dist;

         // targets: nearest liquidity pools above, then the further one, then the
         // volatility-adjusted stretch target as the "final" runner objective
         o.target1 = (liquidity.nearest_liquidity_above>0) ? liquidity.nearest_liquidity_above : o.entry + vol.atr*1.5;
         o.target2 = MathMax(o.target1, liquidity.session_high>o.target1 ? liquidity.prev_week_high : o.entry+vol.atr*2.5);
         if(o.target2<=o.target1) o.target2 = o.target1 + vol.atr*1.0;
         o.target_final = MathMax(o.target2, o.entry + vol.atr*4.0);
        }
      else // DIR_SHORT
        {
         o.entry = bid;
         double structural_stop = (structure.ob_price_high>0) ? structure.ob_price_high : structure.last_swing_high;
         o.stop = structural_stop + min_stop_dist;
         if(o.stop - o.entry < min_stop_dist) o.stop = o.entry + min_stop_dist;

         o.target1 = (liquidity.nearest_liquidity_below>0) ? liquidity.nearest_liquidity_below : o.entry - vol.atr*1.5;
         o.target2 = MathMin(o.target1, o.entry - vol.atr*2.5);
         if(o.target2>=o.target1) o.target2 = o.target1 - vol.atr*1.0;
         o.target_final = MathMin(o.target2, o.entry - vol.atr*4.0);
        }

      o.risk_price_distance = MathAbs(o.entry-o.stop);
      o.reward_price_distance = MathAbs(o.target1-o.entry);
      if(o.risk_price_distance<=0) return o;

      o.r_multiple_potential = o.reward_price_distance/o.risk_price_distance;
      o.expected_move_price = MathAbs(o.target_final-o.entry);

      // Hidden Mechanic #9: reject if the market simply doesn't have room to
      // justify the risk being taken, regardless of how clean the structure looks.
      if(o.r_multiple_potential < m_min_rr)
        { o.valid=false; return o; }

      //--- quality score: structure quality + regime alignment + liquidity clarity
      //--- + volatility suitability, 0..100. This feeds the Flip Score's structure/
      //--- liquidity/momentum components, kept explainable component-by-component.
      double q = structure.quality*0.5;
      bool regime_aligned = (o.direction==DIR_LONG && (regime.regime==REGIME_TREND_BULL||regime.regime==REGIME_STRONG_TREND_BULL||regime.regime==REGIME_EXPANSION)) ||
                            (o.direction==DIR_SHORT && (regime.regime==REGIME_TREND_BEAR||regime.regime==REGIME_STRONG_TREND_BEAR||regime.regime==REGIME_EXPANSION));
      if(regime_aligned) q += 20;
      if(regime.regime==REGIME_STRONG_TREND_BULL||regime.regime==REGIME_STRONG_TREND_BEAR) q += 10;
      if(liquidity.nearest_liquidity_above>0 && liquidity.nearest_liquidity_below>0) q += 5;
      if(vol.classification==VOL_HIGH && vol.character==VOLCHAR_DIRECTIONAL) q += 10;
      if(vol.classification==VOL_EXTREME) q -= 10; // tradable range widens, but so does noise
      if(o.r_multiple_potential>=3.0) q += 5;

      o.quality_score = AxfClamp(q,0,100);
      o.is_aplus = (o.quality_score>=80) && regime_aligned && structure.displacement;

      o.valid = true;
      return o;
     }

private:
   bool CAxfStructureEngineForcesNoTrade(const SAxfStructure &s)
     {
      // a bare CHOCH with no displacement is a warning shot, not yet a tradable
      // change of character — wait for BOS confirmation.
      return (s.choch_confirmed && !s.bos_confirmed && !s.displacement);
     }
  };

#endif // AXF_OPPORTUNITYENGINE_MQH
