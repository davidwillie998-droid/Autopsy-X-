//+------------------------------------------------------------------+
//|                                                    MonteCarlo.mqh |
//|  Monte Carlo Report Engine (FLIPDEMON EXTREME upgrade, spec       |
//|  section 30) - REPORT ONLY, never touches live risk sizing.       |
//|                                                                    |
//|  Method: bootstrap resampling. Draws `simulations` random          |
//|  sequences, EACH THE SAME LENGTH as the real historical sample,    |
//|  WITH REPLACEMENT, from the journal's actual closed-trade R-       |
//|  multiples (CTradeAutopsy::GetDatasetRecords). This reshuffles     |
//|  real outcomes into alternate plausible orderings - it does not    |
//|  invent trade outcomes that never happened. The resulting          |
//|  distribution of max drawdown / losing streaks / total return      |
//|  across simulations is what "risk-of-drawdown scenarios" means     |
//|  here: a real empirical spread, not a theoretical model fit.       |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_MONTECARLO_MQH
#define AX_MONTECARLO_MQH
#include "Defs.mqh"

#define AX_MC_MIN_SAMPLE 20
#define AX_MC_MIN_SIMULATIONS 100

struct SAxMonteCarloReport
  {
   bool     valid;
   int      sampleTrades;
   int      simulations;
   double   medianMaxDrawdownR;
   double   p95MaxDrawdownR;
   double   worstMaxDrawdownR;
   int      medianLosingStreak;
   int      p95LosingStreak;
   int      worstLosingStreak;
   double   medianTotalReturnR;
   double   p5TotalReturnR;    // pessimistic scenario
   double   p95TotalReturnR;   // optimistic scenario
   string   note;
  };

class CMonteCarloEngine
  {
public:
   SAxMonteCarloReport Run(const double &rMultiples[],const int simulations=1000) const
     {
      SAxMonteCarloReport rep;
      rep.valid=false;
      rep.sampleTrades=ArraySize(rMultiples);
      rep.simulations=simulations;
      rep.medianMaxDrawdownR=0; rep.p95MaxDrawdownR=0; rep.worstMaxDrawdownR=0;
      rep.medianLosingStreak=0; rep.p95LosingStreak=0; rep.worstLosingStreak=0;
      rep.medianTotalReturnR=0; rep.p5TotalReturnR=0; rep.p95TotalReturnR=0;
      rep.note="";

      if(rep.sampleTrades<AX_MC_MIN_SAMPLE)
        {
         rep.note=StringFormat("Need >=%d closed trades for a meaningful bootstrap (have %d)",
                                AX_MC_MIN_SAMPLE,rep.sampleTrades);
         return(rep);
        }
      if(simulations<AX_MC_MIN_SIMULATIONS)
        {
         rep.note=StringFormat("Need >=%d simulations for a stable distribution read (requested %d)",
                                AX_MC_MIN_SIMULATIONS,simulations);
         return(rep);
        }

      //--- reseed on every Run() call so repeated Monte Carlo reports across EA restarts (or repeated ---
      //--- calls within one session) are genuinely independent resamples rather than the same fixed  ---
      //--- pseudo-random sequence MQL5's unseeded MathRand() would otherwise reproduce every time     ---
      //--- (code-review finding). ---
      MathSrand((int)GetTickCount());

      double ddResults[];      ArrayResize(ddResults,simulations);
      int    streakResults[];  ArrayResize(streakResults,simulations);
      double retResults[];     ArrayResize(retResults,simulations);

      for(int s=0;s<simulations;s++)
        {
         double equityR=0, peakR=0, maxDdR=0;
         int curStreak=0, worstStreak=0;
         for(int t=0;t<rep.sampleTrades;t++)
           {
            //--- modulo, not a scaled-and-clamped division - the earlier (int)(MathRand()/32767.0*n)
            //--- form gave index n-1 roughly double the draw probability of every other index whenever
            //--- MathRand() returned its maximum value and the result got clamped down (code-review
            //--- finding). Modulo's own bias (32768 not evenly divisible by n in general) is far
            //--- smaller and is the conventional approach for resampling at this scale. ---
            int idx = (int)MathRand() % rep.sampleTrades;
            double r = rMultiples[idx];

            equityR += r;
            if(equityR>peakR) peakR=equityR;
            double dd = peakR-equityR;
            if(dd>maxDdR) maxDdR=dd;

            if(r<0) { curStreak++; if(curStreak>worstStreak) worstStreak=curStreak; }
            else curStreak=0;
           }
         ddResults[s]=maxDdR;
         streakResults[s]=worstStreak;
         retResults[s]=equityR;
        }

      ArraySort(ddResults);
      ArraySort(streakResults);
      ArraySort(retResults);

      int p50 = simulations/2;
      int p95 = (int)MathMin(simulations-1,simulations*0.95);
      int p5  = (int)MathMax(0,(int)(simulations*0.05));

      rep.medianMaxDrawdownR = ddResults[p50];
      rep.p95MaxDrawdownR    = ddResults[p95];
      rep.worstMaxDrawdownR  = ddResults[simulations-1];

      rep.medianLosingStreak = streakResults[p50];
      rep.p95LosingStreak    = streakResults[p95];
      rep.worstLosingStreak  = streakResults[simulations-1];

      rep.medianTotalReturnR = retResults[p50];
      rep.p5TotalReturnR     = retResults[p5];
      rep.p95TotalReturnR    = retResults[p95];

      rep.valid=true;
      rep.note=StringFormat("Bootstrap resample: %d simulations, each %d trades drawn with "
                             "replacement from %d real historical R-multiples",
                             simulations,rep.sampleTrades,rep.sampleTrades);
      return(rep);
     }
  };
//+------------------------------------------------------------------+
#endif // AX_MONTECARLO_MQH
