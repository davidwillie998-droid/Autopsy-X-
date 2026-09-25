//+------------------------------------------------------------------+
//|                                              PriceImpactEngine.mqh|
//|  Price Impact Engine (institutional engine upgrade) - ENGINEERING |
//|  DESIGN, not paper-sourced. The source paper (Malhotra SSRN         |
//|  3306817) emphasizes that price impact materially affects           |
//|  profitability and liquidity assessment (findings items vi-x) and   |
//|  measures it via a VAR/impulse-response model over historical TAQ   |
//|  data (see python/autopsy_research/var_model.py) - it does not      |
//|  specify a live, tick-by-tick approximation. This engine is that    |
//|  live approximation: a fast, deterministic stand-in suited to the   |
//|  MT5 tick loop (spec section 31: "the live EA must remain            |
//|  deterministic, fast, and resilient" - the heavy VAR/impulse-        |
//|  response econometrics belongs offline, in the Python module).      |
//|                                                                    |
//|  Tracks price movement following a real (or simulated) execution   |
//|  point across several configurable time horizons, plus slippage    |
//|  cost normalized against ATR/spread/price.                          |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_PRICEIMPACTENGINE_MQH
#define AX_PRICEIMPACTENGINE_MQH
#include "Defs.mqh"

#define AX_IMPACT_MAX_PENDING   32
#define AX_IMPACT_MAX_WINDOWS   5
#define AX_IMPACT_MAX_HISTORY   200

struct SAxImpactSample
  {
   double   basePrice;
   ENUM_AX_DIR direction;         // direction the "execution" was in, so impact sign is meaningful
                                   // (a BUY that moves price up is a cost; a SELL that moves price
                                   // down is a cost - both should read as POSITIVE impact)
   datetime baseTime;
   bool     captured[AX_IMPACT_MAX_WINDOWS];
   double   impactPts[AX_IMPACT_MAX_WINDOWS];
  };

