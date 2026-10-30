//+------------------------------------------------------------------+
//|                                       RegimeIntelligenceEngine.mqh|
//|  Regime Intelligence layer (10X Market Intelligence upgrade,       |
//|  Phase 3a) - ENGINEERING DESIGN, not paper-sourced.                 |
//|                                                                    |
//|  CORRECTION AGAINST docs/AUDIT_10X_MARKET_INTELLIGENCE.md: that      |
//|  Phase 1 audit claimed "no R1-R8 taxonomy" existed and that a new     |
//|  regime-classification engine would need building. That was WRONG -    |
//|  the audit's own interface grep used a regex that only matched a        |
//|  bare "ENUM_" token followed by whitespace, which silently failed on     |
//|  every real enum name in this codebase (they are all "ENUM_AX_...",       |
//|  no space after "ENUM_"). CRegimeEngine::Regime() ALREADY returns a         |
//|  live, wired, 9-state ENUM_AX_REGIME (TREND/STRONG_TREND/BREAKOUT/           |
//|  RANGE/MEAN_REVERSION/HIGH_VOL/LOW_VOL/CHAOTIC/UNSAFE - see Defs.mqh),         |
//|  already consumed by AlphaEngine, Dashboard, PerformanceAttribution.           |
//|  Building a second, competing R1-R8 taxonomy now would have been            |
//|  exactly the duplicate-engine mistake the audit itself warned against -       |
//|  caught before writing any code for it, not after.                              |
//|                                                                    |
//|  Scope, corrected accordingly: this file does NOT reclassify regime.        |
//|  It reads CRegimeEngine::Regime() (LIVE, WIRED, UNMODIFIED - this file          |
//|  never edits Regime.mqh, per "preserve existing behavior") and adds ONLY         |
//|  the genuinely missing fields the 10X spec's own §4 asks for that no              |
//|  existing engine tracks: PREVIOUS_REGIME, REGIME_CHANGE, REGIME_AGE,                |
//|  REGIME_STABILITY, REGIME_CONFIDENCE, and a thin macro-agreement cross-               |
//|  check. REGIME_TRANSITION_PROBABILITY is explicitly NOT built here - that              |
//|  is the future, separately-approved State Transition Engine's own job                  |
//|  (kept per the confirmed architectural decision, not yet authorized to                  |
//|  build). "Regime change magnitude" is also NOT built: ENUM_AX_REGIME's                    |
//|  9 states are categorical, not an ordered scale, and no consumer needs a                   |
//|  numeric distance between them yet - fabricating one now would be                           |
//|  speculative infrastructure. A caller can already see (previousRegime,                        |
//|  currentRegime) and define its own notion of distance if one is ever needed.                    |
//|                                                                    |
//|  REGIME_CONFIDENCE is grounded in the EXACT thresholds CRegimeEngine's        |
//|  own private Classify() uses (r2>=0.70/0.40/0.20, volRatio>=1.6/<=0.55/>2.2 -   |
//|  read directly from Regime.mqh's own source, not guessed), expressed as how     |
//|  far past the deciding threshold the current reading sits - an engineering       |
//|  design heuristic, like AlphaEngine's own RegimeAlignmentScore, not a             |
//|  statistically fitted probability. ONE exception: AX_REGIME_BREAKOUT's own         |
//|  internal range-expansion ratio (DetectBreakout()'s own 1.8x threshold test)         |
//|  is NOT exposed by any public CRegimeEngine accessor - recomputing it here            |
//|  would duplicate that private method's own logic (against this codebase's own          |
//|  "deliberately thin" convention), so BREAKOUT gets a fixed, honestly-labeled              |
//|  confidence tier instead of a fabricated margin.                                            |
//|                                                                    |
//|  MACRO AGREEMENT is NOT the Causality/Information Transmission Engine        |
//|  (spec §7) - that is a separate, later, unbuilt phase (lead-lag regression,     |
//|  rolling/lagged correlation, information decay, a causal graph). This is a       |
//|  much thinner same-bar directional agreement check between two ALREADY           |
//|  EXISTING regime-layer engines (CRegimeEngine's own slope direction vs             |
//|  CMacroRegimeEngine's already-computed Bias()) - a real, currently available        |
//|  signal, not a proxy for the future engine's own methodology.                         |
//|                                                                    |
//|  DELIBERATELY THIN: never calls CRegimeEngine::Update()/Init() and never       |
//|  reads MarketData/price bars directly - takes an already-updated CRegimeEngine  |
//|  and CMacroRegimeEngine by const reference and only reads their public           |
//|  accessors. Bar-level, not tick-level (Sample() no-ops except on the first        |
//|  tick after a new bar on the caller-supplied timeframe, matching                    |
//|  MarketStateEngine.mqh's own established new-bar-detection convention).              |
//|                                                                    |
//|  SIGNAL, NOT ACTION, NOT WIRED: like every engine in this build, never calls   |
//|  CTrade, not #include'd by the live EA, not part of OnInit/OnTick/OnTimer.       |
//|                                                                    |
//|  VERIFICATION STATUS: balance-checked and code-reviewed only. No MQL5         |
//|  compiler available in this build environment - COMPILATION NOT VERIFIED.        |
//|  No ablation test - no caller exists yet, so there is nothing to ablate           |
//|  against (same honest limitation as MarketStateEngine.mqh's own Phase 2 report).    |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_REGIMEINTELLIGENCEENGINE_MQH
#define AX_REGIMEINTELLIGENCEENGINE_MQH
#include "Defs.mqh"
#include "Regime.mqh"
#include "MacroRegime.mqh"

