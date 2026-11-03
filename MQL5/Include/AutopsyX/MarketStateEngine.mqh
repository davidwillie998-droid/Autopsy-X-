//+------------------------------------------------------------------+
//|                                             MarketStateEngine.mqh|
//|  Market State Engine (10X Market Intelligence upgrade, Phase 2) -  |
//|  ENGINEERING DESIGN, not paper-sourced. Builds the "compact state   |
//|  vector for every decision point" the upgrade's own spec asks for,   |
//|  per its PRICE/STRUCTURE/MOMENTUM/LIQUIDITY/VOLUME/VWAP grouping.      |
//|                                                                    |
//|  DELIBERATELY THIN, matching this codebase's established convention  |
//|  (InformationContentEngine.mqh/HiddenRiskDetector.mqh/CrisisEngine.  |
//|  mqh/TradePermissionMatrix.mqh all state this explicitly): every       |
//|  field below is read from an ALREADY-COMPUTED accessor on an           |
//|  existing engine (CMomentumEngine, CMicrostructureEngine,               |
//|  CLiquidityEngine, CStructureEngine, CRegimeEngine, CVWAPEngine,          |
//|  COrderFlowEngine) - this class recomputes none of their logic. The       |
//|  only genuinely new computation here is (a) a minimal own read of the      |
//|  last CLOSED bar's raw OHLC (no existing engine exposes plain OHLC),        |
//|  since price/return/gap/range have to come from somewhere, and (b) a         |
//|  VWAP-side transition detector (reclaim/rejection), which is this             |
//|  engine's own state to own, not a duplicate of CVWAPEngine's job.              |
//|                                                                    |
//|  BAR-LEVEL, NOT TICK-LEVEL (spec's own performance requirement,        |
//|  section 36): Sample() no-ops on every call except the first tick        |
//|  after a new bar closes - matches this codebase's established new-bar-    |
//|  detection convention (DrawdownEngine.mqh/HiddenRiskDetector.mqh's own      |
//|  "sample at intervals, not every tick" caching pattern).                     |
//|                                                                    |
//|  HONEST GAPS (documented rather than fabricated - matches                |
//|  MacroRegime.mqh's own "HONEST SCOPE" convention):                         |
//|   - MOMENTUM: the spec asks for separate short/medium/long momentum          |
//|     windows. CMomentumEngine currently computes exactly ONE window's          |
//|     velocity/acceleration - this engine exposes that single reading,           |
//|     labeled honestly, rather than fabricating three windows nothing            |
//|     upstream actually measures. Multi-window momentum would require            |
//|     extending CMomentumEngine itself, out of scope for this file.               |
//|   - VOLUME: relative volume, volume acceleration, and volume percentile          |
//|     (spec's own wording) are NOT available anywhere in this codebase today -      |
//|     no engine tracks a rolling volume distribution to rank against. Only           |
//|     COrderFlowEngine's already-computed windowVolume/sessionCvd/imbalanceRatio      |
//|     are exposed. Left as a documented gap, not a fabricated percentile.               |
//|   - LIQUIDITY "sweep events": no engine currently emits a discrete sweep-event         |
//|     boolean. CLiquidityEngine::BullishAttackReady()/BearishAttackReady() are the        |
//|     closest existing proxy (liquidity-attack readiness) and are exposed as such,         |
//|     not relabeled as "sweep detected".                                                     |
//|                                                                    |
//|  DATA INTEGRITY: does NOT reimplement CDataIntegrityEngine's own gate (that    |
//|  would be exactly the duplicate-engine mistake flagged in                        |
//|  docs/AUDIT_10X_MARKET_INTELLIGENCE.md). Sample() takes that engine's ALREADY-     |
//|  COMPUTED Check() result as a plain bool+reason input and threads it into           |
//|  SAxMarketStateSnapshot.dataComplete/incompleteReason - matching the master           |
//|  pipeline's own stated order (DATA INTEGRITY before MARKET STATE, spec section         |
//|  39). A snapshot with dataComplete==false still carries whatever fields could           |
//|  be read, but callers must not treat it as trustworthy (same "NO TRADE on data            |
//|  failure" discipline as everywhere else in this codebase).                                  |
//|                                                                    |
//|  SIGNAL, NOT ACTION: like every engine in this build, this class never calls     |
//|  CTrade or places an order, and is not wired into the live OnTick loop as part      |
//|  of this build.                                                                       |
//|                                                                    |
//|  VERIFICATION STATUS: balance-checked and code-reviewed only - no MQL5           |
//|  compiler is available in this build environment (see docs/VERIFICATION_STATUS.md). |
//|  COMPILATION NOT VERIFIED. No MT5 Strategy Tester run, no ablation test - this        |
//|  file has no live caller yet, so there is nothing to ablate against (see the           |
//|  Phase 2 report for the honest reason ablation testing does not apply here yet).        |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_MARKETSTATEENGINE_MQH
#define AX_MARKETSTATEENGINE_MQH
#include "Defs.mqh"
#include "Momentum.mqh"
#include "Microstructure.mqh"
#include "Liquidity.mqh"
#include "StructureEngine.mqh"
#include "Regime.mqh"
#include "VWAPEngine.mqh"
#include "OrderFlow.mqh"

