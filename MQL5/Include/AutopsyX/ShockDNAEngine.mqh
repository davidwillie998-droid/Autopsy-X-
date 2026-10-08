//+------------------------------------------------------------------+
//|                                                ShockDNAEngine.mqh |
//|  Shock DNA / Shock Characterization Engine (10X Market            |
//|  Intelligence upgrade, Phase 4B) - ENGINEERING DESIGN, not         |
//|  paper-sourced.                                                    |
//|                                                                    |
//|  Executable reference: python/autopsy_research/shock_dna.py -      |
//|  this file ports that module's logic exactly (same waterfall,      |
//|  same thresholds, same confidence formula). Read shock_dna.py's    |
//|  own module docstring for the full mathematical specification,     |
//|  the shock definition and its justification, the state taxonomy    |
//|  and waterfall, the lifecycle/live-vs-completed separation, the    |
//|  look-ahead-protection argument, the confidence methodology, the   |
//|  outlier-defense rationale, and the claim-honesty statement - it   |
//|  is not repeated verbatim here to avoid the two copies drifting;   |
//|  see docs/PHASE4B_SHOCK_DNA_REPORT.md for the condensed version.   |
//|                                                                    |
//|  WHAT IS REUSED, NOT DUPLICATED (see shock_dna.py section 1 for    |
//|  the full reasoning):                                              |
//|    - ATR + CVolatilityEngine's own 5-state taxonomy (State()/      |
//|      CurrentAtr()) - reused via caller-supplied atrPrice/          |
//|      volStateIsShock, never recomputed. volStateIsShock is a       |
//|      CORROBORATING signal only (feeds AxShockConfidence's vol      |
//|      factor), never the primary onset trigger.                     |
//|    - The 9-state ENUM_AX_REGIME_CLASS taxonomy                     |
//|      (RegimeClassifierEngine.mqh, Phase 3) - reused via the        |
//|      caller's already-computed SAxRegimeClassification, purely     |
//|      descriptive context.                                          |
//|    - Cross-asset context - the caller's already-computed           |
//|      SAxInformationTransmissionSnapshot (InformationTransmission   |
//|      Engine.mqh, Phase 4A). That file is NOT modified by this      |
//|      phase.                                                        |
//|    - Data-quality gating - the caller's already-computed           |
//|      dataIntegrityOk/dataIntegrityReason (CDataIntegrityEngine),   |
//|      exactly like every other Phase 3/4A engine's own Sample()     |
//|      signature.                                                    |
//|                                                                    |
//|  WHAT IS GENUINELY NEW: the ATR-relative single-bar onset ratio,   |
//|  the event-lifecycle tracker (k, cumulative displacement, running  |
//|  max excursion / max adverse excursion, retracement), and the      |
//|  state waterfall built from those. velocityAtr/accelerationAtr     |
//|  here are BAR-LEVEL, ATR-normalized quantities - a deliberately    |
//|  different statistical object from CMomentumEngine's own tick-     |
//|  arrival-rate Velocity()/Acceleration() (see shock_dna.py header   |
//|  for the full argument against reusing those fields here, mirror-  |
//|  ing the same distinction VolatilitySerialityEngine.mqh already    |
//|  drew against CMomentumEngine::PersistenceRatio()).                |
//|                                                                    |
//|  Owns its own closed-bar OHLC read (CopyClose/CopyHigh/CopyLow,    |
//|  shift>=1), matching this codebase's "each engine owns its own     |
//|  read" convention - does not read from MarketStateEngine.mqh.      |
//|                                                                    |
//|  BAR-LEVEL, SIGNAL-ONLY, NOT WIRED: matches every other engine in  |
//|  this build. Never calls CTrade, not #include'd by the live EA.    |
//|  Computationally bounded: O(1) work per Sample() call, fixed,      |
//|  finite memory (one optional active-event record).                 |
//|                                                                    |
//|  CLAIM-HONESTY: this engine characterizes a market EVENT. It does  |
//|  not claim, and nothing here should be read as claiming, that a    |
//|  detected shock predicts, causes, or is profitable in any way.     |
//|                                                                    |
//|  VERIFICATION STATUS: balance-checked and code-reviewed only.      |
//|  COMPILATION NOT VERIFIED - no MQL5 compiler available in this     |
//|  build environment.                                                 |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_SHOCKDNAENGINE_MQH
#define AX_SHOCKDNAENGINE_MQH
#include "Defs.mqh"
#include "RegimeClassifierEngine.mqh"
#include "InformationTransmissionEngine.mqh"

