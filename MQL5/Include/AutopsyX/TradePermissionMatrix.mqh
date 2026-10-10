//+------------------------------------------------------------------+
//|                                       TradePermissionMatrix.mqh|
//|  Trade Permission Matrix (spec section 18/28) - the FINAL          |
//|  aggregation point of the institutional engine upgrade, where       |
//|  every engine built in Phases 2-7 converges into ONE decision.      |
//|  ENGINEERING DESIGN throughout - the paper (Malhotra SSRN 3306817)  |
//|  does not specify a gate count, gate list, or decision ladder; the  |
//|  15-gate structure and the HARD/SOFT distinction below are this     |
//|  codebase's own design, built to enforce the spec's own repeated    |
//|  instruction: "a signal must never automatically imply permission   |
//|  to trade" and "the setup exists, but market conditions are         |
//|  unsuitable for deploying risk" must be a real, reachable verdict.  |
//|                                                                    |
//|  DELIBERATELY THIN (matches InformationContentEngine.mqh's/         |
//|  HiddenRiskDetector.mqh's own convention): every gate reads an       |
//|  ALREADY-COMPUTED value from another engine. This class recomputes   |
//|  nothing - it is pure composition/gating, which is also why it is    |
//|  the one place safe to change the DECISION LADDER without touching   |
//|  any engine's own internal logic.                                    |
//|                                                                    |
//|  HARD gates (8): a single failure caps the decision at NO_TRADE or   |
//|  HALT regardless of every other gate - these are conditions where     |
//|  trading AT ALL right now is the problem, not sizing.                 |
//|   - HALT-tier (systemic - stop trading, not just this signal):        |
//|     DataIntegrity, CrisisBlackSwan, DrawdownHalt, ConsecutiveLossBreach,|
//|     ExecutionFailureBreach.                                            |
//|   - NO_TRADE-tier (this attempt specifically is invalid):              |
//|     VolatilityShock, CompositeDirectionTradeable, ExecutionEligibility.|
//|                                                                    |
//|  SOFT gates (7): quality/condition thresholds (Liquidity,            |
//|  ExecutionCost, PriceImpact, AlphaQuality, Capacity, Crowding,         |
//|  HiddenRisk) that scale the decision down (TRADE -> REDUCE_RISK ->     |
//|  WAIT -> NO_TRADE) by COUNT of soft failures rather than hard-        |
//|  blocking on any single one - exactly the spec's own "don't collapse  |
//|  everything into a TRADE/NO-TRADE binary" instruction.                 |
//|                                                                    |
//|  SIGNAL, NOT ACTION: like every engine in this build, Update()       |
//|  below returns a verdict only. It is not wired into the live         |
//|  OnTick loop as part of this build.                                  |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_TRADEPERMISSIONMATRIX_MQH
#define AX_TRADEPERMISSIONMATRIX_MQH
#include "Defs.mqh"

#define AX_GATE_COUNT      15
#define AX_HARD_GATE_COUNT 8
#define AX_SOFT_GATE_COUNT (AX_GATE_COUNT-AX_HARD_GATE_COUNT) // derived, not a second hardcoded literal
                                                                 // (code-review finding: a separately
                                                                 // hardcoded soft-gate total in the reason
                                                                 // string could drift out of sync if the
                                                                 // gate list is ever edited)

struct SAxGateResult
  {
   string   name;
   bool     passed;
   bool     isHardGate;
   bool     isHaltTier;   // only meaningful when isHardGate==true - see Update() below: set explicitly
                            // at each gate's own push site rather than inferred from its array index, so
                            // reordering/inserting gates later can't silently misclassify one (code-review
                            // finding)
   string   reason;
  };

struct SAxPermissionVerdict
  {
   SAxGateResult gates[AX_GATE_COUNT];
   int      hardGatesFailed;
   int      softGatesFailed;
   ENUM_AX_FINAL_DECISION decision;
   string   reason;
  };

