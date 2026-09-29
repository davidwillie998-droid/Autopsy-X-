//+------------------------------------------------------------------+
//|                                       RegimeClassifierEngine.mqh|
//|  Regime Engine (10X Market Intelligence upgrade, Phase 3) -        |
//|  ENGINEERING DESIGN, not paper-sourced. Produces the R1-R8           |
//|  direction-aware classification the spec's own Phase 3 authorization  |
//|  asks for (Persistent Bullish/Bearish Trend, Bullish Unstable,          |
//|  Bearish Transition, Range/Chop, Volatility Shock, Information           |
//|  Conflict, Structural Break).                                             |
//|                                                                    |
//|  NOT a duplicate of CRegimeEngine's own 9-state ENUM_AX_REGIME (see        |
//|  RegimeIntelligenceEngine.mqh's own header for that engine's role)          |
//|  or of CVolatilityEngine's 5-state ENUM_AX_VOLATILITY_STATE. Neither         |
//|  of those carries BULLISH/BEARISH direction, and neither has a Range/         |
//|  Chop-vs-Shock-vs-Conflict-vs-Structural-Break taxonomy - this class            |
//|  FUSES already-computed reads from four existing/prior-phase engines             |
//|  into the genuinely new taxonomy requested, recomputing none of their              |
//|  underlying logic:                                                                    |
//|   - CRegimeEngine (LIVE, WIRED, UNMODIFIED): Regime()/Slope()/VolRatio()                 |
//|   - CVolatilityEngine (dormant, UNMODIFIED): State()                                       |
//|   - CMomentumEngine (LIVE, WIRED, UNMODIFIED): PersistenceRatio()                             |
//|   - CRegimeIntelligenceEngine's own OUTPUT (Phase 3a, dormant, UNMODIFIED):                     |
//|     a caller-supplied SAxRegimeIntelligence snapshot for THIS SAME bar -                          |
//|     regimeAgeBars/regimeStability/regimeConfidence/macroAgreementScore -                            |
//|     reused directly rather than re-derived, per "do not create duplicate                             |
//|     data engines."                                                                                       |
//|                                                                    |
//|  "Do not blindly hard-code labels from indicators" (this phase's own          |
//|  instruction): every branch below cites the SPECIFIC measurable input(s)        |
//|  that produced it in supportingFactors[], and any real countervailing            |
//|  evidence in conflictingFactors[] - see Sample().                                    |
//|                                                                    |
//|  HONEST LIMITATIONS, stated plainly rather than glossed over:                    |
//|   - R6 VOLATILITY SHOCK: CVolatilityEngine.State()==AX_VOL_SHOCK is a               |
//|     direct, already-computed reuse (that engine's own m_shockAccelPct is             |
//|     a private, Configure()-set threshold, not exposed - confidence here is             |
//|     therefore a fixed, honestly-labeled tier, not a computed margin, same                |
//|     limitation as Phase 3a's own BREAKOUT confidence).                                       |
//|   - R7 INFORMATION CONFLICT is NOT the future Causality/Information Transmission                |
//|     Engine (spec section 7) - no lead-lag, no rolling/lagged correlation, no                        |
//|     information decay. It is the same thin, same-bar macro-vs-local directional                       |
//|     agreement check Phase 3a already built (macroAgreementScore), just promoted                          |
//|     to a first-class regime label when it fires alongside a clear local direction.                          |
//|   - R8 STRUCTURAL BREAK is a SELF-CONTAINED proxy (CHAOTIC with volRatio at least                            |
//|     DOUBLE CRegimeEngine's own erratic threshold, i.e. an unusually extreme reading                             |
//|     even for an already-erratic regime), NOT the future Shock DNA Engine (spec section                           |
//|     8, which would classify shock TYPE, duration, recovery time, MAE/MFE). Deliberately                            |
//|     did NOT pull in CCrisisEngine for this: that engine's Update() also requires a                                    |
//|     CDynamicDrawdownEngine reading, an account-level concern with no place in a market-                                 |
//|     regime classifier - adding it would couple two unrelated subsystems for one field.                                    |
//|   - The requested taxonomy is asymmetric by its own wording (R2 "Bullish Unstable" vs                                       |
//|     R4 "Bearish Transition" - not a matching pair). This engine does not invent the two                                       |
//|     missing symmetric labels (a "Bearish Unstable"/"Bullish Transition"): any non-persistent                                     |
//|     bullish reading (fresh OR merely unstable) reports R2, and any non-persistent bearish                                          |
//|     reading (fresh OR merely unstable) reports R4, exactly matching the given label set.                                              |
//|   - CHAOTIC readings that do NOT clear the R8 double-threshold, and BREAKOUT readings                                                    |
//|     with an exactly-zero slope (rare), fall through to R3 Range/Chop as the closest                                                          |
//|     available bucket - an approximation, not a perfect semantic fit, documented here                                                            |
//|     as an ambiguous state per this phase's own "document ambiguous states" instruction.                                                            |
//|                                                                    |
//|  DELIBERATELY THIN, BAR-LEVEL, SIGNAL-ONLY, NOT WIRED: matches every other engine        |
//|  in this build. Never calls CRegimeEngine::Update()/Init(), never calls CTrade, not         |
//|  #include'd by the live EA.                                                                    |
//|                                                                    |
//|  VERIFICATION STATUS: balance-checked and code-reviewed only. COMPILATION NOT       |
//|  VERIFIED - no MQL5 compiler available in this build environment. No ablation test -   |
//|  no caller exists yet (see docs/PHASE3_REGIME_VOLATILITY_REPORT.md for the full          |
//|  explanation).                                                                              |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_REGIMECLASSIFIERENGINE_MQH
#define AX_REGIMECLASSIFIERENGINE_MQH
#include "Defs.mqh"
#include "Regime.mqh"
#include "VolatilityEngine.mqh"
#include "Momentum.mqh"
#include "RegimeIntelligenceEngine.mqh"

