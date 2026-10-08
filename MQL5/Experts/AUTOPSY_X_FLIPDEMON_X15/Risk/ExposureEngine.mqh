//+------------------------------------------------------------------+
//| ExposureEngine.mqh                                                    |
//| Section 23 — PORTFOLIO EXPOSURE ENGINE.                               |
//| Scans all EA-owned open positions (by magic number) into per-symbol   |
//| risk/direction arrays, then asks the CorrelationEngine for effective  |
//| portfolio risk including a candidate new trade. Rejects the candidate |
//| if it would push effective risk past the configured ceiling.          |
//+------------------------------------------------------------------+
#ifndef AXF_EXPOSUREENGINE_MQH
#define AXF_EXPOSUREENGINE_MQH

#include "../Common/Defines.mqh"
#include "../Intelligence/CorrelationEngine.mqh"

class CAxfExposureEngine
  {
private:
   CAxfCorrelationEngine m_corr;
   ulong             m_magic;
   double            m_max_portfolio_risk_pct;

public:
   void              Init(const ulong magic,const double max_portfolio_risk_pct)
     {
      m_magic = magic;
      m_max_portfolio_risk_pct = MathMin(max_portfolio_risk_pct,AXF_HARD_MAX_PORTFOLIO_RISK);
     }

   //--- collects this EA's open positions into risk/direction arrays, expressed
   //--- as % of current equity, using each position's actual initial risk
   //--- (stored risk_pct in the position comment/journal would be ideal; as a
   //--- robust fallback we use live distance-to-SL * volume, which is exact for
   //--- as long as the SL has not since been trailed to reduce risk).
   int               CollectOpenRisk(string &symbols[],double &risk_pct[],ENUM_AXF_DIRECTION &dirs[])
     {
      int total = PositionsTotal();
      ArrayResize(symbols,0); ArrayResize(risk_pct,0); ArrayResize(dirs,0);
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity<=0) return 0;

      int n=0;
      for(int i=0;i<total;i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket==0) continue;
         if(!PositionSelectByTicket(ticket)) continue;
         if((ulong)PositionGetInteger(POSITION_MAGIC) != m_magic) continue;

         string sym = PositionGetString(POSITION_SYMBOL);
         double sl  = PositionGetDouble(POSITION_SL);
         double op  = PositionGetDouble(POSITION_PRICE_OPEN);
         double vol = PositionGetDouble(POSITION_VOLUME);
         long type  = PositionGetInteger(POSITION_TYPE);
         if(sl<=0) continue; // no stop -> cannot quantify risk; PositionManager should never allow this

         double tick_value = SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_VALUE);
         double tick_size  = SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_SIZE);
         if(tick_size<=0) continue;

         double dist = MathAbs(op-sl);
         double money_at_risk = (dist/tick_size)*tick_value*vol;
         double pct = (equity>0) ? money_at_risk/equity*100.0 : 0.0;

         ArrayResize(symbols,n+1); ArrayResize(risk_pct,n+1); ArrayResize(dirs,n+1);
         symbols[n]=sym; risk_pct[n]=pct;
         dirs[n] = (type==POSITION_TYPE_BUY) ? DIR_LONG : DIR_SHORT;
         n++;
        }
      return n;
     }

   //--- returns true if adding candidate_risk_pct on candidate_symbol keeps
   //--- effective portfolio risk within the configured ceiling.
   bool              CanAcceptNewRisk(const string candidate_symbol,const double candidate_risk_pct,
                                       const ENUM_AXF_DIRECTION candidate_dir,double &effective_risk_out)
     {
      string syms[]; double risks[]; ENUM_AXF_DIRECTION dirs[];
      CollectOpenRisk(syms,risks,dirs);

      effective_risk_out = m_corr.EffectivePortfolioRisk(syms,risks,dirs,candidate_symbol,candidate_risk_pct,candidate_dir);
      return (effective_risk_out <= m_max_portfolio_risk_pct);
     }

   double            CurrentEffectiveRisk(void)
     {
      string syms[]; double risks[]; ENUM_AXF_DIRECTION dirs[];
      CollectOpenRisk(syms,risks,dirs);
      return m_corr.EffectivePortfolioRisk(syms,risks,dirs,"",0.0,DIR_NONE);
     }
  };

#endif // AXF_EXPOSUREENGINE_MQH
