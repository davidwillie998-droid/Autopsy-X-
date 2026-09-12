//+------------------------------------------------------------------+
//| CorrelationEngine.mqh                                               |
//| Section 23 — PORTFOLIO EXPOSURE ENGINE.                             |
//| Recognises that several correlated single-symbol positions can be   |
//| one large hidden macro bet, and computes an "effective portfolio    |
//| risk" that is >= the naive sum of per-trade risk whenever open       |
//| positions are correlated in the same direction.                     |
//+------------------------------------------------------------------+
#ifndef AXF_CORRELATIONENGINE_MQH
#define AXF_CORRELATIONENGINE_MQH

#include "../Common/Defines.mqh"

class CAxfCorrelationEngine
  {
private:
   double            PairCorrelation(const string sym_a,const string sym_b,const int bars=40)
     {
      if(sym_a==sym_b) return 1.0;
      MqlRates ra[]; MqlRates rb[];
      ArraySetAsSeries(ra,true); ArraySetAsSeries(rb,true);
      int na = CopyRates(sym_a,PERIOD_H1,1,bars+1,ra);
      int nb = CopyRates(sym_b,PERIOD_H1,1,bars+1,rb);
      if(na<bars+1 || nb<bars+1) return 0.0; // insufficient data -> treat as uncorrelated (conservative for the sum, not for the estimate)

      double reta[], retb[];
      ArrayResize(reta,bars); ArrayResize(retb,bars);
      for(int i=0;i<bars;i++)
        {
         reta[i] = (ra[i+1].close>0) ? MathLog(ra[i].close/ra[i+1].close) : 0;
         retb[i] = (rb[i+1].close>0) ? MathLog(rb[i].close/rb[i+1].close) : 0;
        }
      double ma=0, mb=0;
      for(int i=0;i<bars;i++){ ma+=reta[i]; mb+=retb[i]; }
      ma/=bars; mb/=bars;
      double cov=0, va=0, vb=0;
      for(int i=0;i<bars;i++)
        {
         cov += (reta[i]-ma)*(retb[i]-mb);
         va  += (reta[i]-ma)*(reta[i]-ma);
         vb  += (retb[i]-mb)*(retb[i]-mb);
        }
      double denom = MathSqrt(va*vb);
      return (denom>0) ? cov/denom : 0.0;
     }

public:
   //--- 'open_symbols'/'open_risk_pct'/'open_dir' describe currently open EA
   //--- positions (same length arrays). Returns the effective portfolio risk
   //--- INCLUDING a candidate new trade (candidate_risk_pct may be 0 to just
   //--- measure current exposure).
   double            EffectivePortfolioRisk(const string &open_symbols[],
                                             const double &open_risk_pct[],
                                             const ENUM_AXF_DIRECTION &open_dir[],
                                             const string candidate_symbol,
                                             const double candidate_risk_pct,
                                             const ENUM_AXF_DIRECTION candidate_dir)
     {
      int n = ArraySize(open_symbols);
      int total_n = n + (candidate_risk_pct>0 ? 1 : 0);
      if(total_n==0) return 0.0;

      string syms[]; double risks[]; ENUM_AXF_DIRECTION dirs[];
      ArrayResize(syms,total_n); ArrayResize(risks,total_n); ArrayResize(dirs,total_n);
      for(int i=0;i<n;i++) { syms[i]=open_symbols[i]; risks[i]=open_risk_pct[i]; dirs[i]=open_dir[i]; }
      if(candidate_risk_pct>0)
        { syms[n]=candidate_symbol; risks[n]=candidate_risk_pct; dirs[n]=candidate_dir; }

      // effective risk = sqrt( sum_i sum_j risk_i * risk_j * corr_ij * sign_i * sign_j )
      // — a portfolio-variance-style aggregation. Same-direction correlated
      // positions add up close to linearly; opposite-direction correlated
      // positions partially net out; uncorrelated positions add in quadrature.
      double sum=0;
      for(int i=0;i<total_n;i++)
        {
         for(int j=0;j<total_n;j++)
           {
            double corr = (i==j) ? 1.0 : PairCorrelation(syms[i],syms[j]);
            int si = (dirs[i]==DIR_LONG) ? 1 : -1;
            int sj = (dirs[j]==DIR_LONG) ? 1 : -1;
            sum += risks[i]*risks[j]*corr*si*sj;
           }
        }
      sum = MathMax(0.0,sum);
      return MathSqrt(sum);
     }
  };

#endif // AXF_CORRELATIONENGINE_MQH
