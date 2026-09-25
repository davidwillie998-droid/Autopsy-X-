//+------------------------------------------------------------------+
//|                                                    KellyRuin.mqh |
//|  Kelly Criterion / Ruin-Bound Estimator (FLIPDEMON EXTREME       |
//|  upgrade, spec section 31) - REPORT ONLY.                        |
//|                                                                    |
//|  This class computes the classical Kelly fraction f* = p - q/b     |
//|  (p = win probability, q = 1-p, b = avg win / avg loss payoff      |
//|  ratio) from real closed-trade statistics. That is the entire      |
//|  scope of what is computed here - deliberately.                   |
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
//|  NEVER let this class's output authorize or size a live trade -    |
//|  see AdaptiveFlipEngine.mqh / RiskEngine.mqh for the actual risk   |
//|  authority. This is diagnostics, nothing more.                     |
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
   //--- winRatePct: 0..100. avgWinR/avgLossR: BOTH given as positive R-multiple magnitudes.        ---
   //--- currentRiskPercent: the account's actual configured risk-per-trade (from CRiskEngine),      ---
   //--- passed in so the comparison ratio uses the real number, not a guess. ---
   SAxKellyReport    Evaluate(const double winRatePct,const double avgWinR,const double avgLossR,
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
      if(avgWinR<=0 || avgLossR<=0)
        { rep.note="Average win/loss R must both be positive magnitudes"; return(rep); }
      if(currentRiskPercent<=0)
        { rep.note="Current risk percent must be positive"; return(rep); }

      double p = winRatePct/100.0;
      double q = 1.0-p;
      double b = avgWinR/avgLossR;
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
  };
//+------------------------------------------------------------------+
#endif // AX_KELLYRUIN_MQH
