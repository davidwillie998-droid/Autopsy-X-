//+------------------------------------------------------------------+
//|                                       CapacityCrowdingEngine.mqh|
//|  Capacity Engine + Crowding Proxy (spec sections 16-17),           |
//|  institutional engine upgrade - ENGINEERING DESIGN, not paper-      |
//|  sourced. The source paper (Malhotra SSRN 3306817) discusses        |
//|  strategy capacity and crowding as real, important hedge-fund       |
//|  concerns in general terms (its 400-strategy review and the "third  |
//|  dimension of liquidity" discussion) - it does not specify a         |
//|  capacity formula, a crowding formula, or any threshold below.       |
//|                                                                     |
//|  HONEST SCOPE (same discipline as MacroRegime.mqh's own caveat):     |
//|  a single-symbol retail MT5 tick feed exposes NO real order-book     |
//|  depth-by-price, no other participants' positioning, and no cross-   |
//|  strategy visibility. TRUE capacity (how many lots the market can    |
//|  absorb before moving price) and TRUE crowding (how many other       |
//|  funds are in the same trade) are therefore NOT measurable here.     |
//|  Both scores below are LOCAL, SELF-REFERENTIAL PROXIES built only    |
//|  from data this EA can actually observe - documented as proxies,     |
//|  never presented as the real thing.                                  |
//|                                                                     |
//|  CapacityScore: a blend of already-computed microstructure-health    |
//|  reads (this class recomputes nothing - same "deliberately thin"      |
//|  convention as InformationContentEngine.mqh/HiddenRiskDetector.mqh)   |
//|  standing in for "how much size could likely be deployed right now    |
//|  without the market pushing back hard" - since no size-indexed         |
//|  order-book impact curve exists on this feed to derive it directly.    |
//|                                                                     |
//|  CrowdingProxyScore: this EA's OWN recent same-direction entry         |
//|  frequency (a self-crowding / "am I chasing an already-extended         |
//|  move" proxy) blended with distance-from-VWAP in ATR units (a           |
//|  classic "how extended is this move already" heuristic). Neither is     |
//|  a measurement of other market participants - both are named and        |
//|  documented as proxies for exactly that reason.                          |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_CAPACITYCROWDINGENGINE_MQH
#define AX_CAPACITYCROWDINGENGINE_MQH
#include "Defs.mqh"

#define AX_CROWD_ENTRY_HISTORY 64 // defensive cap on trailing entries tracked for the self-crowding proxy -
                                    // RegisterEntry() actively prunes anything older than the configured
                                    // window on every call (see below), so this cap is only reached under
                                    // genuinely very high same/opposite-direction entry frequency within a
                                    // single window - not a realistic ring-buffer-overwrite risk like the
                                    // one already found and fixed in DrawdownEngine.mqh this session

struct SAxCapacityCrowdingState
  {
   double   capacityScore;         // 0 (no capacity - avoid sizing up) .. 100 (ample capacity)
   double   crowdingProxyScore;    // 0 (looks fresh/uncrowded) .. 100 (looks extended/self-crowded)
   string   reason;
  };

