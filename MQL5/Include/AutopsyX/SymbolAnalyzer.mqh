//+------------------------------------------------------------------+
//|                                               SymbolAnalyzer.mqh |
//| Independent analysis stack for one candidate symbol              |
//| Analysis only: never submits orders or changes account exposure. |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_SYMBOLANALYZER_MQH
#define AX_SYMBOLANALYZER_MQH

#include "Defs.mqh"
#include "MarketData.mqh"
#include "Momentum.mqh"
#include "Microstructure.mqh"
#include "Liquidity.mqh"
#include "Regime.mqh"
#include "SignalScore.mqh"

class CAxSymbolAnalyzer
  {
private:
   string                 m_symbol;
   ENUM_TIMEFRAMES        m_signalTf;
   ENUM_TIMEFRAMES        m_htf;
   CMarketData            m_md;
   CMomentumEngine        m_momentum;
   CMicrostructureEngine  m_micro;
   CLiquidityEngine       m_liquidity;
   CRegimeEngine          m_regime;
   CRegimeEngine          m_regimeHtf;
   CSignalScorer          m_scorer;
   datetime               m_lastSignalBar;
   datetime               m_lastHtfBar;
   SAxScore               m_lastScore;
   bool                   m_initialized;
   bool                   m_scoreValid;

public:
                           CAxSymbolAnalyzer(void)
     {
      m_symbol="";
      m_signalTf=PERIOD_M1;
      m_htf=PERIOD_H1;
      m_lastSignalBar=0;
      m_lastHtfBar=0;
      m_initialized=false;
      m_scoreValid=false;
      ZeroMemory(m_lastScore);
     }

   bool                    Init(const string symbol,
                                const ENUM_TIMEFRAMES signalTf,
                                const ENUM_TIMEFRAMES htf,
                                const double minScore,
                                const double minGap)
     {
      m_symbol=symbol;
      m_signalTf=signalTf;
      m_htf=htf;
      m_initialized=false;
      m_scoreValid=false;

      if(!m_md.Init(m_symbol))
        {
         PrintFormat("AX Analyzer [%s]: market-data init failed.",m_symbol);
         return(false);
        }
      if(!m_regime.Init(m_symbol,m_signalTf))
        {
         PrintFormat("AX Analyzer [%s]: signal regime init failed.",m_symbol);
         return(false);
        }
      if(!m_regimeHtf.Init(m_symbol,m_htf))
        {
         PrintFormat("AX Analyzer [%s]: HTF regime init failed.",m_symbol);
         m_regime.Deinit();
         return(false);
        }
      if(!m_liquidity.Init(m_symbol,m_signalTf))
        {
         PrintFormat("AX Analyzer [%s]: liquidity init failed.",m_symbol);
         m_regime.Deinit();
         m_regimeHtf.Deinit();
         return(false);
        }
      m_scorer.Configure(minScore,minGap);
      // Prime indicators and structural levels immediately; otherwise the analyzer
      // would wait for the next bar transition before its first usable score.
      m_regime.Update();
      m_regimeHtf.Update();
      m_liquidity.RefreshLevels();
      m_liquidity.RefreshHigherTimeframeLevels(m_symbol);
      m_lastSignalBar=iTime(m_symbol,m_signalTf,0);
      m_lastHtfBar=iTime(m_symbol,m_htf,0);
      m_initialized=true;
      PrintFormat("AX Analyzer [%s]: independent analysis stack initialized.",m_symbol);
      return(true);
     }

   void                    Deinit(void)
     {
      m_regime.Deinit();
      m_regimeHtf.Deinit();
      m_initialized=false;
      m_scoreValid=false;
     }

   bool                    Update(void)
     {
      if(!m_initialized) return(false);
      if(!m_md.OnTickUpdate()) return(false);

      m_momentum.Update(m_md);
      m_micro.Update(m_md,m_momentum);
      m_liquidity.UpdateTick(m_md.CurrentBid(),m_md.CurrentAsk(),
                             m_momentum.DisplacementPts(),m_md.Point());

      datetime signalBar=iTime(m_symbol,m_signalTf,0);
      if(signalBar>0 && signalBar!=m_lastSignalBar)
        {
         m_lastSignalBar=signalBar;
         m_regime.Update();
         m_liquidity.RefreshLevels();
         m_liquidity.RefreshHigherTimeframeLevels(m_symbol);
        }

      datetime htfBar=iTime(m_symbol,m_htf,0);
      if(htfBar>0 && htfBar!=m_lastHtfBar)
        {
         m_lastHtfBar=htfBar;
         m_regimeHtf.Update();
        }

      if(m_md.Count()<5) return(false);
      m_lastScore=m_scorer.Evaluate(m_md,m_momentum,m_micro,m_liquidity,m_regime);
      m_scoreValid=(m_lastScore.time>0 && m_regime.Regime()!=AX_REGIME_UNSAFE);
      return(m_scoreValid);
     }

   string                  Symbol(void) const { return(m_symbol); }
   bool                    Initialized(void) const { return(m_initialized); }
   bool                    ScoreValid(void) const { return(m_scoreValid); }
   bool                    ScoreIsFresh(const int maxAgeSeconds) const
     {
      if(!m_scoreValid || maxAgeSeconds<1 || m_lastScore.time<=0) return(false);
      int age=(int)(TimeCurrent()-m_lastScore.time);
      return(age>=0 && age<=maxAgeSeconds);
     }
   int                     ScoreAgeSeconds(void) const
     {
      if(!m_scoreValid || m_lastScore.time<=0) return(2147483647);
      int age=(int)(TimeCurrent()-m_lastScore.time);
      return(age<0 ? 2147483647 : age);
     }
   SAxScore                LastScore(void) const { return(m_lastScore); }
   ENUM_AX_REGIME          Regime(void) const { return(m_regime.Regime()); }
   ENUM_AX_REGIME          HtfRegime(void) const { return(m_regimeHtf.Regime()); }
   double                  SignalAtr(void) const { return(m_regime.CurrentAtr()); }
   double                  SignalSlope(void) const { return(m_regime.Slope()); }
   double                  HtfSlope(void) const { return(m_regimeHtf.Slope()); }
   double                  SpreadPoints(void) const { return(m_md.CurrentSpreadPts()); }
   double                  Point(void) const { return(m_md.Point()); }
  };

#endif // AX_SYMBOLANALYZER_MQH
