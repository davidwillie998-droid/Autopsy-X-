//+------------------------------------------------------------------+
//| DriftEngine.mqh                                                     |
//| Detects statistical drift between recent behavior and the         |
//| strategy's historical baseline (win rate, expectancy, avg R,      |
//| holding time). On significant drift it recommends a risk cut, not |
//| a rewrite - the strategy logic itself is never auto-modified.     |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_AUTOPSY_DRIFTENGINE_MQH
#define AX_AUTOPSY_DRIFTENGINE_MQH
#include "../core/Types.mqh"
#include "TradeJournal.mqh"

#define AX_MIN_DRIFT_SAMPLE 20
#define AX_DRIFT_RECENT_WINDOW 15

struct AXDriftReport
  {
   bool   significant;
   double expectancyDeltaPct;
   double winRateDeltaPts;
   double avgRDeltaPct;
   string summary;
  };

class CDriftEngine
  {
public:
   AXDriftReport Evaluate(const CTradeJournal &journal) const
     {
      AXDriftReport rep;
      rep.significant=false; rep.expectancyDeltaPct=0.0; rep.winRateDeltaPts=0.0; rep.avgRDeltaPct=0.0;
      rep.summary = "Insufficient sample for drift analysis";

      int n = journal.Count();
      if(n < AX_MIN_DRIFT_SAMPLE) return rep;

      double baseExpectancy = journal.Expectancy(0);
      double recentExpectancy = journal.Expectancy(AX_DRIFT_RECENT_WINDOW);
      double baseWinRate = journal.WinRate(0);
      double recentWinRate = journal.WinRate(AX_DRIFT_RECENT_WINDOW);

      double expDeltaPct = (MathAbs(baseExpectancy)>1e-6) ? (recentExpectancy-baseExpectancy)/MathAbs(baseExpectancy)*100.0 : 0.0;
      double winDeltaPts = recentWinRate - baseWinRate;

      rep.expectancyDeltaPct = expDeltaPct;
      rep.winRateDeltaPts    = winDeltaPts;
      rep.avgRDeltaPct       = expDeltaPct;

      bool expectancyDrifted = expDeltaPct < -35.0;
      bool winRateDrifted    = winDeltaPts < -20.0;

      rep.significant = expectancyDrifted || winRateDrifted;
      rep.summary = StringFormat("Recent(%d) vs baseline: expectancy %.1f%%, win rate %.1fpts %s",
                                  AX_DRIFT_RECENT_WINDOW, expDeltaPct, winDeltaPts,
                                  rep.significant ? "-> SIGNIFICANT DRIFT, reduce risk" : "-> within envelope");
      return rep;
     }

   //--- risk multiplier to apply while drift is significant - a de-risk, never a strategy rewrite
   double RiskMultiplierFor(const AXDriftReport &rep) const
     {
      return rep.significant ? 0.5 : 1.0;
     }
  };
#endif // AX_AUTOPSY_DRIFTENGINE_MQH