//--- every field here is an ALREADY-COMPUTED read from another engine - this struct exists only to   ---
//--- keep CTradePermissionMatrix::Update()'s own parameter list from growing unmanageably long, not    ---
//--- to compute or own any of these values itself. ---
struct SAxPermissionInputs
  {
   bool     dataIntegrityOk;
   ENUM_AX_CRISIS_LEVEL crisisLevel;
   ENUM_AX_DRAWDOWN_STATE drawdownState;
   bool     consecutiveLossLimitBreached;
   bool     executionFailureLimitBreached;
   ENUM_AX_VOLATILITY_STATE volatilityState;
   ENUM_AX_COMPOSITE_DIRECTION compositeDirection;
   bool     executionEligible;             // CExecutionEligibility::Check() returned an ELIGIBLE_* verdict
   double   liquidityScore;
   double   executionCostScore;
   double   priceImpactScore;
   double   alphaScore;
   double   capacityScore;
   double   crowdingProxyScore;            // NOTE: soft-gate direction is INVERTED - HIGH is bad here
   double   hiddenRiskScore;               // NOTE: soft-gate direction is INVERTED - HIGH is bad here
  };

class CTradePermissionMatrix
  {
private:
   double            m_minLiquidityScore, m_minExecutionCostScore, m_minPriceImpactScore, m_minAlphaScore;
   double            m_minCapacityScore, m_maxCrowdingProxyScore, m_maxHiddenRiskScore;

   int               m_softFailReduceRiskCeiling; // soft fails <= this -> REDUCE_RISK
   int               m_softFailWaitCeiling;        // soft fails <= this (and > reduceRisk ceiling) -> WAIT
                                                     // soft fails beyond this -> NO_TRADE

public:
                     CTradePermissionMatrix(void)
     {
      m_minLiquidityScore=30.0; m_minExecutionCostScore=30.0; m_minPriceImpactScore=30.0;
      m_minAlphaScore=50.0; m_minCapacityScore=30.0; m_maxCrowdingProxyScore=80.0; m_maxHiddenRiskScore=70.0;
      m_softFailReduceRiskCeiling=2; m_softFailWaitCeiling=4;
     }

   void              Configure(const double minLiquidityScore,const double minExecutionCostScore,
                                const double minPriceImpactScore,const double minAlphaScore,
                                const double minCapacityScore,const double maxCrowdingProxyScore,
                                const double maxHiddenRiskScore,const int softFailReduceRiskCeiling,
                                const int softFailWaitCeiling)
     {
      m_minLiquidityScore=AxClampD(minLiquidityScore,0.0,100.0);
      m_minExecutionCostScore=AxClampD(minExecutionCostScore,0.0,100.0);
      m_minPriceImpactScore=AxClampD(minPriceImpactScore,0.0,100.0);
      m_minAlphaScore=AxClampD(minAlphaScore,0.0,100.0);
      m_minCapacityScore=AxClampD(minCapacityScore,0.0,100.0);
      m_maxCrowdingProxyScore=AxClampD(maxCrowdingProxyScore,0.0,100.0);
      m_maxHiddenRiskScore=AxClampD(maxHiddenRiskScore,0.0,100.0);
      m_softFailReduceRiskCeiling=MathMax(0,softFailReduceRiskCeiling);
      //--- guard against a transposed-argument call silently inverting the ladder (same recurring        ---
      //--- code-review finding/fix as DrawdownEngine.mqh, HiddenRiskDetector.mqh, CrisisEngine.mqh) ---
      m_softFailWaitCeiling=MathMax(m_softFailReduceRiskCeiling,softFailWaitCeiling);
     }

   SAxPermissionVerdict Update(const SAxPermissionInputs &in) const
     {
      SAxPermissionVerdict v;
      int idx=0;

      //--- HARD gates - HALT-tier (systemic): isHaltTier=true set explicitly at each push site, not     ---
      //--- inferred later from array position (code-review finding - see SAxGateResult's own comment). ---
      v.gates[idx].name="DataIntegrity"; v.gates[idx].isHardGate=true; v.gates[idx].isHaltTier=true;
      v.gates[idx].passed=in.dataIntegrityOk;
      v.gates[idx].reason=v.gates[idx].passed?"OK":"Data integrity check failed"; idx++;

      v.gates[idx].name="CrisisBlackSwan"; v.gates[idx].isHardGate=true; v.gates[idx].isHaltTier=true;
      v.gates[idx].passed=(in.crisisLevel!=AX_CRISIS_BLACK_SWAN);
      v.gates[idx].reason=v.gates[idx].passed?"OK":"Black-swan severity level active"; idx++;

      v.gates[idx].name="DrawdownHalt"; v.gates[idx].isHardGate=true; v.gates[idx].isHaltTier=true;
      v.gates[idx].passed=(in.drawdownState!=AX_DD_STATE_HALT);
      v.gates[idx].reason=v.gates[idx].passed?"OK":"Drawdown state is HALT"; idx++;

      v.gates[idx].name="ConsecutiveLossBreach"; v.gates[idx].isHardGate=true; v.gates[idx].isHaltTier=true;
      v.gates[idx].passed=(!in.consecutiveLossLimitBreached);
      v.gates[idx].reason=v.gates[idx].passed?"OK":"Consecutive-loss circuit breaker tripped"; idx++;

      v.gates[idx].name="ExecutionFailureBreach"; v.gates[idx].isHardGate=true; v.gates[idx].isHaltTier=true;
      v.gates[idx].passed=(!in.executionFailureLimitBreached);
      v.gates[idx].reason=v.gates[idx].passed?"OK":"Consecutive execution-failure circuit breaker tripped"; idx++;

      //--- HARD gates - NO_TRADE-tier (this attempt specifically) ---
      v.gates[idx].name="VolatilityShock"; v.gates[idx].isHardGate=true; v.gates[idx].isHaltTier=false;
      v.gates[idx].passed=(in.volatilityState!=AX_VOL_SHOCK);
      v.gates[idx].reason=v.gates[idx].passed?"OK":"Volatility shock regime active"; idx++;

      v.gates[idx].name="CompositeDirectionTradeable"; v.gates[idx].isHardGate=true; v.gates[idx].isHaltTier=false;
      v.gates[idx].passed=(in.compositeDirection==AX_COMPOSITE_BULLISH || in.compositeDirection==AX_COMPOSITE_BEARISH);
      v.gates[idx].reason=v.gates[idx].passed?"OK":
         StringFormat("Composite direction not tradeable (%s)",AxCompositeDirectionToString(in.compositeDirection)); idx++;

      v.gates[idx].name="ExecutionEligibility"; v.gates[idx].isHardGate=true; v.gates[idx].isHaltTier=false;
      v.gates[idx].passed=in.executionEligible;
      v.gates[idx].reason=v.gates[idx].passed?"OK":"Execution eligibility gate did not clear"; idx++;

      //--- SOFT gates - quality/condition thresholds, scale the decision by COUNT failed, never        ---
      //--- individually hard-block (spec's own "don't collapse into a binary" instruction). isHaltTier  ---
      //--- is meaningless for a soft gate but set false for a defined, non-garbage struct value anyway. ---
      v.gates[idx].name="Liquidity"; v.gates[idx].isHardGate=false; v.gates[idx].isHaltTier=false;
      v.gates[idx].passed=(in.liquidityScore>=m_minLiquidityScore);
      v.gates[idx].reason=StringFormat("liquidityScore=%.1f (min %.1f)",in.liquidityScore,m_minLiquidityScore); idx++;

      v.gates[idx].name="ExecutionCost"; v.gates[idx].isHardGate=false; v.gates[idx].isHaltTier=false;
      v.gates[idx].passed=(in.executionCostScore>=m_minExecutionCostScore);
      v.gates[idx].reason=StringFormat("executionCostScore=%.1f (min %.1f)",in.executionCostScore,m_minExecutionCostScore); idx++;

      v.gates[idx].name="PriceImpact"; v.gates[idx].isHardGate=false; v.gates[idx].isHaltTier=false;
      v.gates[idx].passed=(in.priceImpactScore>=m_minPriceImpactScore);
      v.gates[idx].reason=StringFormat("priceImpactScore=%.1f (min %.1f)",in.priceImpactScore,m_minPriceImpactScore); idx++;

      v.gates[idx].name="AlphaQuality"; v.gates[idx].isHardGate=false; v.gates[idx].isHaltTier=false;
      v.gates[idx].passed=(in.alphaScore>=m_minAlphaScore);
      v.gates[idx].reason=StringFormat("alphaScore=%.1f (min %.1f)",in.alphaScore,m_minAlphaScore); idx++;

      v.gates[idx].name="Capacity"; v.gates[idx].isHardGate=false; v.gates[idx].isHaltTier=false;
      v.gates[idx].passed=(in.capacityScore>=m_minCapacityScore);
      v.gates[idx].reason=StringFormat("capacityScore=%.1f (min %.1f)",in.capacityScore,m_minCapacityScore); idx++;

      v.gates[idx].name="Crowding"; v.gates[idx].isHardGate=false; v.gates[idx].isHaltTier=false;
      v.gates[idx].passed=(in.crowdingProxyScore<=m_maxCrowdingProxyScore); // inverted: high = bad
      v.gates[idx].reason=StringFormat("crowdingProxyScore=%.1f (max %.1f)",in.crowdingProxyScore,m_maxCrowdingProxyScore); idx++;

      v.gates[idx].name="HiddenRisk"; v.gates[idx].isHardGate=false; v.gates[idx].isHaltTier=false;
      v.gates[idx].passed=(in.hiddenRiskScore<=m_maxHiddenRiskScore); // inverted: high = bad
      v.gates[idx].reason=StringFormat("hiddenRiskScore=%.1f (max %.1f)",in.hiddenRiskScore,m_maxHiddenRiskScore); idx++;

      //--- idx now == AX_GATE_COUNT (15) - every gate slot has been assigned exactly once, in the order ---
      //--- declared above; nothing here depends on array size beyond that invariant. ---

      int hardFailedHalt=0, hardFailedNoTrade=0, softFailed=0;
      for(int i=0;i<AX_GATE_COUNT;i++)
        {
         if(v.gates[i].passed) continue;
         if(!v.gates[i].isHardGate) { softFailed++; continue; }
         //--- reads each gate's OWN isHaltTier field (set at its push site above), not an inferred index ---
         //--- range - a reordered or newly-inserted gate can't silently land in the wrong tier here.       ---
         if(v.gates[i].isHaltTier) hardFailedHalt++; else hardFailedNoTrade++;
        }
      v.hardGatesFailed = hardFailedHalt+hardFailedNoTrade;
      v.softGatesFailed = softFailed;

      if(hardFailedHalt>0)
         v.decision=AX_DECISION_HALT;
      else if(hardFailedNoTrade>0)
         v.decision=AX_DECISION_NO_TRADE;
      else if(softFailed<=m_softFailReduceRiskCeiling)
         v.decision=(softFailed==0)?AX_DECISION_TRADE:AX_DECISION_REDUCE_RISK;
      else if(softFailed<=m_softFailWaitCeiling)
         v.decision=AX_DECISION_WAIT;
      else
         v.decision=AX_DECISION_NO_TRADE;

      v.reason=StringFormat("decision=%s (hardFailed=%d [halt=%d,noTrade=%d] softFailed=%d/%d)",
                             AxFinalDecisionToString(v.decision),v.hardGatesFailed,hardFailedHalt,
                             hardFailedNoTrade,v.softGatesFailed,AX_SOFT_GATE_COUNT);
      return(v);
     }
  };
//+------------------------------------------------------------------+
#endif // AX_TRADEPERMISSIONMATRIX_MQH
