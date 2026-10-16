//+------------------------------------------------------------------+
//| VolumeProfileEngine.mqh                                           |
//| Real volume-by-price profile built from bar tick/real volume      |
//| over a rolling lookback: point of control and the 70% value area. |
//| A bar's volume is spread evenly across the price buckets its      |
//| [low,high] range touches - the standard approach for retail       |
//| volume profile since MT5 does not expose per-tick trade prints.   |
//+------------------------------------------------------------------+
#pragma once
#include <AutopsyX/Defines.mqh>
#include <AutopsyX/SymbolProfile.mqh>

#define AX_VP_BUCKETS 100

class CAXVolumeProfile
{
private:
   const CAXSymbolProfile *m_profile;
   int      m_lookbackBars;

   double   m_bucketVolume[AX_VP_BUCKETS];
   double   m_gridLow, m_gridHigh, m_bucketSize;
   double   m_totalVolume;

   double   m_poc, m_vah, m_val;
   bool     m_valid;

public:
   CAXVolumeProfile(void) : m_profile(NULL), m_lookbackBars(60), m_gridLow(0), m_gridHigh(0),
      m_bucketSize(0), m_totalVolume(0), m_poc(0), m_vah(0), m_val(0), m_valid(false)
   {
      ArrayInitialize(m_bucketVolume, 0.0);
   }

   void Init(const CAXSymbolProfile &profile, const int lookbackBars)
   {
      m_profile = GetPointer(profile);
      m_lookbackBars = MathMax(10, lookbackBars);
   }

   void OnNewBar(const MqlRates &rates[], const int count)
   {
      m_valid = false;
      if(m_profile == NULL || count < m_lookbackBars + 1) return;

      double gridLow = DBL_MAX, gridHigh = -DBL_MAX;
      for(int i = 1; i <= m_lookbackBars; i++)
      {
         if(rates[i].low  < gridLow)  gridLow  = rates[i].low;
         if(rates[i].high > gridHigh) gridHigh = rates[i].high;
      }
      if(gridHigh <= gridLow) return;

      m_gridLow = gridLow;
      m_gridHigh = gridHigh;
      m_bucketSize = (gridHigh - gridLow) / AX_VP_BUCKETS;
      ArrayInitialize(m_bucketVolume, 0.0);
      m_totalVolume = 0.0;

      for(int i = 1; i <= m_lookbackBars; i++)
      {
         long vol = (rates[i].real_volume > 0) ? rates[i].real_volume : rates[i].tick_volume;
         if(vol <= 0) vol = 1;

         int firstBucket = BucketIndex(rates[i].low);
         int lastBucket  = BucketIndex(rates[i].high);
         if(firstBucket < 0 || lastBucket < 0) continue;
         int span = lastBucket - firstBucket + 1;
         if(span <= 0) continue;

         double perBucket = (double)vol / span;
         for(int b = firstBucket; b <= lastBucket; b++)
         {
            m_bucketVolume[b] += perBucket;
            m_totalVolume += perBucket;
         }
      }

      if(m_totalVolume <= 0.0) return;

      //--- point of control: highest-volume bucket
      int pocIdx = 0;
      double pocVol = m_bucketVolume[0];
      for(int b = 1; b < AX_VP_BUCKETS; b++)
         if(m_bucketVolume[b] > pocVol) { pocVol = m_bucketVolume[b]; pocIdx = b; }
      m_poc = BucketPrice(pocIdx);

      //--- value area: expand outward from POC until 70% of volume is covered
      double covered = m_bucketVolume[pocIdx];
      int lo = pocIdx, hi = pocIdx;
      double target = m_totalVolume * 0.70;
      while(covered < target && (lo > 0 || hi < AX_VP_BUCKETS - 1))
      {
         double volBelow = (lo > 0) ? m_bucketVolume[lo - 1] : -1.0;
         double volAbove = (hi < AX_VP_BUCKETS - 1) ? m_bucketVolume[hi + 1] : -1.0;
         if(volAbove >= volBelow && hi < AX_VP_BUCKETS - 1)
         {
            hi++; covered += m_bucketVolume[hi];
         }
         else if(lo > 0)
         {
            lo--; covered += m_bucketVolume[lo];
         }
         else break;
      }
      m_val = BucketPrice(lo);
      m_vah = BucketPrice(hi) + m_bucketSize;

      m_valid = true;
   }

   bool   IsValid(void) const { return m_valid; }
   double POC(void) const { return m_poc; }
   double VAH(void) const { return m_vah; }
   double VAL(void) const { return m_val; }

   // +1 = trading above value (acceptance/bullish), -1 = below value, 0 = inside value area / no data
   int PositionSignal(const double price) const
   {
      if(!m_valid) return 0;
      if(price > m_vah) return 1;
      if(price < m_val) return -1;
      return 0;
   }

   double DistanceToPocPts(const double price) const
   {
      if(!m_valid || m_profile == NULL) return 0.0;
      return m_profile.PriceToPoints(price - m_poc);
   }

private:
   int BucketIndex(const double price) const
   {
      if(m_bucketSize <= 0.0) return -1;
      int idx = (int)((price - m_gridLow) / m_bucketSize);
      return AXClampInt(idx, 0, AX_VP_BUCKETS - 1);
   }

   double BucketPrice(const int idx) const
   {
      return m_gridLow + idx * m_bucketSize;
   }
};