//--- mirrors Regime.mqh's own private erratic-threshold literal (its Classify(): "erratic =             ---
//--- volRatio>2.2 && r2<0.25", not exposed by any public accessor) - named and centralized here, not     ---
//--- a bare literal repeated inline, specifically so a future change to Regime.mqh's own threshold has    ---
//--- exactly one place in THIS file to update, not several silently-drifting copies (code-review finding:  ---
//--- an earlier draft repeated the bare "2.2" three times across this file). Still requires a human to       ---
//--- notice and update both files - there is no compiler check across the two, since MQL5 has no way for      ---
//--- one file to read another's private constant. ---
#define AX_REGIMECLASSIFIER_ERRATIC_MIRROR 2.2

enum ENUM_AX_REGIME_CLASS
  {
   AX_RC_UNAVAILABLE = 0,              // data quality failure - not a real classification
   AX_RC_PERSISTENT_BULLISH_TREND,     // R1
   AX_RC_BULLISH_UNSTABLE,             // R2
   AX_RC_RANGE_CHOP,                   // R3
   AX_RC_BEARISH_TRANSITION,           // R4
   AX_RC_PERSISTENT_BEARISH_TREND,     // R5
   AX_RC_VOLATILITY_SHOCK,             // R6
   AX_RC_INFORMATION_CONFLICT,         // R7
   AX_RC_STRUCTURAL_BREAK              // R8
  };

string AxRegimeClassToString(const ENUM_AX_REGIME_CLASS c)
  {
   switch(c)
     {
      case AX_RC_PERSISTENT_BULLISH_TREND: return("R1 Persistent Bullish Trend");
      case AX_RC_BULLISH_UNSTABLE:         return("R2 Bullish Unstable");
      case AX_RC_RANGE_CHOP:               return("R3 Range/Chop");
      case AX_RC_BEARISH_TRANSITION:       return("R4 Bearish Transition");
      case AX_RC_PERSISTENT_BEARISH_TREND: return("R5 Persistent Bearish Trend");
      case AX_RC_VOLATILITY_SHOCK:         return("R6 Volatility Shock");
      case AX_RC_INFORMATION_CONFLICT:     return("R7 Information Conflict");
      case AX_RC_STRUCTURAL_BREAK:         return("R8 Structural Break");
      case AX_RC_UNAVAILABLE:              return("Unavailable");
     }
   return("Unavailable");
  }

