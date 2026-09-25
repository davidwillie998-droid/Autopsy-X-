//+------------------------------------------------------------------+
//|                                              StructureEngine.mqh |
//|  Structure Engine (FLIPDEMON EXTREME upgrade, spec section 5)    |
//|                                                                    |
//|  HONEST CAVEAT: "BOS", "CHoCH" and "MSS" do not have one single   |
//|  universally agreed formal definition across retail market-       |
//|  structure ("smart money concepts") education - different         |
//|  educators and tools disagree on exact edge cases. This file      |
//|  implements ONE specific, internally consistent operationalization|
//|  of each term, documented precisely below, rather than presenting |
//|  any of it as THE canonical definition.                           |
//|                                                                    |
//|  Definitions used here:                                           |
//|   - Swing high/low: a fractal (2-bar wing) extreme on CLOSED bars  |
//|     only, with consecutive same-type fractals collapsed to keep    |
//|     only the more extreme one (a clean alternating high/low        |
//|     sequence).                                                     |
//|   - HH/LH/HL/LL: each new swing classified against the PRIOR swing |
//|     of the same type only.                                         |
//|   - Trend: BULLISH if the most recent swing high is HH and most    |
//|     recent swing low is HL; BEARISH if LH and LL; otherwise        |
//|     UNDEFINED (mixed, or too few swings yet).                      |
//|   - BOS: the latest closed bar's close breaks beyond the most      |
//|     recent swing level IN the prevailing trend's direction         |
//|     (continuation).                                                |
//|   - CHoCH: the latest closed bar's close breaks beyond the most    |
//|     recent swing level AGAINST the prevailing trend (the first     |
//|     sign the structure may be turning).                            |
//|   - MSS: a CHoCH that a LATER, genuinely new swing has confirmed   |
//|     by extending further in the new direction than the level that |
//|     was broken - i.e. real follow-through, not just one bar poking |
//|     through a line.                                                |
//|                                                                    |
//|  NO LOOKAHEAD: Update() always reads CopyRates(...,1,...) - shift  |
//|  starts at 1, which is the most recent bar that has actually       |
//|  CLOSED. The currently-forming bar (shift 0) is never read by this |
//|  engine. Every call recomputes fresh from real OHLC data; nothing  |
//|  here is ever revised using information from a bar that wasn't     |
//|  closed yet at the time of that revision.                          |
//|                                                                    |
//|  SIGNAL-ONLY, NEVER TRADE PERMISSION (institutional engine spec     |
//|  section 9, verified rather than requiring a rewrite): this class   |
//|  contains no CTrade / OrderSend / position-open call anywhere -     |
//|  confirmed by inspection, not just convention - and every public    |
//|  accessor returns a read-only classification (trend/BOS/CHoCH/MSS/  |
//|  swing levels). It is a candidate-direction INPUT that CompositeDirection.mqh |
//|  and downstream engines (RiskEngine, ExecutionEligibility) may       |
//|  independently gate or refuse - it can never itself authorize a      |
//|  trade. As of this build it is not yet wired into the live OnTick    |
//|  loop at all (see AutopsyX_FlipDemon_Extreme.mq5's own comment       |
//|  where CExitEngine's PLUS_STRUCTURE mode documents that this engine  |
//|  "isn't integrated into the live tick loop" yet), so there is no     |
//|  existing call site to refactor - the separation this spec section   |
//|  asks for already holds architecturally and is recorded here.        |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_STRUCTUREENGINE_MQH
#define AX_STRUCTUREENGINE_MQH
#include "Defs.mqh"

#define AX_STRUCT_MAX_SWINGS               40
#define AX_STRUCT_FRACTAL_WING             2
#define AX_STRUCT_BASELINE_BARS            50
#define AX_STRUCT_RECENT_BARS              10
#define AX_STRUCT_ENVELOPE_BARS            15
#define AX_STRUCT_CHOCH_MAX_SWINGS_PENDING 6

