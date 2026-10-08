//+------------------------------------------------------------------+
//|                                                     AlphaEngine.mqh|
//|  Alpha Engine (institutional engine upgrade) - ENGINEERING        |
//|  DESIGN, not paper-sourced. The source paper (Malhotra SSRN         |
//|  3306817) discusses the SEVEN CRITERIA it used to review 400        |
//|  hedge-fund strategies (alpha, plausibility, technical profile,     |
//|  operational framework, portfolio risk, portfolio strategies,       |
//|  market crowding, sector capacity, alternative reusability -        |
//|  findings, "Findings" section, note the paper's own text lists      |
//|  more than seven items under that label) - it does NOT provide a    |
//|  formula for scoring a single trade's alpha. This engine's          |
//|  AlphaScore formula, every weight, and every threshold below are    |
//|  this codebase's own design.                                        |
//|                                                                    |
//|  Combines POSITIVE alignment components (how well macro/regime/     |
//|  liquidity/volatility/microstructure/technical-setup/execution-     |
//|  quality all support the proposed trade) against PENALTY            |
//|  components (execution cost, price impact, crowding, event risk,    |
//|  correlation risk) into one 0..100 score. Every weight is a          |
//|  Configure() parameter - none hardcoded as fixed truth.              |
//|                                                                    |
//|  Three inputs (crowding proxy, event risk, correlation risk)         |
//|  default to a NEUTRAL, non-penalizing value until the modules that   |
//|  compute them for real exist (crowding: Phase 7; event/news risk:    |
//|  no News Defense module built yet; correlation: this EA trades a     |
//|  single symbol, so there is nothing to correlate against yet). A     |
//|  caller passing the real default leaves those three components       |
//|  contributing ZERO penalty, honestly, rather than a fabricated        |
//|  guess standing in for a measurement that doesn't exist.              |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_ALPHAENGINE_MQH
#define AX_ALPHAENGINE_MQH
#include "Defs.mqh"

//--- neutral defaults for the three not-yet-measured penalty inputs - passing these leaves that    ---
//--- specific penalty at exactly zero, an explicit, documented "no information" state ---
#define AX_ALPHA_NEUTRAL_SCORE 100.0

struct SAxAlphaBreakdown
  {
   double   macroAlignment;
   double   regimeAlignment;
   double   liquidityAlignment;
   double   volatilityAlignment;
   double   microstructureAlignment;
   double   technicalSetupQuality;
   double   executionQualityAlignment;
   double   positiveScore;          // weighted average of the above, before penalties

   double   executionCostPenalty;   // 0..100, subtracted (already weight-scaled)
   double   priceImpactPenalty;
   double   crowdingPenalty;
   double   eventRiskPenalty;
   double   correlationRiskPenalty;
   double   totalPenalty;

   double   finalScore;             // clamp(positiveScore - totalPenalty, 0, 100)
   string   breakdown;
  };

