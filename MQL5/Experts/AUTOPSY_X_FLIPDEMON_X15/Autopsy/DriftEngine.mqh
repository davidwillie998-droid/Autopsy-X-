//+------------------------------------------------------------------+
//| DriftEngine.mqh                                                       |
//| Section 36 — MARKET DRIFT DETECTION. Compares a rolling recent        |
//| window of closed trades against an older baseline window from the     |
//| same journal. Material deterioration recommends a risk cut;          |
//| persistent deterioration recommends a halt. This engine only ever     |
//| RECOMMENDS — the DrawdownEngine/RiskEngine remain the sole            |
//| enforcers, keeping one authoritative place for hard limits.           |
//+------------------------------------------------------------------+
#ifndef AXF_DRIFTENGINE_MQH
#define AXF_DRIFTENGINE_MQH

#include "../Common/Defines.mqh"

enum ENUM_AXF_DRIFT_SIGNAL
  {
   DRIFT_NONE = 0,
   DRIFT_REDUCE_RISK,
   DRIFT_HALT_RECOMMENDED
  };

class CAxfDriftEngine
  {
private:
   int               m_recent_n;
   int               m_baseline_n;

   double            ExpectancyOf(const SAxfTradeRecord &recs[],const int from,const int count)
     {
      int n=ArraySize(recs);
      int end = MathMin(n,from+count);
      if(end<=from) return 0.0;
      double sum=0; int c=0;
      for(int i=from;i<end;i++) { sum+=recs[i].r_multiple; c++; }
      return (c>0) ? sum/c : 0.0;
     }

public:
                     CAxfDriftEngine(void) { m_recent_n=20; m_baseline_n=60; }

   void              Init(const int recent_n,const int baseline_n)
     {
      m_recent_n = MathMax(5,recent_n);
      m_baseline_n = MathMax(m_recent_n*2,baseline_n);
     }

   //--- 'recs' must be newest-first (as TradeJournal.GetRecords returns).
   ENUM_AXF_DRIFT_SIGNAL Evaluate(const SAxfTradeRecord &recs[],double &recent_expectancy_out,double &baseline_expectancy_out)
     {
      int n = ArraySize(recs);
      recent_expectancy_out=0; baseline_expectancy_out=0;
      if(n < m_recent_n+10) return DRIFT_NONE; // not enough history to compare responsibly

      recent_expectancy_out = ExpectancyOf(recs,0,m_recent_n);
      int baseline_count = MathMin(m_baseline_n,n-m_recent_n);
      baseline_expectancy_out = ExpectancyOf(recs,m_recent_n,baseline_count);

      if(baseline_expectancy_out <= 0)
        {
         // baseline itself was never profitable — that's a strategy problem, not
         // "drift"; flag for halt review rather than pretending there was an
         // edge to drift away from.
         if(recent_expectancy_out <= 0) return DRIFT_HALT_RECOMMENDED;
         return DRIFT_NONE;
        }

      double decline = (baseline_expectancy_out-recent_expectancy_out)/MathAbs(baseline_expectancy_out);

      if(recent_expectancy_out <= 0 && decline > 0.5) return DRIFT_HALT_RECOMMENDED;
      if(decline > 0.35) return DRIFT_REDUCE_RISK;
      return DRIFT_NONE;
     }
  };

#endif // AXF_DRIFTENGINE_MQH