class CPriceImpactEngine
  {
private:
   int      m_windowSeconds[AX_IMPACT_MAX_WINDOWS]; // configurable, not hardcoded (spec: "do not
                                                       // hardcode these windows if the architecture
                                                       // can make them configurable")
   int      m_windowCount;

   SAxImpactSample m_pending[AX_IMPACT_MAX_PENDING];
   int      m_pendingCount;

   //--- rolling history of completed impact readings PER WINDOW, for averaging/scoring ---
   double   m_history[AX_IMPACT_MAX_WINDOWS][AX_IMPACT_MAX_HISTORY];
   int      m_historyCount[AX_IMPACT_MAX_WINDOWS];
   int      m_historyHead[AX_IMPACT_MAX_WINDOWS];

   void              PushHistory(const int windowIdx,const double impactPts)
     {
      int head = m_historyHead[windowIdx];
      m_history[windowIdx][head] = impactPts;
      m_historyHead[windowIdx] = (head+1)%AX_IMPACT_MAX_HISTORY;
      if(m_historyCount[windowIdx]<AX_IMPACT_MAX_HISTORY) m_historyCount[windowIdx]++;
     }

public:
                     CPriceImpactEngine(void)
     {
      m_windowCount=0; m_pendingCount=0;
      for(int w=0;w<AX_IMPACT_MAX_WINDOWS;w++) { m_historyCount[w]=0; m_historyHead[w]=0; }
     }

   //--- windowsSeconds: e.g. {1,5,15,30,60} - paper-adjacent defaults matching spec section 5's own  ---
   //--- listed horizons, but fully configurable, not hardcoded. count must be <= AX_IMPACT_MAX_WINDOWS. ---
   //--- Sorted ascending here (insertion sort - the array is at most AX_IMPACT_MAX_WINDOWS=5 long, so ---
   //--- this is cheap) so index 0 is ALWAYS the shortest/"immediate" window, guaranteed for any caller ---
   //--- - PriceImpactScore() below relies on that guarantee rather than trusting caller-supplied       ---
   //--- ordering (code-review finding: an out-of-order Configure() call would otherwise silently score ---
   //--- against the wrong horizon).                                                                     ---
   //--- Also clears any pending samples: their captured[]/impactPts[] indices were measured against    ---
   //--- the OLD window configuration and are meaningless under a new one - completing or half-          ---
   //--- completing them against a changed window set would silently corrupt history (code-review        ---
   //--- finding), so a reconfigure honestly discards in-flight tracking rather than mis-scoring it. ---
   void              Configure(const int &windowsSeconds[],const int count)
     {
      m_windowCount = MathMin(count,AX_IMPACT_MAX_WINDOWS);
      for(int i=0;i<m_windowCount;i++) m_windowSeconds[i]=MathMax(1,windowsSeconds[i]);

      for(int i=1;i<m_windowCount;i++) // small insertion sort, ascending
        {
         int key=m_windowSeconds[i]; int j=i-1;
         while(j>=0 && m_windowSeconds[j]>key) { m_windowSeconds[j+1]=m_windowSeconds[j]; j--; }
         m_windowSeconds[j+1]=key;
        }

      m_pendingCount=0;
     }

   //--- call at the moment of a real fill (or a periodic simulated sample point) to start tracking   ---
   //--- how price moves afterward. direction: which way the "execution" was, so impact sign is        ---
   //--- consistently "positive = adverse" regardless of BUY/SELL. ---
   void              RegisterExecution(const double basePrice,const ENUM_AX_DIR direction,const datetime baseTime)
     {
      if(m_windowCount<=0) return; // not configured - nothing to track

      //--- when the pending buffer is full, refuse the NEW registration rather than evicting the      ---
      //--- OLDEST one - the oldest pending sample has been waiting longest and is closest to having    ---
      //--- captured every window (including the longest, hardest-to-reach one); evicting it would      ---
      //--- silently throw away the most nearly-complete, most valuable reading in the buffer            ---
      //--- (code-review finding). Losing a brand-new registration under sustained overflow is the       ---
      //--- lesser loss. ---
      if(m_pendingCount>=AX_IMPACT_MAX_PENDING) return;

      SAxImpactSample sample;
      sample.basePrice=basePrice; sample.direction=direction; sample.baseTime=baseTime;
      for(int w=0;w<AX_IMPACT_MAX_WINDOWS;w++) { sample.captured[w]=false; sample.impactPts[w]=0.0; }

      m_pending[m_pendingCount]=sample; m_pendingCount++;
     }

   //--- call every tick: checks every pending sample against every configured window and captures    ---
   //--- the impact reading the instant that window's elapsed time is reached. Completed (all windows  ---
   //--- captured) samples are pruned from the pending list. ---
   void              Update(const double currentPrice,const double point,const datetime now)
     {
      if(point<=0) return;
      for(int i=0;i<m_pendingCount;i++)
        {
         bool allCaptured=true;
         for(int w=0;w<m_windowCount;w++)
           {
            if(m_pending[i].captured[w]) continue;
            allCaptured=false;
            double elapsed = (double)(now-m_pending[i].baseTime);
            if(elapsed<m_windowSeconds[w]) continue;

            double movePts = (currentPrice-m_pending[i].basePrice)/point;
            //--- sign convention: a BUY that moves price UP after execution, or a SELL that moves    ---
            //--- price DOWN, both register as POSITIVE impact (adverse to the executor) ---
            double signedImpact = (m_pending[i].direction==AX_DIR_BUY) ? movePts : -movePts;
            m_pending[i].impactPts[w]=signedImpact;
            m_pending[i].captured[w]=true;
            PushHistory(w,signedImpact);
           }
         if(allCaptured)
           {
            for(int k=i;k<m_pendingCount-1;k++) m_pending[k]=m_pending[k+1];
            m_pendingCount--; i--; // re-check this index, now holding the next sample
           }
        }
     }

   //--- average captured impact (points) for a given window index, over up to AX_IMPACT_MAX_HISTORY  ---
   //--- completed readings - returns 0 with historyOut=0 if nothing has been captured yet, never a    ---
   //--- fabricated average ---
   double            AverageImpactPts(const int windowIdx,int &historyCountOut) const
     {
      historyCountOut=0;
      if(windowIdx<0 || windowIdx>=m_windowCount) return(0.0);
      int cnt = m_historyCount[windowIdx];
      historyCountOut=cnt;
      if(cnt<=0) return(0.0);
      double sum=0;
      for(int i=0;i<cnt;i++) sum+=m_history[windowIdx][i];
      return(sum/cnt);
     }

   int               WindowSeconds(const int windowIdx) const
     {
      if(windowIdx<0 || windowIdx>=m_windowCount) return(0);
      return(m_windowSeconds[windowIdx]);
     }
   int               WindowCount(void) const { return(m_windowCount); }
   int               PendingCount(void) const { return(m_pendingCount); }

   //--- SlippageCost = |ExecutionPrice - RequestedPrice|, normalized by ATR/spread/price/expected     ---
   //--- risk (spec section 5) - a pure function, independent of the time-windowed tracking above.     ---
   //--- Each normalization is reported separately since "normalize by X" doesn't specify which X      ---
   //--- matters most for a given use - the caller picks. ---
   double            SlippageCostPts(const double executionPrice,const double requestedPrice,const double point) const
     {
      if(point<=0) return(0.0);
      return(MathAbs(executionPrice-requestedPrice)/point);
     }

   double            NormalizeByAtr(const double slippagePts,const double atrPts) const
     {
      if(atrPts<=0) return(0.0);
      return(slippagePts/atrPts);
     }
   double            NormalizeBySpread(const double slippagePts,const double spreadPts) const
     {
      if(spreadPts<=0) return(0.0);
      return(slippagePts/spreadPts);
     }
   double            NormalizeByRisk(const double slippagePts,const double riskPts) const
     {
      if(riskPts<=0) return(0.0);
      return(slippagePts/riskPts);
     }

   //--- ExecutionCostScore: 0..100, 100 = no measurable cost, decaying as slippage (normalized by     ---
   //--- spread, since spread is the one normalizer always available - ATR/risk may not be) grows.     ---
   //--- ENGINEERING DESIGN - the specific decay curve is a choice, documented as such. ---
   double            ExecutionCostScore(const double slippagePts,const double spreadPts) const
     {
      double normalized = NormalizeBySpread(slippagePts,spreadPts);
      // 0 normalized slippage -> 100. 3x spread worth of slippage -> 0. Linear between.
      return(AxClampD(100.0-(normalized/3.0)*100.0,0.0,100.0));
     }

   //--- PriceImpactScore: 0..100, 100 = no measurable post-execution drift, using the SHORTEST        ---
   //--- configured window's average impact (the "immediate impact" per spec section 5) normalized     ---
   //--- against the current spread, same reasoning as ExecutionCostScore above ---
   double            PriceImpactScore(const double spreadPts) const
     {
      if(m_windowCount<=0 || spreadPts<=0) return(50.0); // not configured / no spread reference - neutral
      int histCount;
      double avgImmediate = AverageImpactPts(0,histCount);
      if(histCount<=0) return(50.0); // no real readings captured yet - neutral, not fabricated
      double normalized = MathAbs(avgImmediate)/spreadPts;
      return(AxClampD(100.0-(normalized/3.0)*100.0,0.0,100.0));
     }
  };
//+------------------------------------------------------------------+
#endif // AX_PRICEIMPACTENGINE_MQH
