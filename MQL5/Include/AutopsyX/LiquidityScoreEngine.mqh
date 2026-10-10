//+------------------------------------------------------------------+
//|                                            LiquidityScoreEngine.mqh|
//|  Layer 3: Liquidity Score (institutional engine upgrade) -        |
//|  ENGINEERING DESIGN, not paper-sourced. The source paper (Malhotra|
//|  SSRN 3306817) treats liquidity as centrally important but does    |
//|  not give a scoring formula - findings items xii-xiii do point to  |
//|  "macro risk indicators based on liquidity: credit spreads, bid-   |
//|  ask spreads, trade volumes, curves", which is the inspiration for |
//|  using spread and tick-activity as inputs below, not a literal     |
//|  formula from the paper.                                           |
//|                                                                    |
//|  NAMING NOTE: this is a DIFFERENT concept from CLiquidityEngine    |
//|  (Liquidity.mqh), which tracks ICT-style price LEVELS (sweeps,     |
//|  equal highs/lows, PDH/PDL) where liquidity is presumed to rest.   |
//|  This engine instead scores current MARKET CONDITIONS for how      |
//|  tradable/liquid they are right now - a different question,        |
//|  sharing the word "liquidity" because both are real, standard      |
//|  uses of the term in market microstructure.                        |
//|                                                                    |
//|  BROKER_TICK_VOLUME: every "activity" measure here uses this       |
//|  feed's own tick count/frequency, per spec section 3's own          |
//|  instruction not to pretend that equals centralized exchange        |
//|  volume.                                                            |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_LIQUIDITYSCOREENGINE_MQH
#define AX_LIQUIDITYSCOREENGINE_MQH
#include "Defs.mqh"
#include "MarketData.mqh"
#include "Microstructure.mqh"
#include "VolatilityEngine.mqh"

