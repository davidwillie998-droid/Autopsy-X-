//+------------------------------------------------------------------+
//|                                      PerSymbolAnalysisContext.mqh |
//| Independent base market/signal state for one MT5 symbol.          |
//| This context does not authorize execution or share state.          |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_PERSYMBOLANALYSISCONTEXT_MQH
#define AX_PERSYMBOLANALYSISCONTEXT_MQH

#include "Defs.mqh"
#include "MarketData.mqh"
#include "Momentum.mqh"
#include "Microstructure.mqh"
#include "Liquidity.mqh"
#include "Regime.mqh"
#include "SignalScore.mqh"

class CPerSymbolAnalysisContext
  {
private:
   string                 m_symbol;
   ENUM_TIMEFRAMES        m_signalTimeframe;
   ENUM_TIMEFRAMES        m_higherTimeframe;
   CMarketData            m_market;
   CMomentumEngine        m_momentum;
   CMicrostructureEngine  m_microstructure;
   CLiquidityEngine       m_liquidity;
   CRegimeEngine          m_regime;
   CRegimeEngine          m_higherRegime;
   CSignalScorer          m_scorer;
   datetime               m_lastSignalBar;
   datetime               m_lastHigherBar;
   bool                   m_initialized;
   bool                   m_hasValidTick;

public:
                           CPerSymbolAnalysisContext(void)
     {
      m_symbol="";
      m_signalTimeframe=PERIOD_M1;
      m_higherTimeframe=PERIOD_H4;
      m_lastSignalBar=0;
      m_lastHigherBar=0;
      m_initialized=false;
      m_hasValidTick=false;
     }

   bool Init(const string symbol,const ENUM_TIMEFRAMES signalTimeframe,
             const ENUM_TIMEFRAMES higherTimeframe,
             const double minScore,const double minGap)
     {
      Deinit();
      if(symbol=="") return(false);
      m_symbol=symbol;
      m_signalTimeframe=signalTimeframe;
      m_higherTimeframe=higherTimeframe;

      if(!m_market.Init(m_symbol))
        {
         PrintFormat("AX CONTEXT INIT FAILED: market data unavailable for %s",m_symbol);
         return(false);
        }
      if(!m_regime.Init(m_symbol,m_signalTimeframe))
        {
         PrintFormat("AX CONTEXT INIT FAILED: signal regime handle unavailable for %s",m_symbol);
         return(false);
        }
      if(!m_higherRegime.Init(m_symbol,m_higherTimeframe))
        {
         m_regime.Deinit();
         PrintFormat("AX CONTEXT INIT FAILED: higher-timeframe regime handle unavailable for %s",m_symbol);
         return(false);
        }
      if(!m_liquidity.Init(m_symbol,m_signalTimeframe))
        {
         m_higherRegime.Deinit();
         m_regime.Deinit();
         return(false);
        }

      m_scorer.Configure(minScore,minGap);
      m_lastSignalBar=iTime(m_symbol,m_signalTimeframe,0);
      m_lastHigherBar=iTime(m_symbol,m_higherTimeframe,0);
      m_initialized=true;
      m_hasValidTick=false;
      return(true);
     }

   void Deinit(void)
     {
      m_regime.Deinit();
      m_higherRegime.Deinit();
      m_market.Reset();
      m_momentum.Clear();
      m_microstructure.Clear();
      m_symbol="";
      m_lastSignalBar=0;
      m_lastHigherBar=0;
      m_initialized=false;
      m_hasValidTick=false;
     }

   // Call from the EA's central timer/tick scheduler. Every read is explicitly
   // keyed to this context's symbol, never _Symbol or another context's globals.
   bool Update(void)
     {
      if(!m_initialized) return(false);
      if(!m_market.OnTickUpdate()) return(false);

      m_hasValidTick=true;
      m_momentum.Update(m_market);
      m_microstructure.Update(m_market,m_momentum);
      m_liquidity.UpdateTick(m_market.CurrentBid(),m_market.CurrentAsk(),
                             m_momentum.DisplacementPts(),m_market.Point());

      datetime signalBar=iTime(m_symbol,m_signalTimeframe,0);
      if(signalBar>0 && signalBar!=m_lastSignalBar)
        {
         m_lastSignalBar=signalBar;
         m_regime.Update();
         m_liquidity.RefreshLevels();
        }

      datetime higherBar=iTime(m_symbol,m_higherTimeframe,0);
      if(higherBar>0 && higherBar!=m_lastHigherBar)
        {
         m_lastHigherBar=higherBar;
         m_higherRegime.Update();
         m_liquidity.RefreshHigherTimeframeLevels(m_symbol);
        }
      return(true);
     }

   // This is the independent base score only. Order-flow, footprint, VWAP,
   // volume-profile, sniper, spread/session and final entry qualification
   // must be applied by the owning per-symbol pipeline before a candidate
   // can be submitted to COpportunityScanner.
   bool EvaluateBaseScore(SAxScore &scoreOut)
     {
      if(!m_initialized || !m_hasValidTick || m_market.Count()<5)
         return(false);
      if(!m_regime.TradingAllowed())
        {
         scoreOut.buyScore=0.0;
         scoreOut.sellScore=0.0;
         scoreOut.confidence=0.0;
         scoreOut.action=AX_DIR_NONE;
         scoreOut.time=TimeCurrent();
         scoreOut.regime=AX_REGIME_UNSAFE;
         return(true);
        }
      scoreOut=m_scorer.Evaluate(m_market,m_momentum,m_microstructure,m_liquidity,m_regime);
      return(true);
     }

   string Symbol(void) const { return(m_symbol); }
   bool Initialized(void) const { return(m_initialized); }
   bool HasValidTick(void) const { return(m_hasValidTick); }
   double Bid(void) const { return(m_market.CurrentBid()); }
   double Ask(void) const { return(m_market.CurrentAsk()); }
   double Point(void) const { return(m_market.Point()); }
   double SpreadPoints(void) const { return(m_market.CurrentSpreadPts()); }
   double Atr(void) const { return(m_regime.CurrentAtr()); }
   ENUM_AX_REGIME Regime(void) const { return(m_regime.Regime()); }
   double HigherTimeframeSlope(void) const { return(m_higherRegime.Slope()); }
   double HigherTimeframeR2(void) const { return(m_higherRegime.R2()); }
   double LiquidityTarget(const ENUM_AX_DIR direction,const double referencePrice) const
     {
      return(m_liquidity.DrawOnLiquidityTarget(direction,referencePrice));
     }
  };

#endif // AX_PERSYMBOLANALYSISCONTEXT_MQH
