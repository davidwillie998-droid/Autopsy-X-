//+------------------------------------------------------------------+
//|                                                 VolumeProfile.mqh |
//|  Volume Profile Engine - POC / value area from bar tick_volume    |
//|                                                                    |
//|  Rebuilt once per new bar (same cadence as CLiquidityEngine's     |
//|  RefreshLevels) over a rolling lookback window, never per tick -  |
//|  a volume profile is a structural picture, not a tick-by-tick one.|
//|  Each bar's tick_volume is spread evenly across price bins        |
//|  covering its High-Low range, since MT5 doesn't expose a genuine  |
//|  intrabar trade tape on most forex/CFD feeds - see README.        |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_VOLUMEPROFILE_MQH
#define AX_VOLUMEPROFILE_MQH
#include "Defs.mqh"

#define AX_VP_MAX_BARS      240
#define AX_VP_MAX_BINS      200
#define AX_VP_MAX_BINS_PER_BAR 100  // hard cap on one bar's own bin count, regardless of its range/binSize -
                                     // protects the synchronous once-per-bar Refresh() from an unbounded
                                     // O(bins) blowup on symbols where price is large relative to a point
                                     // (indices, crypto CFDs) and the configured bin size is small

class CVolumeProfileEngine
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;
   int               m_lookbackBars;
   double            m_binSize;      // price units per bin

   double            m_binPrice[AX_VP_MAX_BINS];
   double            m_binVolume[AX_VP_MAX_BINS];
   int               m_binCount;

   double            m_poc;
   double            m_vah;
   double            m_val;
   bool              m_valid;
   double            m_hvnPrice[AX_VP_MAX_BINS];
   double            m_lvnPrice[AX_VP_MAX_BINS];
   int               m_hvnCount;
   int               m_lvnCount;

public:
                     CVolumeProfileEngine(void)
     {
      m_binCount=0; m_poc=0; m_vah=0; m_val=0; m_valid=false;
      m_hvnCount=0; m_lvnCount=0;
      m_lookbackBars=120; m_binSize=0;
     }

   bool              Init(const string symbol,const int lookbackBars,const double binSizePoints,
                           const double point,ENUM_TIMEFRAMES tf=PERIOD_M1)
     {
      m_symbol = symbol;
      m_tf     = tf;
      m_lookbackBars = MathMin(MathMax(lookbackBars,20),AX_VP_MAX_BARS);
      double p = (point>0) ? point : 0.00001;
      m_binSize = MathMax(binSizePoints,1.0)*p;
      return(true);
     }

   //--- call once per new bar - rebuilds the whole profile from scratch. Bounded cost: lookbackBars ---
   //--- x avg-bins-per-bar x AddVolume's linear bin search, all capped by AX_VP_MAX_BINS - a once- ---
   //--- per-bar refresh, same performance category as CLiquidityEngine::RefreshLevels ---
   void              Refresh(void)
     {
      m_valid=false;
      m_hvnCount=0; m_lvnCount=0;
      if(m_binSize<=0) return;

      MqlRates rates[];
      ArraySetAsSeries(rates,true);
      int copied = CopyRates(m_symbol,m_tf,0,m_lookbackBars,rates);
      if(copied<10) return;

      m_binCount=0;
      for(int i=0;i<copied;i++)
        {
         double vol = (double)rates[i].tick_volume;
         if(vol<=0) continue;
         double lo=rates[i].low, hi=rates[i].high;
         if(hi<lo) continue;
         int nBins = (int)MathRound((hi-lo)/m_binSize)+1;
         nBins = MathMin(MathMax(1,nBins),AX_VP_MAX_BINS_PER_BAR);
         // if the bar's true range needed more bins than the cap allows, spread across the capped
         // count with a proportionally wider effective step so the bar's full range is still covered
         // (coarser resolution for that one bar, never a truncated slice of its range)
         double step = (nBins>1) ? (hi-lo)/(nBins-1) : 0.0;
         double volPerBin = vol/nBins;
         for(int b=0;b<nBins;b++)
            AddVolume(lo+b*step,volPerBin);
        }

      ComputeValueArea();
      m_valid = (m_binCount>0 && m_poc>0);
     }

   bool              IsValid(void) const { return(m_valid); }
   double            Poc(void)     const { return(m_poc); }
   double            Vah(void)     const { return(m_vah); }
   double            Val(void)     const { return(m_val); }

   //--- nearest local high/low-volume nodes. Return false when no defensible node exists.
   bool              NearestHighVolumeNode(const double refPrice,double &nodePrice,double &distanceBins) const
     {
      return(NearestNode(refPrice,true,nodePrice,distanceBins));
     }
   bool              NearestLowVolumeNode(const double refPrice,double &nodePrice,double &distanceBins) const
     {
      return(NearestNode(refPrice,false,nodePrice,distanceBins));
     }

   //--- where does refPrice sit relative to the value area? +1 above VAH, -1 below VAL, 0 inside ---
   int               Position(const double refPrice) const
     {
      if(!m_valid) return(0);
      if(refPrice>m_vah) return(1);
      if(refPrice<m_val) return(-1);
      return(0);
     }

   //--- 0..100 bias components: pushing beyond value area in a direction is breakout confirmation; ---
   //--- sitting on the POC side of the range without having broken out yet is a mild continuation  ---
   //--- lean. This is advisory - a scoring input, never a hard gate (see main EA wiring). ---
   double            BullishScoreComponent(const double refPrice) const
     {
      if(!m_valid) return(0);
      if(refPrice>m_vah) return(70.0);
      if(refPrice>m_poc) return(30.0);
      return(0.0);
     }

   double            BearishScoreComponent(const double refPrice) const
     {
      if(!m_valid) return(0);
      if(refPrice<m_val) return(70.0);
      if(refPrice<m_poc) return(30.0);
      return(0.0);
     }

