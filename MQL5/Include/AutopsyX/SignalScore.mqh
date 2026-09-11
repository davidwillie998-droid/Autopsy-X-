//+------------------------------------------------------------------+
//|                                                  SignalScore.mqh |
//|  Microstructure Score engine (spec section 4)                    |
//|  Produces independent 0..100 BUY/SELL scores + confidence         |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_SIGNALSCORE_MQH
#define AX_SIGNALSCORE_MQH
#include "Defs.mqh"
#include "MarketData.mqh"
#include "Momentum.mqh"
#include "Microstructure.mqh"
#include "Liquidity.mqh"
#include "Regime.mqh"

class CSignalScorer
  {
private:
   double            m_wMicro;
   double            m_wLiquidity;
   double            m_wMomentum;
   double            m_minScoreToAct;   // e.g. 60
   double            m_minGapToAct;     // e.g. 15 (BUY-SELL gap required)

   SAxScore          m_last;

   double            MomentumBullish(const CMomentumEngine &mom) const
     {
      double score=0;
      double vol = MathMax(mom.VolatilityPts(),0.1);
      if(mom.DisplacementPts()>0)
         score += AxClampD((mom.DisplacementPts()/vol)*8.0,0,50);
      if(mom.PersistentBull()) score += 25;
      score += MathMin(15.0, mom.ConsecBull()*3.0);
      if(mom.IsExhausted() && mom.PersistentBull()) score -= 25;
      return(AxClampD(score,0,100));
     }

   double            MomentumBearish(const CMomentumEngine &mom) const
     {
      double score=0;
      double vol = MathMax(mom.VolatilityPts(),0.1);
      if(mom.DisplacementPts()<0)
         score += AxClampD((-mom.DisplacementPts()/vol)*8.0,0,50);
      if(mom.PersistentBear()) score += 25;
      score += MathMin(15.0, mom.ConsecBear()*3.0);
      if(mom.IsExhausted() && mom.PersistentBear()) score -= 25;
      return(AxClampD(score,0,100));
     }

public:
                     CSignalScorer(void)
     {
      m_wMicro=0.40; m_wLiquidity=0.25; m_wMomentum=0.35;
      m_minScoreToAct=60.0; m_minGapToAct=15.0;
     }

   void              Configure(const double minScoreToAct,const double minGapToAct)
     {
      m_minScoreToAct = minScoreToAct;
      m_minGapToAct   = minGapToAct;
     }

   SAxScore          Evaluate(const CMarketData &md,const CMomentumEngine &mom,
                               const CMicrostructureEngine &micro,const CLiquidityEngine &liq,
                               const CRegimeEngine &regime)
     {
      SAxScore s;
      s.time   = TimeCurrent();
      s.regime = regime.Regime();

      if(!regime.TradingAllowed())
        {
         s.buyScore=0; s.sellScore=0; s.confidence=0; s.action=AX_DIR_NONE;
         m_last = s;
         return(s);
        }

      double microBull = micro.BullishScoreComponent(mom);
      double microBear = micro.BearishScoreComponent(mom);
      double liqBull    = liq.BullishScoreComponent(md.CurrentBid(),md.CurrentAsk());
      double liqBear    = liq.BearishScoreComponent(md.CurrentBid(),md.CurrentAsk());
      double momBull     = MomentumBullish(mom);
      double momBear     = MomentumBearish(mom);

      double buy  = m_wMicro*microBull + m_wLiquidity*liqBull + m_wMomentum*momBull;
      double sell = m_wMicro*microBear + m_wLiquidity*liqBear + m_wMomentum*momBear;

      //--- regime-based aggression scaling of the achieved score (section 7) ---
      double mult = regime.AggressionMultiplier();
      buy  = AxClampD(buy*mult,0,100);
      sell = AxClampD(sell*mult,0,100);

      s.buyScore  = buy;
      s.sellScore = sell;
      double gap  = MathAbs(buy-sell);
      s.confidence = AxClampD(gap*1.15,0,100);

      s.action = AX_DIR_NONE;
      if(gap>=m_minGapToAct)
        {
         if(buy>sell && buy>=m_minScoreToAct) s.action = AX_DIR_BUY;
         else if(sell>buy && sell>=m_minScoreToAct) s.action = AX_DIR_SELL;
        }

      m_last = s;
      return(s);
     }

   SAxScore          Last(void) const { return(m_last); }
  };
//+------------------------------------------------------------------+
#endif // AX_SIGNALSCORE_MQH