struct SAxMarketStateSnapshot
  {
   datetime timestamp;          // this closed bar's own open time (the bar this snapshot describes)
   bool     dataComplete;       // false = caller-supplied data-integrity check failed for this sample;
                                  // fields below are still whatever could be read, but must not be trusted
   string   incompleteReason;   // populated only when dataComplete==false

   //--- PRICE - own minimal read (no existing engine exposes plain OHLC) ---
   double   open, high, low, close;
   double   priorClose;
   double   returnPct;          // (close-priorClose)/priorClose, 0 if priorClose<=0
   double   logReturn;          // ln(close/priorClose), 0 if either side<=0
   double   gapPts;             // (open-priorClose)/point
   double   rangePts;           // (high-low)/point
   double   atrPts;             // CRegimeEngine::CurrentAtr() - reused
   double   realizedVolPts;     // CMomentumEngine::VolatilityPts() - reused

   //--- STRUCTURE - all reused from CStructureEngine/CRegimeEngine ---
   bool     isDisplacement, isConsolidation, isExpansion, isCompression;
   bool     isBreakout;         // CRegimeEngine::IsBreakout()
   double   rangeRatio;
   int      swingCount;
   bool     hasLastSwing;       // false if CStructureEngine has no swing yet - fields below meaningless then
   bool     lastSwingIsHigh, lastSwingIsHH, lastSwingIsLH, lastSwingIsHL, lastSwingIsLL;

   //--- MOMENTUM - reused from CMomentumEngine (single window only - see file header gap) ---
   double   velocity, acceleration;
   int      consecBull, consecBear;
   double   persistenceRatio;
   bool     isExhausted;

   //--- LIQUIDITY - reused from CLiquidityEngine ---
   double   pdh, pdl, sessionHigh, sessionLow;
   bool     bullishAttackReady, bearishAttackReady; // closest existing proxy for "sweep event" - see header
   int      liquidityLevelCount;

   //--- VOLUME - reused from COrderFlowEngine (relative volume/percentile NOT available - see header gap) ---
   double   windowVolume, sessionCvd, imbalanceRatio;

   //--- MICROSTRUCTURE - reused from CMicrostructureEngine ---
   double   tickImbalance, avgSpreadPts, currentSpreadPts;
   bool     spreadExpanding, spreadCompressing, microVolatilityExpanding;

   //--- VWAP - reused from CVWAPEngine, plus one new minimal transition detector (this engine's own state) ---
   //--- vwapValue/vwapMode: CVWAPEngine only exposes GetVWAP()/Mode() publicly (GetRollingVwap()/          ---
   //--- GetSessionAnchoredVwap() are private to that class - code-review finding, this is NOT the two      ---
   //--- separate readings an earlier draft of this file assumed). ---
   double   vwapValue;
   ENUM_AX_VWAP_MODE vwapMode;
   string   vwapTrend;          // CVWAPEngine::ClassifyVWAPTrend()'s own BULLISH/BEARISH/NEUTRAL read
   string   vwapTransition;     // "VWAP_RECLAIM" / "VWAP_REJECTION" / "NONE" - new, see file header
  };