#define AX_SHOCKDNA_EPS 0.000000001

enum ENUM_AX_SHOCK_STATE
  {
   AX_SHOCK_UNKNOWN = 0,          // data quality bad or ATR unusable this bar
   AX_SHOCK_INSUFFICIENT_DATA,    // usable data, not yet enough bar history
   AX_SHOCK_NONE,                 // no active event; this bar under onset threshold
   AX_SHOCK_ONSET,                // new event detected this bar (k==0)
   AX_SHOCK_IMPULSE,              // still extending, still at/near its own peak
   AX_SHOCK_FOLLOW_THROUGH,       // extended beyond impulse window, low retracement
   AX_SHOCK_ABSORPTION,           // meaningful give-back, or stalled (default/catch-all)
   AX_SHOCK_REVERSAL,             // flipped sign meaningfully, or gave back most of the peak
   AX_SHOCK_NORMALIZING           // lifecycle cap reached, or decayed near zero - terminal
  };

string AxShockStateToString(const ENUM_AX_SHOCK_STATE s)
  {
   switch(s)
     {
      case AX_SHOCK_UNKNOWN:           return("Unknown");
      case AX_SHOCK_INSUFFICIENT_DATA: return("Insufficient data");
      case AX_SHOCK_NONE:              return("No shock");
      case AX_SHOCK_ONSET:             return("Onset");
      case AX_SHOCK_IMPULSE:           return("Impulse");
      case AX_SHOCK_FOLLOW_THROUGH:    return("Follow-through");
      case AX_SHOCK_ABSORPTION:        return("Absorption");
      case AX_SHOCK_REVERSAL:          return("Reversal");
      case AX_SHOCK_NORMALIZING:       return("Normalizing");
     }
   return("Unknown");
  }

struct SAxShockDNASnapshot
  {
   datetime                    timestamp;
   bool                        valid;
   bool                        dataQualityOk;
   string                      dataQualityReason;

   bool                        shockDetected;
   ENUM_AX_SHOCK_STATE         shockState;
   int                         direction;               // -1, 0, +1

   double                      magnitudeRawPts;          // reference/debugging only, not scale-aware
   double                      normalizedMagnitude;       // this bar's own |return|/ATR ratio
   double                      eventMagnitudeAtr;         // |cumulative displacement| of active event
   double                      rangeExpansionAtr;         // (high-low)/ATR, this bar

   double                      velocityAtr;
   double                      accelerationAtr;
   int                         persistenceBars;           // k, bars since onset
   double                      maxExcursionAtr;
   double                      maxAdverseExcursionAtr;
   double                      retracementFraction;

   bool                        followThrough;
   bool                        absorption;
   bool                        recovery;

   bool                        volatilityEngineShock;     // CVolatilityEngine.State()==AX_VOL_SHOCK, corroborating only

   ENUM_AX_REGIME_CLASS        regime;
   double                      regimeStrength;
   ENUM_AX_TRANSMISSION_STATE  transmissionState;
   bool                        transmissionAvailable;
   bool                        crossAssetConfirmationAvailable;
   bool                        crossAssetConfirmation;    // meaningful only if crossAssetConfirmationAvailable

   double                      confidence;
  };

