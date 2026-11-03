//+------------------------------------------------------------------+
//|                                     PerformanceAttribution.mqh|
//|  Performance Attribution (spec section 20-ish, institutional       |
//|  engine upgrade) - ENGINEERING DESIGN, not paper-sourced. The       |
//|  paper (Malhotra SSRN 3306817) does not specify an attribution      |
//|  breakdown; standard institutional practice (attributing P&L to     |
//|  regime, direction, etc. rather than reporting one blended number)  |
//|  motivates this, not any specific formula from the paper.            |
//|                                                                    |
//|  DELIBERATELY THIN: reads CTradeAutopsy's existing closed-trade      |
//|  ledger (Journal v2, already built and reviewed in an earlier         |
//|  phase) and groups it - it does not recompute win/loss classification|
//|  or reimplement anything CStatistics.mqh already owns. This is a      |
//|  GROUP-BY on top of the same ledger CStatistics.Compute() already      |
//|  walks, not a second bookkeeping system.                                |
//|                                                                    |
//|  CRITICAL STATISTICAL RULE (spec's own instruction, carried into      |
//|  this file): these buckets are for DIAGNOSIS, never for silently       |
//|  re-optimizing solely toward whichever regime/direction currently       |
//|  looks best - a caller reading a SAxAttributionBucket is expected to     |
//|  apply the same "insufficient sample size = don't act on it yet"          |
//|  judgment already used everywhere else in this codebase (see             |
//|  winRate=0/avgNetProfit=0 on an empty bucket below - never fabricated).    |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_PERFORMANCEATTRIBUTION_MQH
#define AX_PERFORMANCEATTRIBUTION_MQH
#include "Defs.mqh"
#include "TradeAutopsy.mqh"

//--- must match ENUM_AX_REGIME's real cardinality (Defs.mqh) - MQL5 has no compile-time enum-count     ---
//--- reflection to derive this automatically, so it is a documented, manually-verified constant: 9      ---
//--- members (TREND, STRONG_TREND, BREAKOUT, RANGE, MEAN_REVERSION, HIGH_VOL, LOW_VOL, CHAOTIC, UNSAFE). ---
#define AX_ATTRIBUTION_REGIME_COUNT 9

struct SAxAttributionBucket
  {
   string   label;
   int      trades;
   int      wins;
   double   netProfit;
   double   winRate;       // 0 on an empty bucket - never fabricated
   double   avgNetProfit;  // 0 on an empty bucket - never fabricated
  };

class CPerformanceAttribution
  {
private:
   void              ResetBucket(SAxAttributionBucket &b,const string label) const
     {
      b.label=label; b.trades=0; b.wins=0; b.netProfit=0.0; b.winRate=0.0; b.avgNetProfit=0.0;
     }

   void              Finalize(SAxAttributionBucket &b) const
     {
      b.winRate      = (b.trades>0) ? 100.0*b.wins/b.trades : 0.0;
      b.avgNetProfit = (b.trades>0) ? b.netProfit/b.trades  : 0.0;
     }

   void              Accumulate(SAxAttributionBucket &b,const SAxTradeRecord &r) const
     {
      b.trades++;
      if(r.netProfit>0) b.wins++;
      b.netProfit += r.netProfit;
     }

public:
   //--- out[] must already be a dynamic array on the caller's side - ArrayResize()'d here to exactly    ---
   //--- AX_ATTRIBUTION_REGIME_COUNT buckets, one per ENUM_AX_REGIME value, index-aligned with the enum's ---
   //--- own integer values so out[(int)someRegime] is always the right bucket. ---
   int               ByRegime(const CTradeAutopsy &autopsy,SAxAttributionBucket &out[]) const
     {
      ArrayResize(out,AX_ATTRIBUTION_REGIME_COUNT);
      for(int i=0;i<AX_ATTRIBUTION_REGIME_COUNT;i++)
         ResetBucket(out[i],AxRegimeToString((ENUM_AX_REGIME)i));

      int n=autopsy.Count();
      for(int t=0;t<n;t++)
        {
         SAxTradeRecord r;
         if(!autopsy.GetRecord(t,r)) continue;
         if(r.isPartial) continue; // matches CStatistics.mqh's own convention - a scale-out slice is
                                     // not a standalone trade outcome
         int idx=(int)r.regime;
         if(idx<0 || idx>=AX_ATTRIBUTION_REGIME_COUNT) continue; // defensive - should never happen for a
                                                                    // real ENUM_AX_REGIME value
         Accumulate(out[idx],r);
        }
      for(int i=0;i<AX_ATTRIBUTION_REGIME_COUNT;i++) Finalize(out[i]);
      return(AX_ATTRIBUTION_REGIME_COUNT);
     }

   //--- out[0]=BUY, out[1]=SELL. AX_DIR_NONE never appears in a closed trade record, so no third bucket. ---
   int               ByDirection(const CTradeAutopsy &autopsy,SAxAttributionBucket &out[]) const
     {
      ArrayResize(out,2);
      ResetBucket(out[0],"BUY");
      ResetBucket(out[1],"SELL");

      int n=autopsy.Count();
      for(int t=0;t<n;t++)
        {
         SAxTradeRecord r;
         if(!autopsy.GetRecord(t,r)) continue;
         if(r.isPartial) continue;
         if(r.direction==AX_DIR_BUY)       Accumulate(out[0],r);
         else if(r.direction==AX_DIR_SELL) Accumulate(out[1],r);
         // AX_DIR_NONE: not a real closed-trade direction - silently excluded, not an error
        }
      Finalize(out[0]); Finalize(out[1]);
      return(2);
     }

   //--- out[0]=flip-originated trades (flipSeq>0), out[1]=non-flip trades - answers "does this EA's own ---
   //--- flip mechanism actually help or hurt, on the real closed-trade record" directly. ---
   int               ByFlipOrigin(const CTradeAutopsy &autopsy,SAxAttributionBucket &out[]) const
     {
      ArrayResize(out,2);
      ResetBucket(out[0],"FLIP");
      ResetBucket(out[1],"NON_FLIP");

      int n=autopsy.Count();
      for(int t=0;t<n;t++)
        {
         SAxTradeRecord r;
         if(!autopsy.GetRecord(t,r)) continue;
         if(r.isPartial) continue;
         if(r.flipSeq>0) Accumulate(out[0],r);
         else             Accumulate(out[1],r);
        }
      Finalize(out[0]); Finalize(out[1]);
      return(2);
     }
  };
//+------------------------------------------------------------------+
#endif // AX_PERFORMANCEATTRIBUTION_MQH
