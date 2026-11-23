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
   double            m_spreadHistory[100];
   int               m_spreadHistoryCount;
   int               m_spreadHistoryNext;
   double            m_spreadHistoryAverage;
   long              m_stopsLevelPoints;
   long              m_freezeLevelPoints;

public:
                     CMicrostructureEngine(void) { Clear(); }

   void              Clear(void)
     {
      m_tickImbalance=0; m_avgSpreadPts=0; m_currentSpreadPts=0; m_spreadDeltaPts=0;
      m_spreadExpanding=false; m_spreadCompressing=false; m_volExpansion=false;
      m_volBaseline=0; m_volBaselinePrev=0;
      m_spreadHistoryCount=0; m_spreadHistoryNext=0; m_spreadHistoryAverage=0.0;
      m_stopsLevelPoints=0; m_freezeLevelPoints=0;
      for(int i=0;i<100;i++) m_spreadHistory[i]=0.0;
     }

   void              Update(const string symbol,const CMarketData &md,const CMomentumEngine &mom)
     {
      // Record each accepted tick in a fixed 100-observation spread ring.
      // A nonzero freeze level is metadata for distance checks, not a blanket
      // ban on every new entry or every protective position action.
      m_currentSpreadPts=md.CurrentSpreadPts();
      if(MathIsValidNumber(m_currentSpreadPts) && m_currentSpreadPts>=0.0)
        {
         m_spreadHistory[m_spreadHistoryNext]=m_currentSpreadPts;
         m_spreadHistoryNext=(m_spreadHistoryNext+1)%100;
         if(m_spreadHistoryCount<100) m_spreadHistoryCount++;
         double sum=0.0;
         for(int spreadIndex=0;spreadIndex<m_spreadHistoryCount;spreadIndex++)
            sum+=m_spreadHistory[spreadIndex];
         m_spreadHistoryAverage=(m_spreadHistoryCount>0)?sum/(double)m_spreadHistoryCount:0.0;
        }
      m_stopsLevelPoints=SymbolInfoInteger(symbol,SYMBOL_TRADE_STOPS_LEVEL);
      m_freezeLevelPoints=SymbolInfoInteger(symbol,SYMBOL_TRADE_FREEZE_LEVEL);

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
      m_spreadDeltaPts   = m_currentSpreadPts - m_spreadHistoryAverage;
      m_spreadExpanding   = m_currentSpreadPts > m_avgSpreadPts*1.4 && m_currentSpreadPts>m_avgSpreadPts+0.5;
      m_spreadCompressing = m_currentSpreadPts < m_avgSpreadPts*0.7;

      //--- volatility expansion: current momentum volatility vs previous reading ---
      m_volBaselinePrev = m_volBaseline;
      m_volBaseline = mom.VolatilityPts();
      m_volExpansion = (m_volBaselinePrev>0) && (m_volBaseline > m_volBaselinePrev*1.3);
     }

   double            TickImbalance(void)     const { return(m_tickImbalance); }
   double            AvgSpreadPts(void)      const { return(m_avgSpreadPts); }
   double            Rolling100SpreadAvgPts(void) const { return(m_spreadHistoryAverage); }
   int               RollingSpreadSampleCount(void) const { return(m_spreadHistoryCount); }
   long              StopsLevelPoints(void) const { return(m_stopsLevelPoints); }
   long              FreezeLevelPoints(void) const { return(m_freezeLevelPoints); }
   double            SpreadSpikeMultiple(void) const
     {
      return(m_spreadHistoryAverage>0.0 ? m_currentSpreadPts/m_spreadHistoryAverage : 0.0);
     }
   bool              SpreadSpikeDetected(const double multiple=3.0) const
     {
      return(m_spreadHistoryCount>=20 && multiple>1.0 &&
             m_spreadHistoryAverage>0.0 && m_currentSpreadPts>m_spreadHistoryAverage*multiple);
     }
   double            CurrentSpreadPts(void)  const { return(m_currentSpreadPts); }
   bool              SpreadExpanding(void)   const { return(m_spreadExpanding); }
   bool              SpreadCompressing(void) const { return(m_spreadCompressing); }
   bool              VolatilityExpanding(void) const { return(m_volExpansion); }

   bool              SpreadAcceptable(const double maxSpreadPts) const
     {
      return(MathIsValidNumber(m_currentSpreadPts) && m_currentSpreadPts>=0.0 &&
             m_currentSpreadPts<=maxSpreadPts);
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
