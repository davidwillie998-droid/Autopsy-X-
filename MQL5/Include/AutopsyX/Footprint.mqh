//+------------------------------------------------------------------+
//|                                                    Footprint.mqh |
//|  Footprint Engine - per-bar buy/sell volume-at-price grid         |
//|                                                                    |
//|  Unlike Volume Profile (built from completed bars' tick_volume,   |
//|  no direction), a footprint needs the buy/sell SPLIT at each      |
//|  price level within a single bar - so this engine consumes live   |
//|  tick-by-tick classification from COrderFlowEngine (one owner of  |
//|  "which side did this tick trade" logic, reused rather than       |
//|  re-derived here) and bins it into the currently forming bar's    |
//|  grid. On bar close the grid is snapshotted into a small ring     |
//|  history and scanned for "stacked imbalance" - several consecutive|
//|  price levels all heavily one-sided, a classic footprint          |
//|  exhaustion/aggression tell.                                      |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_FOOTPRINT_MQH
#define AX_FOOTPRINT_MQH
#include "Defs.mqh"

#define AX_FP_MAX_LEVELS 40
#define AX_FP_HISTORY    20

struct SAxFootprintBar
  {
   datetime barTime;
   double   delta;         // net buy-sell volume for the whole bar
   double   deltaRatio;    // delta / totalVolume, -1..+1
   double   totalVolume;
   int      stackedDir;    // +1 stacked buy imbalance, -1 stacked sell imbalance, 0 none
  };

