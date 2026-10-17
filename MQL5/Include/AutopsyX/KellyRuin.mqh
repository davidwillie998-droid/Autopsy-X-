//+------------------------------------------------------------------+
//|                                                    KellyRuin.mqh |
//|  Conservative Kelly risk gate (FLIPDEMON EXTREME upgrade).      |
//|                                                                    |
//|  Computes classical Kelly using a conservative 95% Wilson lower   |
//|  bound on observed win rate, then supports half-Kelly size caps.   |
//|  Research context: Sinclair (2014), SSRN 2457368; Sukhov (2026),  |
//|  SSRN 6195358. Wilson-bound sizing is this project's conservative |
//|  engineering choice, not a result claimed by either paper.        |
//|                                                                    |
//|  HONEST LIMITATION: a precise closed-form "probability of ruin"    |
//|  for fractional-Kelly betting depends on assumptions this class    |
//|  has no principled way to fix (bet-sizing scheme, what counts as   |
//|  "ruin", continuous vs discrete compounding). Rather than invent a |
//|  formula with an arbitrary constant dressed up as science, this    |
//|  class reports the one thing that IS a real, standard, citable     |
//|  result: how the account's CURRENT risk-per-trade compares to the  |
//|  Kelly-optimal fraction (as a ratio) - which is the number the     |
//|  actual Kelly/fractional-Kelly literature (e.g. Thorp) uses to     |
//|  warn about overbetting, not a fabricated probability.             |
//|                                                                    |
//|  This class may only reduce permitted size or block an entry. It  |
//|  never raises risk; RiskEngine remains the hard-cap authority.     |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_KELLYRUIN_MQH
#define AX_KELLYRUIN_MQH
#include "Defs.mqh"

#define AX_KELLY_MIN_SAMPLE 30

struct SAxKellyReport
  {
   ENUM_AX_KELLY_STATE state;
   double              kellyFraction;         // f* as a fraction of equity, e.g. 0.05 = 5%
   double              halfKellyFraction;      // the commonly-used conservative half-Kelly figure
   double              currentRiskAsMultipleOfKelly; // e.g. 2.0 = currently risking 2x Kelly-optimal.
                                                       // >1.0 is the real, standard overbetting warning
                                                       // sign in the Kelly literature - not a probability.
   string              note;
  };

