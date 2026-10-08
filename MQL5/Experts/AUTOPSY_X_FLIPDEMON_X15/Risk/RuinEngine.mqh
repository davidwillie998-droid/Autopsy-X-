//+------------------------------------------------------------------+
//| RuinEngine.mqh                                                       |
//| Layer 12 — PROBABILITY-OF-RUIN ENGINE (Hidden Mechanic #2), plus     |
//| the Monte Carlo Engine (Section 37).                                 |
//|                                                                        |
//| Produces probability-of-drawdown estimates at 10/20/30/50/75% and     |
//| near-total loss, using:                                               |
//|   (a) a closed-form diffusion approximation (fast, always available)  |
//|   (b) a Monte Carlo simulation over the EA's own realised win rate /  |
//|       payoff distribution (slower, run periodically, not per tick)    |
//| Every number returned carries model_estimate=true. This engine        |
//| never claims certainty — with fewer than ~20 closed trades it widens  |
//| its estimate toward the conservative (higher-risk) side rather than   |
//| reporting a falsely precise number from a tiny sample.                |
//+------------------------------------------------------------------+
#ifndef AXF_RUINENGINE_MQH
#define AXF_RUINENGINE_MQH

#include "../Common/Defines.mqh"

class CAxfRuinEngine
  {
private:
   int               m_mc_paths;
   int               m_mc_trades;
   double            m_thr_elevated;
   double            m_thr_defensive;
   double            m_thr_halt;

   //--- closed-form gambler's-ruin-style diffusion approximation for a barrier
   //--- at log-drawdown B, given per-trade drift mu and variance sigma^2 in
   //--- log-equity space: P(ever hit barrier) ~= exp(-2*mu*B/sigma^2) for mu>0,
   //--- and 1.0 for mu<=0 (a negative-expectancy walk eventually hits any barrier).
   double            DiffusionBarrierProb(const double mu,const double sigma2,const double barrier_log)
     {
      if(barrier_log<=0) return 0.0;
      if(sigma2<=1e-12) return (mu>0)?0.0:1.0;
      if(mu<=0) return 1.0;
      double p = MathExp(-2.0*mu*barrier_log/sigma2);
      return AxfClamp(p,0.0,1.0);
     }

public:
                     CAxfRuinEngine(void) { m_mc_paths=2000; m_mc_trades=200; m_thr_elevated=15; m_thr_defensive=30; m_thr_halt=50; }

   void              Init(const int mc_paths,const int mc_trades,
                           const double thr_elevated,const double thr_defensive,const double thr_halt)
     {
      m_mc_paths  = AxfClampInt(mc_paths,200,20000);
      m_mc_trades = AxfClampInt(mc_trades,50,2000);
      m_thr_elevated  = thr_elevated;
      m_thr_defensive = thr_defensive;
      m_thr_halt      = thr_halt;
     }

   //--- fast closed-form estimate — safe to call every timer tick.
   SAxfRuinEstimate  AnalyticalEstimate(const double win_rate,const double avg_win_r,
                                         const double avg_loss_r_abs,const double risk_pct,
                                         const int sample_size)
     {
      SAxfRuinEstimate e; ZeroMemory(e); e.model_estimate=true; e.valid=false;

      double p = win_rate, q = 1.0-win_rate;
      double f = risk_pct/100.0;
      if(f<=0 || avg_win_r<=0 || avg_loss_r_abs<=0)
        {
         // no usable statistics yet: cannot claim a number, report maximum caution
         e.p_dd10=100; e.p_dd20=100; e.p_dd30=50; e.p_dd50=25; e.p_dd75=10; e.p_near_total=2;
         e.valid=true;
         return e;
        }

      // per-trade log-equity step: win -> ln(1+f*avg_win_r), loss -> ln(1-f*avg_loss_r_abs)
      double up   = MathLog(1.0+f*avg_win_r);
      double down = MathLog(MathMax(1e-6,1.0-f*avg_loss_r_abs));
      double mu = p*up + q*down;
      double sigma2 = p*(up-mu)*(up-mu) + q*(down-mu)*(down-mu);

      // small-sample widening: with under 20 trades, blend toward a pessimistic
      // prior (zero edge) so the estimate doesn't overstate confidence.
      double sample_weight = AxfClamp((double)sample_size/20.0,0.0,1.0);
      mu *= sample_weight; // shrinks drift toward 0 (neither proven good nor bad) when sample is thin

      double b10 = MathAbs(MathLog(0.90));
      double b20 = MathAbs(MathLog(0.80));
      double b30 = MathAbs(MathLog(0.70));
      double b50 = MathAbs(MathLog(0.50));
      double b75 = MathAbs(MathLog(0.25));
      double b95 = MathAbs(MathLog(0.05));

      e.p_dd10 = DiffusionBarrierProb(mu,sigma2,b10)*100.0;
      e.p_dd20 = DiffusionBarrierProb(mu,sigma2,b20)*100.0;
      e.p_dd30 = DiffusionBarrierProb(mu,sigma2,b30)*100.0;
      e.p_dd50 = DiffusionBarrierProb(mu,sigma2,b50)*100.0;
      e.p_dd75 = DiffusionBarrierProb(mu,sigma2,b75)*100.0;
      e.p_near_total = DiffusionBarrierProb(mu,sigma2,b95)*100.0;
      e.valid = true;
      return e;
     }

   //--- Monte Carlo simulation using a Bernoulli(win_rate) draw and the two
   //--- realised average payoffs. Deliberately simple (two-point outcome
   //--- distribution) rather than resampling a tiny historical trade list,
   //--- which would just replay noise; documented as such.
   //--- Call this periodically (e.g. every N minutes or after each closed
   //--- trade), never on every tick — it is O(paths*trades).
   SAxfRuinEstimate  MonteCarloEstimate(const double win_rate,const double avg_win_r,
                                         const double avg_loss_r_abs,const double risk_pct)
     {
      SAxfRuinEstimate e; ZeroMemory(e); e.model_estimate=true; e.valid=false;
      double f = risk_pct/100.0;
      if(f<=0 || avg_win_r<=0 || avg_loss_r_abs<=0 || win_rate<=0)
        {
         e.p_dd10=100; e.p_dd20=100; e.p_dd30=50; e.p_dd50=25; e.p_dd75=10; e.p_near_total=2;
         e.valid=true;
         return e;
        }

      int hit10=0, hit20=0, hit30=0, hit50=0, hit75=0, hit95=0;

      for(int path=0; path<m_mc_paths; path++)
        {
         double equity = 1.0;
         double peak = 1.0;
         bool h10=false,h20=false,h30=false,h50=false,h75=false,h95=false;
         for(int t=0; t<m_mc_trades; t++)
           {
            double r = (MathRand()/32767.0);
            if(r < win_rate)
               equity *= (1.0+f*avg_win_r);
            else
               equity *= MathMax(0.0,1.0-f*avg_loss_r_abs);

            if(equity>peak) peak=equity;
            double dd = (peak>0) ? (peak-equity)/peak : 0.0;
            if(dd>=0.10) h10=true;
            if(dd>=0.20) h20=true;
            if(dd>=0.30) h30=true;
            if(dd>=0.50) h50=true;
            if(dd>=0.75) h75=true;
            if(dd>=0.95) h95=true;
            if(equity<=0.02) { h95=true; break; } // effectively wiped out
           }
         if(h10) hit10++;
         if(h20) hit20++;
         if(h30) hit30++;
         if(h50) hit50++;
         if(h75) hit75++;
         if(h95) hit95++;
        }

      e.p_dd10 = 100.0*hit10/m_mc_paths;
      e.p_dd20 = 100.0*hit20/m_mc_paths;
      e.p_dd30 = 100.0*hit30/m_mc_paths;
      e.p_dd50 = 100.0*hit50/m_mc_paths;
      e.p_dd75 = 100.0*hit75/m_mc_paths;
      e.p_near_total = 100.0*hit95/m_mc_paths;
      e.valid = true;
      return e;
     }

   //--- conservative blend: take the WORSE (higher) reading from the two
   //--- methods on the governing metric (P 50% DD), then classify the state.
   ENUM_AXF_RUIN_STATE ClassifyState(const SAxfRuinEstimate &analytical,const SAxfRuinEstimate &monte_carlo)
     {
      double governing = MathMax(analytical.p_dd50, monte_carlo.p_dd50);
      if(governing >= m_thr_halt)      return RUIN_HALT;
      if(governing >= m_thr_defensive) return RUIN_DEFENSIVE;
      if(governing >= m_thr_elevated)  return RUIN_ELEVATED;
      return RUIN_LOW;
     }
  };

#endif // AXF_RUINENGINE_MQH
