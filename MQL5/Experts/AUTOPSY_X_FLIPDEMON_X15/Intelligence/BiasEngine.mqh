//+------------------------------------------------------------------+
//| BiasEngine.mqh                                                      |
//| HTF directional bias fusion + a macro cross-check.                  |
//| Macro bias (DXY correlation for USD pairs / Gold) is used only when |
//| a DXY symbol is configured AND available in Market Watch. Per spec  |
//| section 44 (No Fabricated Intelligence), an unavailable symbol      |
//| yields UNKNOWN — it never silently defaults to "neutral" dressed up |
//| as a real read.                                                     |
//+------------------------------------------------------------------+
#ifndef AXF_BIASENGINE_MQH
#define AXF_BIASENGINE_MQH

#include "../Common/Defines.mqh"

class CAxfBiasEngine
  {
private:
   string            m_dxy_symbol;
   bool              m_dxy_available;

public:
                     CAxfBiasEngine(void) { m_dxy_symbol=""; m_dxy_available=false; }

   void              Init(const string dxy_symbol)
     {
      m_dxy_symbol = dxy_symbol;
      m_dxy_available = false;
      if(StringLen(m_dxy_symbol)>0)
         m_dxy_available = SymbolSelect(m_dxy_symbol,true);
     }

   //--- HTF bias purely from structure: DIR_LONG/DIR_SHORT/DIR_NONE.
   ENUM_AXF_DIRECTION HtfBias(const SAxfStructure &htf_structure)
     {
      if(!htf_structure.valid) return DIR_NONE;
      return htf_structure.bias;
     }

   //--- Returns true only if macro data was genuinely available and was checked.
   //--- 'aligned' is meaningless unless the return value is true.
   bool              MacroAlignment(const string symbol,const ENUM_AXF_DIRECTION dir,bool &aligned)
     {
      aligned = false;
      if(!m_dxy_available || dir==DIR_NONE) return false;

      // Correlation sign is asset-dependent and NOT hard-coded as a permanent law
      // (spec section 24): Gold and most non-USD-base majors trade broadly inverse
      // to DXY, but this is measured, not assumed, using a rolling correlation of
      // recent returns rather than a fixed lookup table.
      MqlRates rs[]; MqlRates rd[];
      ArraySetAsSeries(rs,true); ArraySetAsSeries(rd,true);
      int n = 40;
      int ns = CopyRates(symbol,PERIOD_H1,1,n+1,rs);
      int nd = CopyRates(m_dxy_symbol,PERIOD_H1,1,n+1,rd);
      if(ns<n+1 || nd<n+1) return false;

      double rs_ret[], rd_ret[];
      ArrayResize(rs_ret,n); ArrayResize(rd_ret,n);
      for(int i=0;i<n;i++)
        {
         rs_ret[i] = (rs[i+1].close>0) ? MathLog(rs[i].close/rs[i+1].close) : 0;
         rd_ret[i] = (rd[i+1].close>0) ? MathLog(rd[i].close/rd[i+1].close) : 0;
        }
      double ms=0, md=0;
      for(int i=0;i<n;i++){ ms+=rs_ret[i]; md+=rd_ret[i]; }
      ms/=n; md/=n;
      double cov=0, vs=0, vd=0;
      for(int i=0;i<n;i++)
        {
         cov += (rs_ret[i]-ms)*(rd_ret[i]-md);
         vs  += (rs_ret[i]-ms)*(rs_ret[i]-ms);
         vd  += (rd_ret[i]-md)*(rd_ret[i]-md);
        }
      double denom = MathSqrt(vs*vd);
      double corr = (denom>0) ? cov/denom : 0.0;

      // recent DXY momentum (last 5 closed H1 bars)
      double dxy_mom = rd[0].close - rd[5].close;
      int dxy_dir = (dxy_mom>0) ? 1 : (dxy_mom<0 ? -1 : 0);
      if(dxy_dir==0) return false;

      // expected symbol direction implied by measured correlation + DXY momentum
      int implied_symbol_dir = (corr>=0) ? dxy_dir : -dxy_dir;
      int wanted_dir = (dir==DIR_LONG) ? 1 : -1;

      aligned = (implied_symbol_dir == wanted_dir);
      return true; // data was available and genuinely checked
     }

   bool              HasMacroData(void) const { return m_dxy_available; }
  };

#endif // AXF_BIASENGINE_MQH
