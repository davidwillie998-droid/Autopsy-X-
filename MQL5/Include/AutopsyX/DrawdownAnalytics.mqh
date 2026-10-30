//+------------------------------------------------------------------+
//|                                         DrawdownAnalytics.mqh|
//|  Drawdown Analytics (spec section 21-ish, institutional engine     |
//|  upgrade) - ENGINEERING DESIGN, not paper-sourced. Distinct from    |
//|  DrawdownEngine.mqh (Phase 6): that class tracks LIVE, real-time     |
//|  drawdown state tick-by-tick from account equity. This class          |
//|  analyzes the HISTORICAL episode record from CTradeAutopsy's closed-  |
//|  trade ledger (Journal v2) after the fact - how many drawdown          |
//|  episodes has this account actually been through, how deep, how        |
//|  long, not just what the CURRENT one looks like.                        |
//|                                                                    |
//|  An "episode" here is defined purely mechanically from the trade-      |
//|  by-trade equity curve reconstructed the same way CStatistics.mqh's     |
//|  own Compute() already walks it: it begins the first time equity        |
//|  drops below its running peak, and ends the first time equity            |
//|  reaches a NEW peak strictly above the pre-episode peak. This is an       |
//|  ENGINEERING DEFINITION - the paper does not define "episode" this        |
//|  or any other specific way.                                                |
//|                                                                    |
//|  DELIBERATELY THIN: reuses CTradeAutopsy's existing ledger, does not       |
//|  reimplement equity-curve reconstruction differently than                   |
//|  CStatistics.mqh already does it (same peak-tracking walk, same             |
//|  "a partial slice never counts as a standalone trade outcome"                |
//|  convention).                                                                 |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_DRAWDOWNANALYTICS_MQH
#define AX_DRAWDOWNANALYTICS_MQH
#include "Defs.mqh"
#include "TradeAutopsy.mqh"

struct SAxDrawdownEpisode
  {
   datetime startTime;      // exit time of the trade that first took equity below the running peak
   datetime troughTime;     // exit time of the trade at the deepest point of this episode (so far)
   datetime recoveryTime;   // exit time of the trade that first re-set a new peak - 0 if not yet recovered
   double   peakEquity;     // the equity level this episode fell from (and must reclaim to "recover")
   double   troughEquity;
   double   depthCurrency;
   double   depthPercent;
   int      durationSeconds; // troughTime-startTime if unrecovered so far, else recoveryTime-startTime
   bool     recovered;
  };

#define AX_DD_ANALYTICS_MAX_EPISODES 500 // defensive cap - a live account realistically produces far
                                           // fewer than this many distinct episodes; if genuinely
                                           // exceeded, the OLDEST episodes are dropped from the summary
                                           // stats (documented below), never silently truncating count

struct SAxDrawdownAnalyticsResult
  {
   int      episodeCount;          // TRUE total episodes found - may exceed AX_DD_ANALYTICS_MAX_EPISODES
   int      storedEpisodeCount;    // == ArraySize(episodesOut) after Compute() returns - ALWAYS the
                                     // correct bound for iterating episodesOut[]. Callers must use this
                                     // (or ArraySize(episodesOut) directly), never episodeCount, to index
                                     // into episodesOut[] - episodeCount can exceed what was actually kept
                                     // once the AX_DD_ANALYTICS_MAX_EPISODES cap evicts old entries
                                     // (code-review finding).
   int      recoveredEpisodeCount;
   int      unrecoveredEpisodeCount;
   double   avgDepthPercent;
   double   maxDepthPercent;
   double   avgDurationSeconds;    // over RECOVERED episodes only - an unrecovered episode's duration
                                     // is still growing and would understate the true average if mixed in
   double   maxDurationSeconds;    // over RECOVERED episodes only, same reasoning
   string   reason;
  };