class CCapacityCrowdingEngine
  {
private:
   //--- capacity blend weights ---
   double            m_wTickActivity, m_wLiquidity, m_wPriceImpact, m_wExecutionCost;

   //--- crowding blend weights ---
   double            m_wSelfFrequency, m_wVwapExtension;
   double            m_extensionAtrCeiling; // ATR multiples of VWAP distance treated as "fully extended" (100)
   int               m_selfFrequencyWindowSeconds; // recent-entry lookback for the self-crowding proxy
   int               m_selfFrequencyCeiling;        // entry count within the window treated as "fully crowded" (100)

   //--- chronological (index 0 = oldest), NOT a ring buffer: RegisterEntry() prunes anything already   ---
   //--- outside the self-frequency window before appending, so a still-valid entry can never be         ---
   //--- silently evicted by a newer one the way a fixed-slot ring buffer would (code-review finding,     ---
   //--- same root cause class as the DrawdownEngine.mqh ring-buffer fix earlier this session). ---
   datetime          m_entryTimes[AX_CROWD_ENTRY_HISTORY];
   ENUM_AX_DIR       m_entryDirs[AX_CROWD_ENTRY_HISTORY];
   int               m_entryCount;

public:
                     CCapacityCrowdingEngine(void)
     {
      m_wTickActivity=25; m_wLiquidity=35; m_wPriceImpact=25; m_wExecutionCost=15;
      m_wSelfFrequency=50; m_wVwapExtension=50;
      m_extensionAtrCeiling=3.0; m_selfFrequencyWindowSeconds=3600; m_selfFrequencyCeiling=5;
      m_entryCount=0;
     }

   void              Configure(const double wTickActivity,const double wLiquidity,const double wPriceImpact,
                                const double wExecutionCost,const double wSelfFrequency,
                                const double wVwapExtension,const double extensionAtrCeiling,
                                const int selfFrequencyWindowSeconds,const int selfFrequencyCeiling)
     {
      m_wTickActivity=MathMax(0,wTickActivity); m_wLiquidity=MathMax(0,wLiquidity);
      m_wPriceImpact=MathMax(0,wPriceImpact); m_wExecutionCost=MathMax(0,wExecutionCost);
      m_wSelfFrequency=MathMax(0,wSelfFrequency); m_wVwapExtension=MathMax(0,wVwapExtension);
      m_extensionAtrCeiling=MathMax(0.1,extensionAtrCeiling);
      m_selfFrequencyWindowSeconds=MathMax(60,selfFrequencyWindowSeconds);
      m_selfFrequencyCeiling=MathMax(1,selfFrequencyCeiling);
     }

   //--- drops any tracked entry already outside the self-frequency window as of `now` - called from     ---
   //--- RegisterEntry() below before appending, so the fixed-size array is never asked to hold more      ---
   //--- genuinely-in-window entries than it has room for by evicting the OLDEST slot on overflow          ---
   //--- (which is what a ring buffer would have silently done, including to still-valid entries). ---
   void              PruneStale(const datetime now)
     {
      int firstValid=0;
      while(firstValid<m_entryCount && (double)(now-m_entryTimes[firstValid])>m_selfFrequencyWindowSeconds)
         firstValid++;
      if(firstValid<=0) return;
      for(int i=firstValid;i<m_entryCount;i++)
        {
         m_entryTimes[i-firstValid]=m_entryTimes[i];
         m_entryDirs[i-firstValid]=m_entryDirs[i];
        }
      m_entryCount-=firstValid;
     }

   //--- call once per real (or simulated) entry, so the self-crowding proxy has real data to read -    ---
   //--- never call this speculatively, only on an entry actually taken (matches the rest of this        ---
   //--- codebase's "never fabricate a read" discipline: a proxy built from entries that didn't happen   ---
   //--- would be fabricated, not observed). ---
   void              RegisterEntry(const ENUM_AX_DIR dir,const datetime t)
     {
      PruneStale(t); // drop anything already stale as of this entry's own time before appending
      if(m_entryCount>=AX_CROWD_ENTRY_HISTORY)
        {
         //--- still full after pruning: genuinely more in-window entries than the defensive cap allows -  ---
         //--- an extreme-frequency edge case this codebase's anti-chop/cooldown gating is not expected to ---
         //--- reach in practice. Drop the oldest rather than refuse the registration - documented, not      ---
         //--- silent, and only reachable at all under a load this proxy was never sized to fully track. ---
         for(int i=1;i<AX_CROWD_ENTRY_HISTORY;i++)
           {
            m_entryTimes[i-1]=m_entryTimes[i];
            m_entryDirs[i-1]=m_entryDirs[i];
           }
         m_entryCount=AX_CROWD_ENTRY_HISTORY-1;
        }
      m_entryTimes[m_entryCount]=t; m_entryDirs[m_entryCount]=dir;
      m_entryCount++;
     }

   //--- count of this EA's OWN entries in `dir` within the trailing self-frequency window - the only   ---
   //--- half of the self-crowding proxy that needs history; the ring buffer holds both directions so a ---
   //--- caller asking about the opposite direction still gets a correct, independent count. ---
   int               RecentSameDirectionEntries(const ENUM_AX_DIR dir,const datetime now) const
     {
      int cnt=0;
      for(int i=0;i<m_entryCount;i++)
        {
         if(m_entryDirs[i]!=dir) continue;
         if((double)(now-m_entryTimes[i])<=m_selfFrequencyWindowSeconds) cnt++;
        }
      return(cnt);
     }

   //--- capacityScore inputs are all already-computed 0..100 reads from other engines: tickActivityScore---
   //--- and liquidityScore from CLiquidityScoreEngine, priceImpactScore from CPriceImpactEngine's own   ---
   //--- PriceImpactScore(), executionCostScore from CPriceImpactEngine's own ExecutionCostScore(). ---
   double            CapacityScore(const double tickActivityScore,const double liquidityScore,
                                    const double priceImpactScore,const double executionCostScore) const
     {
      double totalWeight = m_wTickActivity+m_wLiquidity+m_wPriceImpact+m_wExecutionCost;
      if(totalWeight<=0) return(50.0); // unconfigured - neutral, not fabricated
      double score = (AxClampD(tickActivityScore,0.0,100.0)*m_wTickActivity+
                       AxClampD(liquidityScore,0.0,100.0)*m_wLiquidity+
                       AxClampD(priceImpactScore,0.0,100.0)*m_wPriceImpact+
                       AxClampD(executionCostScore,0.0,100.0)*m_wExecutionCost)/totalWeight;
      return(AxClampD(score,0.0,100.0));
     }

   //--- shared implementation once `recentEntries` is already known, so a caller that needs both the    ---
   //--- score and the raw count (e.g. Update() below, for its reason string) doesn't re-scan the entry   ---
   //--- history a second time (code-review finding: the original Update() called                         ---
   //--- RecentSameDirectionEntries() twice per invocation). ---
   double            CrowdingProxyScoreFromCount(const int recentEntries,const double currentPrice,
                                                  const double vwapValue,const double atrPts,
                                                  const double point) const
     {
      double selfFreqSeverity = AxClampD(100.0*recentEntries/(double)m_selfFrequencyCeiling,0.0,100.0);

      bool   vwapDataAvailable = (atrPts>0 && point>0 && vwapValue>0);
      double weightedSum  = selfFreqSeverity*m_wSelfFrequency;
      double activeWeight = m_wSelfFrequency;

      if(vwapDataAvailable)
        {
         double distancePts = MathAbs(currentPrice-vwapValue)/point;
         double distanceAtr = distancePts/atrPts;
         double vwapExtensionSeverity = AxClampD(distanceAtr/m_extensionAtrCeiling*100.0,0.0,100.0);
         weightedSum  += vwapExtensionSeverity*m_wVwapExtension;
         activeWeight += m_wVwapExtension;
        }
      //--- when VWAP/ATR isn't available yet, the extension term is EXCLUDED from the average entirely  ---
      //--- (renormalized over activeWeight, i.e. m_wSelfFrequency alone) rather than averaged in as a     ---
      //--- fabricated 0.0 ("price exactly at VWAP") reading, which previously diluted/understated a real  ---
      //--- self-frequency signal by up to half whenever VWAP simply hadn't warmed up yet (code-review      ---
      //--- finding). ---

      if(activeWeight<=0) return(50.0); // neither term configured - neutral, matching CapacityScore()'s
                                          // equivalent no-data fallback (code-review finding: this used to
                                          // return 0.0, "definitely uncrowded", which silently disables the
                                          // safeguard under a config bug instead of signaling uncertainty)
      return(AxClampD(weightedSum/activeWeight,0.0,100.0));
     }

   //--- crowdingProxyScore: HIGH = looks more extended/self-crowded (a reason for caution), LOW = looks ---
   //--- fresh. currentPrice/vwapValue/atrPts are already-computed live reads (VWAPEngine/ATR handle),   ---
   //--- never recomputed here. proposedDir/now are used only to read this EA's own entry history above. ---
   double            CrowdingProxyScore(const ENUM_AX_DIR proposedDir,const double currentPrice,
                                         const double vwapValue,const double atrPts,const double point,
                                         const datetime now) const
     {
      int recentEntries = RecentSameDirectionEntries(proposedDir,now);
      return(CrowdingProxyScoreFromCount(recentEntries,currentPrice,vwapValue,atrPts,point));
     }

   SAxCapacityCrowdingState Update(const double tickActivityScore,const double liquidityScore,
                                    const double priceImpactScore,const double executionCostScore,
                                    const ENUM_AX_DIR proposedDir,const double currentPrice,
                                    const double vwapValue,const double atrPts,const double point,
                                    const datetime now) const
     {
      SAxCapacityCrowdingState s;
      s.capacityScore = CapacityScore(tickActivityScore,liquidityScore,priceImpactScore,executionCostScore);
      int recentEntries = RecentSameDirectionEntries(proposedDir,now);
      s.crowdingProxyScore = CrowdingProxyScoreFromCount(recentEntries,currentPrice,vwapValue,atrPts,point);
      s.reason=StringFormat("capacity=%.1f crowdingProxy=%.1f (recentSameDirEntries=%d)",
                             s.capacityScore,s.crowdingProxyScore,recentEntries);
      return(s);
     }
  };
//+------------------------------------------------------------------+
#endif // AX_CAPACITYCROWDINGENGINE_MQH