private:
   void              AddVolume(const double price,const double vol)
     {
      double key = MathRound(price/m_binSize)*m_binSize;
      int nearestIdx=-1; double nearestDist=DBL_MAX;
      for(int i=0;i<m_binCount;i++)
        {
         double dist = MathAbs(m_binPrice[i]-key);
         if(dist<m_binSize*0.5) { m_binVolume[i]+=vol; return; }
         if(dist<nearestDist) { nearestDist=dist; nearestIdx=i; }
        }
      if(m_binCount<AX_VP_MAX_BINS)
        {
         m_binPrice[m_binCount]  = key;
         m_binVolume[m_binCount] = vol;
         m_binCount++;
         return;
        }
      // table is full and this price doesn't match any existing bin closely enough - fold its volume
      // into the closest existing bin rather than dropping it, so total volume (and therefore the
      // value-area percentage math) stays conserved even when resolution has to give a little
      if(nearestIdx>=0) m_binVolume[nearestIdx] += vol;
     }

   void              ComputeValueArea(void)
     {
      m_poc=0; m_vah=0; m_val=0;
      m_hvnCount=0; m_lvnCount=0;
      if(m_binCount<=0) return;

      int pocIdx=0; double best=-1; double total=0;
      for(int i=0;i<m_binCount;i++)
        {
         total += m_binVolume[i];
         if(m_binVolume[i]>best) { best=m_binVolume[i]; pocIdx=i; }
        }
      if(total<=0) return;
      m_poc = m_binPrice[pocIdx];

      //--- sort bin indices by price once so "expand outward from POC" is a simple two-pointer walk ---
      int order[];
      ArrayResize(order,m_binCount);
      for(int i=0;i<m_binCount;i++) order[i]=i;
      for(int i=1;i<m_binCount;i++)
        {
         int key=order[i]; double kp=m_binPrice[key]; int j=i-1;
         while(j>=0 && m_binPrice[order[j]]>kp) { order[j+1]=order[j]; j--; }
         order[j+1]=key;
        }

      int pocPos=0;
      for(int i=0;i<m_binCount;i++) if(order[i]==pocIdx) { pocPos=i; break; }

      double covered = m_binVolume[pocIdx];
      int lo=pocPos, hi=pocPos;
      while(covered<total*0.70 && (lo>0 || hi<m_binCount-1))
        {
         double volBelow = (lo>0) ? m_binVolume[order[lo-1]] : -1.0;
         double volAbove = (hi<m_binCount-1) ? m_binVolume[order[hi+1]] : -1.0;
         if(volAbove>=volBelow) { hi++; covered+=m_binVolume[order[hi]]; }
         else                   { lo--; covered+=m_binVolume[order[lo]]; }
        }
      m_val = m_binPrice[order[lo]];
      m_vah = m_binPrice[order[hi]];

      //--- classify local nodes against this profile's own mean bin volume. This avoids fixed
      //--- contract/lot thresholds and adapts to each symbol, broker feed and lookback.
      double meanVolume=total/m_binCount;
      double highThreshold=meanVolume*1.50;
      double lowThreshold=meanVolume*0.50;
      for(int pos=0;pos<m_binCount;pos++)
        {
         int idx=order[pos];
         double vol=m_binVolume[idx];
         // Only compare bins that are genuinely adjacent in price. Sparse
         // profiles can contain large gaps between occupied bins.
         bool hasBelow=(pos>0 &&
                        MathAbs(m_binPrice[idx]-m_binPrice[order[pos-1]])<=m_binSize*1.5);
         bool hasAbove=(pos<m_binCount-1 &&
                        MathAbs(m_binPrice[idx]-m_binPrice[order[pos+1]])<=m_binSize*1.5);
         double below=hasBelow ? m_binVolume[order[pos-1]] : 0.0;
         double above=hasAbove ? m_binVolume[order[pos+1]] : 0.0;
         bool localHigh=(vol>=highThreshold &&
                         (!hasBelow || vol>=below) && (!hasAbove || vol>=above) &&
                         ((hasBelow && vol>below) || (hasAbove && vol>above)));
         // An LVN needs occupied neighbors on both sides. Treating a missing
         // bin as zero would incorrectly label the edge of a sparse gap as a node.
         bool localLow=(hasBelow && hasAbove && vol>0 && vol<=lowThreshold &&
                        vol<=below && vol<=above && (vol<below || vol<above));
         if(localHigh && m_hvnCount<AX_VP_MAX_BINS)
            m_hvnPrice[m_hvnCount++]=m_binPrice[idx];
         if(localLow && m_lvnCount<AX_VP_MAX_BINS)
            m_lvnPrice[m_lvnCount++]=m_binPrice[idx];
        }
     }

   bool              NearestNode(const double refPrice,const bool highVolume,
                                  double &nodePrice,double &distanceBins) const
     {
      nodePrice=0; distanceBins=DBL_MAX;
      if(!m_valid || m_binSize<=0) return(false);
      int count=highVolume ? m_hvnCount : m_lvnCount;
      if(count<=0) return(false);
      double best=DBL_MAX; int bestIdx=-1;
      for(int i=0;i<count;i++)
        {
         double candidate=highVolume ? m_hvnPrice[i] : m_lvnPrice[i];
         double d=MathAbs(candidate-refPrice)/m_binSize;
         if(d<best) { best=d; bestIdx=i; }
        }
      if(bestIdx<0) return(false);
      nodePrice=highVolume ? m_hvnPrice[bestIdx] : m_lvnPrice[bestIdx];
      distanceBins=best;
      return(true);
     }
  };
//+------------------------------------------------------------------+
#endif // AX_VOLUMEPROFILE_MQH
