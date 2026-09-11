//+------------------------------------------------------------------+
//| ProbabilityEngine.mqh                                              |
//| Empirical-Bayes probability estimates from this EA's own closed-  |
//| trade history. Small samples shrink hard toward a neutral 50%     |
//| prior instead of reporting a false-precision number - probability |
//| is never presented as certainty.                                  |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_SIGNALS_PROBABILITYENGINE_MQH
#define AX_SIGNALS_PROBABILITYENGINE_MQH
#include "../core/Types.mqh"
#include "../autopsy/TradeJournal.mqh"

#define AX_PRIOR_WEIGHT 10.0  // pseudo-observations pulling small samples toward 50/50

class CProbabilityEngine
  {
private:
   CTradeJournal *m_journal;

   double ShrinkToPrior(int successes, int trials, double priorProb=0.5) const
     {
      return (successes + AX_PRIOR_WEIGHT*priorProb) / (trials + AX_PRIOR_WEIGHT);
     }

public:
   void Init(CTradeJournal *journal) { m_journal = journal; }

   //--- fraction of historical trades of this setup that closed net positive
   double ProbContinuation(ENUM_AX_SETUP setup) const
     {
      string label = AXSetupToString(setup);
      int n = m_journal.Count();
      int trials=0, successes=0;
      for(int i=0;i<n;i++)
        {
         AXAutopsy r = m_journal.GetRecord(i);
         if(r.setupType!=label) continue;
         trials++;
         if(r.netProfit>0.0) successes++;
        }
      if(trials==0) return 0.5; // no history -> neutral, not invented confidence
      return ShrinkToPrior(successes, trials);
     }

   double ProbReversal(ENUM_AX_SETUP setup) const
     {
      return 1.0 - ProbContinuation(setup);
     }

   //--- probability the trade's MFE historically reached at least `targetR` multiples of initial risk
   double ProbReachesR(ENUM_AX_SETUP setup, double targetR) const
     {
      string label = AXSetupToString(setup);
      int n = m_journal.Count();
      int trials=0, successes=0;
      for(int i=0;i<n;i++)
        {
         AXAutopsy r = m_journal.GetRecord(i);
         if(r.setupType!=label) continue;
         trials++;
         if(r.mfeR >= targetR) successes++;
        }
      if(trials==0) return MathMax(0.1, 0.6 - targetR*0.1); // conservative geometric prior, never a guaranteed hit
      return ShrinkToPrior(successes, trials, MathMax(0.05, 0.6-targetR*0.1));
     }

   double ProbTp1(ENUM_AX_SETUP setup, double tp1R) const   { return ProbReachesR(setup, tp1R); }
   double ProbTp2(ENUM_AX_SETUP setup, double tp2R) const   { return ProbReachesR(setup, tp2R); }
   double ProbFinal(ENUM_AX_SETUP setup, double finalR) const { return ProbReachesR(setup, finalR); }

   int SampleSize(ENUM_AX_SETUP setup) const
     {
      string label = AXSetupToString(setup);
      int n = m_journal.Count(); int trials=0;
      for(int i=0;i<n;i++) if(m_journal.GetRecord(i).setupType==label) trials++;
      return trials;
     }
  };
#endif // AX_SIGNALS_PROBABILITYENGINE_MQH