class CAlphaEngine
  {
private:
   //--- positive-component weights ---
   double m_wMacro, m_wRegime, m_wLiquidity, m_wVolatility, m_wMicrostructure, m_wTechnical, m_wExecQuality;
   //--- penalty weights (0..1 - fraction of the (100-score) penalty gap actually applied) ---
   double m_wExecCostPenalty, m_wImpactPenalty, m_wCrowdingPenalty, m_wEventPenalty, m_wCorrelationPenalty;

   double            RegimeAlignmentScore(const ENUM_AX_REGIME regime) const
     {
      switch(regime)
        {
         case AX_REGIME_STRONG_TREND:    return(90.0);
         case AX_REGIME_BREAKOUT:        return(85.0);
         case AX_REGIME_TREND:           return(75.0);
         case AX_REGIME_RANGE:           return(50.0);
         case AX_REGIME_MEAN_REVERSION:  return(45.0);
         case AX_REGIME_HIGH_VOL:        return(40.0);
         case AX_REGIME_LOW_VOL:         return(35.0);
         case AX_REGIME_CHAOTIC:         return(10.0);
         case AX_REGIME_UNSAFE:          return(0.0);
        }
      return(50.0);
     }

   double            VolatilityAlignmentScore(const ENUM_AX_VOLATILITY_STATE state) const
     {
      switch(state)
        {
         case AX_VOL_NORMAL:  return(80.0);
         case AX_VOL_LOW:     return(60.0);
         case AX_VOL_HIGH:    return(55.0);
         case AX_VOL_EXTREME: return(20.0);
         case AX_VOL_SHOCK:   return(5.0);
        }
      return(50.0);
     }

   double            MacroAlignmentScore(const ENUM_AX_MACRO_BIAS bias,const ENUM_AX_DIR proposedDir) const
     {
      if(proposedDir==AX_DIR_NONE) return(50.0); // no proposed direction to agree/disagree with -
                                                   // neutral, not "disagreement" (code-review finding)
      if(bias==AX_MACRO_DATA_UNAVAILABLE || bias==AX_MACRO_NEUTRAL) return(50.0); // no penalty for
                                                                                    // missing/neutral
                                                                                    // macro data - Layer 1
                                                                                    // is best-effort
      bool bullish = (bias==AX_MACRO_BULLISH);
      bool agreesWithBuy  = bullish && proposedDir==AX_DIR_BUY;
      bool agreesWithSell = !bullish && proposedDir==AX_DIR_SELL;
      return((agreesWithBuy||agreesWithSell) ? 85.0 : 15.0);
     }

   //--- microstructure alignment: does the inferred signal pressure (CInformationContentEngine) agree ---
   //--- with the proposed direction, and how strongly? 50 = no edge either way. ---
   double            MicrostructureAlignmentScore(const double signalPressure,const ENUM_AX_DIR proposedDir) const
     {
      if(proposedDir==AX_DIR_NONE) return(50.0); // no proposed direction - neutral, not an active
                                                   // penalty regardless of signalPressure's sign
                                                   // (code-review finding)
      double magnitude = MathAbs(signalPressure)/2.0; // signalPressure is -100..100 -> magnitude 0..50
      bool agrees = (proposedDir==AX_DIR_BUY && signalPressure>0) ||
                    (proposedDir==AX_DIR_SELL && signalPressure<0);
      return(AxClampD(50.0 + (agrees ? magnitude : -magnitude),0.0,100.0));
     }

public:
                     CAlphaEngine(void)
     {
      m_wMacro=10; m_wRegime=20; m_wLiquidity=15; m_wVolatility=10; m_wMicrostructure=15;
      m_wTechnical=20; m_wExecQuality=10;
      m_wExecCostPenalty=0.5; m_wImpactPenalty=0.5; m_wCrowdingPenalty=0.3;
      m_wEventPenalty=0.3; m_wCorrelationPenalty=0.2;
     }

   void              Configure(const double wMacro,const double wRegime,const double wLiquidity,
                                const double wVolatility,const double wMicrostructure,const double wTechnical,
                                const double wExecQuality,const double wExecCostPenalty,
                                const double wImpactPenalty,const double wCrowdingPenalty,
                                const double wEventPenalty,const double wCorrelationPenalty)
     {
      m_wMacro=MathMax(0,wMacro); m_wRegime=MathMax(0,wRegime); m_wLiquidity=MathMax(0,wLiquidity);
      m_wVolatility=MathMax(0,wVolatility); m_wMicrostructure=MathMax(0,wMicrostructure);
      m_wTechnical=MathMax(0,wTechnical); m_wExecQuality=MathMax(0,wExecQuality);
      m_wExecCostPenalty=AxClampD(wExecCostPenalty,0.0,1.0);
      m_wImpactPenalty=AxClampD(wImpactPenalty,0.0,1.0);
      m_wCrowdingPenalty=AxClampD(wCrowdingPenalty,0.0,1.0);
      m_wEventPenalty=AxClampD(wEventPenalty,0.0,1.0);
      m_wCorrelationPenalty=AxClampD(wCorrelationPenalty,0.0,1.0);
     }

   //--- crowdingProxyScore/eventRiskScore/correlationRiskScore: pass AX_ALPHA_NEUTRAL_SCORE (100) for ---
   //--- any of these that don't yet have a real measurement behind them - see file header. ---
   SAxAlphaBreakdown ComputeAlphaScore(const ENUM_AX_MACRO_BIAS macroBias,const ENUM_AX_DIR proposedDir,
                                        const ENUM_AX_REGIME regime,const double liquidityScore,
                                        const ENUM_AX_VOLATILITY_STATE volState,const double signalPressure,
                                        const double technicalSetupScore,const double executionQualityScore,
                                        const double executionCostScore,const double priceImpactScore,
                                        const double crowdingProxyScore,const double eventRiskScore,
                                        const double correlationRiskScore) const
     {
      SAxAlphaBreakdown b;
      b.macroAlignment           = MacroAlignmentScore(macroBias,proposedDir);
      b.regimeAlignment          = RegimeAlignmentScore(regime);
      b.liquidityAlignment       = AxClampD(liquidityScore,0.0,100.0);
      b.volatilityAlignment      = VolatilityAlignmentScore(volState);
      b.microstructureAlignment  = MicrostructureAlignmentScore(signalPressure,proposedDir);
      b.technicalSetupQuality    = AxClampD(technicalSetupScore,0.0,100.0);
      b.executionQualityAlignment= AxClampD(executionQualityScore,0.0,100.0);

      double posWeight = m_wMacro+m_wRegime+m_wLiquidity+m_wVolatility+m_wMicrostructure+
                          m_wTechnical+m_wExecQuality;
      b.positiveScore = (posWeight>0) ?
         (b.macroAlignment*m_wMacro + b.regimeAlignment*m_wRegime + b.liquidityAlignment*m_wLiquidity +
          b.volatilityAlignment*m_wVolatility + b.microstructureAlignment*m_wMicrostructure +
          b.technicalSetupQuality*m_wTechnical + b.executionQualityAlignment*m_wExecQuality)/posWeight
         : 0.0;

      //--- each penalty is (100-score) scaled by its own NORMALIZED weight (weight / sum of all       ---
      //--- penalty weights) - a score of 100 (perfect) on any penalty input contributes exactly zero   ---
      //--- penalty, and totalPenalty itself is guaranteed to stay within 0..100 regardless of how the   ---
      //--- five penalty weights are configured (they no longer need to sum to 1). Without this          ---
      //--- normalization, default weights alone already summed to 1.8, so a worst-case set of inputs    ---
      //--- produced a totalPenalty of 180 on a field documented as 0..100 - finalScore's own clamp hid  ---
      //--- the overflow, but the raw totalPenalty/breakdown values were silently off-scale for any      ---
      //--- caller reading them directly rather than only finalScore (code-review finding). ---
      double penWeight = m_wExecCostPenalty+m_wImpactPenalty+m_wCrowdingPenalty+m_wEventPenalty+m_wCorrelationPenalty;
      double penScale = (penWeight>0) ? 1.0/penWeight : 0.0;
      b.executionCostPenalty    = (100.0-AxClampD(executionCostScore,0.0,100.0))*m_wExecCostPenalty*penScale;
      b.priceImpactPenalty      = (100.0-AxClampD(priceImpactScore,0.0,100.0))*m_wImpactPenalty*penScale;
      b.crowdingPenalty         = (100.0-AxClampD(crowdingProxyScore,0.0,100.0))*m_wCrowdingPenalty*penScale;
      b.eventRiskPenalty        = (100.0-AxClampD(eventRiskScore,0.0,100.0))*m_wEventPenalty*penScale;
      b.correlationRiskPenalty  = (100.0-AxClampD(correlationRiskScore,0.0,100.0))*m_wCorrelationPenalty*penScale;
      b.totalPenalty = b.executionCostPenalty+b.priceImpactPenalty+b.crowdingPenalty+
                        b.eventRiskPenalty+b.correlationRiskPenalty;

      b.finalScore = AxClampD(b.positiveScore-b.totalPenalty,0.0,100.0);

      b.breakdown = StringFormat(
         "macro=%.0f regime=%.0f liq=%.0f vol=%.0f micro=%.0f tech=%.0f exec=%.0f | positive=%.1f | "
         "penalties: cost=%.1f impact=%.1f crowd=%.1f event=%.1f corr=%.1f total=%.1f | final=%.1f",
         b.macroAlignment,b.regimeAlignment,b.liquidityAlignment,b.volatilityAlignment,
         b.microstructureAlignment,b.technicalSetupQuality,b.executionQualityAlignment,b.positiveScore,
         b.executionCostPenalty,b.priceImpactPenalty,b.crowdingPenalty,b.eventRiskPenalty,
         b.correlationRiskPenalty,b.totalPenalty,b.finalScore);

      return(b);
     }
  };
//+------------------------------------------------------------------+
#endif // AX_ALPHAENGINE_MQH
