//+------------------------------------------------------------------+
//|                                                Microstructure.mqh|
//|  Microstructure Score inputs (spec section 4)                    |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_MICROSTRUCTURE_MQH
#define AX_MICROSTRUCTURE_MQH
#include "Defs.mqh"
#include "MarketData.mqh"
#include "Momentum.mqh"

class CMicrostructureEngine
  {
private:
   double            m_tickImbalance;   // -1 (all down) .. +1 (all up)
   double            m_avgSpreadPts;
   double            m_currentSpreadPts;
   double            m_spreadDeltaPts;  // current - average
   bool              m_spreadExpanding;
   bool              m_spreadCompressing;
   bool              m_volExpansion;
   double            m_volBaseline;
   double            m_volBaselinePrev;

public:
                     CMicrostructureEngine(void) { Clear(); }

   void              Clear(void)
     {
      m_tickImbalance=0; m_avgSpreadPts=0; m_currentSpreadPts=0; m_spreadDeltaPts=0;
      m_spreadExpanding=false; m_spreadCompressing=false; m_volExpansion=false;
      m_volBaseline=0; m_volBaselinePrev=0;
     }

   void              Update(const CMarketData &md,const CMomentumEngine &mom)
     {
      int n = MathMin(md.Count(),40);
      if(n<5) return;

      int up=0,down=0; double spreadSum=0;
      for(int i=0;i<n;i++)
        {
         SAxTick t;
         if(!md.GetSample(i,t)) continue;
         if(t.dir>0) up++;
         else if(t.dir<0) down++;
         spreadSum += t.spreadPts;
        }
      int total = up+down;
      m_tickImbalance = (total>0)? (double)(up-down)/(double)total : 0.0;

      m_avgSpreadPts     = spreadSum/n;
      m_currentSpreadPts = md.CurrentSpreadPts();
      m_spreadDeltaPts   = m_currentSpreadPts - m_avgSpreadPts;
      m_spreadExpanding   = m_currentSpreadPts > m_avgSpreadPts*1.4 && m_currentSpreadPts>m_avgSpreadPts+0.5;
      m_spreadCompressing = m_currentSpreadPts < m_avgSpreadPts*0.7;

      //--- volatility expansion: current momentum volatility vs previous reading ---
      m_volBaselinePrev = m_volBaseline;
      m_volBaseline = mom.VolatilityPts();
      m_volExpansion = (m_volBaselinePrev>0) && (m_volBaseline > m_volBaselinePrev*1.3);
     }

   double            TickImbalance(void)     const { return(m_tickImbalance); }
   double            AvgSpreadPts(void)      const { return(m_avgSpreadPts); }
   double            CurrentSpreadPts(void)  const { return(m_currentSpreadPts); }
   bool              SpreadExpanding(void)   const { return(m_spreadExpanding); }
   bool              SpreadCompressing(void) const { return(m_spreadCompressing); }
   bool              VolatilityExpanding(void) const { return(m_volExpansion); }

   bool              SpreadAcceptable(const double maxSpreadPts) const
     {
      return(m_currentSpreadPts>0 && m_currentSpreadPts<=maxSpreadPts);
     }

   //--- 0..100 microstructure bias components, combined with momentum/liquidity in SignalScore ---
   double            BullishScoreComponent(const CMomentumEngine &mom) const
     {
      double score=0;
      if(m_tickImbalance>0) score += m_tickImbalance*35;           // positive tick imbalance
      if(mom.Acceleration()>0 && mom.PersistentBull()) score += 20; // bullish acceleration
      if(mom.ConsecBull()>=3) score += 15;
      if(m_volExpansion && mom.DisplacementPts()>0) score += 15;    // volatility expansion + displacement
      if(!m_spreadExpanding) score += 15;                           // spread acceptable
      return(AxClampD(score,0,100));
     }

   double            BearishScoreComponent(const CMomentumEngine &mom) const
     {
      double score=0;
      if(m_tickImbalance<0) score += (-m_tickImbalance)*35;
      if(mom.Acceleration()<0 && mom.PersistentBear()) score += 20;
      if(mom.ConsecBear()>=3) score += 15;
      if(m_volExpansion && mom.DisplacementPts()<0) score += 15;
      if(!m_spreadExpanding) score += 15;
      return(AxClampD(score,0,100));
     }
  };
//+------------------------------------------------------------------+
#endif // AX_MICROSTRUCTURE_MQH
