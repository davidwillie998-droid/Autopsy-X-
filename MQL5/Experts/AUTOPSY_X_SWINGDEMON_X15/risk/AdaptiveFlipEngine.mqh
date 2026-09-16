//+------------------------------------------------------------------+
//| AdaptiveFlipEngine.mqh                                              |
//| Gates whether an existing position may be FLIPPED (closed and     |
//| reversed) into a fresh opposing signal, replacing the old hard    |
//| block on any opposing position. Every input is this account's own |
//| real, live state (equity, journal history, drawdown, execution    |
//| quality) - no fixed dollar/lot/currency assumption anywhere, so   |
//| the same engine is correct on a $500 account and a $500,000 one.  |
//|                                                                    |
//| A flip is a strictly harder decision than a fresh entry: it       |
//| discards the open position's thesis and unrealized state and      |
//| commits to the opposite one, so it must clear everything a fresh  |
//| entry clears PLUS: confirmed regime change since the open position|
//| was entered, a minimum confidence/EV improvement over the thesis  |
//| being replaced, a cooldown, daily/weekly flip caps, and the       |
//| account's own capital-state machine (NORMAL/CAUTIOUS/DEFENSIVE/   |
//| RECOVERY/LOCKED). This also fulfils the original spec's section-  |
//| 17 "Swing Flip Engine" requirement, which the initial build never |
//| implemented.                                                       |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_RISK_ADAPTIVEFLIPENGINE_MQH
#define AX_RISK_ADAPTIVEFLIPENGINE_MQH
#include "../core/Types.mqh"
#include "../autopsy/TradeJournal.mqh"
#include "../autopsy/DriftEngine.mqh"
#include "../risk/DrawdownEngine.mqh"
#include "../execution/ExecutionEngine.mqh"

struct AXFlipDecision
  {
   bool                  allowed;
   string                reason;
   double                riskMultiplier;      // apply to the new trade's normal risk% when allowed==true
   ENUM_AX_CAPITAL_STATE capitalState;
   double                riskOfRuinPercent;   // 0..100, fixed-fractional approximation - see EstimateRiskOfRuinPercent
   double                edgeHealthScore;     // 0..100, 100=healthy edge, drives CAUTIOUS/DEFENSIVE thresholds
   int                   flipsToday;
   int                   flipsThisWeek;
  };

