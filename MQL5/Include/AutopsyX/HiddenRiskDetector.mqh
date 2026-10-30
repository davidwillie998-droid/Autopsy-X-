//+------------------------------------------------------------------+
//|                                           HiddenRiskDetector.mqh|
//|  Hidden-Risk Detector (spec section 13), institutional engine     |
//|  upgrade - ENGINEERING DESIGN, not paper-sourced. The source      |
//|  paper (Malhotra SSRN 3306817) warns that traditional return-     |
//|  based risk measures miss hidden liquidity/microstructure risk    |
//|  building up beneath a normal-looking equity curve (findings      |
//|  items v, x) - it does not specify a HiddenRiskScore formula,     |
//|  its components, or their weights. All of those are this          |
//|  codebase's own design.                                            |
//|                                                                    |
//|  Deliberately thin, matching InformationContentEngine.mqh's own    |
//|  convention: does not recompute anything another engine already    |
//|  computes. It only (a) tracks short trailing history of a few      |
//|  already-computed 0..100 scores from other engines and reads       |
//|  whether they are DETERIORATING, and (b) combines that with the    |
//|  current volatility state and consecutive-loss count into one      |
//|  composite HiddenRiskScore, so risk that is BUILDING but not yet   |
//|  visible in the account equity curve can be surfaced separately    |
//|  from the Dynamic Drawdown Engine (which only reads realized       |
//|  equity, i.e. risk that has ALREADY materialized).                 |
//|                                                                    |
//|  "increasing slippage" (spec section 13's own wording) is          |
//|  deliberately NOT a separate component here: PriceImpactEngine's   |
//|  ExecutionCostScore() is already slippage normalized by spread, so |
//|  a falling execution-cost-score trend IS a rising-slippage trend.  |
//|  Scoring both would double-count the same underlying signal.       |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_HIDDENRISKDETECTOR_MQH
#define AX_HIDDENRISKDETECTOR_MQH
#include "Defs.mqh"

#define AX_HRD_HISTORY 30 // trailing samples for trend detection - not tied to tick rate (see m_minSampleIntervalSeconds)

struct SAxHiddenRiskState
  {
   double   score;                  // 0 (no hidden risk detected) .. 100 (severe)
   double   spreadRisingSeverity;
   double   volatilityStateSeverity;
   double   executionDeteriorationSeverity; // also captures "increasing slippage" - see file header
   double   tickActivityFallingSeverity;
   double   velocityAbnormalSeverity;
   double   consecutiveStopOutSeverity;
   string   label;                  // "NORMAL" / "ELEVATED_HIDDEN_RISK" / "SEVERE_HIDDEN_RISK"
   string   reason;
  };

