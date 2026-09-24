//+------------------------------------------------------------------+
//|                                           CompositeDirection.mqh |
//|  Composite Direction Engine (FLIPDEMON EXTREME upgrade, spec     |
//|  section 4) - weighs every directional engine against every      |
//|  other one and returns an explicit state, never a bare BUY/SELL. |
//|                                                                    |
//|  Two inputs referenced by the spec do not exist as real modules   |
//|  yet: VP-MACD and News Defense. Rather than fabricate a reading    |
//|  for either, this engine takes their state as plain strings and   |
//|  only ever counts a REAL "BULLISH"/"BEARISH" report from them -   |
//|  "DATA_UNAVAILABLE" (the honest value a caller should pass until  |
//|  those modules are built) contributes nothing to the vote, and    |
//|  News reporting "BLOCK" is a hard veto handled before any vote is |
//|  even tallied, exactly as spec section 11 requires ("must NEVER   |
//|  generate BUY or SELL direction").                                |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_COMPOSITEDIRECTION_MQH
#define AX_COMPOSITEDIRECTION_MQH
#include "Defs.mqh"
#include "Regime.mqh"
#include "OrderFlow.mqh"
#include "AntiChop.mqh"

class CCompositeDirectionEngine
  {
private:
   double            m_minConfidence;     // 0..100 - minimum |net vote| to ever call BULLISH/BEARISH
   double            m_htfMinR2;          // mirrors AxHtfConfluenceOk's own "no clear opinion" floor
   bool              m_requireNewsData;   // if true, missing news data blocks entries outright rather
                                           // than just being excluded from the vote (off by default -
                                           // see the Phase 1 gap report: no News Defense module exists
                                           // yet, and defaulting this to true would silently disable
                                           // every entry until that module is built)

public:
                     CCompositeDirectionEngine(void)
     {
      m_minConfidence   = 55.0;
      m_htfMinR2        = 0.35;
      m_requireNewsData = false;
     }

   void              Configure(const double minConfidence,const double htfMinR2,const bool requireNewsData)
     {
      m_minConfidence   = AxClampD(minConfidence,0.0,100.0);
      m_htfMinR2        = MathMax(0.0,htfMinR2);
      m_requireNewsData = requireNewsData;
     }

   //--- hard defensive blocks are checked FIRST and unconditionally override any directional read -
   //--- no vote tally, however lopsided, can ever produce BULLISH/BEARISH through a BLOCKED gate. ---
   //--- liquidity/momentum/microstructure are deliberately NOT taken as separate parameters here -   ---
   //--- CSignalScorer::Evaluate() (see SignalScore.mqh) already blends exactly those three engines    ---
   //--- into score.action via m_wLiquidity/m_wMomentum/m_wMicro, so "score" below already represents  ---
   //--- them. Passing the raw engines in as well and voting on them a second time was an earlier      ---
   //--- version of this function - removed after code-review flagged it as double/triple-counting    ---
   //--- correlated evidence and overstating the reported vote confidence. ---
   ENUM_AX_COMPOSITE_DIRECTION Evaluate(const CRegimeEngine &execRegime,const CRegimeEngine &htfRegime,
                                         const COrderFlowEngine &oflow,const CAntiChopEngine &antiChop,
                                         const SAxScore &score,const double vwapValue,const string vwapTrend,
                                         const string vpMacdState,const string newsState,
                                         const bool spreadOk,string &reasonOut) const
     {
      //--- 1. hard defensive blocks ---
      if(!spreadOk)
        { reasonOut="Spread outside acceptable range"; return(AX_COMPOSITE_BLOCKED); }
      if(antiChop.IsInCooldown())
        {
         reasonOut=StringFormat("Anti-chop cooldown (%ds remaining)",antiChop.CooldownRemainingSec());
         return(AX_COMPOSITE_BLOCKED);
        }
      if(newsState=="BLOCK")
        { reasonOut="News Defense: high-impact event window"; return(AX_COMPOSITE_BLOCKED); }
      if(m_requireNewsData && newsState=="DATA_UNAVAILABLE")
        { reasonOut="News data required but unavailable"; return(AX_COMPOSITE_BLOCKED); }

      //--- 2. data availability - regime returning UNSAFE means insufficient ATR history to classify ---
      //--- anything, which is a data problem, not a defensive condition ---
      if(!execRegime.TradingAllowed())
        {
         reasonOut="Execution-timeframe regime data unavailable (insufficient ATR history)";
         return(AX_COMPOSITE_DATA_UNAVAILABLE);
        }

      //--- 3. weighted vote tally, -1 (max bearish) .. +1 (max bullish) per usable input. an input   ---
      //--- that has no real read (e.g. VWAP unavailable, VP-MACD not built, micro imbalance near     ---
      //--- flat) is excluded from BOTH the numerator and the weight denominator - it does not get     ---
      //--- silently counted as neutral-zero, which would just dilute genuine signal with noise. ---
      double net=0.0, weightUsed=0.0; int usableInputs=0;

      //--- HTF and execution-timeframe regime slope are genuinely independent of SignalScore below -
      //--- CSignalScorer never reads either engine's Slope(), only TradingAllowed()/AggressionMultiplier() ---
      //--- the MathAbs(...)>0 guard matches CRegimeEngine::Classify()'s own "r2 alone isn't enough,   ---
      //--- slope must be genuinely nonzero too" rule - an r2==0 exactly-flat slope must never be      ---
      //--- treated as a real (if weak) directional opinion via the >=0 comparison alone. ---
      if(htfRegime.TradingAllowed() && htfRegime.R2()>=m_htfMinR2 && MathAbs(htfRegime.Slope())>0)
        {
         net += (htfRegime.Slope()>0 ? 1.0 : -1.0)*1.0;
         weightUsed += 1.0; usableInputs++;
        }

      if(execRegime.R2()>=m_htfMinR2 && MathAbs(execRegime.Slope())>0)
        {
         net += (execRegime.Slope()>0 ? 1.0 : -1.0)*0.6;
         weightUsed += 0.6; usableInputs++;
        }

      //--- liquidity-attack-readiness, momentum persistence and microstructure tick imbalance are   ---
      //--- deliberately NOT counted here as separate votes - CSignalScorer::Evaluate() already blends ---
      //--- exactly these three (m_wLiquidity/m_wMomentum/m_wMicro) into score.action below. Counting  ---
      //--- them again here would double/triple-count the same underlying evidence and report a vote   ---
      //--- confidence far higher than how independent the evidence actually is (code-review finding). ---
      //--- Order flow, VWAP and VP-MACD are kept as separate votes because none of them feed into      ---
      //--- CSignalScorer's own blend - they are computed and applied entirely outside it. ---
      if(MathAbs(oflow.ImbalanceRatio())>=0.1)
        {
         net += (oflow.ImbalanceRatio()>0 ? 1.0 : -1.0)*0.5;
         weightUsed += 0.5; usableInputs++;
        }

      if(vwapValue>0 && (vwapTrend=="BULLISH" || vwapTrend=="BEARISH"))
        {
         net += (vwapTrend=="BULLISH" ? 1.0 : -1.0)*0.5;
         weightUsed += 0.5; usableInputs++;
        }

      //--- VP-MACD: no module exists yet (Phase 1 gap report) - a caller passing "DATA_UNAVAILABLE"
      //--- contributes nothing here, exactly like any other genuinely-unavailable input ---
      if(vpMacdState=="BULLISH" || vpMacdState=="BEARISH")
        {
         net += (vpMacdState=="BULLISH" ? 1.0 : -1.0)*0.5;
         weightUsed += 0.5; usableInputs++;
        }

      //--- the blended SignalScore itself - already a combination of micro/liquidity/momentum, so it
      //--- carries the heaviest single weight rather than double-counting its own inputs at full price ---
      if(score.action!=AX_DIR_NONE)
        {
         net += (score.action==AX_DIR_BUY ? 1.0 : -1.0)*1.2;
         weightUsed += 1.2; usableInputs++;
        }

      //--- 4. insufficient evidence: too few engines produced a usable read at all to justify acting ---
      if(usableInputs<3 || weightUsed<1.5)
        {
         reasonOut=StringFormat("Only %d directional inputs produced a usable read (need >=3, weight>=1.5)",
                                 usableInputs);
         return(AX_COMPOSITE_INSUFFICIENT_EVIDENCE);
        }

      double normalized = net/weightUsed; // -1..+1
      double voteStrengthPct = MathAbs(normalized)*100.0;

      if(voteStrengthPct<m_minConfidence)
        {
         reasonOut=StringFormat("%d inputs contributed, net vote %.1f%% below confidence floor %.1f%%",
                                 usableInputs,voteStrengthPct,m_minConfidence);
         return(AX_COMPOSITE_NEUTRAL);
        }

      if(normalized>0)
        {
         reasonOut=StringFormat("%d inputs contributed, net bullish vote %.1f%%",usableInputs,voteStrengthPct);
         return(AX_COMPOSITE_BULLISH);
        }

      reasonOut=StringFormat("%d inputs contributed, net bearish vote %.1f%%",usableInputs,voteStrengthPct);
      return(AX_COMPOSITE_BEARISH);
     }
  };
//+------------------------------------------------------------------+
#endif // AX_COMPOSITEDIRECTION_MQH
