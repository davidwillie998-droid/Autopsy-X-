//+------------------------------------------------------------------+
//| AdaptiveFlipEngine.mqh                                                |
//| The single, modular, account-agnostic core of the "flip" decision:    |
//| probability -> expected value -> risk-of-ruin -> order-flow           |
//| confirmation -> flip score -> adaptive capital state -> dynamic risk  |
//| -> portfolio exposure -> position size, in that fixed order.          |
//|                                                                        |
//| This module does not invent any new math. It OWNS and SEQUENCES the   |
//| existing ProbabilityEngine / ExpectedValue / DiagnosticEngine /        |
//| RiskEngine / ExposureEngine exactly as the main EA previously called   |
//| them inline — every formula, threshold and rejection order is         |
//| unchanged. What changes is that it is now one addressable, testable    |
//| unit instead of five separate globals manipulated by ~80 lines of     |
//| procedural code in the .mq5 file, and that DriftEngine's edge-decay    |
//| signal — previously computed and only ever printed — is now actually  |
//| enforced here (see the DRIFT block below).                            |
//|                                                                        |
//| ACCOUNT-AGNOSTIC BY CONSTRUCTION: every quantity this engine touches   |
//| is either a percentage (risk %, drawdown %), an R-multiple, or a       |
//| broker-reported per-unit value (tick value/size) passed in by the      |
//| caller. Nothing here reads AccountInfo*, a global equity constant, or  |
//| any other single-account assumption directly — it is a pure function   |
//| of its inputs, so the identical engine instance is correct whether     |
//| the account behind it holds $500 or $5,000,000, in any currency.       |
//|                                                                        |
//| HARD SAFETY LIMITS are not re-implemented here — they live exactly     |
//| where they always have (AXF_HARD_MAX_RISK_PCT etc. in Defines.mqh,     |
//| enforced as the final clamp inside RiskEngine::ComputeFinalRiskPct).   |
//| This engine cannot bypass them because it calls that same function;    |
//| it has no separate risk-calculation path of its own.                  |
//+------------------------------------------------------------------+
#ifndef AXF_ADAPTIVEFLIPENGINE_MQH
#define AXF_ADAPTIVEFLIPENGINE_MQH

#include "../Common/Defines.mqh"
#include "../Intelligence/ProbabilityEngine.mqh"
#include "../Intelligence/ExpectedValue.mqh"
#include "../Autopsy/DiagnosticEngine.mqh"
#include "../Autopsy/DriftEngine.mqh"
#include "RiskEngine.mqh"
#include "ExposureEngine.mqh"

