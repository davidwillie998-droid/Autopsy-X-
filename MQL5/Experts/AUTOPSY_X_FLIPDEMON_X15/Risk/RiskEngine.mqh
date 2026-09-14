//+------------------------------------------------------------------+
//| RiskEngine.mqh                                                        |
//| Layer 10 — POSITION-SIZING ENGINE, plus Hidden Mechanic #3            |
//| (Adaptive Risk Multiplier) and Section 16 (Account Growth Mode).      |
//|                                                                        |
//| Final Risk = Base Risk x Setup x Regime x EV x Execution x Survival,  |
//| every factor individually bounded, and the PRODUCT re-clamped again   |
//| against both the user's configured ceiling and the absolute hard      |
//| ceiling in Defines.mqh. No code path in this class can emit a risk    |
//| percentage above AXF_HARD_MAX_RISK_PCT — that clamp is the last line  |
//| of every public method here.                                          |
//|                                                                        |
//| Position sizing asks "how much can I safely lose" first: lots are     |
//| derived from risk%% and stop distance, never from a profit target.    |
//+------------------------------------------------------------------+
#ifndef AXF_RISKENGINE_MQH
#define AXF_RISKENGINE_MQH

#include "../Common/Defines.mqh"

class CAxfRiskEngine
  {
private:
   double            m_base_risk_pct;
   double            m_max_risk_pct;
   bool              m_flip_enabled;
   double            m_flip_multiplier;

   double            SetupQualityFactor(const double opportunity_quality_0_100) const
     {
      // 0..100 quality maps to a 0.4..1.3 multiplier — a mediocre setup shrinks
      // risk, an elite one is rewarded, but never beyond a modest ceiling here
      // (FLIP mode's extra multiplier is applied separately and explicitly).
      return AxfClamp(0.4 + (opportunity_quality_0_100/100.0)*0.9, 0.0, 1.3);
     }

   double            RegimeQualityFactor(const ENUM_AXF_REGIME regime) const
     {
      switch(regime)
        {
         case REGIME_STRONG_TREND_BULL:
         case REGIME_STRONG_TREND_BEAR: return 1.25;
         case REGIME_EXPANSION:         return 1.15;
         case REGIME_TREND_BULL:
         case REGIME_TREND_BEAR:        return 1.0;
         case REGIME_RANGE:             return 0.7;
         case REGIME_CONTRACTION:       return 0.5;
         case REGIME_REVERSAL:          return 0.4;
         case REGIME_CHAOS:             return 0.0;
         default:                       return 0.3; // UNKNOWN
        }
     }

   double            EVQualityFactor(const SAxfExpectedValue &ev) const
     {
      if(!ev.valid || !ev.positive) return 0.0;
      // scale gently with the size of the net edge, capped
      return AxfClamp(0.6 + ev.net_expected_r*0.4, 0.0, 1.4);
     }

   double            ExecutionQualityFactor(const double execution_score_0_100) const
     {
      return AxfClamp(0.3 + (execution_score_0_100/100.0)*0.9, 0.0, 1.2);
     }

   double            SurvivalFactor(const ENUM_AXF_RUIN_STATE ruin_state,const double account_dd_pct) const
     {
      double f = 1.0;
      switch(ruin_state)
        {
         case RUIN_LOW:       f = 1.1;  break;
         case RUIN_NORMAL:    f = 1.0;  break;
         case RUIN_ELEVATED:  f = 0.5;  break;
         case RUIN_DEFENSIVE: f = 0.2;  break;
         case RUIN_HALT:      f = 0.0;  break;
        }
      // additional linear fade as realised account drawdown climbs, independent
      // of the ruin model — a second, model-free brake.
      if(account_dd_pct>5.0)
         f *= AxfClamp(1.0 - (account_dd_pct-5.0)/15.0, 0.0, 1.0);
      return f;
     }

public:
                     CAxfRiskEngine(void) { m_base_risk_pct=0.5; m_max_risk_pct=2.5; m_flip_enabled=true; m_flip_multiplier=2.0; }

   void              Init(const double base_risk_pct,const double max_risk_pct,
                           const bool flip_enabled,const double flip_multiplier)
     {
      m_base_risk_pct = MathMax(0.0,base_risk_pct);
      m_max_risk_pct  = MathMin(max_risk_pct,AXF_HARD_MAX_RISK_PCT);
      m_flip_enabled  = flip_enabled;
      m_flip_multiplier = AxfClamp(flip_multiplier,1.0,AXF_HARD_MAX_RISK_MULT);
     }

   //--- Section 16/17: decide the operating mode. FLIP requires the caller to
   //--- have already verified every FLIP activation condition (news, macro,
   //--- correlated exposure, execution health) — this function only applies
   //--- the score/regime/ruin gate; the EA's decision hierarchy enforces the
   //--- rest before ever calling ComputeFinalRisk with allow_flip=true.
   ENUM_AXF_GROWTH_MODE DetermineMode(const double flip_score,const ENUM_AXF_RUIN_STATE ruin_state,
                                       const ENUM_AXF_REGIME regime,const double account_dd_pct,
                                       const double flip_threshold_aplus) const
     {
      if(ruin_state==RUIN_HALT) return MODE_SURVIVAL;
      if(ruin_state==RUIN_DEFENSIVE) return MODE_SURVIVAL;
      if(account_dd_pct>=10.0) return MODE_SURVIVAL;
      if(ruin_state==RUIN_ELEVATED) return MODE_NORMAL;

      if(m_flip_enabled && flip_score>=flip_threshold_aplus &&
         (regime==REGIME_STRONG_TREND_BULL||regime==REGIME_STRONG_TREND_BEAR||regime==REGIME_EXPANSION) &&
         ruin_state==RUIN_LOW)
         return MODE_FLIP;

      if(flip_score>=flip_threshold_aplus && ruin_state<=RUIN_NORMAL)
         return MODE_AGGRESSIVE;

      return MODE_NORMAL;
     }

   //--- the full Hidden Mechanic #3 chain. Every factor is bounded above and
   //--- clamped again at the end — a bug in any one factor cannot escape here.
   double            ComputeFinalRiskPct(const ENUM_AXF_GROWTH_MODE mode,
                                          const double opportunity_quality_0_100,
                                          const ENUM_AXF_REGIME regime,
                                          const SAxfExpectedValue &ev,
                                          const double execution_score_0_100,
                                          const ENUM_AXF_RUIN_STATE ruin_state,
                                          const double account_dd_pct,
                                          const double loss_streak_factor,
                                          const double win_streak_ceiling_mult) const
     {
      if(mode==MODE_SURVIVAL) return 0.0; // survival mode places no new risk, full stop below

      double setup_f     = SetupQualityFactor(opportunity_quality_0_100);
      double regime_f     = RegimeQualityFactor(regime);
      double ev_f         = EVQualityFactor(ev);
      double exec_f       = ExecutionQualityFactor(execution_score_0_100);
      double survival_f   = SurvivalFactor(ruin_state,account_dd_pct);

      double multiplier = setup_f*regime_f*ev_f*exec_f*survival_f;

      if(mode==MODE_FLIP)
         multiplier *= m_flip_multiplier;

      // loss-streak defense always cuts, never boosts; win-streak protection
      // always caps, never boosts beyond its ceiling
      multiplier *= loss_streak_factor;
      multiplier = MathMin(multiplier, win_streak_ceiling_mult);

      multiplier = AxfClamp(multiplier, AXF_HARD_MIN_RISK_MULT, AXF_HARD_MAX_RISK_MULT);

      double risk_pct = m_base_risk_pct*multiplier;
      risk_pct = MathMin(risk_pct, m_max_risk_pct);
      risk_pct = MathMin(risk_pct, AXF_HARD_MAX_RISK_PCT); // last line of defense, unconditional

      if(ev_f<=0.0 || regime_f<=0.0 || survival_f<=0.0) return 0.0; // any zero factor -> no trade, not "tiny trade"

      return MathMax(0.0,risk_pct);
     }

   //--- Position sizing: "how much can I safely lose" first. Lots are derived
   //--- purely from risk money / (stop distance in price * money-per-price-unit).
   //--- Never derived from a profit target (spec section 22).
   bool              ComputeLots(const double equity,const double risk_pct,
                                  const double stop_distance_price,
                                  const double tick_value,const double tick_size,
                                  const double volume_min,const double volume_max,const double volume_step,
                                  double &lots_out) const
     {
      lots_out = 0.0;
      if(risk_pct<=0 || stop_distance_price<=0 || tick_size<=0 || tick_value<=0 || volume_step<=0) return false;

      double risk_money = equity*(risk_pct/100.0);
      double money_per_price_unit_per_lot = tick_value/tick_size;
      if(money_per_price_unit_per_lot<=0) return false;

      double raw_lots = risk_money/(stop_distance_price*money_per_price_unit_per_lot);
      double lots = MathFloor(raw_lots/volume_step)*volume_step;
      lots = AxfClamp(lots,0.0,volume_max);

      if(lots < volume_min) return false; // required size below broker minimum -> reject, never round up past risk

      lots_out = lots;
      return true;
     }
  };

#endif // AXF_RISKENGINE_MQH