class CStructureEngine
  {
private:
   string                  m_symbol;
   ENUM_TIMEFRAMES         m_tf;
   int                     m_lookbackBars;

   SAxSwingPoint           m_swings[AX_STRUCT_MAX_SWINGS]; // chronological, oldest first
   int                     m_swingCount;

   ENUM_AX_STRUCT_TREND    m_trend;
   ENUM_AX_STRUCTURE_EVENT m_lastEvent;
   datetime                m_lastEventTime;

   bool                    m_isDisplacement;
   bool                    m_isConsolidation;
   bool                    m_isExpansion;
   bool                    m_isCompression;
   double                  m_rangeRatio;      // recent avg range / baseline avg range

   //--- a CHoCH awaits confirmation into an MSS by a genuinely new, more-extreme swing forming ---
   //--- AFTER the CHoCH bar - tracked across Update() calls. Cleared when: (a) it confirms into ---
   //--- an MSS, (b) a fresh CHoCH fires on the opposite side, (c) the ORIGINAL pre-CHoCH trend    ---
   //--- resumes with its own BOS (the reversal thesis died, don't leave it armed), or (d) it goes  ---
   //--- AX_STRUCT_CHOCH_MAX_SWINGS_PENDING new swings without confirming (staleness backstop). ---
   bool                    m_chochPendingBullish;
   bool                    m_chochPendingBearish;
   double                  m_chochBrokenLevel;
   datetime                m_chochTime;
   int                     m_chochSwingCountAtPending; // m_swingCount snapshot when the pending
                               // CHoCH was set - lets DetectEvent tell a genuinely fresh follow-
                               // through swing apart from one that formed long before the CHoCH
                               // ever happened (code-review finding: a stale pending flag with no
                               // invalidation path could fire MSS using an unrelated, much-later
                               // swing once the market organically resumed trending)

   void PushSwing(const SAxSwingPoint &sp)
     {
      if(m_swingCount<AX_STRUCT_MAX_SWINGS)
        {
         m_swings[m_swingCount]=sp; m_swingCount++;
        }
      else
        {
         for(int i=1;i<AX_STRUCT_MAX_SWINGS;i++) m_swings[i-1]=m_swings[i];
         m_swings[AX_STRUCT_MAX_SWINGS-1]=sp;
        }
     }

   //--- builds the alternating swing sequence from closed-bar rates (series-indexed, [0]=newest ---
   //--- closed bar). Walks chronologically (oldest closed bar to newest) so PushSwing appends in ---
   //--- true time order. ---
   void BuildSwings(const MqlRates &rates[],const int count)
     {
      m_swingCount=0;
      int wing=AX_STRUCT_FRACTAL_WING;
      if(count<(2*wing+5)) return;

      SAxSwingPoint lastKept;
      bool haveKept=false;

      for(int i=count-1-wing;i>=wing;i--) // decreasing series-index = increasing time
        {
         bool isSwingHigh=true, isSwingLow=true;
         for(int w=1;w<=wing;w++)
           {
            if(rates[i].high<rates[i-w].high || rates[i].high<rates[i+w].high) isSwingHigh=false;
            if(rates[i].low >rates[i-w].low  || rates[i].low >rates[i+w].low)  isSwingLow=false;
           }
         if(!isSwingHigh && !isSwingLow) continue;

         //--- a bar that is fractally both a swing high AND swing low (can happen on a wide-range ---
         //--- bar) is treated as a swing high first, matching how price action would resolve it ---
         //--- for structure purposes (the extreme that happened is what matters) ---
         SAxSwingPoint cand;
         cand.time = rates[i].time;
         cand.isHH=false; cand.isLH=false; cand.isHL=false; cand.isLL=false;
         if(isSwingHigh) { cand.price=rates[i].high; cand.isHigh=true; }
         else             { cand.price=rates[i].low;  cand.isHigh=false; }

         if(!haveKept)
           {
            lastKept=cand; haveKept=true;
            continue;
           }

         if(cand.isHigh==lastKept.isHigh)
           {
            //--- same type as the last kept swing - collapse to whichever is more extreme, rather ---
            //--- than storing both (this is what keeps the sequence alternating) ---
            bool candMoreExtreme = cand.isHigh ? (cand.price>lastKept.price) : (cand.price<lastKept.price);
            if(candMoreExtreme) lastKept = cand;
            continue;
           }

         //--- type changed - commit the previous kept swing, start tracking the new one ---
         PushSwing(lastKept);
         lastKept = cand;
        }

      if(haveKept) PushSwing(lastKept);
     }

   //--- classify each swing's HH/LH/HL/LL against the PRIOR swing of the same type ---
   void ClassifySwings(void)
     {
      int prevHighIdx=-1, prevLowIdx=-1;
      for(int i=0;i<m_swingCount;i++)
        {
         if(m_swings[i].isHigh)
           {
            if(prevHighIdx>=0)
              {
               m_swings[i].isHH = (m_swings[i].price>m_swings[prevHighIdx].price);
               m_swings[i].isLH = !m_swings[i].isHH;
              }
            prevHighIdx=i;
           }
         else
           {
            if(prevLowIdx>=0)
              {
               m_swings[i].isHL = (m_swings[i].price>m_swings[prevLowIdx].price);
               m_swings[i].isLL = !m_swings[i].isHL;
              }
            prevLowIdx=i;
           }
        }
     }

   //--- most recent swing of a given type that has actually been classified (isHH/isLH or ---
   //--- isHL/isLL meaningful - i.e. not the very first swing of that type in the window) ---
   bool MostRecentClassifiedSwing(const bool wantHigh,SAxSwingPoint &out) const
     {
      for(int i=m_swingCount-1;i>=0;i--)
        {
         if(m_swings[i].isHigh!=wantHigh) continue;
         bool classified = wantHigh ? (m_swings[i].isHH||m_swings[i].isLH) : (m_swings[i].isHL||m_swings[i].isLL);
         if(!classified) continue;
         out = m_swings[i];
         return(true);
        }
      return(false);
     }

   bool MostRecentSwing(const bool wantHigh,SAxSwingPoint &out) const
     {
      for(int i=m_swingCount-1;i>=0;i--)
        {
         if(m_swings[i].isHigh==wantHigh) { out=m_swings[i]; return(true); }
        }
      return(false);
     }

   void DetermineTrend(void)
     {
      SAxSwingPoint recentHigh, recentLow;
      bool haveHigh = MostRecentClassifiedSwing(true,recentHigh);
      bool haveLow  = MostRecentClassifiedSwing(false,recentLow);
      if(!haveHigh || !haveLow) { m_trend=AX_STRUCT_TREND_UNDEFINED; return; }

      if(recentHigh.isHH && recentLow.isHL)      m_trend=AX_STRUCT_TREND_BULLISH;
      else if(recentHigh.isLH && recentLow.isLL) m_trend=AX_STRUCT_TREND_BEARISH;
      else                                        m_trend=AX_STRUCT_TREND_UNDEFINED;
     }

   void DetectVolatilityState(const MqlRates &rates[],const int count)
     {
      m_isDisplacement=false; m_isConsolidation=false; m_isExpansion=false; m_isCompression=false;
      m_rangeRatio=1.0;
      if(count<AX_STRUCT_BASELINE_BARS+1) return;

      double recentSum=0; for(int i=0;i<AX_STRUCT_RECENT_BARS;i++) recentSum+=(rates[i].high-rates[i].low);
      double baseSum=0;   for(int i=0;i<AX_STRUCT_BASELINE_BARS;i++) baseSum+=(rates[i].high-rates[i].low);
      double recentAvg = recentSum/AX_STRUCT_RECENT_BARS;
      double baseAvg    = baseSum/AX_STRUCT_BASELINE_BARS;
      if(baseAvg<=0) return;
      m_rangeRatio = recentAvg/baseAvg;

      m_isExpansion   = (m_rangeRatio>=1.5);
      m_isCompression = (m_rangeRatio<=0.6);

      double envHigh=-DBL_MAX, envLow=DBL_MAX;
      for(int i=0;i<AX_STRUCT_ENVELOPE_BARS && i<count;i++)
        {
         if(rates[i].high>envHigh) envHigh=rates[i].high;
         if(rates[i].low<envLow)   envLow=rates[i].low;
        }
      double envelopeWidth = envHigh-envLow;
      m_isConsolidation = (!m_isExpansion) && (envelopeWidth < baseAvg*4.0);

      //--- displacement: the latest CLOSED bar's own range far exceeds baseline, with most of that ---
      //--- range being real body (a genuine directional push), not mostly wick ---
      double bar0Range = rates[0].high-rates[0].low;
      if(bar0Range>0)
        {
         double bodyRatio = MathAbs(rates[0].close-rates[0].open)/bar0Range;
         m_isDisplacement = (bar0Range > baseAvg*2.0) && (bodyRatio>=0.6);
        }
     }

   void DetectEvent(const MqlRates &rates[],const int count)
     {
      m_lastEvent = AX_STRUCT_NONE;
      double close0 = rates[0].close;
      datetime time0 = rates[0].time;

      SAxSwingPoint recentHigh, recentLow;
      bool haveHigh = MostRecentSwing(true,recentHigh);
      bool haveLow  = MostRecentSwing(false,recentLow);

      if(m_trend==AX_STRUCT_TREND_BULLISH && haveHigh && haveLow)
        {
         if(close0>recentHigh.price)
           {
            m_lastEvent=AX_STRUCT_BOS_BULLISH; m_lastEventTime=time0;
            //--- the original (pre-CHoCH) bullish trend just resumed with a fresh higher high -
            //--- any still-pending bearish CHoCH was never confirmed and is now dead, not stale-
            //--- waiting - clear it so it can never later fire an MSS using an unrelated swing ---
            m_chochPendingBearish=false;
           }
         else if(close0<recentLow.price)
           {
            m_lastEvent=AX_STRUCT_CHOCH_BEARISH; m_lastEventTime=time0;
            m_chochPendingBearish=true; m_chochPendingBullish=false;
            m_chochBrokenLevel=recentLow.price; m_chochTime=time0;
            m_chochSwingCountAtPending=m_swingCount;
           }
        }
      else if(m_trend==AX_STRUCT_TREND_BEARISH && haveHigh && haveLow)
        {
         if(close0<recentLow.price)
           {
            m_lastEvent=AX_STRUCT_BOS_BEARISH; m_lastEventTime=time0;
            m_chochPendingBullish=false; // symmetric: original bearish trend resumed, kill any stale pending bullish CHoCH
           }
         else if(close0>recentHigh.price)
           {
            m_lastEvent=AX_STRUCT_CHOCH_BULLISH; m_lastEventTime=time0;
            m_chochPendingBullish=true; m_chochPendingBearish=false;
            m_chochBrokenLevel=recentHigh.price; m_chochTime=time0;
            m_chochSwingCountAtPending=m_swingCount;
           }
        }

      //--- staleness backstop: even without a clean BOS-in-the-original-direction event to clear it ---
      //--- (e.g. the market chops through AX_STRUCT_TREND_UNDEFINED for a long stretch), a pending  ---
      //--- CHoCH that has gone this many new swings without confirming into an MSS is treated as     ---
      //--- expired - it no longer represents a live, recent reversal thesis. ---
      if(m_chochPendingBearish && (m_swingCount-m_chochSwingCountAtPending)>AX_STRUCT_CHOCH_MAX_SWINGS_PENDING)
         m_chochPendingBearish=false;
      if(m_chochPendingBullish && (m_swingCount-m_chochSwingCountAtPending)>AX_STRUCT_CHOCH_MAX_SWINGS_PENDING)
         m_chochPendingBullish=false;

      //--- MSS confirmation check runs independent of the current trend read above, since a fresh ---
      //--- CHoCH deliberately leaves m_trend UNDEFINED until a new swing re-establishes a sequence ---
      if(m_chochPendingBearish && haveLow && recentLow.time>m_chochTime && recentLow.price<m_chochBrokenLevel)
        {
         m_lastEvent=AX_STRUCT_MSS_BEARISH; m_lastEventTime=time0;
         m_chochPendingBearish=false;
        }
      if(m_chochPendingBullish && haveHigh && recentHigh.time>m_chochTime && recentHigh.price>m_chochBrokenLevel)
        {
         m_lastEvent=AX_STRUCT_MSS_BULLISH; m_lastEventTime=time0;
         m_chochPendingBullish=false;
        }
     }

public:
                     CStructureEngine(void)
     {
      m_swingCount=0; m_trend=AX_STRUCT_TREND_UNDEFINED; m_lastEvent=AX_STRUCT_NONE; m_lastEventTime=0;
      m_isDisplacement=false; m_isConsolidation=false; m_isExpansion=false; m_isCompression=false;
      m_rangeRatio=1.0;
      m_chochPendingBullish=false; m_chochPendingBearish=false; m_chochBrokenLevel=0; m_chochTime=0;
      m_chochSwingCountAtPending=0;
     }

   bool              Init(const string symbol,const ENUM_TIMEFRAMES tf,const int lookbackBars=300)
     {
      m_symbol=symbol; m_tf=tf; m_lookbackBars=MathMax(50,lookbackBars);
      return(true);
     }

   //--- call once per new CLOSED bar on this engine's own timeframe ---
   void              Update(void)
     {
      MqlRates rates[];
      ArraySetAsSeries(rates,true);
      int copied = CopyRates(m_symbol,m_tf,1,m_lookbackBars,rates); // shift=1: skip the forming bar
      if(copied<20)
        {
         m_trend=AX_STRUCT_TREND_UNDEFINED; m_lastEvent=AX_STRUCT_NONE;
         return;
        }
      BuildSwings(rates,copied);
      ClassifySwings();
      DetermineTrend();
      DetectVolatilityState(rates,copied);
      DetectEvent(rates,copied);
     }

   ENUM_AX_STRUCT_TREND    Trend(void)         const { return(m_trend); }
   ENUM_AX_STRUCTURE_EVENT LastEvent(void)     const { return(m_lastEvent); }
   datetime                LastEventTime(void) const { return(m_lastEventTime); }
   bool                    IsDisplacement(void)   const { return(m_isDisplacement); }
   bool                    IsConsolidation(void)  const { return(m_isConsolidation); }
   bool                    IsExpansion(void)      const { return(m_isExpansion); }
   bool                    IsCompression(void)    const { return(m_isCompression); }
   double                  RangeRatio(void)       const { return(m_rangeRatio); }
   int                     SwingCount(void)       const { return(m_swingCount); }

   bool                    GetSwing(const int i,SAxSwingPoint &out) const
     {
      if(i<0 || i>=m_swingCount) return(false);
      out = m_swings[i];
      return(true);
     }

   //--- nearest swing level of the requested type to a reference price - 0.0 if none tracked yet. ---
   //--- Used for structure-based stop placement; never fabricates a level that wasn't really found. ---
   double                  NearestSwingLevel(const bool wantHigh,const double refPrice) const
     {
      double best=0.0, bestDist=DBL_MAX;
      for(int i=0;i<m_swingCount;i++)
        {
         if(m_swings[i].isHigh!=wantHigh) continue;
         double dist=MathAbs(m_swings[i].price-refPrice);
         if(dist<bestDist) { bestDist=dist; best=m_swings[i].price; }
        }
      return(best);
     }

   //--- compact human-readable summary for TradeThesis.structureState / dashboard ---
   string                  StateSummary(void) const
     {
      return(StringFormat("trend=%s event=%s%s",
             AxStructTrendToString(m_trend),
             AxStructureEventToString(m_lastEvent),
             m_isDisplacement ? " DISPLACEMENT" : (m_isExpansion ? " EXPANSION" :
             (m_isCompression ? " COMPRESSION" : (m_isConsolidation ? " CONSOLIDATION" : "")))));
     }
  };
//+------------------------------------------------------------------+
#endif // AX_STRUCTUREENGINE_MQH
