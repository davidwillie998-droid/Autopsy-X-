//+------------------------------------------------------------------+
//|                                                  CrisisEngine.mqh|
//|  Crisis Mode + Black-Swan Mode (spec sections 14-15), institutional|
//|  engine upgrade - ENGINEERING DESIGN, not paper-sourced. The       |
//|  source paper (Malhotra SSRN 3306817) documents that 64% of the    |
//|  hedge funds it studied experienced losses exceeding TWICE their   |
//|  own past maximum drawdown during the 2008 crisis (finding v) -    |
//|  i.e. tail events can break a strategy's own historical risk       |
//|  envelope. It does NOT provide a crisis-detection formula, a       |
//|  black-swan trigger, or any of the thresholds/weights below - the  |
//|  paper's finding is the MOTIVATION for having a systemic-severity  |
//|  ladder at all, not the source of its mechanics.                   |
//|                                                                    |
//|  Combines Crisis Mode and Black-Swan Mode into ONE 4-level ladder  |
//|  (see ENUM_AX_CRISIS_LEVEL in Defs.mqh for why) rather than two    |
//|  independently-computed booleans.                                  |
//|                                                                    |
//|  Deliberately thin, matching InformationContentEngine.mqh's/        |
//|  HiddenRiskDetector.mqh's own convention: every input is an        |
//|  ALREADY-COMPUTED read from another engine. This class recomputes  |
//|  nothing except its own internal data-integrity-failure streak.    |
//|                                                                    |
//|  SIGNAL, NOT ACTION: like every engine in this build, this class   |
//|  never closes a position, cancels an order, or touches CTrade. It  |
//|  reports a severity level plus two RECOMMENDATION flags            |
//|  (blockNewEntries, restrictToClosingOnly) for a caller to act on -  |
//|  it is not wired into the live OnTick loop as part of this build.  |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_CRISISENGINE_MQH
#define AX_CRISISENGINE_MQH
#include "Defs.mqh"

struct SAxCrisisState
  {
   double   severity;               // 0..100 composite
   double   volatilitySeverity;
   double   drawdownSeverity;
   double   hiddenRiskSeverity;
   double   dataIntegritySeverity;
   ENUM_AX_CRISIS_LEVEL level;
   bool     blockNewEntries;        // recommendation only - level >= AX_CRISIS_CRISIS
   bool     restrictToClosingOnly;  // recommendation only - level == AX_CRISIS_BLACK_SWAN
   string   reason;
  };