class CAxfAdaptiveFlipEngine
  {
private:
   CAxfProbabilityEngine   m_probability;
   CAxfExpectedValue       m_ev;
   CAxfDiagnosticEngine    m_diagnostic;
   CAxfRiskEngine          m_riskEngine;
   CAxfExposureEngine      m_exposure;

   double                  m_flip_threshold_aplus;
   double                  m_drift_reduce_factor;
   bool                    m_drift_halt_enabled;

public:
   //--- forwards straight through to each owned sub-engine's own Init —
   //--- same parameters, same meaning, as when the caller Init'd them
   //--- separately. Consolidating ownership, not behavior.
   void              Init(const ulong magic,
                           const int prob_min_sample_full_confidence,
                           const double base_risk_pct,const double max_risk_pct,
                           const bool flip_enabled,const double flip_risk_multiplier,
                           const double max_portfolio_risk_pct,
                           const double flip_score_elite,const double flip_score_aplus,
                           const double flip_score_a,const double flip_score_b,
                           const double drift_reduce_factor,const bool drift_halt_enabled)
     {
      m_probability.Init(prob_min_sample_full_confidence);
      m_diagnostic.Init(flip_score_elite,flip_score_aplus,flip_score_a,flip_score_b);
      m_riskEngine.Init(base_risk_pct,max_risk_pct,flip_enabled,flip_risk_multiplier);
      m_exposure.Init(magic,max_portfolio_risk_pct);
      m_flip_threshold_aplus = flip_score_aplus;
      m_drift_reduce_factor = AxfClamp(drift_reduce_factor,0.0,1.0);
      m_drift_halt_enabled = drift_halt_enabled;
     }

   //--- the consolidated decision. 'history' must already be filtered to the
   //--- relevant setup class (same regime+direction) by the caller, exactly
   //--- as before. Returns a fully-populated SAxfFlipDecision; on rejection,
   //--- 'approved' is false and 'decision'/'reason' explain why — the caller
   //--- is responsible for logging that (e.g. into CAxfDecisionAudit), so
   //--- this engine never reaches into global state to report itself.
   SAxfFlipDecision  Evaluate(const string symbol,
                               const double equity,
                               const SAxfRegime &regime,
                               const SAxfStructure &structure,
                               const SAxfLiquidityMap &liquidity,
                               const SAxfVolatility &vol,
                               const SAxfOpportunity &opportunity,
                               const SAxfOrderFlow &orderflow,
                               SAxfTradeRecord &history[],
                               const double execution_score_0_100,
                               const double account_health_0_100,
                               const ENUM_AXF_RUIN_STATE ruin_state,
                               const SAxfRuinEstimate &analytical_ruin,
                               const SAxfRuinEstimate &monte_carlo_ruin,
                               const double account_dd_pct,
                               const double loss_streak_factor,
                               const double win_streak_ceiling,
                               const ENUM_AXF_DRIFT_SIGNAL drift_signal,
                               const double tick_value,const double tick_size,
                               const double volume_min,const double volume_max,const double volume_step,
                               const bool orderflow_confirmation_required,
                               const double orderflow_confirm_pulse_min,
                               const double spread_price,const double commission_per_lot,
                               const double contract_size,const double assumed_slippage_points,
                               const double point)
     {
      SAxfFlipDecision d; ZeroMemory(d);
      d.approved = false;
      d.mode = MODE_NORMAL; // matches the caller's own defensive default: only ever
                             // overwritten below once a mode is actually determined,
                             // never left reading as MODE_SURVIVAL(=0) by accident.

      //--- PROBABILITY (this EA's own journal, sample-size discounted) —
      //--- rung 10, unchanged position in the sequence.
      d.probability = m_probability.Compute(history);

      //--- EXPECTED VALUE — rung 11
      double reward_r_tp2 = (opportunity.reward_price_distance>0)
         ? MathAbs(opportunity.target2-opportunity.entry)/opportunity.risk_price_distance
         : opportunity.r_multiple_potential;
      d.ev = m_ev.Compute(d.probability,opportunity.r_multiple_potential,reward_r_tp2,
                           opportunity.risk_price_distance,
                           spread_price,commission_per_lot,1.0,
                           contract_size,tick_value,tick_size,
                           assumed_slippage_points,point);
      if(!d.ev.valid || !d.ev.positive)
        { d.decision=DECISION_REJECT_EXPECTED_VALUE; d.reason="expected value non-positive or unproven (sample confidence too low)"; return d; }

      //--- RISK OF RUIN — rung 12. Classification is owned entirely by
      //--- CAxfRuinEngine (it alone holds Inp_RuinThreshold_Elevated/
      //--- Defensive/Halt) — the caller passes in its already-classified
      //--- state so this engine never carries a second, potentially-
      //--- drifting copy of those thresholds. The two raw estimates are
      //--- still passed through for the flip score's own ruin_penalty
      //--- (see 'worse_ruin' below).
      d.ruin_state = ruin_state;
      if(d.ruin_state==RUIN_HALT)
        { d.decision=DECISION_REJECT_RISK_OF_RUIN; d.reason="probability of ruin at HALT threshold"; return d; }

      //--- ORDER FLOW CONFIRMATION (optional hard gate; off by default)
      if(orderflow_confirmation_required && orderflow.valid && orderflow.flow_valid)
        {
         double aligned_pulse = (opportunity.direction==DIR_LONG) ? orderflow.pulse : -orderflow.pulse;
         if(aligned_pulse < orderflow_confirm_pulse_min)
           {
            d.decision=DECISION_REJECT_PROBABILITY;
            d.reason=StringFormat("order flow does not confirm: pulse %.0f opposes %s",orderflow.pulse,opportunity.direction==DIR_LONG?"LONG":"SHORT");
            return d;
           }
        }

      //--- FLIP SCORE
      SAxfRuinEstimate worse_ruin = (analytical_ruin.p_dd50>monte_carlo_ruin.p_dd50) ? analytical_ruin : monte_carlo_ruin;
      d.flip = m_diagnostic.Compute(regime,structure,liquidity,vol,opportunity,d.ev,
                                     execution_score_0_100,account_health_0_100,worse_ruin,orderflow);
      if(d.flip.grade=="NO TRADE")
        { d.decision=DECISION_REJECT_PROBABILITY; d.reason="flip score below trading floor ("+DoubleToString(d.flip.total,1)+")"; return d; }

      //--- EDGE-DECAY PROTECTION (Section 36 fix): DriftEngine's signal is
      //--- now actually enforced, not just logged. A halt recommendation
      //--- rejects outright; a reduce recommendation is folded in as one
      //--- more multiplicative factor alongside loss-streak/win-streak,
      //--- never bypassing the hard ceilings in RiskEngine.
      if(drift_signal==DRIFT_HALT_RECOMMENDED && m_drift_halt_enabled)
        { d.decision=DECISION_REJECT_ACCOUNT_SURVIVAL; d.reason="edge-decay halt: recent performance has not been profitable versus this setup's own baseline"; return d; }

      double drift_factor = (drift_signal==DRIFT_REDUCE_RISK) ? m_drift_reduce_factor : 1.0;

      //--- ADAPTIVE CAPITAL STATE (mode)
      d.mode = m_riskEngine.DetermineMode(d.flip.total,d.ruin_state,regime.regime,account_dd_pct,m_flip_threshold_aplus);
      if(d.mode==MODE_SURVIVAL)
        { d.decision=DECISION_REJECT_ACCOUNT_SURVIVAL; d.reason="mode forced to SURVIVAL — no new risk"; return d; }

      //--- DYNAMIC RISK (hard-clamped inside RiskEngine regardless of what
      //--- any factor above computes — see AXF_HARD_MAX_RISK_PCT)
      d.risk_pct = m_riskEngine.ComputeFinalRiskPct(d.mode,opportunity.quality_score,regime.regime,d.ev,
                                                     execution_score_0_100,d.ruin_state,account_dd_pct,
                                                     loss_streak_factor,win_streak_ceiling);
      d.risk_pct *= drift_factor;
      if(d.risk_pct<=0)
        { d.decision=DECISION_REJECT_POSITION_SIZE; d.reason="computed risk collapsed to zero (a hard gate tripped)"; return d; }

      //--- PORTFOLIO / CORRELATED EXPOSURE
      if(!m_exposure.CanAcceptNewRisk(symbol,d.risk_pct,opportunity.direction,d.effective_portfolio_risk_pct))
        { d.decision=DECISION_REJECT_RISK_OF_RUIN; d.reason=StringFormat("effective portfolio risk would reach %.2f%% (correlated exposure)",d.effective_portfolio_risk_pct); return d; }

      //--- POSITION SIZE
      if(!m_riskEngine.ComputeLots(equity,d.risk_pct,opportunity.risk_price_distance,
                                    tick_value,tick_size,volume_min,volume_max,volume_step,d.lots))
        { d.decision=DECISION_REJECT_POSITION_SIZE; d.reason="sized lot below broker minimum for this risk%"; return d; }

      d.approved = true;
      d.decision = DECISION_APPROVE;
      d.reason = "approved";
      return d;
     }

   //--- pass-throughs so pyramiding adds and the dashboard share the exact
   //--- same sizing/exposure math as fresh entries — one source of truth.
   bool              ComputeLots(const double equity,const double risk_pct,const double stop_distance_price,
                                  const double tick_value,const double tick_size,
                                  const double volume_min,const double volume_max,const double volume_step,
                                  double &lots_out)
     {
      return m_riskEngine.ComputeLots(equity,risk_pct,stop_distance_price,tick_value,tick_size,
                                       volume_min,volume_max,volume_step,lots_out);
     }

   bool              CanAcceptNewRisk(const string symbol,const double risk_pct,const ENUM_AXF_DIRECTION dir,
                                       double &effective_risk_out)
     {
      return m_exposure.CanAcceptNewRisk(symbol,risk_pct,dir,effective_risk_out);
     }

   double            CurrentEffectiveRisk(void) { return m_exposure.CurrentEffectiveRisk(); }
  };

#endif // AXF_ADAPTIVEFLIPENGINE_MQH