class CLiquidityScoreEngine
  {
private:
   //--- component weights - all configurable, none hardcoded as fixed truth (spec: "make all        ---
   //--- weights configurable") ---
   double m_wSpread, m_wSpreadPercentile, m_wTickActivity, m_wVolatility, m_wVelocity,
          m_wExecQuality, m_wQuoteStability;

   //--- absolute thresholds, symbol-specific and configurable - "excellent" maps to score 100,       ---
   //--- "poor" maps to score 0, linear between ---
   double m_excellentSpreadPts, m_poorSpreadPts;
   double m_excellentTicksPerSec, m_poorTicksPerSec;
   double m_excellentVelocityPtsPerSec, m_poorVelocityPtsPerSec; // NOTE: here "excellent" = SLOWER
                                                                   // price movement - an engineering
                                                                   // choice (fast-moving price is
                                                                   // harder to execute cleanly in),
                                                                   // not a paper-sourced conclusion

   int    m_spreadPercentileLookback;

   double LinearScore(const double value,const double excellentAt,const double poorAt) const
     {
      if(excellentAt==poorAt) return(50.0);
      double t = (value-poorAt)/(excellentAt-poorAt);
      return(AxClampD(t*100.0,0.0,100.0));
     }

public:
                     CLiquidityScoreEngine(void)
     {
      m_wSpread=20; m_wSpreadPercentile=15; m_wTickActivity=15; m_wVolatility=15;
      m_wVelocity=15; m_wExecQuality=15; m_wQuoteStability=5;
      m_excellentSpreadPts=10; m_poorSpreadPts=100;
      m_excellentTicksPerSec=2.0; m_poorTicksPerSec=0.05;
      m_excellentVelocityPtsPerSec=1.0; m_poorVelocityPtsPerSec=30.0;
      m_spreadPercentileLookback=100;
     }

   void              Configure(const double wSpread,const double wSpreadPercentile,
                                const double wTickActivity,const double wVolatility,
                                const double wVelocity,const double wExecQuality,
                                const double wQuoteStability,
                                const double excellentSpreadPts,const double poorSpreadPts,
                                const double excellentTicksPerSec,const double poorTicksPerSec,
                                const double excellentVelocityPtsPerSec,const double poorVelocityPtsPerSec,
                                const int spreadPercentileLookback)
     {
      m_wSpread=MathMax(0,wSpread); m_wSpreadPercentile=MathMax(0,wSpreadPercentile);
      m_wTickActivity=MathMax(0,wTickActivity); m_wVolatility=MathMax(0,wVolatility);
      m_wVelocity=MathMax(0,wVelocity); m_wExecQuality=MathMax(0,wExecQuality);
      m_wQuoteStability=MathMax(0,wQuoteStability);
      m_excellentSpreadPts=excellentSpreadPts; m_poorSpreadPts=poorSpreadPts;
      m_excellentTicksPerSec=excellentTicksPerSec; m_poorTicksPerSec=poorTicksPerSec;
      m_excellentVelocityPtsPerSec=excellentVelocityPtsPerSec; m_poorVelocityPtsPerSec=poorVelocityPtsPerSec;
      m_spreadPercentileLookback=MathMax(10,spreadPercentileLookback);
     }

   //--- 0 = tightest spread seen recently, 100 = widest - a RELATIVE measure, distinct from the      ---
   //--- absolute spreadScore in ComputeScore() below (a symbol whose typical spread is always wide   ---
   //--- can still read NORMAL here even while scoring poorly on the absolute component) ---
   double            SpreadPercentileRank(const CMarketData &md,const double currentSpreadPts) const
     {
      int n = MathMin(md.Count(),m_spreadPercentileLookback+1);
      if(n<20) return(50.0); // insufficient history - neutral midpoint, not a fabricated extreme
      //--- mid-rank convention (tie = half credit), same reasoning and same fix as               ---
      //--- CVolatilityEngine's percentile rank - a strict <= would pin this to 100 (worst) on a   ---
      //--- broker/symbol with a genuinely fixed spread, scoring a flat/tie history identically to ---
      //--- a real outlier-wide spread (code-review finding). ---
      double belowWeight=0.0; int cnt=0;
      for(int i=1;i<n;i++) // i=1: exclude the current tick from its own baseline (same reasoning as
        {                  // CDataIntegrityEngine::RollingSpreadZScore)
         SAxTick t;
         if(!md.GetSample(i,t)) continue;
         if(t.spreadPts<currentSpreadPts)       belowWeight += 1.0;
         else if(t.spreadPts==currentSpreadPts) belowWeight += 0.5;
         cnt++;
        }
      if(cnt<20) return(50.0);
      return(100.0*belowWeight/(double)cnt);
     }

   //--- BROKER_TICK_VOLUME activity - ticks per second over the available buffer, never claimed as  ---
   //--- centralized exchange volume ---
   double            TickActivityPerSecond(const CMarketData &md) const
     {
      int n = MathMin(md.Count(),50);
      if(n<5) return(0.0);
      SAxTick newest,oldest;
      if(!md.GetSample(0,newest) || !md.GetSample(n-1,oldest)) return(0.0);
      double dt = (double)(newest.time-oldest.time);
      if(dt<=0) dt=1.0;
      return((double)n/dt);
     }

   //--- Velocity = |delta MidPrice| / delta Time, in points/second (spec section 4's own formula,    ---
   //--- units are an engineering choice since the spec doesn't specify one) ---
   double            PriceVelocityPtsPerSecond(const CMarketData &md) const
     {
      int n = MathMin(md.Count(),20);
      if(n<3) return(0.0);
      SAxTick newest,oldest;
      if(!md.GetSample(0,newest) || !md.GetSample(n-1,oldest)) return(0.0);
      double dt = (double)(newest.time-oldest.time);
      if(dt<=0) dt=1.0;
      double point = md.Point(); if(point<=0) point=0.00001;
      return(MathAbs(newest.mid-oldest.mid)/point/dt);
     }

   //--- combines every component into one 0..100 LiquidityScore. execution-quality inputs           ---
   //--- (avgSlippagePts/avgLatencyMs/consecutivePoorFills) are passed in rather than recomputed here -  ---
   //--- they already exist as live-tracked state elsewhere in the EA (AFE/main.mq5's fill-quality    ---
   //--- tracking) and this engine should not duplicate that bookkeeping. ---
   double            ComputeScore(const CMarketData &md,const CMicrostructureEngine &micro,
                                   const CVolatilityEngine &volEngine,const double avgSlippagePts,
                                   const double avgLatencyMs,const int consecutivePoorFills,
                                   string &breakdownOut) const
     {
      double spreadPts = md.CurrentSpreadPts();
      double spreadScore = LinearScore(spreadPts,m_excellentSpreadPts,m_poorSpreadPts);

      double spreadPctRank = SpreadPercentileRank(md,spreadPts);
      double spreadPercentileScore = 100.0-spreadPctRank;

      //--- md.Count()<5 is TickActivityPerSecond's own "insufficient data" threshold - checked here    ---
      //--- too (rather than trusting its 0.0 return alone) because 0.0 is ALSO a value that function   ---
      //--- can legitimately report from real data (activity genuinely below the tracked buffer's      ---
      //--- resolution) - the two cases need different scores and only ComputeScore knows which one    ---
      //--- applies. Insufficient data reads as neutral (50), never as the worst possible score         ---
      //--- (code-review finding: 0.0 was silently forced into LinearScore as if it were a real, very   ---
      //--- low reading, at exactly the startup/sparse-data moment there's no real basis to judge it). ---
      double ticksPerSec = TickActivityPerSecond(md);
      double tickActivityScore = (md.Count()<5) ? 50.0 : LinearScore(ticksPerSec,m_excellentTicksPerSec,m_poorTicksPerSec);

      double volScore;
      switch(volEngine.State())
        {
         case AX_VOL_SHOCK:   volScore=10;  break;
         case AX_VOL_EXTREME: volScore=25;  break;
         case AX_VOL_HIGH:    volScore=55;  break;
         case AX_VOL_LOW:     volScore=70;  break;
         default:              volScore=85;  break; // AX_VOL_NORMAL
        }

      //--- same insufficient-data reasoning as tickActivityScore above: PriceVelocityPtsPerSecond's   ---
      //--- own 0.0-on-too-few-samples return would otherwise be read as "zero price movement" and     ---
      //--- score the maximum 100 ("excellent" = slow-moving, per this engine's own convention) at      ---
      //--- exactly the moment there's no real basis to judge velocity at all (code-review finding). ---
      double velocityPtsPerSec = PriceVelocityPtsPerSecond(md);
      double velocityScore = (md.Count()<3) ? 50.0 : LinearScore(velocityPtsPerSec,m_excellentVelocityPtsPerSec,m_poorVelocityPtsPerSec);

      double execQualityScore = 100.0;
      if(avgSlippagePts>0) execQualityScore -= MathMin(50.0,avgSlippagePts*2.0);
      if(avgLatencyMs>0)   execQualityScore -= MathMin(30.0,avgLatencyMs/50.0);
      execQualityScore -= MathMin(20.0,consecutivePoorFills*10.0);
      execQualityScore = AxClampD(execQualityScore,0.0,100.0);

      double quoteStabilityScore = micro.SpreadExpanding() ? 30.0 : (micro.SpreadCompressing() ? 90.0 : 70.0);

      double totalWeight = m_wSpread+m_wSpreadPercentile+m_wTickActivity+m_wVolatility+
                            m_wVelocity+m_wExecQuality+m_wQuoteStability;
      if(totalWeight<=0)
        { breakdownOut="No weight configured"; return(0.0); }

      double weighted = spreadScore*m_wSpread + spreadPercentileScore*m_wSpreadPercentile +
                         tickActivityScore*m_wTickActivity + volScore*m_wVolatility +
                         velocityScore*m_wVelocity + execQualityScore*m_wExecQuality +
                         quoteStabilityScore*m_wQuoteStability;
      double finalScore = AxClampD(weighted/totalWeight,0.0,100.0);

      breakdownOut = StringFormat(
         "spread=%.0f spreadPct=%.0f tickAct(BROKER_TICK_VOLUME)=%.0f vol=%.0f velocity=%.0f exec=%.0f quoteStab=%.0f",
         spreadScore,spreadPercentileScore,tickActivityScore,volScore,velocityScore,
         execQualityScore,quoteStabilityScore);
      return(finalScore);
     }
  };
//+------------------------------------------------------------------+
#endif // AX_LIQUIDITYSCOREENGINE_MQH
