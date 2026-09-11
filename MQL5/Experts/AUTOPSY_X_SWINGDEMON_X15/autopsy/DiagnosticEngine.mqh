//+------------------------------------------------------------------+
//| DiagnosticEngine.mqh                                                |
//| Self-diagnostic: continuously watches recent performance against  |
//| the strategy's own historical baseline and can request that new   |
//| entries be suspended when live conditions fall outside it.        |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_AUTOPSY_DIAGNOSTICENGINE_MQH
#define AX_AUTOPSY_DIAGNOSTICENGINE_MQH
#include "../core/Types.mqh"
#include "TradeJournal.mqh"

#define AX_MIN_DIAG_SAMPLE 15

class CDiagnosticEngine
  {
private:
   int    m_maxTradesPerDay;
   int    m_maxTradesPerWeek;
   double m_slippageWarnPoints;

public:
   void Init(int maxTradesPerDay, int maxTradesPerWeek, double slippageWarnPoints)
     {
      m_maxTradesPerDay = maxTradesPerDay;
      m_maxTradesPerWeek = maxTradesPerWeek;
      m_slippageWarnPoints = slippageWarnPoints;
     }

   //--- true = suspend new entries; reason explains why. Never acts on a sample too small to mean anything.
   bool ShouldSuspend(const CTradeJournal &journal, int tradesOpenedToday, int tradesOpenedThisWeek,
                       double recentAvgSlippagePoints, string &reason) const
     {
      if(tradesOpenedToday > m_maxTradesPerDay)
        { reason = StringFormat("Overtrading: %d trades today exceeds cap %d", tradesOpenedToday, m_maxTradesPerDay); return true; }
      if(tradesOpenedThisWeek > m_maxTradesPerWeek)
        { reason = StringFormat("Overtrading: %d trades this week exceeds cap %d", tradesOpenedThisWeek, m_maxTradesPerWeek); return true; }
      if(recentAvgSlippagePoints > m_slippageWarnPoints)
        { reason = StringFormat("Execution quality degraded: avg slippage %.1f pts > threshold %.1f", recentAvgSlippagePoints, m_slippageWarnPoints); return true; }

      int n = journal.Count();
      if(n < AX_MIN_DIAG_SAMPLE) { reason=""; return false; } // not enough history to diagnose anything

      double baselineExpectancy = journal.Expectancy(0);
      double recentExpectancy   = journal.Expectancy(MathMin(10, n));
      double baselineWinRate    = journal.WinRate(0);
      double recentWinRate      = journal.WinRate(MathMin(10, n));

      if(recentExpectancy < baselineExpectancy*0.4 && baselineExpectancy>0.0)
        { reason = StringFormat("Expectancy deteriorating: recent %.2fR vs baseline %.2fR", recentExpectancy, baselineExpectancy); return true; }

      if(recentWinRate < baselineWinRate - 25.0 && baselineWinRate>0.0)
        { reason = StringFormat("Win rate deteriorating: recent %.1f%% vs baseline %.1f%%", recentWinRate, baselineWinRate); return true; }

      int recentLossStreak = journal.MaxConsecutiveLosses(MathMin(10, n));
      if(recentLossStreak >= 5)
        { reason = StringFormat("Excessive recent losses: %d consecutive", recentLossStreak); return true; }

      reason = "";
      return false;
     }
  };
#endif // AX_AUTOPSY_DIAGNOSTICENGINE_MQH