struct SAxRegimeIntelligence
  {
   datetime          timestamp;             // the closed bar this sample describes
   ENUM_AX_REGIME    currentRegime;         // CRegimeEngine::Regime() - reused, never reclassified here
   ENUM_AX_REGIME    previousRegime;        // meaningless when hasPreviousRegime==false (this engine's
                                              // very first sample - nothing to compare against yet)
   bool              hasPreviousRegime;
   bool              regimeChanged;
   int               regimeAgeBars;         // bars since the last regime change, 0 on the change bar itself
   double            regimeStability;       // 0..100: % of the recent history window matching currentRegime
   double            regimeConfidence;      // 0..100: engineering-design heuristic - see file header
   bool              macroDataAvailable;    // false if macroSymbol not configured / unreadable / stale
   double            macroAgreementScore;   // -100 (opposes) / 0 (neutral or unavailable) / +100 (agrees)
  };

class CRegimeIntelligenceEngine
  {
private:
   int               m_historyCapacity;
   ENUM_AX_REGIME    m_history[];
   int               m_historyCount;
   int               m_historyHead;

   ENUM_AX_REGIME    m_previousRegime;
   bool              m_hasPreviousRegime;
   int               m_ageBars;
   datetime          m_lastSampledBarTime;

   //--- grounded in CRegimeEngine::Classify()'s own exact thresholds (Regime.mqh source, not guessed) - ---
   //--- see file header for why BREAKOUT is a fixed tier rather than a computed margin. ---
   double            ComputeConfidence(const ENUM_AX_REGIME regime,const double volRatio,const double r2) const
     {
      switch(regime)
        {
         case AX_REGIME_UNSAFE:
            return(0.0); // not a real classification - insufficient ATR history, not a confident read
         case AX_REGIME_CHAOTIC:
           {
            // erratic = volRatio>2.2 && r2<0.25 - confidence is the WEAKER of the two margins, since
            // both conditions must hold and the classification is only as solid as its shakiest leg
            double volMargin = AxClampD((volRatio-2.2)/2.2*100.0,0.0,100.0);
            double r2Margin  = AxClampD((0.25-r2)/0.25*100.0,0.0,100.0);
            return(MathMin(volMargin,r2Margin));
           }
         case AX_REGIME_BREAKOUT:
            // DetectBreakout()'s own range-expansion ratio isn't publicly exposed - see file header
            return(60.0);
         case AX_REGIME_STRONG_TREND:
           {
            // STRONG_TREND requires BOTH r2>=0.70 AND volRatio>=1.15 (Classify()'s own deciding        ---
            // condition vs plain TREND) - confidence is the WEAKER of the two margins, same "weakest    ---
            // leg" logic as CHAOTIC above (code-review finding: an earlier draft scored only the r2      ---
            // gate, which is guaranteed true just to reach this branch at all, and never referenced       ---
            // volRatio - the actual STRONG_TREND-vs-TREND deciding factor - which could report near-        ---
            // certain confidence for a reading one tick from flipping to TREND, or near-zero confidence      ---
            // for the most clear-cut STRONG_TREND reading possible). ---
            double r2Margin  = AxClampD((r2-0.70)/0.30*100.0,0.0,100.0);
            double volMargin = AxClampD((volRatio-1.15)/1.15*100.0,0.0,100.0);
            return(MathMin(r2Margin,volMargin));
           }
         case AX_REGIME_TREND:
            // reached via r2>=0.70 with either a flat/zero slope OR a real trend that just misses the
            // volRatio>=1.15 STRONG_TREND gate, or via the separate r2>=0.40 branch - distance above
            // the LOWER of the two r2 gates this branch can actually be entered from
            return(AxClampD((r2-0.40)/0.60*100.0,0.0,100.0));
         case AX_REGIME_HIGH_VOL:
            return(AxClampD((volRatio-1.6)/1.6*100.0,0.0,100.0));
         case AX_REGIME_LOW_VOL:
            return(AxClampD((0.55-volRatio)/0.55*100.0,0.0,100.0));
         case AX_REGIME_MEAN_REVERSION:
            return(AxClampD((0.20-r2)/0.20*100.0,0.0,100.0));
         case AX_REGIME_RANGE:
            // residual bucket (0.20<=r2<0.40, entered only after every other branch above has already
            // failed) - confidence reflects how centered r2 sits within that band, not volRatio, as a
            // deliberate simplification (see file header)
           {
            double distToLow  = AxClampD((r2-0.20)/0.10*100.0,0.0,100.0);
            double distToHigh = AxClampD((0.40-r2)/0.10*100.0,0.0,100.0);
            return(MathMin(distToLow,distToHigh));
           }
        }
      return(0.0);
     }

public:
                     CRegimeIntelligenceEngine(void)
     {
      m_historyCapacity=20; m_historyCount=0; m_historyHead=0;
      m_hasPreviousRegime=false; m_previousRegime=AX_REGIME_UNSAFE;
      m_ageBars=0; m_lastSampledBarTime=0;
      ArrayResize(m_history,m_historyCapacity);
     }

   void              Configure(const int historyCapacity)
     {
      m_historyCapacity = MathMax(2,historyCapacity);
      ArrayResize(m_history,m_historyCapacity);
      m_historyCount=0; m_historyHead=0;
      m_hasPreviousRegime=false; m_previousRegime=AX_REGIME_UNSAFE;
      m_ageBars=0; m_lastSampledBarTime=0;
     }

   //--- call every tick; no-ops (returns false) unless a NEW bar has closed on `regimeTimeframe` since  ---
   //--- the last successful sample - matches this codebase's established new-bar-detection convention.   ---
   //--- regime/macro must already be CRegimeEngine::Update()'d / current for this tick - never called      ---
   //--- here (deliberately thin, file header). macroSymbol="" is a valid, honest "not configured" input -    ---
   //--- macroDataAvailable will simply read false, matching CMacroRegimeEngine's own convention. ---
   bool              Sample(const string symbol,const ENUM_TIMEFRAMES regimeTimeframe,
                             const CRegimeEngine &regime,const CMacroRegimeEngine &macro,
                             const string macroSymbol,SAxRegimeIntelligence &out)
     {
      datetime lastClosedBarTime = iTime(symbol,regimeTimeframe,1);
      if(lastClosedBarTime<=0) return(false);
      if(lastClosedBarTime==m_lastSampledBarTime) return(false);

      SAxRegimeIntelligence s;
      s.timestamp = lastClosedBarTime;
      s.currentRegime = regime.Regime();

      s.hasPreviousRegime = m_hasPreviousRegime;
      s.previousRegime = m_previousRegime;
      s.regimeChanged = m_hasPreviousRegime && (s.currentRegime!=m_previousRegime);

      if(!m_hasPreviousRegime || s.regimeChanged) m_ageBars=0;
      else m_ageBars++;
      s.regimeAgeBars = m_ageBars;

      m_history[m_historyHead] = s.currentRegime;
      m_historyHead = (m_historyHead+1) % m_historyCapacity;
      if(m_historyCount<m_historyCapacity) m_historyCount++;

      int matches=0;
      for(int i=0;i<m_historyCount;i++) if(m_history[i]==s.currentRegime) matches++;
      s.regimeStability = (m_historyCount>0) ? (100.0*matches/m_historyCount) : 0.0;

      s.regimeConfidence = ComputeConfidence(s.currentRegime,regime.VolRatio(),regime.R2());

      string macroReason;
      ENUM_AX_MACRO_BIAS bias = macro.Bias(macroSymbol,macroReason);
      s.macroDataAvailable = (bias!=AX_MACRO_DATA_UNAVAILABLE);
      if(!s.macroDataAvailable)
        {
         s.macroAgreementScore = 0.0;
        }
      else
        {
         double slope = regime.Slope();
         int localDir = (slope>0) ? 1 : (slope<0 ? -1 : 0);
         int macroDir = (bias==AX_MACRO_BULLISH) ? 1 : (bias==AX_MACRO_BEARISH ? -1 : 0);
         if(localDir==0 || macroDir==0) s.macroAgreementScore=0.0;
         else s.macroAgreementScore = (localDir==macroDir) ? 100.0 : -100.0;
        }

      m_previousRegime = s.currentRegime;
      m_hasPreviousRegime = true;
      m_lastSampledBarTime = lastClosedBarTime;

      out = s;
      return(true);
     }
  };
//+------------------------------------------------------------------+
#endif // AX_REGIMEINTELLIGENCEENGINE_MQH