class CDrawdownAnalytics
  {
public:
   //--- episodesOut[] must already be a dynamic array on the caller's side - filled with up to          ---
   //--- AX_DD_ANALYTICS_MAX_EPISODES entries (oldest-dropped-first if the real count exceeds the cap,    ---
   //--- so the MOST RECENT episodes - the ones most relevant to current risk posture - are always kept). ---
   //--- Iterate episodesOut[] using the returned result's storedEpisodeCount (or ArraySize(episodesOut)  ---
   //--- directly) - NOT episodeCount, which is the true uncapped historical total and can exceed what    ---
   //--- is actually stored (code-review finding). ---
   SAxDrawdownAnalyticsResult Compute(const CTradeAutopsy &autopsy,const double startingEquity,
                                       SAxDrawdownEpisode &episodesOut[]) const
     {
      SAxDrawdownAnalyticsResult res;
      res.episodeCount=0; res.storedEpisodeCount=0; res.recoveredEpisodeCount=0; res.unrecoveredEpisodeCount=0;
      res.avgDepthPercent=0.0; res.maxDepthPercent=0.0; res.avgDurationSeconds=0.0; res.maxDurationSeconds=0.0;
      ArrayResize(episodesOut,0);

      int n=autopsy.Count();
      if(n<=0) { res.reason="No closed trades yet"; return(res); }

      double equity=startingEquity;
      double peak=startingEquity;
      bool inEpisode=false;
      SAxDrawdownEpisode current;

      double sumDepthPct=0.0; int depthSampleCount=0;
      double sumDurationSec=0.0; int durationSampleCount=0;

      for(int t=0;t<n;t++)
        {
         SAxTradeRecord r;
         if(!autopsy.GetRecord(t,r)) continue;
         //--- every record moves real equity, same convention as CStatistics.mqh - a partial scale-out ---
         //--- slice still moves the equity curve even though it isn't a standalone win/loss outcome ---
         equity += r.netProfit;

         if(equity>=peak)
           {
            if(inEpisode)
              {
               //--- new peak reached - this episode has recovered ---
               current.recoveryTime = r.exitTime;
               current.recovered = true;
               current.durationSeconds = (int)(current.recoveryTime-current.startTime);
               PushEpisode(episodesOut,current);
               res.episodeCount++;
               res.recoveredEpisodeCount++;
               sumDepthPct += current.depthPercent;
               if(current.depthPercent>res.maxDepthPercent) res.maxDepthPercent=current.depthPercent;
               depthSampleCount++;
               sumDurationSec += current.durationSeconds;
               if(current.durationSeconds>res.maxDurationSeconds) res.maxDurationSeconds=current.durationSeconds;
               durationSampleCount++;
               inEpisode=false;
              }
            peak=equity;
           }
         else
           {
            if(!inEpisode)
              {
               //--- first tick below the running peak - a new episode begins ---
               inEpisode=true;
               current.startTime=r.exitTime; current.peakEquity=peak;
               current.troughTime=r.exitTime; current.troughEquity=equity;
               current.recoveryTime=0; current.recovered=false;
              }
            if(equity<current.troughEquity)
              { current.troughEquity=equity; current.troughTime=r.exitTime; }
            current.depthCurrency = current.peakEquity-current.troughEquity;
            current.depthPercent  = (current.peakEquity>0) ? 100.0*current.depthCurrency/current.peakEquity : 0.0;
           }
        }

      //--- if the ledger ends still underwater, that episode is real and reported - just not counted    ---
      //--- into avgDurationSeconds/maxDurationSeconds (see struct comment: it's still growing) ---
      if(inEpisode)
        {
         //--- `current` is one struct reused across the whole loop - durationSeconds was last set        ---
         //--- (if at all) by a PREVIOUS, already-recovered episode's recovery branch, so it must be        ---
         //--- freshly computed here rather than left stale before this ongoing episode is pushed            ---
         //--- (code-review finding: without this, an ongoing final episode could report a completely         ---
         //--- unrelated duration left over from an earlier episode in the same ledger). ---
         current.durationSeconds = (int)(current.troughTime-current.startTime);
         PushEpisode(episodesOut,current);
         res.episodeCount++;
         res.unrecoveredEpisodeCount++;
         sumDepthPct += current.depthPercent;
         if(current.depthPercent>res.maxDepthPercent) res.maxDepthPercent=current.depthPercent;
         depthSampleCount++;
        }

      res.storedEpisodeCount = ArraySize(episodesOut);
      res.avgDepthPercent    = (depthSampleCount>0)    ? sumDepthPct/depthSampleCount       : 0.0;
      res.avgDurationSeconds = (durationSampleCount>0) ? sumDurationSec/durationSampleCount : 0.0;
      res.reason=StringFormat("%d episode(s) (%d recovered, %d ongoing, %d stored): avgDepth=%.2f%% maxDepth=%.2f%%",
                               res.episodeCount,res.recoveredEpisodeCount,res.unrecoveredEpisodeCount,
                               res.storedEpisodeCount,res.avgDepthPercent,res.maxDepthPercent);
      return(res);
     }

private:
   //--- appends to episodesOut[], dropping the OLDEST entry first if already at the defensive cap -     ---
   //--- keeps the most recent, most currently-relevant episodes rather than the earliest ones. ---
   void              PushEpisode(SAxDrawdownEpisode &episodesOut[],const SAxDrawdownEpisode &ep) const
     {
      int size=ArraySize(episodesOut);
      if(size<AX_DD_ANALYTICS_MAX_EPISODES)
        {
         ArrayResize(episodesOut,size+1);
         episodesOut[size]=ep;
        }
      else
        {
         for(int i=1;i<AX_DD_ANALYTICS_MAX_EPISODES;i++) episodesOut[i-1]=episodesOut[i];
         episodesOut[AX_DD_ANALYTICS_MAX_EPISODES-1]=ep;
        }
     }
  };
//+------------------------------------------------------------------+
#endif // AX_DRAWDOWNANALYTICS_MQH
