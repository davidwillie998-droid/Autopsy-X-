//+------------------------------------------------------------------+
//| DiagnosticEngine.mqh                                                  |
//| Section 32 — FLIP SCORE, and Section 33 — DECISION ENGINE audit       |
//| trail. The score is a plain weighted sum of named, inspectable        |
//| components — never an opaque number. The decision hierarchy walk      |
//| is logged so every NO TRADE has a stated reason.                      |
//+------------------------------------------------------------------+
#ifndef AXF_DIAGNOSTICENGINE_MQH
#define AXF_DIAGNOSTICENGINE_MQH

#include "../Common/Defines.mqh"

class CAxfDiagnosticEngine
  {
private:
   double            m_thr_elite, m_thr_aplus, m_thr_a, m_thr_b;

public:
   void              Init(const double thr_elite,const double thr_aplus,const double thr_a,const double thr_b)
     {
      m_thr_elite=thr_elite; m_thr_aplus=thr_aplus; m_thr_a=thr_a; m_thr_b=thr_b;
     }

   SAxfFlipScore     Compute(const SAxfRegime &regime,const SAxfStructure &structure,
                              const SAxfLiquidityMap &liquidity,const SAxfVolatility &vol,
                              const SAxfOpportunity &opportunity,const SAxfExpectedValue &ev,
                              const double execution_score_0_100,const double account_health_0_100,
                              const SAxfRuinEstimate &ruin,const SAxfOrderFlow &orderflow)
     {
      SAxfFlipScore f; ZeroMemory(f);

      // regime component: strong trend/expansion score highest, chaos/unknown score zero
      switch(regime.regime)
        {
         case REGIME_STRONG_TREND_BULL: case REGIME_STRONG_TREND_BEAR: f.regime_c=12; break;
         case REGIME_EXPANSION:                                        f.regime_c=10; break;
         case REGIME_TREND_BULL: case REGIME_TREND_BEAR:               f.regime_c=8;  break;
         case REGIME_RANGE:                                            f.regime_c=4;  break;
         default:                                                      f.regime_c=0;  break;
        }

      f.structure_c  = structure.valid ? (structure.quality/100.0)*12.0 : 0;
      f.liquidity_c  = (liquidity.valid && (liquidity.nearest_liquidity_above>0 || liquidity.nearest_liquidity_below>0)) ? 10.0 : 0;
      f.volatility_c = (vol.valid && vol.classification>=VOL_NORMAL && vol.character!=VOLCHAR_CHAOTIC) ? 10.0 : (vol.valid?4.0:0.0);
      f.momentum_c   = structure.displacement ? 8.0 : 0.0;
      f.ev_c         = (ev.valid && ev.positive) ? AxfClamp(ev.net_expected_r*8.0,0,12) : 0.0;
      f.asymmetry_c  = opportunity.valid ? AxfClamp((opportunity.r_multiple_potential-1.0)*4.0,0,10) : 0.0;
      f.execution_c  = (execution_score_0_100/100.0)*10.0;
      f.account_health_c = (account_health_0_100/100.0)*10.0;

      // order-flow component (max 6): unavailable/unmeasured data is worth
      // zero, never a guessed credit — this only ever ADDS confirmation, it
      // never substitutes for structure/liquidity/EV.
      f.order_flow_c = 0.0;
      if(orderflow.valid && opportunity.valid && opportunity.direction!=DIR_NONE)
        {
         if(orderflow.flow_valid)
           {
            double aligned_pulse = (opportunity.direction==DIR_LONG) ? orderflow.pulse : -orderflow.pulse;
            f.order_flow_c += AxfClamp(aligned_pulse/100.0*3.0,0.0,3.0);
           }
         if(orderflow.footprint_valid && orderflow.footprint_imbalance_dir==opportunity.direction)
            f.order_flow_c += AxfClamp(orderflow.footprint_stacked_bars*1.0,0.0,3.0);
        }

      double ruin_pen = 0;
      switch(ruin.state)
        {
         case RUIN_LOW: ruin_pen=0; break;
         case RUIN_NORMAL: ruin_pen=2; break;
         case RUIN_ELEVATED: ruin_pen=15; break;
         case RUIN_DEFENSIVE: ruin_pen=35; break;
         case RUIN_HALT: ruin_pen=100; break;
        }
      f.ruin_penalty = ruin_pen;

      double total = f.regime_c+f.structure_c+f.liquidity_c+f.volatility_c+f.momentum_c+
                     f.ev_c+f.asymmetry_c+f.execution_c+f.account_health_c+f.order_flow_c - f.ruin_penalty;
      f.total = AxfClamp(total,0,100);

      if(f.total>=m_thr_elite) f.grade="ELITE";
      else if(f.total>=m_thr_aplus) f.grade="A+";
      else if(f.total>=m_thr_a) f.grade="A";
      else if(f.total>=m_thr_b) f.grade="B";
      else f.grade="NO TRADE";

      return f;
     }
  };

//+------------------------------------------------------------------+
//| lightweight decision-hierarchy audit trail (Section 33)            |
//+------------------------------------------------------------------+
class CAxfDecisionAudit
  {
private:
   ENUM_AXF_DECISION m_last_decision;
   string            m_last_reason;

public:
                     CAxfDecisionAudit(void) { m_last_decision=DECISION_APPROVE; m_last_reason=""; }

   void              Reject(const ENUM_AXF_DECISION decision,const string reason)
     {
      m_last_decision = decision;
      m_last_reason = reason;
     }
   void              Approve(void) { m_last_decision=DECISION_APPROVE; m_last_reason="approved"; }

   ENUM_AXF_DECISION LastDecision(void) const { return m_last_decision; }
   string            LastReason(void) const { return m_last_reason; }
   bool              WasApproved(void) const { return m_last_decision==DECISION_APPROVE; }
  };

#endif // AXF_DIAGNOSTICENGINE_MQH