class CShockDNAEngine
  {
private:
   //--- config (all Configure()-able; defaults documented in shock_dna.py section 2) ---
   double            m_onsetThresholdAtr;
   int               m_impulseBars;
   double            m_followThroughMult;
   double            m_absorptionRetracementFrac;
   double            m_reversalRetracementFrac;
   double            m_reversalMinMagnitudeAtr;
   double            m_normalizationFloorAtr;
   int               m_minDecayBars;
   int               m_lifecycleBars;
   int               m_minHistoryBars;
   ENUM_TIMEFRAMES   m_barTimeframe;

   //--- active event state (mirrors shock_dna.py's _ActiveEvent) ---
   bool              m_hasActive;
   double            m_onsetDisplacementAtr;
   int               m_onsetSign;
   int               m_k;
   double            m_cumulativeDisplacementAtr;
   double            m_maxExcursionAtr;
   double            m_prevVelocityAtr;

   int               m_barsSampled;
   datetime          m_lastSampledBarTime;

   //--- (adverseExc, retracement) for the engine's CURRENT active-event state - the single      ---
   //--- definition shared by Classify() and Sample() (code-review finding, mirrors the identical ---
   //--- fix in shock_dna.py's own _retracement() helper), so the two never drift apart. ---
   void              RetracementOf(double &adverseExcOut,double &retracementOut) const
     {
      double maxExc = m_maxExcursionAtr;
      adverseExcOut = MathMax(0.0,maxExc-m_onsetSign*m_cumulativeDisplacementAtr);
      retracementOut = (maxExc>AX_SHOCKDNA_EPS) ? (adverseExcOut/maxExc) : 0.0;
     }

   //--- deterministic state waterfall - see shock_dna.py section 5 for the full derivation ---
   ENUM_AX_SHOCK_STATE Classify(void) const
     {
      int    k        = m_k;
      int    onsetSign= m_onsetSign;
      double cum       = m_cumulativeDisplacementAtr;
      double maxExc    = m_maxExcursionAtr;
      double adverseExc,retracement;
      RetracementOf(adverseExc,retracement);

      if(k>=m_lifecycleBars) return(AX_SHOCK_NORMALIZING);
      if(MathAbs(cum)<=m_normalizationFloorAtr && k>=m_minDecayBars) return(AX_SHOCK_NORMALIZING);
      if(onsetSign*cum<=-m_reversalMinMagnitudeAtr) return(AX_SHOCK_REVERSAL);
      if(retracement>=m_reversalRetracementFrac) return(AX_SHOCK_REVERSAL);
      if(retracement>=m_absorptionRetracementFrac) return(AX_SHOCK_ABSORPTION);
      if(k==0) return(AX_SHOCK_ONSET);
      if(k<=m_impulseBars && onsetSign*cum>=maxExc-AX_SHOCKDNA_EPS) return(AX_SHOCK_IMPULSE);
      if(onsetSign*cum>=MathAbs(m_onsetDisplacementAtr)*m_followThroughMult) return(AX_SHOCK_FOLLOW_THROUGH);
      return(AX_SHOCK_ABSORPTION);
     }

   //--- gated minimum of independent evidence-quality factors, never a blind average - matching     ---
   //--- TradePermissionMatrix.mqh/InformationTransmissionEngine.mqh/RegimeClassifierEngine.mqh's own  ---
   //--- established confidence convention (shock_dna.py section 8). regimeAvailable (NOT truthiness   ---
   //--- of regimeStrength) gates the regime-certainty factor - a genuinely reported regimeConfidence   ---
   //--- of exactly 0.0 must gate confidence down hard, not be mistaken for "no regime data supplied"   ---
   //--- and bumped up to the unavailable-default factor (defect found and fixed during this phase's    ---
   //--- own adversarial self-review of the Python reference - see the phase report). ---
   double            Confidence(const double magnitudeAtr,const double regimeStrength,const bool regimeAvailable,
                                 const bool transmissionAvailable,const bool volStateIsShock) const
     {
      double sampleFactor = MathMin(1.0,(double)m_barsSampled/(m_minHistoryBars*2.0));
      double qualityFactor = 1.0;      // gated true already, by construction of the call path
      double magnitudeFactor = MathMin(1.0,magnitudeAtr/(m_onsetThresholdAtr*2.0));
      double consistencyFactor = 1.0;  // OHLC/ATR sanity already checked before this call path
      double crossAssetFactor = transmissionAvailable ? 1.0 : 0.6;
      double regimeCertaintyFactor = regimeAvailable ? AxClampD(regimeStrength/100.0,0.0,1.0) : 0.5;
      double volCorroborationFactor = volStateIsShock ? 1.0 : 0.85;
      double m = MathMin(sampleFactor,qualityFactor);
      m = MathMin(m,magnitudeFactor);
      m = MathMin(m,consistencyFactor);
      m = MathMin(m,crossAssetFactor);
      m = MathMin(m,regimeCertaintyFactor);
      m = MathMin(m,volCorroborationFactor);
      return(100.0*m);
     }

public:
                     CShockDNAEngine(void) { Clear(); }

   void              Clear(void)
     {
      m_onsetThresholdAtr=1.5; m_impulseBars=2; m_followThroughMult=0.6;
      m_absorptionRetracementFrac=0.5; m_reversalRetracementFrac=0.75;
      m_reversalMinMagnitudeAtr=0.5; m_normalizationFloorAtr=0.3;
      m_minDecayBars=2; m_lifecycleBars=10; m_minHistoryBars=20;
      m_barTimeframe=PERIOD_M5;
      m_hasActive=false; m_onsetDisplacementAtr=0.0; m_onsetSign=0; m_k=0;
      m_cumulativeDisplacementAtr=0.0; m_maxExcursionAtr=0.0; m_prevVelocityAtr=0.0;
      m_barsSampled=0; m_lastSampledBarTime=0;
     }

   void              Configure(const ENUM_TIMEFRAMES barTimeframe,const double onsetThresholdAtr,
                                const int impulseBars,const double followThroughMult,
                                const double absorptionRetracementFrac,const double reversalRetracementFrac,
                                const double reversalMinMagnitudeAtr,const double normalizationFloorAtr,
                                const int minDecayBars,const int lifecycleBars,const int minHistoryBars)
     {
      m_barTimeframe = barTimeframe;
      m_onsetThresholdAtr = MathMax(0.01,onsetThresholdAtr);
      m_impulseBars = MathMax(0,impulseBars);
      m_followThroughMult = MathMax(0.0,followThroughMult);
      m_absorptionRetracementFrac = AxClampD(absorptionRetracementFrac,0.0,1.0);
      m_reversalRetracementFrac = AxClampD(reversalRetracementFrac,0.0,1.0);
      m_reversalMinMagnitudeAtr = MathMax(0.0,reversalMinMagnitudeAtr);
      m_normalizationFloorAtr = MathMax(0.0,normalizationFloorAtr);
      m_minDecayBars = MathMax(0,minDecayBars);
      m_lifecycleBars = MathMax(1,lifecycleBars);
      m_minHistoryBars = MathMax(1,minHistoryBars);
      m_hasActive=false; m_barsSampled=0; m_lastSampledBarTime=0;
     }

   //--- call every tick; no-ops (returns false) unless a NEW bar has closed on m_barTimeframe since  ---
   //--- the last successful sample. atrPrice/volStateIsShock (CVolatilityEngine), regimeClass         ---
   //--- (CRegimeClassifierEngine, Phase 3) and transmission (CInformationTransmissionEngine, Phase     ---
   //--- 4A) must all be THIS SAME bar's own already-computed outputs, supplied by the caller           ---
   //--- (deliberately thin - file header). Owns its own closed-bar OHLC read for the shock             ---
   //--- computation itself, matching this codebase's "each engine owns its own read" convention.       ---
   bool              Sample(const string symbol,const bool dataIntegrityOk,const string dataIntegrityReason,
                             const double atrPrice,const double point,const bool volStateIsShock,
                             const SAxRegimeClassification &regimeClass,
                             const SAxInformationTransmissionSnapshot &transmission,
                             SAxShockDNASnapshot &out)
     {
      datetime lastClosedBarTime = iTime(symbol,m_barTimeframe,1);
      if(lastClosedBarTime<=0) return(false);
      if(lastClosedBarTime==m_lastSampledBarTime) return(false);

      //--- shift 1 and 2 = the two most recently closed bars - no lookahead, same convention as     ---
      //--- every other engine's own bar reads in this codebase. Only mark this bar "processed" once  ---
      //--- the reads actually succeed - a transient CopyX failure must be retried on a LATER tick     ---
      //--- within the same bar interval, not silently and permanently skipped (matches the            ---
      //--- established fix already applied in VolatilitySerialityEngine.mqh/RegimeClassifierEngine.   ---
      //--- mqh for the identical failure mode). ---
      double closes[],highs[],lows[];
      ArraySetAsSeries(closes,true); ArraySetAsSeries(highs,true); ArraySetAsSeries(lows,true);
      bool gotClose = CopyClose(symbol,m_barTimeframe,1,2,closes)>=2;
      bool gotHigh  = gotClose && CopyHigh(symbol,m_barTimeframe,1,1,highs)>=1;
      bool gotLow   = gotHigh  && CopyLow(symbol,m_barTimeframe,1,1,lows)>=1;
      if(!gotClose || !gotHigh || !gotLow) return(false);

      double closePrev = closes[1];
      double closeCurr = closes[0];
      double highCurr  = highs[0];
      double lowCurr   = lows[0];

      bool regimeAvailable = regimeClass.dataQualityOk;
      double regimeStrength = regimeClass.regimeConfidence;
      bool transmissionAvailable = transmission.valid && transmission.dataQualityOk;

      //--- UNKNOWN: caller-reported data quality bad, or ATR/prices unusable this bar ---
      bool atrUsable = atrPrice>0;
      bool pricesSane = (closePrev>0 && closeCurr>0 && highCurr>0 && lowCurr>0 && highCurr>=lowCurr);
      if(!dataIntegrityOk || !atrUsable || !pricesSane)
        {
         string reason = !dataIntegrityOk ? dataIntegrityReason :
                          (!atrUsable ? "ATR unusable (<= 0)" : "Non-sane OHLC (high < low or non-positive price)");
         //--- a genuinely bad/unusable bar does not advance m_barsSampled or the active event - it is ---
         //--- excluded from the event's history entirely (outlier-defense, shock_dna.py section 9).    ---
         out = SnapshotUnavailable(lastClosedBarTime,AX_SHOCK_UNKNOWN,false,reason,regimeClass,transmission,
                                    volStateIsShock);
         m_lastSampledBarTime = lastClosedBarTime;
         return(true);
        }

      //--- data usable this bar - count it toward this engine's own readiness floor (CVolatilityEngine ---
      //--- and CRegimeEngine expose no public "ATR history ready" flag - see file header). ---
      m_barsSampled++;

      if(m_barsSampled<m_minHistoryBars)
        {
         string reason = StringFormat("Insufficient bar history: %d bars (need %d)",m_barsSampled,m_minHistoryBars);
         out = SnapshotUnavailable(lastClosedBarTime,AX_SHOCK_INSUFFICIENT_DATA,true,reason,regimeClass,transmission,
                                    volStateIsShock);
         m_lastSampledBarTime = lastClosedBarTime;
         return(true);
        }

      double pointSafe = (point>0) ? point : 0.00001;
      double magnitudeRawPts = MathAbs(closeCurr-closePrev)/pointSafe;
      double normalizedMagnitude = MathAbs(closeCurr-closePrev)/atrPrice;
      double rangeExpansionAtr = (highCurr-lowCurr)/atrPrice;
      double signedReturnAtr = (closeCurr-closePrev)/atrPrice;

      ENUM_AX_SHOCK_STATE state;
      if(!m_hasActive)
        {
         if(normalizedMagnitude>=m_onsetThresholdAtr)
           {
            m_onsetSign = (signedReturnAtr>0) ? 1 : -1;
            m_onsetDisplacementAtr = signedReturnAtr;
            m_k = 0;
            m_cumulativeDisplacementAtr = signedReturnAtr;
            m_maxExcursionAtr = MathMax(0.0,m_onsetSign*signedReturnAtr);
            m_prevVelocityAtr = 0.0;
            m_hasActive = true;
            //--- code-review finding (ported from shock_dna.py's identical fix): route the onset  ---
            //--- bar through Classify() rather than hardcoding AX_SHOCK_ONSET, so it is subject to  ---
            //--- the same documented waterfall (section 5) as every later bar. Under any sane        ---
            //--- config (all thresholds > 0) rules 1-5 provably cannot match at k==0, so this        ---
            //--- changes no observable behavior for normal configs - it only restores waterfall       ---
            //--- consistency for degenerate ones. ---
            state = Classify();
           }
         else
           {
            out = SnapshotNone(lastClosedBarTime,magnitudeRawPts,normalizedMagnitude,rangeExpansionAtr,
                                regimeClass,transmission,volStateIsShock);
            m_lastSampledBarTime = lastClosedBarTime;
            return(true);
           }
        }
      else
        {
         m_k++;
         m_cumulativeDisplacementAtr += signedReturnAtr;
         m_maxExcursionAtr = MathMax(m_maxExcursionAtr,MathMax(0.0,m_onsetSign*m_cumulativeDisplacementAtr));
         state = Classify();
        }

      double cum = m_cumulativeDisplacementAtr;
      double maxExc = m_maxExcursionAtr;
      double adverseExc,retracement;
      RetracementOf(adverseExc,retracement);

      //--- velocity: this bar's own incremental (signed, ATR-normalized) contribution - identical     ---
      //--- whether this bar created the event (k==0, equals onsetDisplacementAtr by construction) or   ---
      //--- extended it. acceleration: change vs. the PREVIOUS in-event bar's own velocity - undefined   ---
      //--- (0.0) on the onset bar itself (no prior in-event bar to difference against). ---
      double velocityAtr = signedReturnAtr;
      double accelerationAtr = (m_k==0) ? 0.0 : (velocityAtr-m_prevVelocityAtr);
      m_prevVelocityAtr = velocityAtr;

      double confidence = Confidence(MathAbs(m_onsetDisplacementAtr),regimeStrength,regimeAvailable,
                                      transmissionAvailable,volStateIsShock);

      bool caAvailable = transmissionAvailable;
      bool caConfirmation = false;
      if(caAvailable)
         caConfirmation = (transmission.direction!=0) && ((transmission.direction>0)==(m_onsetSign>0));

      SAxShockDNASnapshot s;
      s.timestamp = lastClosedBarTime;
      s.valid = true;
      s.dataQualityOk = true;
      s.dataQualityReason = "";
      s.shockDetected = true;
      s.shockState = state;
      s.direction = m_onsetSign;
      s.magnitudeRawPts = magnitudeRawPts;
      s.normalizedMagnitude = normalizedMagnitude;
      s.eventMagnitudeAtr = MathAbs(cum);
      s.rangeExpansionAtr = rangeExpansionAtr;
      s.velocityAtr = velocityAtr;
      s.accelerationAtr = accelerationAtr;
      s.persistenceBars = m_k;
      s.maxExcursionAtr = maxExc;
      s.maxAdverseExcursionAtr = adverseExc;
      s.retracementFraction = retracement;
      s.followThrough = (state==AX_SHOCK_FOLLOW_THROUGH);
      s.absorption = (state==AX_SHOCK_ABSORPTION);
      s.recovery = (state==AX_SHOCK_NORMALIZING && MathAbs(cum)<=m_normalizationFloorAtr);
      s.volatilityEngineShock = volStateIsShock;
      s.regime = regimeClass.regime;
      s.regimeStrength = regimeStrength;
      s.transmissionState = transmission.state;
      s.transmissionAvailable = transmissionAvailable;
      s.crossAssetConfirmationAvailable = caAvailable;
      s.crossAssetConfirmation = caConfirmation;
      s.confidence = confidence;

      if(state==AX_SHOCK_NORMALIZING)
         m_hasActive = false;

      out = s;
      m_lastSampledBarTime = lastClosedBarTime;
      return(true);
     }

private:
   SAxShockDNASnapshot SnapshotUnavailable(const datetime ts,const ENUM_AX_SHOCK_STATE state,
                                            const bool dataQualityOk,const string reason,
                                            const SAxRegimeClassification &regimeClass,
                                            const SAxInformationTransmissionSnapshot &transmission,
                                            const bool volStateIsShock) const
     {
      SAxShockDNASnapshot s;
      s.timestamp=ts; s.valid=false; s.dataQualityOk=dataQualityOk; s.dataQualityReason=reason;
      s.shockDetected=false; s.shockState=state; s.direction=0;
      s.magnitudeRawPts=0.0; s.normalizedMagnitude=0.0; s.eventMagnitudeAtr=0.0; s.rangeExpansionAtr=0.0;
      s.velocityAtr=0.0; s.accelerationAtr=0.0; s.persistenceBars=0;
      s.maxExcursionAtr=0.0; s.maxAdverseExcursionAtr=0.0; s.retracementFraction=0.0;
      s.followThrough=false; s.absorption=false; s.recovery=false;
      s.volatilityEngineShock=volStateIsShock;
      s.regime=regimeClass.regime; s.regimeStrength=regimeClass.regimeConfidence;
      s.transmissionState=transmission.state; s.transmissionAvailable=(transmission.valid && transmission.dataQualityOk);
      s.crossAssetConfirmationAvailable=false; s.crossAssetConfirmation=false;
      s.confidence=0.0;
      return(s);
     }

   SAxShockDNASnapshot SnapshotNone(const datetime ts,const double magnitudeRawPts,const double normalizedMagnitude,
                                     const double rangeExpansionAtr,
                                     const SAxRegimeClassification &regimeClass,
                                     const SAxInformationTransmissionSnapshot &transmission,
                                     const bool volStateIsShock) const
     {
      SAxShockDNASnapshot s;
      s.timestamp=ts; s.valid=true; s.dataQualityOk=true; s.dataQualityReason="";
      s.shockDetected=false; s.shockState=AX_SHOCK_NONE; s.direction=0;
      s.magnitudeRawPts=magnitudeRawPts; s.normalizedMagnitude=normalizedMagnitude;
      s.eventMagnitudeAtr=0.0; s.rangeExpansionAtr=rangeExpansionAtr;
      s.velocityAtr=0.0; s.accelerationAtr=0.0; s.persistenceBars=0;
      s.maxExcursionAtr=0.0; s.maxAdverseExcursionAtr=0.0; s.retracementFraction=0.0;
      s.followThrough=false; s.absorption=false; s.recovery=false;
      s.volatilityEngineShock=volStateIsShock;
      s.regime=regimeClass.regime; s.regimeStrength=regimeClass.regimeConfidence;
      s.transmissionState=transmission.state; s.transmissionAvailable=(transmission.valid && transmission.dataQualityOk);
      s.crossAssetConfirmationAvailable=false; s.crossAssetConfirmation=false;
      s.confidence=0.0;
      return(s);
     }
  };
//+------------------------------------------------------------------+
#endif // AX_SHOCKDNAENGINE_MQH
