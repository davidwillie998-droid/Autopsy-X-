//+------------------------------------------------------------------+
//| OpportunityEngine.mqh                                                |
//| Layer 07 — OPPORTUNITY ENGINE, fusing Hidden Mechanics #9           |
//| (Opportunity Magnitude) and #12 (Asymmetry), plus the SNIPER ENTRY   |
//| logic: instead of chasing the displacement candle with a market      |
//| order, this locates the order block / FVG that CAUSED the break of   |
//| structure and prices a precise retracement zone inside it. The       |
//| caller places a pending limit order there — a planned price, not     |
//| whatever the market hands back after a breakout.                     |
//|                                                                       |
//| The stop is always placed at a structurally valid point (beyond the  |
//| order block / last swing) — never widened or narrowed just to        |
//| manufacture a prettier R:R, per spec section 16.                     |
//+------------------------------------------------------------------+
#ifndef AXF_OPPORTUNITYENGINE_MQH
#define AXF_OPPORTUNITYENGINE_MQH

#include "../Common/Defines.mqh"

class CAxfOpportunityEngine
  {
private:
   double            m_min_rr;
   bool              m_sniper_required;   // Inp_SniperEntryMode: no zone -> no trade, never a market chase
   double            m_sniper_fraction;   // 0=near edge of the zone (easy fill) .. 1=far edge (best price)
   double            m_sniper_max_atr;    // reject a zone farther than this many ATRs from current price
   double            m_sniper_min_points; // reject a zone that isn't a real retracement (too close to price)

   bool CAxfStructureEngineForcesNoTrade(const SAxfStructure &s)
     {
      // a bare CHOCH with no displacement is a warning shot, not yet a tradable
      // change of character — wait for BOS confirmation.
      return (s.choch_confirmed && !s.bos_confirmed && !s.displacement);
     }

   //--- Locates the retracement zone (the OB, falling back to the FVG) that a
   //--- sniper limit order should sit inside, and validates it is a genuine,
   //--- reachable, structurally-sound retracement rather than a chase.
   //--- Returns false (zone_price left untouched) when no honest zone exists —
   //--- the caller must then either reject the setup (sniper-required) or fall
   //--- back to a market entry, never fabricate a zone.
   bool BuildZone(const ENUM_AXF_DIRECTION dir,const SAxfStructure &structure,
                  const double market_price,const double stop,const double atr,
                  const double point,double &zone_price_out,double &zone_distance_atr_out)
     {
      bool have_ob  = (structure.ob_price_high>0 && structure.ob_price_low>0 && structure.ob_price_high>structure.ob_price_low);
      bool have_fvg = (structure.fvg_high>0 && structure.fvg_low>0 && structure.fvg_high>structure.fvg_low);
      if(!have_ob && !have_fvg) return false;

      double near_edge, far_edge; // 'near' = reached first as price retraces, 'far' = deepest/best price
      if(have_ob) {
         if(dir==DIR_LONG) { near_edge=structure.ob_price_high; far_edge=structure.ob_price_low; }
         else              { near_edge=structure.ob_price_low;  far_edge=structure.ob_price_high; }
        }
      else {
         if(dir==DIR_LONG) { near_edge=structure.fvg_high; far_edge=structure.fvg_low; }
         else              { near_edge=structure.fvg_low;  far_edge=structure.fvg_high; }
        }

      double zone = near_edge + (far_edge-near_edge)*m_sniper_fraction;

      // must be a real retracement: on the correct side of both current price
      // and the stop, with positive room on both legs.
      if(dir==DIR_LONG)
        {
         if(!(zone < market_price && zone > stop)) return false;
        }
      else
        {
         if(!(zone > market_price && zone < stop)) return false;
        }

      double distance_price = MathAbs(market_price-zone);
      if(point>0 && distance_price/point < m_sniper_min_points) return false; // basically already at market, not a retracement
      if(atr>0 && distance_price > atr*m_sniper_max_atr) return false;        // too far — this is a chase dressed as a zone

      zone_price_out = zone;
      zone_distance_atr_out = (atr>0) ? distance_price/atr : 0.0;
      return true;
     }

public:
                     CAxfOpportunityEngine(void)
     {
      m_min_rr=1.5; m_sniper_required=true; m_sniper_fraction=0.55;
      m_sniper_max_atr=2.0; m_sniper_min_points=20;
     }

   void              Init(const double min_rr,const bool sniper_required,const double sniper_fraction,
                           const double sniper_max_atr,const double sniper_min_points)
     {
      m_min_rr = MathMax(1.0,min_rr);
      m_sniper_required = sniper_required;
      m_sniper_fraction = AxfClamp(sniper_fraction,0.0,1.0);
      m_sniper_max_atr = MathMax(0.1,sniper_max_atr);
      m_sniper_min_points = MathMax(0.0,sniper_min_points);
     }

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
      o.market_price = (o.direction==DIR_LONG) ? ask : bid;
      double min_stop_dist = MathMax(stops_level_points*point, vol.atr*0.05);

      //--- stop is always derived from structure first, independent of entry
      //--- mode — the zone (below) never influences where the stop goes.
      if(o.direction==DIR_LONG)
        {
         double structural_stop = (structure.ob_price_low>0) ? structure.ob_price_low : structure.last_swing_low;
         o.stop = structural_stop - min_stop_dist;
         if(o.market_price - o.stop < min_stop_dist) o.stop = o.market_price - min_stop_dist;
        }
      else
        {
         double structural_stop = (structure.ob_price_high>0) ? structure.ob_price_high : structure.last_swing_high;
         o.stop = structural_stop + min_stop_dist;
         if(o.stop - o.market_price < min_stop_dist) o.stop = o.market_price + min_stop_dist;
        }

      //--- SNIPER ZONE: this is the priority path. Only when no honest zone
      //--- exists AND sniper mode is not mandatory do we fall back to entering
      //--- at the current market price.
      double zone_price, zone_atr;
      bool have_zone = BuildZone(o.direction,structure,o.market_price,o.stop,vol.atr,point,zone_price,zone_atr);

      if(have_zone)
        {
         o.entry = zone_price;
         o.entry_is_limit = true;
         o.zone_distance_atr = zone_atr;
        }
      else
        {
         if(m_sniper_required) return o; // no honest retracement zone -> no trade, never a market chase
         o.entry = o.market_price;
         o.entry_is_limit = false;
         o.zone_distance_atr = 0.0;
        }

      //--- targets are measured from the ACTUAL planned entry, not market price,
      //--- so R-multiples reflect what the trade will really risk/return.
      if(o.direction==DIR_LONG)
        {
         o.target1 = (liquidity.nearest_liquidity_above>0) ? liquidity.nearest_liquidity_above : o.entry + vol.atr*1.5;
         o.target2 = MathMax(o.target1, liquidity.session_high>o.target1 ? liquidity.prev_week_high : o.entry+vol.atr*2.5);
         if(o.target2<=o.target1) o.target2 = o.target1 + vol.atr*1.0;
         o.target_final = MathMax(o.target2, o.entry + vol.atr*4.0);
        }
      else
        {
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
      //--- + volatility suitability + zone precision, 0..100. Feeds the Flip
      //--- Score's structure/liquidity/momentum components, kept explainable
      //--- component-by-component.
      double q = structure.quality*0.5;
      bool regime_aligned = (o.direction==DIR_LONG && (regime.regime==REGIME_TREND_BULL||regime.regime==REGIME_STRONG_TREND_BULL||regime.regime==REGIME_EXPANSION)) ||
                            (o.direction==DIR_SHORT && (regime.regime==REGIME_TREND_BEAR||regime.regime==REGIME_STRONG_TREND_BEAR||regime.regime==REGIME_EXPANSION));
      if(regime_aligned) q += 20;
      if(regime.regime==REGIME_STRONG_TREND_BULL||regime.regime==REGIME_STRONG_TREND_BEAR) q += 10;
      if(liquidity.nearest_liquidity_above>0 && liquidity.nearest_liquidity_below>0) q += 5;
      if(vol.classification==VOL_HIGH && vol.character==VOLCHAR_DIRECTIONAL) q += 10;
      if(vol.classification==VOL_EXTREME) q -= 10; // tradable range widens, but so does noise
      if(o.r_multiple_potential>=3.0) q += 5;
      if(o.entry_is_limit) q += 5; // a real sniper zone is itself a quality signal, not just execution style

      // zone-relative premium/discount: does the PLANNED entry (not just the
      // live close) actually sit in discount for a long / premium for a short?
      if(structure.range_high>structure.range_low)
        {
         double mid = (structure.range_high+structure.range_low)/2.0;
         double check_price = o.entry_is_limit ? o.entry : o.market_price;
         if((o.direction==DIR_LONG && check_price<mid) || (o.direction==DIR_SHORT && check_price>mid))
            q += 5;
        }

      o.quality_score = AxfClamp(q,0,100);
      o.is_aplus = (o.quality_score>=80) && regime_aligned && structure.displacement;

      o.valid = true;
      return o;
     }
  };

#endif // AXF_OPPORTUNITYENGINE_MQH