class CHiddenRiskDetector
  {
private:
   int      m_windowSeconds;             // total trend-lookback window
   int      m_minSampleIntervalSeconds;  // derived: m_windowSeconds / AX_HRD_HISTORY
   datetime m_lastSampleTime;

   //--- plain chronological arrays (index 0 = oldest), NOT a ring buffer: samples are pushed at most  ---
   //--- once per m_minSampleIntervalSeconds (see Update()), so a shift-on-full append is cheap and     ---
   //--- keeps chronological order trivial to read back, unlike a wraparound ring buffer (matches the   ---
   //--- fix applied to DrawdownEngine.mqh's ring buffer for the same tick-rate-vs-window mismatch). ---
   double   m_spreadZHist[AX_HRD_HISTORY];
   double   m_execHist[AX_HRD_HISTORY];
   double   m_tickActHist[AX_HRD_HISTORY];
   int      m_histCount;

   double            m_wSpread, m_wVolatility, m_wExecution, m_wTickActivity, m_wVelocity, m_wConsecLosses;
   double            m_elevatedThreshold, m_severeThreshold;
   int               m_maxConsecutiveLossesForFullPenalty;

   void              PushSample(const double spreadZ,const double execScore,const double tickActScore)
     {
      if(m_histCount<AX_HRD_HISTORY)
        {
         m_spreadZHist[m_histCount]=spreadZ; m_execHist[m_histCount]=execScore; m_tickActHist[m_histCount]=tickActScore;
         m_histCount++;
        }
      else
        {
         for(int i=0;i<AX_HRD_HISTORY-1;i++)
           {
            m_spreadZHist[i]=m_spreadZHist[i+1]; m_execHist[i]=m_execHist[i+1]; m_tickActHist[i]=m_tickActHist[i+1];
           }
         m_spreadZHist[AX_HRD_HISTORY-1]=spreadZ; m_execHist[AX_HRD_HISTORY-1]=execScore; m_tickActHist[AX_HRD_HISTORY-1]=tickActScore;
        }
     }

   //--- compares the average of the older half of the trailing samples to the newer half; returns     ---
   //--- 0..100 "how much worse". worseWhenRising=true for a metric where a HIGHER raw value is worse   ---
   //--- (spread z-score); false for a metric where a LOWER raw value is worse (a 0..100 quality score, ---
   //--- e.g. execution/tick-activity scores from other engines, where higher = healthier). Returns 0   ---
   //--- (neutral, not fabricated) when fewer than 4 samples exist yet - same "no fabricated reads on    ---
   //--- insufficient data" convention used throughout this codebase (DataIntegrity/LiquidityScore/etc). ---
   double            TrendSeverity(const double &buf[],const int count,const bool worseWhenRising,const double scale) const
     {
      if(count<4) return(0.0);
      int half=count/2;
      double oldAvg=0.0; for(int i=0;i<half;i++) oldAvg+=buf[i]; oldAvg/=half;
      int newCount=count-half;
      double newAvg=0.0; for(int i=half;i<count;i++) newAvg+=buf[i]; newAvg/=newCount;
      double delta = worseWhenRising ? (newAvg-oldAvg) : (oldAvg-newAvg);
      return(AxClampD(delta*scale,0.0,100.0));
     }

public:
                     CHiddenRiskDetector(void)
     {
      m_windowSeconds=300; m_histCount=0; m_lastSampleTime=0;
      m_minSampleIntervalSeconds=MathMax(1,m_windowSeconds/AX_HRD_HISTORY);
      m_wSpread=20; m_wVolatility=15; m_wExecution=20; m_wTickActivity=15; m_wVelocity=15; m_wConsecLosses=15;
      m_elevatedThreshold=40.0; m_severeThreshold=70.0;
      m_maxConsecutiveLossesForFullPenalty=6;
     }

   void              Configure(const int windowSeconds,const double wSpread,const double wVolatility,
                                const double wExecution,const double wTickActivity,const double wVelocity,
                                const double wConsecLosses,const double elevatedThreshold,
                                const double severeThreshold,const int maxConsecutiveLossesForFullPenalty)
     {
      m_windowSeconds=MathMax(30,windowSeconds);
      m_minSampleIntervalSeconds=MathMax(1,m_windowSeconds/AX_HRD_HISTORY);
      m_wSpread=MathMax(0,wSpread); m_wVolatility=MathMax(0,wVolatility); m_wExecution=MathMax(0,wExecution);
      m_wTickActivity=MathMax(0,wTickActivity); m_wVelocity=MathMax(0,wVelocity); m_wConsecLosses=MathMax(0,wConsecLosses);
      //--- guard against a transposed-argument call silently inverting label priority (code-review       ---
      //--- finding: MQL5 has no named parameters, so two adjacent same-typed doubles are an easy swap)   ---
      //--- - severeThreshold is never allowed below elevatedThreshold, whichever order the caller passed ---
      m_elevatedThreshold=elevatedThreshold; m_severeThreshold=MathMax(elevatedThreshold,severeThreshold);
      m_maxConsecutiveLossesForFullPenalty=MathMax(1,maxConsecutiveLossesForFullPenalty);
     }

   //--- inputs are all ALREADY-COMPUTED reads from other engines (spec section 13's own components),  ---
   //--- this call never re-derives them: spreadZScore from CDataIntegrityEngine, volState from         ---
   //--- CVolatilityEngine, executionCostScore from CPriceImpactEngine, tickActivityScore/velocityScore ---
   //--- from CLiquidityScoreEngine, consecutiveLosses from CRiskEngine. Call at any cadence - internal  ---
   //--- sampling into the trend history is throttled to m_minSampleIntervalSeconds regardless. ---
   SAxHiddenRiskState Update(const double spreadZScore,const ENUM_AX_VOLATILITY_STATE volState,
                              const double executionCostScore,const double tickActivityScore,
                              const double velocityScore,const int consecutiveLosses,const datetime now)
     {
      if(m_lastSampleTime==0 || (double)(now-m_lastSampleTime)>=m_minSampleIntervalSeconds)
        {
         PushSample(spreadZScore,executionCostScore,tickActivityScore);
         m_lastSampleTime=now;
        }

      SAxHiddenRiskState s;
      //--- scale=10.0: a rising spread z-score delta of 10.0 (old-vs-new half average) reaches max      ---
      //--- severity - ENGINEERING DESIGN choice, not paper-sourced ---
      s.spreadRisingSeverity = TrendSeverity(m_spreadZHist,m_histCount,true,10.0);
      s.executionDeteriorationSeverity = TrendSeverity(m_execHist,m_histCount,false,2.0);
      s.tickActivityFallingSeverity = TrendSeverity(m_tickActHist,m_histCount,false,2.0);

      //--- volatility-state severity - a different scale/purpose than DrawdownEngine's volMultiplier   ---
      //--- (that one scales realized drawdown; this one scores the regime itself as a hidden-risk       ---
      //--- input), so intentionally not shared/reused - each engine's read stays independently          ---
      //--- reviewable (same convention as VolatilityEngine owning its own ATR handle). ---
      switch(volState)
        {
         case AX_VOL_NORMAL:  s.volatilityStateSeverity=0.0;  break;
         case AX_VOL_LOW:     s.volatilityStateSeverity=0.0;  break; // calm is not itself a hidden risk
         case AX_VOL_HIGH:    s.volatilityStateSeverity=50.0; break;
         case AX_VOL_EXTREME: s.volatilityStateSeverity=75.0; break;
         case AX_VOL_SHOCK:   s.volatilityStateSeverity=100.0; break;
         default:              s.volatilityStateSeverity=0.0;  break;
        }

      //--- abnormal velocity read as a LEVEL check (spec section 13 lists it alongside the trend items  ---
      //--- but describes it as "abnormal", not "rising"/"falling"): velocityScore is already a 0..100   ---
      //--- quality score from CLiquidityScoreEngine where a LOW score means fast/chaotic price movement ---
      //--- - so a low score IS the abnormal-velocity signal, no further derivation needed. ---
      s.velocityAbnormalSeverity = AxClampD(100.0-AxClampD(velocityScore,0.0,100.0),0.0,100.0);

      s.consecutiveStopOutSeverity = AxClampD(100.0*consecutiveLosses/(double)m_maxConsecutiveLossesForFullPenalty,0.0,100.0);

      double totalWeight = m_wSpread+m_wVolatility+m_wExecution+m_wTickActivity+m_wVelocity+m_wConsecLosses;
      s.score = (totalWeight>0) ?
         (s.spreadRisingSeverity*m_wSpread+s.volatilityStateSeverity*m_wVolatility+
          s.executionDeteriorationSeverity*m_wExecution+s.tickActivityFallingSeverity*m_wTickActivity+
          s.velocityAbnormalSeverity*m_wVelocity+s.consecutiveStopOutSeverity*m_wConsecLosses)/totalWeight
         : 0.0;

      if(s.score>=m_severeThreshold)        s.label="SEVERE_HIDDEN_RISK";
      else if(s.score>=m_elevatedThreshold) s.label="ELEVATED_HIDDEN_RISK";
      else                                    s.label="NORMAL";

      s.reason=StringFormat(
         "hiddenRisk=%.1f (spread=%.0f vol=%.0f exec=%.0f tickAct=%.0f velocity=%.0f consec=%.0f)",
         s.score,s.spreadRisingSeverity,s.volatilityStateSeverity,s.executionDeteriorationSeverity,
         s.tickActivityFallingSeverity,s.velocityAbnormalSeverity,s.consecutiveStopOutSeverity);

      return(s);
     }
  };
//+------------------------------------------------------------------+
#endif // AX_HIDDENRISKDETECTOR_MQH