class CFootprintEngine
  {
private:
   double            m_binSize;
   double            m_imbalanceRatio;   // e.g. 0.70 -> a level counts as imbalanced at 70/30 or worse
   int               m_stackedLevels;    // consecutive imbalanced levels required to call it "stacked"

   //--- currently forming bar's live grid ---
   datetime          m_curBarTime;
   double            m_levelPrice[AX_FP_MAX_LEVELS];
   double            m_levelBuy[AX_FP_MAX_LEVELS];
   double            m_levelSell[AX_FP_MAX_LEVELS];
   int               m_levelCount;

   SAxFootprintBar   m_history[AX_FP_HISTORY];
   int               m_histHead;
   int               m_histCount;

public:
                     CFootprintEngine(void) { Clear(); }

   void              Clear(void)
     {
      m_binSize=0; m_imbalanceRatio=0.70; m_stackedLevels=3;
      m_curBarTime=0; m_levelCount=0;
      m_histHead=-1; m_histCount=0;
     }

   void              Configure(const double binSizePoints,const double imbalanceRatio,
                                const int stackedLevels,const double point)
     {
      double p = (point>0) ? point : 0.00001;
      m_binSize        = MathMax(binSizePoints,1.0)*p;
      m_imbalanceRatio = AxClampD(imbalanceRatio,0.5,0.95);
      m_stackedLevels  = MathMax(2,stackedLevels);
     }

   //--- call every tick with the current bar's open time and this tick's classified buy/sell volume ---
   //--- (from COrderFlowEngine::LastTickBuyVol/SellVol, computed the same tick) ---
   void              OnTick(const datetime barTime,const double price,
                             const double buyVol,const double sellVol)
     {
      if(m_binSize<=0) return;

      if(barTime!=m_curBarTime)
        {
         if(m_curBarTime!=0) SnapshotBar();
         m_curBarTime = barTime;
         m_levelCount = 0;
        }
      if(buyVol<=0 && sellVol<=0) return;

      double key = MathRound(price/m_binSize)*m_binSize;
      int nearestIdx=-1; double nearestDist=DBL_MAX;
      for(int i=0;i<m_levelCount;i++)
        {
         double dist = MathAbs(m_levelPrice[i]-key);
         if(dist<m_binSize*0.5)
           {
            m_levelBuy[i]  += buyVol;
            m_levelSell[i] += sellVol;
            return;
           }
         if(dist<nearestDist) { nearestDist=dist; nearestIdx=i; }
        }
      if(m_levelCount<AX_FP_MAX_LEVELS)
        {
         m_levelPrice[m_levelCount] = key;
         m_levelBuy[m_levelCount]   = buyVol;
         m_levelSell[m_levelCount]  = sellVol;
         m_levelCount++;
         return;
        }
      // grid is full for this bar (a genuinely wide/volatile bar) - fold into the nearest existing
      // level instead of dropping the volume outright, so delta/imbalance totals stay conserved even
      // though the extreme edge of the bar's range loses a little resolution
      if(nearestIdx>=0) { m_levelBuy[nearestIdx]+=buyVol; m_levelSell[nearestIdx]+=sellVol; }
     }

   int               LastBarStackedDir(void)  const { return(m_histCount>0 ? m_history[m_histHead].stackedDir  : 0); }
   double            LastBarDeltaRatio(void)  const { return(m_histCount>0 ? m_history[m_histHead].deltaRatio  : 0.0); }
   double            LastBarDelta(void)       const { return(m_histCount>0 ? m_history[m_histHead].delta       : 0.0); }
   bool              HaveHistory(void)        const { return(m_histCount>0); }

   //--- 0..100 bias components: a fresh stacked imbalance on the last completed bar is a strong,   ---
   //--- discrete tell; otherwise fall back to a scaled reading of that bar's plain delta ratio ---
   double            BullishScoreComponent(void) const
     {
      if(!HaveHistory()) return(0);
      if(LastBarStackedDir()>0) return(100.0);
      double dr = LastBarDeltaRatio();
      return(dr>0 ? AxClampD(dr*70.0,0,70) : 0.0);
     }

   double            BearishScoreComponent(void) const
     {
      if(!HaveHistory()) return(0);
      if(LastBarStackedDir()<0) return(100.0);
      double dr = LastBarDeltaRatio();
      return(dr<0 ? AxClampD(-dr*70.0,0,70) : 0.0);
     }

private:
   void              SnapshotBar(void)
     {
      if(m_levelCount<=0) return;

      //--- sort levels by price once (m_levelCount is small, <=AX_FP_MAX_LEVELS) to walk them in  ---
      //--- price order when looking for consecutive same-direction imbalance ---
      int order[];
      ArrayResize(order,m_levelCount);
      for(int i=0;i<m_levelCount;i++) order[i]=i;
      for(int i=1;i<m_levelCount;i++)
        {
         int key=order[i]; double kp=m_levelPrice[key]; int j=i-1;
         while(j>=0 && m_levelPrice[order[j]]>kp) { order[j+1]=order[j]; j--; }
         order[j+1]=key;
        }

      double totalDelta=0, totalVol=0;
      int consecBuy=0, consecSell=0, maxConsecBuy=0, maxConsecSell=0;
      for(int i=0;i<m_levelCount;i++)
        {
         int idx=order[i];
         double buy=m_levelBuy[idx], sell=m_levelSell[idx], tot=buy+sell;
         totalDelta += (buy-sell);
         totalVol   += tot;
         if(tot>0 && buy/tot>=m_imbalanceRatio)       { consecBuy++;  consecSell=0; }
         else if(tot>0 && sell/tot>=m_imbalanceRatio)  { consecSell++; consecBuy=0; }
         else                                          { consecBuy=0;  consecSell=0; }
         maxConsecBuy  = MathMax(maxConsecBuy,consecBuy);
         maxConsecSell = MathMax(maxConsecSell,consecSell);
        }

      SAxFootprintBar bar;
      bar.barTime     = m_curBarTime;
      bar.delta       = totalDelta;
      bar.deltaRatio  = (totalVol>0) ? totalDelta/totalVol : 0.0;
      bar.totalVolume = totalVol;
      bar.stackedDir  = (maxConsecBuy>=m_stackedLevels) ? 1 : (maxConsecSell>=m_stackedLevels ? -1 : 0);

      m_histHead = (m_histHead+1) % AX_FP_HISTORY;
      m_history[m_histHead] = bar;
      if(m_histCount<AX_FP_HISTORY) m_histCount++;
     }
  };
//+------------------------------------------------------------------+
#endif // AX_FOOTPRINT_MQH