class CKellyRuinEngine
  {
public:
   //--- winRatePct: 0..100. Average win/loss magnitudes must be positive and use the same units.        ---
   //--- currentRiskPercent: the account's actual configured risk-per-trade (from CRiskEngine),      ---
   //--- passed in so the comparison ratio uses the real number, not a guess. ---
   SAxKellyReport    Evaluate(const double winRatePct,const double avgWinMagnitude,const double avgLossMagnitude,
                               const int sampleTrades,const double currentRiskPercent) const
     {
      SAxKellyReport rep;
      rep.state=AX_KELLY_INVALID_INPUT; rep.kellyFraction=0; rep.halfKellyFraction=0;
      rep.currentRiskAsMultipleOfKelly=0; rep.note="";

      if(sampleTrades<AX_KELLY_MIN_SAMPLE)
        {
         rep.state=AX_KELLY_INSUFFICIENT_SAMPLE;
         rep.note=StringFormat("Need >=%d closed trades for a meaningful Kelly estimate (have %d)",
                                AX_KELLY_MIN_SAMPLE,sampleTrades);
         return(rep);
        }
      if(winRatePct<=0 || winRatePct>=100)
        { rep.note="Win rate out of valid (0,100) range"; return(rep); }
      if(avgWinMagnitude<=0 || avgLossMagnitude<=0)
        { rep.note="Average win/loss R must both be positive magnitudes"; return(rep); }
      if(currentRiskPercent<=0)
        { rep.note="Current risk percent must be positive"; return(rep); }

      double p = winRatePct/100.0;
      double q = 1.0-p;
      double b = avgWinMagnitude/avgLossMagnitude;
      double kelly = p-(q/b);

      if(!MathIsValidNumber(kelly))
        {
         rep.state=AX_KELLY_BOUND_FAILED;
         rep.note="Kelly computation produced an invalid number (check inputs)";
         return(rep);
        }

      rep.kellyFraction = kelly;
      rep.halfKellyFraction = kelly/2.0;

      if(kelly<=0)
        {
         rep.state=AX_KELLY_RUIN_CONDITION;
         rep.note="Kelly fraction <= 0: at this win rate and payoff ratio the system has no positive "
                   "edge - any sustained position sizing risks long-run ruin regardless of risk-per-trade";
         return(rep);
        }

      rep.currentRiskAsMultipleOfKelly = (currentRiskPercent/100.0)/kelly;
      rep.state=AX_KELLY_VALID;
      rep.note=StringFormat("Kelly f*=%.3f (%.1f%% of equity); half-Kelly=%.1f%%; current risk %.2f%% "
                             "is %.2fx Kelly-optimal%s",
                             kelly,kelly*100.0,rep.halfKellyFraction*100.0,currentRiskPercent,
                             rep.currentRiskAsMultipleOfKelly,
                             (rep.currentRiskAsMultipleOfKelly>1.0) ? " (OVERBETTING relative to Kelly)" : "");
      return(rep);
     }

   // Conservative estimate: replace the point win-rate with the lower bound of a two-sided
   // 95% Wilson score interval before computing Kelly. This is a deliberately cautious
   // frequentist approximation, not a full Bayesian Kelly solution; payoff-ratio uncertainty
   // is not estimated here, so the caller must still apply fractional Kelly and hard risk caps.
   SAxKellyReport EvaluateConservative(const double winRatePct,const double avgWinMagnitude,const double avgLossMagnitude,
                                       const int sampleTrades,const double currentRiskPercent) const
     {
      SAxKellyReport rep;
      rep.state=AX_KELLY_INVALID_INPUT; rep.kellyFraction=0; rep.halfKellyFraction=0;
      rep.currentRiskAsMultipleOfKelly=0; rep.note="";

      if(sampleTrades<AX_KELLY_MIN_SAMPLE)
        {
         rep.state=AX_KELLY_INSUFFICIENT_SAMPLE;
         rep.note=StringFormat("Need >=%d closed trades for conservative Kelly (have %d)",
                               AX_KELLY_MIN_SAMPLE,sampleTrades);
         return(rep);
        }
      if(winRatePct<0.0 || winRatePct>100.0 || avgWinMagnitude<=0.0 || avgLossMagnitude<=0.0 || currentRiskPercent<=0.0)
        {
         rep.state=AX_KELLY_INVALID_INPUT;
         rep.note="Invalid win-rate, payoff, or current-risk input for conservative Kelly";
         return(rep);
        }

      double n=(double)sampleTrades;
      double p=winRatePct/100.0;
      const double z=1.959963984540054; // two-sided 95% Wilson interval
      double z2=z*z;
      double denom=1.0+z2/n;
      double center=p+z2/(2.0*n);
      double margin=z*MathSqrt((p*(1.0-p)/n)+(z2/(4.0*n*n)));
      double lowerP=(center-margin)/denom;
      lowerP=AxClampD(lowerP,0.0,1.0);

      if(lowerP<=0.0)
        {
         rep.state=AX_KELLY_RUIN_CONDITION;
         rep.note="95% Wilson lower bound for win probability is zero; no conservative positive edge established";
         return(rep);
        }

      rep=Evaluate(lowerP*100.0,avgWinMagnitude,avgLossMagnitude,sampleTrades,currentRiskPercent);
      if(rep.state==AX_KELLY_VALID)
         rep.note=StringFormat("95%% Wilson lower-bound win rate %.2f%%. %s",lowerP*100.0,rep.note);
      return(rep);
     }
  };
//+------------------------------------------------------------------+
#endif // AX_KELLYRUIN_MQH