class CAdaptiveFlipEngine
  {
private:
   string   m_prefix;
   int      m_day, m_week;
   int      m_flipsToday, m_flipsThisWeek;
   datetime m_lastFlipTime;

   //--- configurable hard limits (all account-agnostic: percentages and R-multiples, never fixed money)
   int    m_maxFlipsPerDay;
   int    m_maxFlipsPerWeek;
   int    m_cooldownMinutes;
   double m_minConfidenceDelta;        // fused.confidence must beat the open thesis's by at least this many points
   double m_minEvImprovementR;         // fused.expectedValueR must beat the open thesis's expectedR by at least this much
   double m_maxRiskOfRuinPercent;
   double m_ruinThresholdEquityPercent;// equity-drawdown% treated as "ruin" for the risk-of-ruin approximation
   double m_maxExecSlippagePoints;
   int    m_minExecSamples;

   string GvName(string key) const { return m_prefix+"_"+key; }

   double GvGetOrInit(string key, double defVal)
     {
      string name = GvName(key);
      if(GlobalVariableCheck(name)) return GlobalVariableGet(name);
      GlobalVariableSet(name, defVal);
      return defVal;
     }

   void GvSet(string key, double val) { GlobalVariableSet(GvName(key), val); }

   int ISOWeekNumber(datetime t) const
     {
      MqlDateTime dt; TimeToStruct(t, dt);
      int dayOfYear = dt.day_of_year;
      int dow = (dt.day_of_week==0)?7:dt.day_of_week;
      return (dayOfYear - dow + 10) / 7;
     }

   int SeverityRank(ENUM_AX_CAPITAL_STATE s) const
     {
      switch(s)
        {
         case CAPITAL_NORMAL:    return 0;
         case CAPITAL_CAUTIOUS:  return 1;
         case CAPITAL_RECOVERY:  return 2;
         case CAPITAL_DEFENSIVE: return 3;
         case CAPITAL_LOCKED:    return 4;
        }
      return 0;
     }

   //--- raw classification only ever resolves to NORMAL/CAUTIOUS/DEFENSIVE/LOCKED - RECOVERY is a
   //--- transitional state the step-machine below assigns on the way back down, never a direct target
   ENUM_AX_CAPITAL_STATE RawCapitalState(const CDrawdownEngine &dd, double riskOfRuinPercent, double edgeHealthScore,
                                         double maxDailyLossPct, double maxWeeklyLossPct) const
     {
      double dailyDD  = dd.DailyDrawdownPercent();
      double weeklyDD = dd.WeeklyDrawdownPercent();

      if(dailyDD >= maxDailyLossPct*0.9 || weeklyDD >= maxWeeklyLossPct*0.9 || riskOfRuinPercent >= m_maxRiskOfRuinPercent*2.5)
         return CAPITAL_LOCKED;
      if(dailyDD >= maxDailyLossPct*0.6 || weeklyDD >= maxWeeklyLossPct*0.6 || riskOfRuinPercent >= m_maxRiskOfRuinPercent || edgeHealthScore < 35.0)
         return CAPITAL_DEFENSIVE;
      if(dailyDD >= maxDailyLossPct*0.3 || dd.ConsecutiveLosses()>=3 || edgeHealthScore < 60.0)
         return CAPITAL_CAUTIOUS;
      return CAPITAL_NORMAL;
     }

   //--- escalation (risk rising) is immediate - bad news is never delayed by hysteresis. De-escalation
   //--- (risk falling) steps down exactly one severity level per call, and DEFENSIVE/LOCKED must pass
   //--- through RECOVERY before regaining full-size risk, so one good trade can't undo a real breach.
   ENUM_AX_CAPITAL_STATE StepCapitalState(ENUM_AX_CAPITAL_STATE current, ENUM_AX_CAPITAL_STATE target) const
     {
      int curRank = SeverityRank(current);
      int tgtRank = SeverityRank(target);
      if(tgtRank >= curRank) return target;

      if(current==CAPITAL_LOCKED)    return CAPITAL_DEFENSIVE;
      if(current==CAPITAL_DEFENSIVE) return CAPITAL_RECOVERY;
      if(current==CAPITAL_RECOVERY)  return (tgtRank==0) ? CAPITAL_CAUTIOUS : CAPITAL_RECOVERY;
      if(current==CAPITAL_CAUTIOUS)  return target; // CAUTIOUS->NORMAL is an ordinary one-level step
      return current;
     }

public:
   //--- public so both the flip gate below AND a setup that manages its own flips outside this gate
   //--- (e.g. Setup G's VWAP recross) can size consistently off the same capital-state machine.
   double RiskMultiplierFor(ENUM_AX_CAPITAL_STATE s) const
     {
      switch(s)
        {
         case CAPITAL_NORMAL:    return 1.00;
         case CAPITAL_CAUTIOUS:  return 0.70;
         case CAPITAL_RECOVERY:  return 0.40;
         case CAPITAL_DEFENSIVE: return 0.25;
         case CAPITAL_LOCKED:    return 0.00;
        }
      return 1.00;
     }

   void Init(const string symbol, long magic,
             int maxFlipsPerDay=2, int maxFlipsPerWeek=6, int cooldownMinutes=60,
             double minConfidenceDelta=12.0, double minEvImprovementR=0.15,
             double maxRiskOfRuinPercent=5.0, double ruinThresholdEquityPercent=30.0,
             double maxExecSlippagePoints=25.0, int minExecSamples=5)
     {
      m_prefix = StringFormat("AXSD15_FLIP_%s_%I64d", symbol, magic);
      MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
      m_day = dt.day; m_week = ISOWeekNumber(TimeCurrent());
      m_flipsToday    = (int)GvGetOrInit("flips_day", 0);
      m_flipsThisWeek = (int)GvGetOrInit("flips_week", 0);
      m_lastFlipTime  = (datetime)GvGetOrInit("last_flip_time", 0);
      GvGetOrInit("capital_state", (double)CAPITAL_NORMAL);

      m_maxFlipsPerDay = MathMax(0, maxFlipsPerDay);
      m_maxFlipsPerWeek = MathMax(0, maxFlipsPerWeek);
      m_cooldownMinutes = MathMax(0, cooldownMinutes);
      m_minConfidenceDelta = minConfidenceDelta;
      m_minEvImprovementR = minEvImprovementR;
      m_maxRiskOfRuinPercent = MathMax(0.1, maxRiskOfRuinPercent);
      m_ruinThresholdEquityPercent = MathMax(1.0, ruinThresholdEquityPercent);
      m_maxExecSlippagePoints = maxExecSlippagePoints;
      m_minExecSamples = MathMax(1, minExecSamples);
     }

   //--- call once per tick/bar before evaluating; rolls day/week flip counters forward on rollover
   void Update()
     {
      MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
      int week = ISOWeekNumber(TimeCurrent());
      if(dt.day != m_day) { m_day = dt.day; m_flipsToday = 0; GvSet("flips_day", 0); }
      if(week != m_week)  { m_week = week;  m_flipsThisWeek = 0; GvSet("flips_week", 0); }
     }

   void RecordFlip()
     {
      m_flipsToday++; m_flipsThisWeek++; m_lastFlipTime = TimeCurrent();
      GvSet("flips_day", m_flipsToday);
      GvSet("flips_week", m_flipsThisWeek);
      GvSet("last_flip_time", (double)m_lastFlipTime);
     }

   int FlipsToday() const { return m_flipsToday; }
   int FlipsThisWeek() const { return m_flipsThisWeek; }
   ENUM_AX_CAPITAL_STATE CurrentCapitalState() const { return (ENUM_AX_CAPITAL_STATE)(int)GlobalVariableGet(GvName("capital_state")); }

   //--- manual override (e.g. an operator-controlled input) - never called automatically by this engine
   void ForceCapitalState(ENUM_AX_CAPITAL_STATE s) { GvSet("capital_state", (double)s); }

   //--- fixed-fractional risk-of-ruin approximation (classic gambler's-ruin-with-edge form, e.g. Vince,
   //--- "Portfolio Management Formulas"): advantage A = edge / (avg amount won+lost per trade, in R),
   //--- RoR = ((1-A)/(1+A))^Z where Z is the number of "risk units" (trades at proposedRiskPercent) between
   //--- current equity and the configured ruin threshold. This is a bounded heuristic derived from the
   //--- account's OWN measured win rate and win/loss R, not a guarantee of anything - with too few closed
   //--- trades to trust an empirical edge it degrades to a conservative flat estimate rather than 0%.
   double EstimateRiskOfRuinPercent(const CTradeJournal &journal, double proposedRiskPercent) const
     {
      int n = journal.Count();
      if(n < 15 || proposedRiskPercent<=0.0) return 20.0;

      double winRate = journal.WinRate(0)/100.0;
      double avgWin  = journal.AverageWinR(0);
      double avgLoss = journal.AverageLossR(0); // positive magnitude
      if(avgWin<=0.0 || avgLoss<=0.0) return 20.0;

      double edge = winRate*avgWin - (1.0-winRate)*avgLoss; // expectancy, in R
      if(edge <= 0.0) return 100.0; // no measured edge - ruin is the expected long-run outcome, not a guess

      double denom = winRate*avgWin + (1.0-winRate)*avgLoss;
      double advantage = MathMax(0.0001, MathMin(0.9999, edge/denom));
      double z = MathMax(1.0, m_ruinThresholdEquityPercent/proposedRiskPercent);

      double ror = MathPow((1.0-advantage)/(1.0+advantage), z);
      return MathMax(0.0, MathMin(100.0, ror*100.0));
     }

   //--- combines DriftEngine's statistical-significance flag with recent expectancy and the live
   //--- consecutive-loss streak into one 0..100 score - a single dial for "is the edge still working."
   double EstimateEdgeHealthScore(const CTradeJournal &journal, const AXDriftReport &drift, int consecutiveLosses) const
     {
      double score = 100.0;
      if(drift.significant) score -= 35.0;
      if(drift.expectancyDeltaPct < 0.0) score += MathMax(-25.0, drift.expectancyDeltaPct*0.3);
      if(consecutiveLosses>=3) score -= 15.0;
      if(consecutiveLosses>=5) score -= 20.0;
      if(journal.Count()>=15 && journal.Expectancy(15) < 0.0) score -= 20.0;
      return MathMax(0.0, MathMin(100.0, score));
     }

   //--- the main gate. Returns allowed=false with a human-readable reason the instant any criterion
   //--- fails, so the caller (and the journal/dashboard) always has a concrete explanation on record.
   AXFlipDecision EvaluateFlip(const AXFusedSignal &fused,
                               const AXTradeThesis &openThesis,
                               ENUM_AX_REGIME currentRegime,
                               const CTradeJournal &journal,
                               const CDrawdownEngine &drawdown,
                               const AXExecutionQualityStats &execStats,
                               double proposedRiskPercent,
                               double maxDailyLossPct, double maxWeeklyLossPct,
                               bool allowFlips)
     {
      AXFlipDecision d;
      d.allowed = false; d.reason = ""; d.riskMultiplier = 0.0;
      d.flipsToday = m_flipsToday; d.flipsThisWeek = m_flipsThisWeek;

      CDriftEngine driftEngine;
      AXDriftReport drift = driftEngine.Evaluate(journal);
      d.riskOfRuinPercent = EstimateRiskOfRuinPercent(journal, proposedRiskPercent);
      d.edgeHealthScore   = EstimateEdgeHealthScore(journal, drift, drawdown.ConsecutiveLosses());

      ENUM_AX_CAPITAL_STATE rawTarget = RawCapitalState(drawdown, d.riskOfRuinPercent, d.edgeHealthScore, maxDailyLossPct, maxWeeklyLossPct);
      ENUM_AX_CAPITAL_STATE prevState = CurrentCapitalState();
      ENUM_AX_CAPITAL_STATE newState  = StepCapitalState(prevState, rawTarget);
      if(newState != prevState) GvSet("capital_state", (double)newState);
      d.capitalState = newState;

      if(!allowFlips)
        { d.reason = "Flip engine disabled by configuration"; return d; }

      if(newState==CAPITAL_LOCKED)
        {
         d.reason = StringFormat("Capital state LOCKED (RoR %.1f%%, edge health %.0f) - no flips until state recovers",
                                  d.riskOfRuinPercent, d.edgeHealthScore);
         return d;
        }

      if(m_flipsToday >= m_maxFlipsPerDay)
        { d.reason = StringFormat("Daily flip cap reached (%d/%d)", m_flipsToday, m_maxFlipsPerDay); return d; }
      if(m_flipsThisWeek >= m_maxFlipsPerWeek)
        { d.reason = StringFormat("Weekly flip cap reached (%d/%d)", m_flipsThisWeek, m_maxFlipsPerWeek); return d; }
      if(m_lastFlipTime>0 && (TimeCurrent()-m_lastFlipTime) < m_cooldownMinutes*60)
        {
         d.reason = StringFormat("Flip cooldown active (%.0f of %d min elapsed)",
                                  (double)(TimeCurrent()-m_lastFlipTime)/60.0, m_cooldownMinutes);
         return d;
        }

      if(!fused.passesFilters)
        { d.reason = "Opposing signal fails standard fusion filters: "+fused.rejectReason; return d; }
      if(fused.signal.direction == openThesis.direction)
        { d.reason = "Not an opposing signal - same direction as the open position"; return d; }

      // a flip is a bet the underlying regime actually turned, not short-term noise - require the
      // regime attached to the fresh signal to differ from the one the open position was entered under
      if(currentRegime == openThesis.regime)
        {
         d.reason = StringFormat("Regime unchanged since entry (%s) - opposition may be noise, not a genuine reversal",
                                  AXRegimeToString(currentRegime));
         return d;
        }

      double confidenceDelta = fused.confidence - openThesis.confidence;
      if(confidenceDelta < m_minConfidenceDelta)
        {
         d.reason = StringFormat("Confidence improvement %.1f below minimum %.1f (new %.1f vs open %.1f)",
                                  confidenceDelta, m_minConfidenceDelta, fused.confidence, openThesis.confidence);
         return d;
        }

      double evImprovement = fused.expectedValueR - openThesis.expectedR;
      if(evImprovement < m_minEvImprovementR)
        {
         d.reason = StringFormat("EV improvement %.2fR below minimum %.2fR", evImprovement, m_minEvImprovementR);
         return d;
        }

      if(execStats.sampleSize >= m_minExecSamples && execStats.avgSlippagePoints > m_maxExecSlippagePoints)
        {
         d.reason = StringFormat("Execution quality too poor to trust a flip's fill (avg slippage %.1f pts > limit %.1f)",
                                  execStats.avgSlippagePoints, m_maxExecSlippagePoints);
         return d;
        }

      if(d.riskOfRuinPercent > m_maxRiskOfRuinPercent)
        {
         d.reason = StringFormat("Estimated risk-of-ruin %.1f%% exceeds limit %.1f%%", d.riskOfRuinPercent, m_maxRiskOfRuinPercent);
         return d;
        }

      d.allowed = true;
      d.riskMultiplier = RiskMultiplierFor(newState);
      d.reason = StringFormat("Flip approved: capital=%s, RoR=%.1f%%, edge=%.0f, confDelta=%.1f, evImp=%.2fR",
                               AXCapitalStateToString(newState), d.riskOfRuinPercent, d.edgeHealthScore,
                               confidenceDelta, evImprovement);
      return d;
     }
  };
#endif // AX_RISK_ADAPTIVEFLIPENGINE_MQH