class CCrisisEngine
  {
private:
   double            m_wVolatility, m_wDrawdown, m_wHiddenRisk, m_wDataIntegrity;
   double            m_elevatedThreshold, m_crisisThreshold, m_blackSwanThreshold;
   int               m_maxIntegrityFailuresForFullPenalty;

   int               m_consecutiveIntegrityFailures;

public:
                     CCrisisEngine(void)
     {
      m_wVolatility=30; m_wDrawdown=30; m_wHiddenRisk=25; m_wDataIntegrity=15;
      m_elevatedThreshold=30.0; m_crisisThreshold=55.0; m_blackSwanThreshold=80.0;
      m_maxIntegrityFailuresForFullPenalty=20;
      m_consecutiveIntegrityFailures=0;
     }

   void              Configure(const double wVolatility,const double wDrawdown,const double wHiddenRisk,
                                const double wDataIntegrity,const double elevatedThreshold,
                                const double crisisThreshold,const double blackSwanThreshold,
                                const int maxIntegrityFailuresForFullPenalty)
     {
      m_wVolatility=MathMax(0,wVolatility); m_wDrawdown=MathMax(0,wDrawdown);
      m_wHiddenRisk=MathMax(0,wHiddenRisk); m_wDataIntegrity=MathMax(0,wDataIntegrity);
      //--- guard against a transposed-argument call silently inverting the ladder (same code-review     ---
      //--- finding/fix already applied to DrawdownEngine.mqh and HiddenRiskDetector.mqh's Configure()) ---
      m_elevatedThreshold=elevatedThreshold;
      m_crisisThreshold=MathMax(m_elevatedThreshold,crisisThreshold);
      m_blackSwanThreshold=MathMax(m_crisisThreshold,blackSwanThreshold);
      m_maxIntegrityFailuresForFullPenalty=MathMax(1,maxIntegrityFailuresForFullPenalty);
     }

   //--- inputs are all already-computed reads: volState from CVolatilityEngine, ddState from            ---
   //--- CDynamicDrawdownEngine, hiddenRiskScore from CHiddenRiskDetector, dataIntegrityOk from a fresh   ---
   //--- CDataIntegrityEngine::Check() call this tick. Call every tick (cheap - no history scan). ---
   SAxCrisisState    Update(const ENUM_AX_VOLATILITY_STATE volState,const ENUM_AX_DRAWDOWN_STATE ddState,
                             const double hiddenRiskScore,const bool dataIntegrityOk)
     {
      if(dataIntegrityOk) m_consecutiveIntegrityFailures=0;
      //--- capped, not left to grow unbounded - the ratio below only needs to reach                    ---
      //--- m_maxIntegrityFailuresForFullPenalty (default 20) to saturate at severity 100; letting an int---
      //--- counter run forever under a very long sustained failure streak risks an eventual overflow to ---
      //--- a negative value, which would silently clamp the ratio back to 0 - the OPPOSITE of the        ---
      //--- intended saturated-100 reading at the worst possible moment (code-review finding). The cap    ---
      //--- is far above anything m_maxIntegrityFailuresForFullPenalty would ever need. ---
      else if(m_consecutiveIntegrityFailures<1000000) m_consecutiveIntegrityFailures++;

      SAxCrisisState s;

      //--- volatility severity - intentionally its OWN mapping, not shared with DrawdownEngine's         ---
      //--- volMultiplier or HiddenRiskDetector's volatilityStateSeverity, so each engine's read stays     ---
      //--- independently reviewable (same "each engine owns its own read" convention used throughout). ---
      switch(volState)
        {
         case AX_VOL_NORMAL:  s.volatilitySeverity=0.0;   break;
         case AX_VOL_LOW:     s.volatilitySeverity=0.0;   break;
         case AX_VOL_HIGH:    s.volatilitySeverity=35.0;  break;
         case AX_VOL_EXTREME: s.volatilitySeverity=70.0;  break;
         case AX_VOL_SHOCK:   s.volatilitySeverity=100.0; break;
         default:              s.volatilitySeverity=0.0;   break;
        }

      switch(ddState)
        {
         case AX_DD_STATE_NORMAL:    s.drawdownSeverity=0.0;   break;
         case AX_DD_STATE_CAUTION:   s.drawdownSeverity=25.0;  break;
         case AX_DD_STATE_DEFENSIVE: s.drawdownSeverity=50.0;  break;
         case AX_DD_STATE_SEVERE:    s.drawdownSeverity=75.0;  break;
         case AX_DD_STATE_HALT:      s.drawdownSeverity=100.0; break;
         default:                     s.drawdownSeverity=0.0;   break;
        }

      s.hiddenRiskSeverity = AxClampD(hiddenRiskScore,0.0,100.0);
      s.dataIntegritySeverity = AxClampD(
         100.0*m_consecutiveIntegrityFailures/(double)m_maxIntegrityFailuresForFullPenalty,0.0,100.0);

      double totalWeight = m_wVolatility+m_wDrawdown+m_wHiddenRisk+m_wDataIntegrity;
      s.severity = (totalWeight>0) ?
         (s.volatilitySeverity*m_wVolatility+s.drawdownSeverity*m_wDrawdown+
          s.hiddenRiskSeverity*m_wHiddenRisk+s.dataIntegritySeverity*m_wDataIntegrity)/totalWeight
         : 0.0;

      if(s.severity>=m_blackSwanThreshold)   s.level=AX_CRISIS_BLACK_SWAN;
      else if(s.severity>=m_crisisThreshold) s.level=AX_CRISIS_CRISIS;
      else if(s.severity>=m_elevatedThreshold) s.level=AX_CRISIS_ELEVATED;
      else                                     s.level=AX_CRISIS_NONE;

      s.blockNewEntries = (s.level==AX_CRISIS_CRISIS || s.level==AX_CRISIS_BLACK_SWAN);
      s.restrictToClosingOnly = (s.level==AX_CRISIS_BLACK_SWAN);

      s.reason=StringFormat(
         "crisis=%.1f [%s] (vol=%.0f dd=%.0f hiddenRisk=%.0f dataIntegrity=%.0f, integrityFailStreak=%d)",
         s.severity,AxCrisisLevelToString(s.level),s.volatilitySeverity,s.drawdownSeverity,
         s.hiddenRiskSeverity,s.dataIntegritySeverity,m_consecutiveIntegrityFailures);

      return(s);
     }

   int               ConsecutiveIntegrityFailures(void) const { return(m_consecutiveIntegrityFailures); }
  };
//+------------------------------------------------------------------+
#endif // AX_CRISISENGINE_MQH