struct SAxRegimeClassification
  {
   datetime             timestamp;
   bool                 dataQualityOk;
   string               dataQualityReason;

   ENUM_AX_REGIME_CLASS regime;
   double               regimeConfidence;      // 0..100 - see file header for per-branch grounding
   int                  regimeAgeBars;          // bars since THIS classification (not the underlying
                                                  // CRegimeEngine enum) last changed
   bool                 hasPreviousRegime;
   ENUM_AX_REGIME_CLASS previousRegime;
   bool                 transitionDetected;
   string               transitionDescription;

   string               supportingFactors[];
   string               conflictingFactors[];
  };

class CRegimeClassifierEngine
  {
private:
   ENUM_AX_REGIME_CLASS m_previousClass;
   bool                 m_hasPrevious;
   int                  m_ageBars;
   datetime             m_lastSampledBarTime;

   //--- OWN direction-persistence tracker, keyed on SIGN (bullish/bearish/none), deliberately NOT on      ---
   //--- regimeIntel's exact-ENUM_AX_REGIME history (code-review finding: STRONG_TREND and TREND flip       ---
   //--- back and forth routinely as volRatio drifts across CRegimeEngine's own 1.15 gate with no             ---
   //--- hysteresis, which reset Phase 3a's own enum-exact age/stability every time even though the            ---
   //--- DIRECTION never changed - using those fields here could keep "established" false forever for a          ---
   //--- genuinely persistent trend). This engine owns its own read for exactly this reason - same               ---
   //--- "each engine owns its own read" convention already established throughout this codebase. ---
   int                  m_dirHistoryCapacity;
   int                  m_dirHistory[];      // -1 bearish / 0 none / +1 bullish, one slot per sampled bar
   int                  m_dirHistoryCount;
   int                  m_dirHistoryHead;
   int                  m_directionAgeBars;  // consecutive bars with an UNCHANGED nonzero sign
   int                  m_lastDirectionSign; // last nonzero sign seen - a sign==0 bar neither advances

   int                  m_minAgeForPersistent;      // bars a directional read must hold before "persistent"
   double               m_minStabilityForPersistent;// this engine's own direction-sign stability floor
   double               m_minMomentumForPersistent;  // CMomentumEngine::PersistenceRatio() floor
   double               m_structuralBreakVolRatioMult; // multiple of CRegimeEngine's own 2.2 erratic
                                                          // threshold required before calling it R8

   void              AppendFactor(string &arr[],const string text) const
     {
      int n = ArraySize(arr);
      ArrayResize(arr,n+1);
      arr[n] = text;
     }

   void              ResetState(void)
     {
      m_hasPrevious=false; m_previousClass=AX_RC_UNAVAILABLE; m_ageBars=0; m_lastSampledBarTime=0;
      m_dirHistoryCapacity=20; ArrayResize(m_dirHistory,m_dirHistoryCapacity);
      m_dirHistoryCount=0; m_dirHistoryHead=0; m_directionAgeBars=0; m_lastDirectionSign=0;
     }

public:
                     CRegimeClassifierEngine(void)
     {
      m_minAgeForPersistent=10; m_minStabilityForPersistent=70.0;
      //--- CMomentumEngine::PersistentBull()/PersistentBear() (used for momentumConfirms above) only     ---
      //--- ever return true at PersistenceRatio()>=0.6 (Momentum.mqh's own internal floor) - a default     ---
      //--- here at or below 0.6 would make the "AND magnitude" half of the established-check a no-op        ---
      //--- whenever momentumConfirms is already true (code-review finding: an earlier draft shipped 0.55,     ---
      //--- below that floor, so the magnitude check never actually added anything under default config).       ---
      m_minMomentumForPersistent=0.70;
      m_structuralBreakVolRatioMult=2.0; // 2x CRegimeEngine's own 2.2 erratic threshold = 4.4
      ResetState();
     }

   void              Configure(const int minAgeForPersistent,const double minStabilityForPersistent,
                                const double minMomentumForPersistent,const double structuralBreakVolRatioMult)
     {
      m_minAgeForPersistent = MathMax(1,minAgeForPersistent);
      m_minStabilityForPersistent = AxClampD(minStabilityForPersistent,0.0,100.0);
      m_minMomentumForPersistent = AxClampD(minMomentumForPersistent,0.0,1.0);
      m_structuralBreakVolRatioMult = MathMax(1.0,structuralBreakVolRatioMult);
      ResetState();
     }

   //--- call every tick; no-ops (returns false) unless a NEW bar has closed on `regimeTimeframe` since  ---
   //--- the last successful sample. regime/vol/mom must already be Update()'d for this tick by the        ---
   //--- caller (deliberately thin, file header). regimeIntel must be THIS SAME bar's own already-           ---
   //--- computed CRegimeIntelligenceEngine::Sample() output (Phase 3a) - not recomputed here. ---
   bool              Sample(const string symbol,const ENUM_TIMEFRAMES regimeTimeframe,
                             const bool dataIntegrityOk,const string dataIntegrityReason,
                             const CRegimeEngine &regime,const CVolatilityEngine &vol,
                             const CMomentumEngine &mom,const SAxRegimeIntelligence &regimeIntel,
                             SAxRegimeClassification &out)
     {
      datetime lastClosedBarTime = iTime(symbol,regimeTimeframe,1);
      if(lastClosedBarTime<=0) return(false);
      if(lastClosedBarTime==m_lastSampledBarTime) return(false);

      SAxRegimeClassification s;
      s.timestamp = lastClosedBarTime;
      ArrayResize(s.supportingFactors,0);
      ArrayResize(s.conflictingFactors,0);

      ENUM_AX_REGIME baseRegime = regime.Regime();
      //--- regimeIntel must be THIS SAME bar's own fresh sample, not a stale one the caller forgot to    ---
      //--- re-run - without this check, a caller bug (wrong call order, a gating mistake) could silently   ---
      //--- fuse a previous bar's macroAgreementScore/regimeConfidence into the current classification        ---
      //--- (e.g. firing R7 off an already-resolved macro disagreement) with dataQualityOk left true and       ---
      //--- nothing flagging it (code-review finding). ---
      bool regimeIntelFresh = (regimeIntel.timestamp==lastClosedBarTime);
      s.dataQualityOk = dataIntegrityOk && (baseRegime!=AX_REGIME_UNSAFE) && regimeIntelFresh;
      if(!dataIntegrityOk)
         s.dataQualityReason = dataIntegrityReason;
      else if(baseRegime==AX_REGIME_UNSAFE)
         s.dataQualityReason = "CRegimeEngine reports UNSAFE (insufficient ATR history)";
      else if(!regimeIntelFresh)
         s.dataQualityReason = "regimeIntel snapshot is stale (not sampled for this bar) - refusing to fuse it";
      else
         s.dataQualityReason = "";

      if(!s.dataQualityOk)
        {
         //--- never fabricate a classification from bad/insufficient data - and never let a data gap    ---
         //--- corrupt what this engine already knew before it (this file's own history/age tracker is    ---
         //--- left untouched, not reset, matching "unavailable data fails safely" from this phase's own    ---
         //--- failure policy). ---
         s.regime = AX_RC_UNAVAILABLE;
         s.regimeConfidence = 0.0;
         s.hasPreviousRegime = m_hasPrevious;
         s.previousRegime = m_previousClass;
         s.regimeAgeBars = m_ageBars;
         s.transitionDetected = false;
         s.transitionDescription = "";
         AppendFactor(s.supportingFactors,s.dataQualityReason);
         m_lastSampledBarTime = lastClosedBarTime;
         out = s;
         return(true);
        }

      double slope = regime.Slope();
      double volRatio = regime.VolRatio();
      ENUM_AX_VOLATILITY_STATE volState = vol.State();
      double momPersistence = mom.PersistenceRatio();

      ENUM_AX_REGIME_CLASS newClass = AX_RC_RANGE_CHOP; // residual default - see file header

      bool hasClearLocalDirection =
         (baseRegime==AX_REGIME_STRONG_TREND || baseRegime==AX_REGIME_TREND || baseRegime==AX_REGIME_BREAKOUT)
         && slope!=0;

      //--- own direction-sign bookkeeping, run unconditionally every successful sample regardless of      ---
      //--- which priority branch ends up firing below - see the member declarations above for why this     ---
      //--- is tracked separately from regimeIntel's exact-enum history. ---
      int currentDirSign = hasClearLocalDirection ? ((slope>0) ? 1 : -1) : 0;
      m_dirHistory[m_dirHistoryHead] = currentDirSign;
      m_dirHistoryHead = (m_dirHistoryHead+1) % m_dirHistoryCapacity;
      if(m_dirHistoryCount<m_dirHistoryCapacity) m_dirHistoryCount++;
      int dirMatches=0;
      for(int i=0;i<m_dirHistoryCount;i++) if(m_dirHistory[i]==currentDirSign) dirMatches++;
      double directionStability = (m_dirHistoryCount>0) ? (100.0*dirMatches/m_dirHistoryCount) : 0.0;
      if(currentDirSign!=0)
        {
         if(currentDirSign==m_lastDirectionSign) m_directionAgeBars++;
         else { m_directionAgeBars=0; m_lastDirectionSign=currentDirSign; }
        }
      //--- currentDirSign==0 (a non-directional bar) deliberately leaves m_directionAgeBars/                ---
      //--- m_lastDirectionSign untouched - a single non-directional blip inside an otherwise persistent      ---
      //--- trend shouldn't retroactively erase the accumulated age, unlike Phase 3a's own stricter            ---
      //--- reset-on-any-enum-change policy (a deliberate, documented difference in what each engine is         ---
      //--- actually trying to measure). ---

      //--- priority 1: R6 Volatility Shock - CVolatilityEngine's own already-computed shock read ---
      if(volState==AX_VOL_SHOCK)
        {
         newClass = AX_RC_VOLATILITY_SHOCK;
         s.regimeConfidence = 80.0; // fixed tier - CVolatilityEngine's own shockAccelPct isn't exposed, see header
         AppendFactor(s.supportingFactors,StringFormat("CVolatilityEngine reports SHOCK (acceleration %.1f%%)",vol.AccelerationPct()));
        }
      //--- priority 2: R7 Information Conflict - macro cross-check disagrees with a clear local direction ---
      else if(regimeIntel.macroDataAvailable && regimeIntel.macroAgreementScore<0 && hasClearLocalDirection)
        {
         newClass = AX_RC_INFORMATION_CONFLICT;
         //--- fixed, not computed: regimeIntel.macroAgreementScore is only 3-valued (-100/0/+100), and      ---
         //--- this branch is only reached when it's exactly -100, so MathAbs() of it is a disguised          ---
         //--- constant, not a graded margin (code-review finding: an earlier draft's own comment implied       ---
         //--- otherwise) - stated as a plain fixed tier instead, same honesty convention as R6/R8 above. ---
         s.regimeConfidence = 100.0;
         AppendFactor(s.supportingFactors,
                      StringFormat("Local %s direction (slope=%.2f) conflicts with macro cross-check",
                                   (slope>0?"bullish":"bearish"),slope));
         AppendFactor(s.conflictingFactors,
                      StringFormat("CRegimeEngine itself reports %s with no local ambiguity",AxRegimeToString(baseRegime)));
        }
      //--- priority 3: R8 Structural Break - a self-contained proxy, NOT the future Shock DNA Engine (header) ---
      else if(baseRegime==AX_REGIME_CHAOTIC && volRatio>=AX_REGIMECLASSIFIER_ERRATIC_MIRROR*m_structuralBreakVolRatioMult)
        {
         newClass = AX_RC_STRUCTURAL_BREAK;
         s.regimeConfidence = 55.0; // fixed, deliberately the lowest-confidence tier - see header
         AppendFactor(s.supportingFactors,
                      StringFormat("CHAOTIC with volRatio %.2f, %.1fx CRegimeEngine's own 2.2 erratic threshold",
                                   volRatio,volRatio/AX_REGIMECLASSIFIER_ERRATIC_MIRROR));
        }
      //--- priority 4: directional buckets - reuses Phase 3a's own regimeIntel fields, recomputes nothing ---
      else if(hasClearLocalDirection)
        {
         bool bullish = slope>0;
         //--- direction-AWARE momentum confirmation - CMomentumEngine::PersistenceRatio() alone is the   ---
         //--- magnitude of whichever tick direction currently dominates, not confirmation that it agrees  ---
         //--- with THIS bar's own slope direction; PersistentBull()/PersistentBear() are the correct,      ---
         //--- already-computed direction-matched accessors for that (code-review finding: an earlier        ---
         //--- draft gated on the direction-agnostic ratio alone, which could label a regime "persistent      ---
         //--- bearish trend" while tick-level momentum was actually persistently bullish, with no              ---
         //--- conflicting-factor raised despite this file's own stated policy). ---
         bool momentumConfirms = bullish ? mom.PersistentBull() : mom.PersistentBear();
         bool momentumOpposes  = bullish ? mom.PersistentBear() : mom.PersistentBull();
         //--- STRONG_TREND or plain TREND may both qualify as "established" given enough age/stability/    ---
         //--- momentum - hard-gating on STRONG_TREND alone would permanently mislabel a long-held, highly    ---
         //--- stable plain-TREND read (e.g. r2 in [0.40,0.70) sustained for hundreds of bars) as merely       ---
         //--- "unstable"/"in transition" forever (code-review finding). ---
         bool established = (baseRegime==AX_REGIME_STRONG_TREND || baseRegime==AX_REGIME_TREND)
                             && (m_directionAgeBars>=m_minAgeForPersistent)
                             && (directionStability>=m_minStabilityForPersistent)
                             && momentumConfirms
                             && (momPersistence>=m_minMomentumForPersistent); // direction AND magnitude
         if(established)
           {
            newClass = bullish ? AX_RC_PERSISTENT_BULLISH_TREND : AX_RC_PERSISTENT_BEARISH_TREND;
            AppendFactor(s.supportingFactors,
                         StringFormat("%s direction held %d bars, direction stability %.0f%%, tick momentum confirms (ratio %.2f)",
                                      AxRegimeToString(baseRegime),m_directionAgeBars,
                                      directionStability,momPersistence));
           }
         else
           {
            newClass = bullish ? AX_RC_BULLISH_UNSTABLE : AX_RC_BEARISH_TRANSITION;
            AppendFactor(s.supportingFactors,
                         StringFormat("%s, slope %.2f, direction age %d bars, direction stability %.0f%%, momentum persistence %.2f",
                                      AxRegimeToString(baseRegime),slope,m_directionAgeBars,
                                      directionStability,momPersistence));
            if(baseRegime==AX_REGIME_STRONG_TREND || baseRegime==AX_REGIME_TREND)
               AppendFactor(s.conflictingFactors,"Does not yet clear the persistence bar (age/stability/tick-momentum confirmation)");
            if(momentumOpposes)
               AppendFactor(s.conflictingFactors,
                            StringFormat("Tick-level momentum is persistently %s, opposing this bar's own %s slope",
                                         (bullish?"BEARISH":"BULLISH"),(bullish?"bullish":"bearish")));
           }
         s.regimeConfidence = regimeIntel.regimeConfidence; // reuse Phase 3a's own branch-grounded value
        }
      //--- priority 5 (residual): R3 Range/Chop - RANGE/MEAN_REVERSION/HIGH_VOL/LOW_VOL, non-extreme    ---
      //--- CHAOTIC, or a zero-slope BREAKOUT (ambiguous edge case - see file header) ---
      else
        {
         newClass = AX_RC_RANGE_CHOP;
         s.regimeConfidence = regimeIntel.regimeConfidence;
         AppendFactor(s.supportingFactors,StringFormat("%s, volRatio %.2f, R2 %.2f",AxRegimeToString(baseRegime),volRatio,regime.R2()));
         if(baseRegime==AX_REGIME_CHAOTIC)
            AppendFactor(s.conflictingFactors,StringFormat("CHAOTIC but volRatio %.2f does not clear the structural-break threshold",volRatio));
        }

      s.regime = newClass;
      s.hasPreviousRegime = m_hasPrevious;
      s.previousRegime = m_previousClass;
      s.transitionDetected = m_hasPrevious && (newClass!=m_previousClass);
      s.transitionDescription = s.transitionDetected ?
         StringFormat("%s -> %s",AxRegimeClassToString(m_previousClass),AxRegimeClassToString(newClass)) : "";

      if(!m_hasPrevious || s.transitionDetected) m_ageBars=0;
      else m_ageBars++;
      s.regimeAgeBars = m_ageBars;

      m_previousClass = newClass;
      m_hasPrevious = true;
      m_lastSampledBarTime = lastClosedBarTime;

      out = s;
      return(true);
     }
  };
//+------------------------------------------------------------------+
#endif // AX_REGIMECLASSIFIERENGINE_MQH