class CMarketStateEngine
  {
private:
   int                     m_capacity;
   ENUM_TIMEFRAMES         m_barTimeframe;
   SAxMarketStateSnapshot  m_ring[];
   int                     m_count;
   int                     m_head;          // index one past the most recently written slot
   datetime                m_lastSampledBarTime;
   string                  m_lastVwapSide;  // "ABOVE" / "BELOW" / "" (unknown yet) - own tracked state

   int               RingIndex(const int back) const
     {
      // back=0 is the most recently written slot
      int idx = m_head-1-back;
      while(idx<0) idx+=m_capacity;
      return(idx % m_capacity);
     }

public:
                     CMarketStateEngine(void)
     {
      m_capacity=500; m_barTimeframe=PERIOD_M5;
      m_count=0; m_head=0; m_lastSampledBarTime=0; m_lastVwapSide="";
      ArrayResize(m_ring,m_capacity);
     }

   void              Configure(const int capacity,const ENUM_TIMEFRAMES barTimeframe)
     {
      m_capacity = MathMax(10,capacity);
      m_barTimeframe = barTimeframe;
      ArrayResize(m_ring,m_capacity);
      m_count=0; m_head=0; m_lastSampledBarTime=0; m_lastVwapSide="";
     }

   //--- call every tick. Internally no-ops (returns false, `out` left untouched) unless a NEW bar has  ---
   //--- closed since the last successful sample - bar-level, not tick-level processing (file header).   ---
   //--- dataIntegrityOk/dataIntegrityReason: the caller's ALREADY-COMPUTED CDataIntegrityEngine::Check()  ---
   //--- result for this same tick - not recomputed here (file header). Returns true only when a genuinely  ---
   //--- new snapshot was built and pushed into the ring buffer. ---
   bool              Sample(const string symbol,const datetime now,const double point,
                             const bool dataIntegrityOk,const string dataIntegrityReason,
                             const CMomentumEngine &mom,const CMicrostructureEngine &micro,
                             const CLiquidityEngine &liq,const CStructureEngine &structure,
                             const CRegimeEngine &regime,const CVWAPEngine &vwap,
                             const COrderFlowEngine &orderFlow,
                             SAxMarketStateSnapshot &out)
     {
      if(point<=0) return(false);

      datetime lastClosedBarTime = iTime(symbol,m_barTimeframe,1);
      if(lastClosedBarTime<=0) return(false);          // no history yet - never fabricate a snapshot
      if(lastClosedBarTime==m_lastSampledBarTime) return(false); // already sampled this bar

      MqlRates rates[];
      ArraySetAsSeries(rates,true);
      //--- shift 1 = last CLOSED bar, shift 2 = the one before it - no lookahead (same convention as    ---
      //--- every other engine's own bar reads in this codebase, e.g. ORBEngine.mqh/VWAPEngine.mqh). ---
      if(CopyRates(symbol,m_barTimeframe,1,2,rates)<2) return(false);

      SAxMarketStateSnapshot s;
      s.timestamp = lastClosedBarTime;
      s.dataComplete = dataIntegrityOk;
      s.incompleteReason = dataIntegrityOk ? "" : dataIntegrityReason;

      s.open=rates[0].open; s.high=rates[0].high; s.low=rates[0].low; s.close=rates[0].close;
      s.priorClose=rates[1].close;
      s.returnPct = (s.priorClose>0) ? (s.close-s.priorClose)/s.priorClose : 0.0;
      s.logReturn = (s.priorClose>0 && s.close>0) ? MathLog(s.close/s.priorClose) : 0.0;
      s.gapPts   = (s.open-s.priorClose)/point;
      s.rangePts = (s.high-s.low)/point;
      //--- CRegimeEngine::CurrentAtr() returns a PRICE-space ATR (its own iATR buffer value), NOT points -  ---
      //--- confirmed against Regime.mqh's own m_currentAtr=atrBuf[0] assignment and the live EA's own        ---
      //--- point-converting call sites (e.g. AutopsyX_FlipDemon_Extreme.mq5's afeVolatilityPts). Divide       ---
      //--- here so this field's name/comment actually matches its stored unit (code-review finding). ---
      s.atrPts = (point>0) ? regime.CurrentAtr()/point : 0.0;
      s.realizedVolPts = mom.VolatilityPts();

      s.isDisplacement = structure.IsDisplacement();
      s.isConsolidation = structure.IsConsolidation();
      s.isExpansion = structure.IsExpansion();
      s.isCompression = structure.IsCompression();
      s.isBreakout = regime.IsBreakout();
      s.rangeRatio = structure.RangeRatio();
      s.swingCount = structure.SwingCount();
      SAxSwingPoint lastSwing;
      //--- CStructureEngine::m_swings is chronological, OLDEST first (its own header comment) - the    ---
      //--- most recent swing is therefore index (SwingCount()-1), never index 0 (would be a real bug     ---
      //--- if assumed otherwise - confirmed against StructureEngine.mqh's own source before writing this). ---
      s.hasLastSwing = (s.swingCount>0) && structure.GetSwing(s.swingCount-1,lastSwing);
      if(s.hasLastSwing)
        {
         s.lastSwingIsHigh=lastSwing.isHigh;
         s.lastSwingIsHH=lastSwing.isHH; s.lastSwingIsLH=lastSwing.isLH;
         s.lastSwingIsHL=lastSwing.isHL; s.lastSwingIsLL=lastSwing.isLL;
        }
      else
        {
         s.lastSwingIsHigh=false; s.lastSwingIsHH=false; s.lastSwingIsLH=false;
         s.lastSwingIsHL=false; s.lastSwingIsLL=false;
        }

      s.velocity = mom.Velocity(); s.acceleration = mom.Acceleration();
      s.consecBull = mom.ConsecBull(); s.consecBear = mom.ConsecBear();
      s.persistenceRatio = mom.PersistenceRatio();
      s.isExhausted = mom.IsExhausted();

      s.pdh = liq.PDH(); s.pdl = liq.PDL();
      s.sessionHigh = liq.SessionHigh(); s.sessionLow = liq.SessionLow();
      s.liquidityLevelCount = liq.LevelCount();
      //--- BullishAttackReady/BearishAttackReady both take a displacement-in-points argument - reuse    ---
      //--- this SAME sample's own displacement reading (mom.DisplacementPts()) rather than a second,      ---
      //--- independently-chosen threshold, so this snapshot's liquidity read is self-consistent with        ---
      //--- its own momentum read. ---
      s.bullishAttackReady = liq.BullishAttackReady(mom.DisplacementPts());
      s.bearishAttackReady = liq.BearishAttackReady(mom.DisplacementPts());

      s.windowVolume = orderFlow.WindowVolume();
      s.sessionCvd = orderFlow.SessionCvd();
      s.imbalanceRatio = orderFlow.ImbalanceRatio();

      s.tickImbalance = micro.TickImbalance();
      s.avgSpreadPts = micro.AvgSpreadPts();
      s.currentSpreadPts = micro.CurrentSpreadPts();
      s.spreadExpanding = micro.SpreadExpanding();
      s.spreadCompressing = micro.SpreadCompressing();
      s.microVolatilityExpanding = micro.VolatilityExpanding();

      //--- CVWAPEngine only exposes GetVWAP()/Mode() publicly - GetRollingVwap()/GetSessionAnchoredVwap() ---
      //--- are private to that class (code-review finding: an earlier draft called both directly, which  ---
      //--- would not compile). GetVWAP() itself already dispatches on the engine's own configured mode. ---
      s.vwapValue = vwap.GetVWAP(symbol,m_barTimeframe);
      s.vwapMode = vwap.Mode();
      //--- ClassifyVWAPTrend()'s atrPrice parameter wants a raw PRICE-space ATR, same as every existing  ---
      //--- call site (e.g. the live EA passes g_regime.CurrentAtr() straight through, no point division) - ---
      //--- pass regime.CurrentAtr() directly here too, NOT s.atrPts (which is now genuinely in points -    ---
      //--- see above fix) times point again (code-review finding: an earlier draft double-converted this,  ---
      //--- collapsing the deadband to roughly zero and defeating ClassifyVWAPTrend's own anti-flip-flop     ---
      //--- noise guard). ---
      s.vwapTrend = vwap.ClassifyVWAPTrend(s.close,s.vwapValue,regime.CurrentAtr());

      //--- new, minimal VWAP-side transition detector - this engine's own state, not CVWAPEngine's job ---
      //--- (file header). "" (unknown) on the very first sample - never guesses a transition it can't  ---
      //--- actually have observed yet. ---
      s.vwapTransition = "NONE";
      if(s.vwapValue>0)
        {
         string currentSide = (s.close>=s.vwapValue) ? "ABOVE" : "BELOW";
         if(m_lastVwapSide=="BELOW" && currentSide=="ABOVE") s.vwapTransition="VWAP_RECLAIM";
         else if(m_lastVwapSide=="ABOVE" && currentSide=="BELOW") s.vwapTransition="VWAP_REJECTION";
         m_lastVwapSide = currentSide;
        }
      else
        {
         //--- VWAP unavailable this bar - clear the tracked side rather than leaving it stale, so a       ---
         //--- later gap in valid readings can't compare a fresh side against a side from before the gap    ---
         //--- and report a transition that may have actually happened (or not) somewhere unobserved in       ---
         //--- between (code-review finding). Costs one "NONE" the bar VWAP genuinely resumes, in exchange     ---
         //--- for never fabricating a transition timing it didn't actually see. ---
         m_lastVwapSide = "";
        }

      m_ring[m_head] = s;
      m_head = (m_head+1) % m_capacity;
      if(m_count<m_capacity) m_count++;
      m_lastSampledBarTime = lastClosedBarTime;

      out = s;
      return(true);
     }

   int               Count(void) const { return(m_count); }

   //--- back=0 is the most recently sampled snapshot, back=Count()-1 the oldest still held ---
   bool              GetSample(const int back,SAxMarketStateSnapshot &out) const
     {
      if(back<0 || back>=m_count) return(false);
      out = m_ring[RingIndex(back)];
      return(true);
     }
  };
//+------------------------------------------------------------------+
#endif // AX_MARKETSTATEENGINE_MQH
