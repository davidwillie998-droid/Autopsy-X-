//+------------------------------------------------------------------+
//| SymbolAnalysisSlot.mqh                                           |
//| Independent, scan-only analysis state for one discovered symbol. |
//| No order placement and no risk/execution authorization.           |
//+------------------------------------------------------------------+
#ifndef AUTOPSYX_SYMBOL_ANALYSIS_SLOT_MQH
#define AUTOPSYX_SYMBOL_ANALYSIS_SLOT_MQH

#include "Defs.mqh"
#include "MarketData.mqh"
#include "Momentum.mqh"
#include "Microstructure.mqh"
#include "Liquidity.mqh"
#include "Regime.mqh"
#include "SignalScore.mqh"

struct SAxSymbolAnalysis
  {
   string       symbol;
   datetime     evaluated_at;
   bool         valid;
   ENUM_AX_DIR  action;
   double       buy_score;
   double       sell_score;
   double       confidence;
   ENUM_AX_REGIME regime;
   double       bid;
   double       ask;
   double       spread_points;
   string       reason;
  };

class CSymbolAnalysisSlot
  {
private:
   string                m_symbol;
   ENUM_TIMEFRAMES       m_tf;
   datetime              m_last_bar;
   bool                  m_initialized;
   CMarketData           m_md;
   CMomentumEngine       m_momentum;
   CMicrostructureEngine m_micro;
   CLiquidityEngine      m_liquidity;
   CRegimeEngine         m_regime;
   CSignalScorer         m_scorer;
   SAxSymbolAnalysis     m_last;

public:
                     CSymbolAnalysisSlot(void)
     {
      m_symbol="";
      m_tf=PERIOD_M1;
      m_last_bar=0;
      m_initialized=false;
      ResetResult("Not initialized");
     }

   bool              Init(const string symbol,
                          const ENUM_TIMEFRAMES timeframe=PERIOD_M1,
                          const double min_score=60.0,
                          const double min_gap=15.0)
     {
      Deinit();
      if(symbol=="") { ResetResult("Empty symbol"); return(false); }
      m_symbol=symbol;
      m_tf=timeframe;
      if(!SymbolSelect(m_symbol,true)) { ResetResult("SymbolSelect failed"); return(false); }
      if(!m_md.Init(m_symbol)) { ResetResult("Market data initialization failed"); return(false); }
      if(!m_liquidity.Init(m_symbol,m_tf)) { ResetResult("Liquidity initialization failed"); return(false); }
      if(!m_regime.Init(m_symbol,m_tf))
        {
         m_regime.Deinit();
         ResetResult("Regime indicator initialization failed");
         return(false);
        }
      m_scorer.Configure(min_score,min_gap);
      m_last_bar=iTime(m_symbol,m_tf,0);
      m_initialized=true;
      ResetResult("Initialized; waiting for sufficient live ticks and history");
      return(true);
     }

   void              Deinit(void)
     {
      m_regime.Deinit();
      m_initialized=false;
      m_symbol="";
      m_last_bar=0;
     }

   // Call for each scanner cycle. This updates only analysis state; it never trades.
   bool              Update(void)
     {
      if(!m_initialized)
        {
         ResetResult("Slot is not initialized");
         return(false);
        }

      if(!m_md.OnTickUpdate())
        {
         ResetResult("No valid current tick");
         return(false);
        }

      m_momentum.Update(m_md);
      m_micro.Update(m_md,m_momentum);

      MqlTick tick;
      if(!SymbolInfoTick(m_symbol,tick) || tick.bid<=0.0 || tick.ask<=0.0)
        {
         ResetResult("Quote unavailable");
         return(false);
        }

      m_liquidity.UpdateTick(tick.bid,tick.ask,m_momentum.DisplacementPts(),m_md.Point());

      datetime bar=iTime(m_symbol,m_tf,0);
      if(bar>0 && bar!=m_last_bar)
        {
         m_last_bar=bar;
         m_liquidity.RefreshLevels();
         m_liquidity.RefreshHigherTimeframeLevels(m_symbol);
         m_regime.Update();
        }
      else if(m_last_bar==0)
        {
         m_last_bar=bar;
         m_liquidity.RefreshLevels();
         m_liquidity.RefreshHigherTimeframeLevels(m_symbol);
         m_regime.Update();
        }

      SAxScore score=m_scorer.Evaluate(m_md,m_momentum,m_micro,m_liquidity,m_regime);
      m_last.symbol=m_symbol;
      m_last.evaluated_at=TimeCurrent();
      m_last.valid=(m_md.Count()>=5 && m_regime.TradingAllowed());
      m_last.action=m_last.valid ? score.action : AX_DIR_NONE;
      m_last.buy_score=m_last.valid ? score.buyScore : 0.0;
      m_last.sell_score=m_last.valid ? score.sellScore : 0.0;
      m_last.confidence=m_last.valid ? score.confidence : 0.0;
      m_last.regime=m_regime.Regime();
      m_last.bid=tick.bid;
      m_last.ask=tick.ask;
      m_last.spread_points=(m_md.Point()>0.0) ? (tick.ask-tick.bid)/m_md.Point() : 0.0;
      m_last.reason=m_last.valid ? "Analysis only; not an execution authorization"
                                  : "Insufficient ticks or unsafe market regime";
      return(m_last.valid);
     }

   bool              GetResult(SAxSymbolAnalysis &out) const
     {
      if(!m_initialized) return(false);
      out=m_last;
      return(true);
     }

   string            Symbol(void) const { return(m_symbol); }
   bool              IsInitialized(void) const { return(m_initialized); }

private:
   void              ResetResult(const string reason)
     {
      m_last.symbol=m_symbol;
      m_last.evaluated_at=0;
      m_last.valid=false;
      m_last.action=AX_DIR_NONE;
      m_last.buy_score=0.0;
      m_last.sell_score=0.0;
      m_last.confidence=0.0;
      m_last.regime=AX_REGIME_UNSAFE;
      m_last.bid=0.0;
      m_last.ask=0.0;
      m_last.spread_points=0.0;
      m_last.reason=reason;
     }
  };

#endif // AUTOPSYX_SYMBOL_ANALYSIS_SLOT_MQH
