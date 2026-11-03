//+------------------------------------------------------------------+
//|                                       DynamicPositionSizing.mqh|
//|  Dynamic Position Sizing / risk-multiplier stack (spec section 19),|
//|  institutional engine upgrade - ENGINEERING DESIGN, not paper-      |
//|  sourced. The paper (Malhotra SSRN 3306817) motivates WHY sizing     |
//|  should respond to drawdown/liquidity/regime conditions (its         |
//|  finding that 64% of funds exceeded 2x their own past max drawdown   |
//|  shows static sizing through changing conditions is dangerous) - it   |
//|  does not specify a multiplier formula, weights, or ceiling.          |
//|                                                                    |
//|  SIZE-DOWN ONLY, BY DESIGN: every component multiplier below is       |
//|  clamped to [0.0, 1.0] BEFORE combining, so the product of any         |
//|  combination can mechanically never exceed 1.0 - this stack can        |
//|  only ever REDUCE the caller-supplied base risk percent, never         |
//|  amplify it. m_maxTotalMultiplier is an additional, defensive           |
//|  ceiling clamp applied to the final product anyway (matches this        |
//|  codebase's established "clamp defensively even when the math          |
//|  should already guarantee the bound" pattern, e.g. AlphaEngine.mqh's    |
//|  weight normalization). This directly serves the standing project        |
//|  rule carried through this entire build: no martingale, no                |
//|  averaging down, no unlimited risk, ever.                                  |
//|                                                                    |
//|  KELLY IS DELIBERATELY EXCLUDED from this stack. KellyRuin.mqh's own       |
//|  header is explicit: "NEVER let this class's output authorize or           |
//|  size a live trade... This is diagnostics, nothing more." Feeding           |
//|  halfKellyFraction into a live sizing multiplier would directly             |
//|  violate that already-established constraint from an earlier phase           |
//|  of this build - so this engine does not read KellyRuin.mqh at all.           |
//|                                                                    |
//|  NO LOSS-CHASING: no component here reads a losing-streak length and         |
//|  responds by INCREASING size - that would be martingale-shaped                |
//|  regardless of what it's called. The only loss-streak signal in this          |
//|  pipeline (RiskEngine's ConsecutiveLossLimitBreached) is a HARD GATE           |
//|  in TradePermissionMatrix.mqh that blocks trading entirely, never a            |
//|  sizing input here.                                                             |
//|                                                                    |
//|  SIGNAL, NOT ACTION: Compute() below returns a recommended risk        |
//|  percent only - it never calls CRiskEngine::CalculateLotSize() or       |
//|  places an order itself, and is not wired into the live OnTick loop     |
//|  as part of this build.                                                  |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_DYNAMICPOSITIONSIZING_MQH
#define AX_DYNAMICPOSITIONSIZING_MQH
#include "Defs.mqh"

struct SAxSizingResult
  {
   double   baseRiskPercent;
   double   finalRiskPercent;
   double   totalMultiplier;
   double   decisionMultiplier;
   double   drawdownMultiplier;
   double   crisisMultiplier;
   double   alphaMultiplier;
   double   capacityMultiplier;
   string   reason;
  };

class CDynamicPositionSizing
  {
private:
   double            m_maxTotalMultiplier; // defensive ceiling backstop - see file header

   double            DecisionMultiplier(const ENUM_AX_FINAL_DECISION d) const
     {
      switch(d)
        {
         case AX_DECISION_TRADE:        return(1.0);
         case AX_DECISION_REDUCE_RISK:  return(0.5);
         case AX_DECISION_WAIT:         return(0.0); // WAIT means "not this bar" - zero size, not partial
         case AX_DECISION_NO_TRADE:     return(0.0);
         case AX_DECISION_HALT:         return(0.0);
         default:                        return(0.0);
        }
     }

   double            DrawdownMultiplier(const ENUM_AX_DRAWDOWN_STATE s) const
     {
      switch(s)
        {
         case AX_DD_STATE_NORMAL:    return(1.0);
         case AX_DD_STATE_CAUTION:   return(0.75);
         case AX_DD_STATE_DEFENSIVE: return(0.5);
         case AX_DD_STATE_SEVERE:    return(0.25);
         case AX_DD_STATE_HALT:      return(0.0);
         default:                     return(0.0);
        }
     }

   double            CrisisMultiplier(const ENUM_AX_CRISIS_LEVEL l) const
     {
      switch(l)
        {
         case AX_CRISIS_NONE:       return(1.0);
         case AX_CRISIS_ELEVATED:   return(0.75);
         case AX_CRISIS_CRISIS:     return(0.4);
         case AX_CRISIS_BLACK_SWAN: return(0.0);
         default:                    return(0.0);
        }
     }

   //--- simple linear pass-through, 0..100 -> 0.0..1.0: a stronger alpha read earns "up to full base   ---
   //--- risk", never a bonus beyond it (see file header - this stack is size-down only) ---
   double            AlphaMultiplier(const double alphaScore) const
     {
      return(AxClampD(alphaScore,0.0,100.0)/100.0);
     }

   //--- same linear pass-through convention as AlphaMultiplier - low market capacity (spec section 16)  ---
   //--- directly caps how much of the base risk this stack will recommend ---
   double            CapacityMultiplier(const double capacityScore) const
     {
      return(AxClampD(capacityScore,0.0,100.0)/100.0);
     }

public:
                     CDynamicPositionSizing(void)
     {
      m_maxTotalMultiplier=1.0;
     }

   void              Configure(const double maxTotalMultiplier)
     {
      //--- intentionally capped at 1.0, not just floored at 0 - see file header: this stack is         ---
      //--- documented, architecturally, as size-down only. A caller-supplied value above 1.0 would       ---
      //--- contradict that guarantee, so it is refused here rather than silently honored. ---
      m_maxTotalMultiplier=AxClampD(maxTotalMultiplier,0.0,1.0);
     }

   SAxSizingResult   Compute(const double baseRiskPercent,const ENUM_AX_FINAL_DECISION decision,
                              const ENUM_AX_DRAWDOWN_STATE drawdownState,const ENUM_AX_CRISIS_LEVEL crisisLevel,
                              const double alphaScore,const double capacityScore) const
     {
      SAxSizingResult r;
      r.baseRiskPercent = MathMax(0.0,baseRiskPercent);
      r.decisionMultiplier = DecisionMultiplier(decision);
      r.drawdownMultiplier = DrawdownMultiplier(drawdownState);
      r.crisisMultiplier   = CrisisMultiplier(crisisLevel);
      r.alphaMultiplier    = AlphaMultiplier(alphaScore);
      r.capacityMultiplier = CapacityMultiplier(capacityScore);

      double product = r.decisionMultiplier*r.drawdownMultiplier*r.crisisMultiplier*
                        r.alphaMultiplier*r.capacityMultiplier;
      r.totalMultiplier = AxClampD(product,0.0,m_maxTotalMultiplier);
      r.finalRiskPercent = r.baseRiskPercent*r.totalMultiplier;

      r.reason=StringFormat(
         "risk %.2f%% -> %.2f%% (x%.3f: decision=%.2f dd=%.2f crisis=%.2f alpha=%.2f capacity=%.2f)",
         r.baseRiskPercent,r.finalRiskPercent,r.totalMultiplier,r.decisionMultiplier,r.drawdownMultiplier,
         r.crisisMultiplier,r.alphaMultiplier,r.capacityMultiplier);
      return(r);
     }
  };
//+------------------------------------------------------------------+
#endif // AX_DYNAMICPOSITIONSIZING_MQH
