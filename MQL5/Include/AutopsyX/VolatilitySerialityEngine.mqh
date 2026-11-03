//+------------------------------------------------------------------+
//|                                     VolatilitySerialityEngine.mqh|
//|  Volatility x Seriality Engine (10X Market Intelligence upgrade,   |
//|  Phase 3) - ENGINEERING DESIGN, not paper-sourced.                  |
//|                                                                    |
//|  NOT a duplicate of CVolatilityEngine's own 5-state                  |
//|  ENUM_AX_VOLATILITY_STATE (NORMAL/LOW/HIGH/EXTREME/SHOCK, already      |
//|  live-eligible and reused here directly via State()/CurrentAtr()/       |
//|  PercentileRank()/AccelerationPct() - none of it recomputed). What        |
//|  genuinely doesn't exist anywhere in this codebase, and is the only        |
//|  new computation in this file, is BAR-LEVEL RETURN SERIAL DEPENDENCE:       |
//|  lag-1 return autocorrelation, directional persistence, and reversal         |
//|  frequency, measured over closed-bar log returns.                              |
//|                                                                    |
//|  NOT CMomentumEngine::PersistenceRatio(): that field measures the            |
//|  fraction of the last ~30 TICKS moving in the dominant direction over          |
//|  a sub-window of raw tick flow - a genuinely different statistical              |
//|  object, on a different time scale, from BAR-TO-BAR return serial               |
//|  dependence. Reusing it here would have been dressing up a tick-level             |
//|  measurement as a bar-level one - this file computes its own, honestly            |
//|  labeled, bar-level equivalent instead.                                              |
//|                                                                    |
//|  "Do not assume high volatility automatically means a bad trading             |
//|  environment" (this phase's own instruction): the classification below           |
//|  explicitly distinguishes LOW-vol-persistent from LOW-vol-random, and              |
//|  HIGH-vol-trending from HIGH-vol-mean-reverting, rather than collapsing              |
//|  volatility level alone into a single good/bad signal.                                 |
//|                                                                    |
//|  "Trend persistence" (spec wording) is treated as the SAME measured value       |
//|  as directionalPersistence below, not a second, independently-derived one -       |
//|  building a genuinely different trend-persistence measure would duplicate           |
//|  CRegimeEngine's own R2 (already used for exactly this purpose in                     |
//|  RegimeClassifierEngine.mqh) - stated honestly rather than fabricating a                |
//|  second number for the same concept.                                                       |
//|                                                                    |
//|  HONEST LIMITATIONS:                                                          |
//|   - Autocorrelation/persistence/reversal-frequency are all computed over a       |
//|     single configurable lookback window (default 50 bars). No claim of              |
//|     statistical significance is made anywhere - this phase's own instruction          |
//|     is explicit: "At this stage, do not claim trading alpha... the objective            |
//|     is to establish whether the measurements provide useful state information            |
//|     for later phases," not to prove an edge.                                                |
//|   - sampleSize is exposed precisely so a caller can judge a low-sample-size              |
//|     reading as low-confidence - there is no separate fabricated confidence                  |
//|     score here (unlike RegimeClassifierEngine.mqh, whose spec explicitly asked               |
//|     for one; this spec did not).                                                                |
//|   - "Volatility expansion" (distinct from CVolatilityEngine's own SHOCK state)          |
//|     uses THIS file's own configurable m_expansionAccelPct threshold, deliberately          |
//|     lower than a typical shock threshold - CVolatilityEngine's own m_shockAccelPct           |
//|     is a private, Configure()-set value not exposed publicly (same limitation as               |
//|     RegimeClassifierEngine.mqh's own R6 confidence) - ordering is safe regardless               |
//|     since AX_VOL_SHOCK is checked with top priority before this branch is reached.                |
//|                                                                    |
//|  DELIBERATELY THIN except for the one genuinely new computation above.        |
//|  Owns its OWN closed-bar read (iTime/CopyClose), matching this codebase's         |
//|  "each engine owns its own read" convention - does not read from                    |
//|  MarketStateEngine.mqh or duplicate its OHLC read.                                      |
//|                                                                    |
//|  BAR-LEVEL, SIGNAL-ONLY, NOT WIRED: matches every other engine in this        |
//|  build. Never calls CTrade, not #include'd by the live EA.                        |
//|                                                                    |
//|  VERIFICATION STATUS: balance-checked and code-reviewed only. COMPILATION     |
//|  NOT VERIFIED - no MQL5 compiler available in this build environment. No          |
//|  ablation test - no caller exists yet (see docs/PHASE3_REGIME_VOLATILITY_          |
//|  REPORT.md for the full explanation).                                                 |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_VOLATILITYSERIALITYENGINE_MQH
#define AX_VOLATILITYSERIALITYENGINE_MQH
#include "Defs.mqh"
#include "VolatilityEngine.mqh"

enum ENUM_AX_VOL_SERIALITY_CLASS
  {
   AX_VS_UNAVAILABLE = 0,            // data quality / insufficient sample - not a real classification
   AX_VS_LOW_VOL_PERSISTENT,         // low vol + persistent movement
   AX_VS_LOW_VOL_RANDOM,             // low vol + random movement
   AX_VS_HIGH_VOL_TRENDING,          // high vol + persistent trend
   AX_VS_HIGH_VOL_MEAN_REVERTING,    // high vol + mean reversion
   AX_VS_VOLATILITY_SHOCK,           // volatility shock (direct CVolatilityEngine::State() passthrough)
   AX_VS_VOL_EXPANSION_TREND_ACCEL,  // volatility expansion + trend acceleration
   AX_VS_VOL_EXPANSION_REVERSAL      // volatility expansion + reversal
  };

string AxVolSerialityClassToString(const ENUM_AX_VOL_SERIALITY_CLASS c)
  {
   switch(c)
     {
      case AX_VS_LOW_VOL_PERSISTENT:        return("Low vol / persistent movement");
      case AX_VS_LOW_VOL_RANDOM:            return("Low vol / random movement");
      case AX_VS_HIGH_VOL_TRENDING:         return("High vol / persistent trend");
      case AX_VS_HIGH_VOL_MEAN_REVERTING:   return("High vol / mean reverting");
      case AX_VS_VOLATILITY_SHOCK:          return("Volatility shock");
      case AX_VS_VOL_EXPANSION_TREND_ACCEL: return("Volatility expansion + trend acceleration");
      case AX_VS_VOL_EXPANSION_REVERSAL:    return("Volatility expansion + reversal");
      case AX_VS_UNAVAILABLE:               return("Unavailable");
     }
   return("Unavailable");
  }

struct SAxVolatilitySeriality
  {
   datetime                    timestamp;
   bool                        dataQualityOk;
   string                      dataQualityReason;

   //--- reused, unmodified, from CVolatilityEngine ---
   double                      atrPrice;
   double                      volPercentile;
   double                      volAccelerationPct;
   ENUM_AX_VOLATILITY_STATE    volState;

   //--- genuinely new: bar-level return serial-dependence (see file header) ---
   double                      returnAutocorrelation;  // lag-1 sample autocorrelation, -1..+1, 0 if undefined
   double                      directionalPersistence;  // 0..100 - also stands in for "trend persistence" (header)
   double                      reversalFrequencyPct;    // 0..100
   int                         sampleSize;              // bars actually used - low values are low-confidence

   ENUM_AX_VOL_SERIALITY_CLASS classification;
   string                      classificationReason;
  };

class CVolatilitySerialityEngine
  {
private:
   int               m_lookbackBars;
   ENUM_TIMEFRAMES   m_barTimeframe;
   int               m_minSampleSize;
   double            m_expansionAccelPct;   // THIS engine's own "expansion" threshold - see file header

   double            m_returns[];
   int               m_returnCount;
   int               m_returnHead;
   datetime          m_lastSampledBarTime;

public:
                     CVolatilitySerialityEngine(void)
     {
      m_lookbackBars=50; m_barTimeframe=PERIOD_M5; m_minSampleSize=10; m_expansionAccelPct=20.0;
      m_returnCount=0; m_returnHead=0; m_lastSampledBarTime=0;
      ArrayResize(m_returns,m_lookbackBars);
     }

   void              Configure(const int lookbackBars,const ENUM_TIMEFRAMES barTimeframe,
                                const int minSampleSize,const double expansionAccelPct)
     {
      m_lookbackBars = MathMax(10,lookbackBars);
      m_barTimeframe = barTimeframe;
      //--- must never exceed m_lookbackBars - m_returnCount is hard-capped there (see the ring-buffer      ---
      //--- push below), so a floor higher than the cap would make dataQualityOk permanently unreachable     ---
      //--- (code-review finding). ---
      m_minSampleSize = (int)AxClampD(minSampleSize,5,m_lookbackBars);
      m_expansionAccelPct = MathMax(0.0,expansionAccelPct);
      ArrayResize(m_returns,m_lookbackBars);
      m_returnCount=0; m_returnHead=0; m_lastSampledBarTime=0;
     }

   //--- call every tick; no-ops (returns false) unless a NEW bar has closed on `barTimeframe` since the  ---
   //--- last successful sample. vol must already be Update()'d for this tick by the caller (deliberately   ---
   //--- thin for CVolatilityEngine's own fields - file header). Owns its own closed-bar CLOSE read for       ---
   //--- the return-history computation, matching this codebase's "each engine owns its own read" convention.---
   bool              Sample(const string symbol,const bool dataIntegrityOk,const string dataIntegrityReason,
                             const CVolatilityEngine &vol,SAxVolatilitySeriality &out)
     {
      datetime lastClosedBarTime = iTime(symbol,m_barTimeframe,1);
      if(lastClosedBarTime<=0) return(false);
      if(lastClosedBarTime==m_lastSampledBarTime) return(false);

      //--- shift 1 and 2 = the two most recently closed bars - no lookahead, same convention as every  ---
      //--- other engine's own bar reads in this codebase ---
      double closes[];
      ArraySetAsSeries(closes,true);
      bool haveNewReturn = (CopyClose(symbol,m_barTimeframe,1,2,closes)>=2) && closes[0]>0 && closes[1]>0;
      //--- only mark this bar as "processed" once the close read actually succeeds - a transient        ---
      //--- CopyClose failure (e.g. history still backfilling) must be retried on a LATER tick within        ---
      //--- the same bar interval, not silently and permanently skipped (code-review finding: an earlier      ---
      //--- draft advanced m_lastSampledBarTime unconditionally, so a transient failure meant this bar's        ---
      //--- return was lost for the rest of the session with no retry). ---
      if(!haveNewReturn) return(false);

      //--- only feed a bar's return into the rolling window when the CALLER's own current-tick data       ---
      //--- integrity read is good - a conservative, deliberate choice: dataIntegrityOk is a live, THIS-      ---
      //--- tick feed-quality signal (spread/staleness/stuck-feed), not a statement about whether this          ---
      //--- particular closed bar's own price is wrong, but skipping the push whenever the caller says not      ---
      //--- to trust data this tick errs toward "unavailable data fails safely" rather than quietly trusting     ---
      //--- a read taken under flagged conditions (code-review finding: an earlier draft pushed the return       ---
      //--- unconditionally, so one bad-data bar could silently skew every autocorrelation/persistence/           ---
      //--- reversal reading for up to m_lookbackBars future samples). ---
      if(dataIntegrityOk)
        {
         double logReturn = MathLog(closes[0]/closes[1]);
         m_returns[m_returnHead] = logReturn;
         m_returnHead = (m_returnHead+1) % m_lookbackBars;
         if(m_returnCount<m_lookbackBars) m_returnCount++;
        }

      SAxVolatilitySeriality s;
      s.timestamp = lastClosedBarTime;
      s.atrPrice = vol.CurrentAtr();
      s.volPercentile = vol.PercentileRank();
      s.volAccelerationPct = vol.AccelerationPct();
      s.volState = vol.State();
      s.sampleSize = m_returnCount;

      s.dataQualityOk = dataIntegrityOk && (m_returnCount>=m_minSampleSize);
      if(!dataIntegrityOk)
         s.dataQualityReason = dataIntegrityReason;
      else if(m_returnCount<m_minSampleSize)
         s.dataQualityReason = StringFormat("Insufficient return history: %d bars (need %d)",m_returnCount,m_minSampleSize);
      else
         s.dataQualityReason = "";

      if(!s.dataQualityOk)
        {
         s.returnAutocorrelation=0.0; s.directionalPersistence=0.0; s.reversalFrequencyPct=0.0;
         s.classification = AX_VS_UNAVAILABLE;
         s.classificationReason = s.dataQualityReason;
         m_lastSampledBarTime = lastClosedBarTime;
         out = s;
         return(true);
        }

      //--- reconstruct the window in chronological order (oldest first) for the calculations below -    ---
      //--- the ring buffer's own storage order is insertion order, not time order, once it has wrapped   ---
      double window[];
      ArrayResize(window,m_returnCount);
      for(int i=0;i<m_returnCount;i++)
        {
         int idx = (m_returnHead-m_returnCount+i);
         while(idx<0) idx+=m_lookbackBars;
         idx = idx % m_lookbackBars;
         window[i] = m_returns[idx];
        }

      //--- lag-1 sample autocorrelation ---
      double mean=0; for(int i=0;i<m_returnCount;i++) mean+=window[i]; mean/=m_returnCount;
      double num=0, den=0;
      for(int i=0;i<m_returnCount;i++)
        {
         double dev = window[i]-mean;
         den += dev*dev;
         if(i>0) num += dev*(window[i-1]-mean);
        }
      s.returnAutocorrelation = (den>0) ? AxClampD(num/den,-1.0,1.0) : 0.0;

      //--- directional persistence: % of nonzero-return bars matching the dominant sign ---
      int posCount=0, negCount=0, nonZero=0;
      for(int i=0;i<m_returnCount;i++)
        {
         if(window[i]>0) { posCount++; nonZero++; }
         else if(window[i]<0) { negCount++; nonZero++; }
        }
      int dominant = MathMax(posCount,negCount);
      s.directionalPersistence = (nonZero>0) ? (100.0*dominant/nonZero) : 0.0;

      //--- reversal frequency: % of consecutive NONZERO-sign transitions that flip sign - zero-return    ---
      //--- bars are skipped when pairing (neither "same" nor "reversed"), not counted as either ---
      int transitions=0, flips=0; int lastSign=0;
      for(int i=0;i<m_returnCount;i++)
        {
         int sign = (window[i]>0) ? 1 : (window[i]<0 ? -1 : 0);
         if(sign==0) continue;
         if(lastSign!=0)
           {
            transitions++;
            if(sign!=lastSign) flips++;
           }
         lastSign = sign;
        }
      s.reversalFrequencyPct = (transitions>0) ? (100.0*flips/transitions) : 0.0;

      //--- classification - priority order matches the file header's own precedence discussion ---
      if(s.volState==AX_VOL_SHOCK)
        {
         s.classification = AX_VS_VOLATILITY_SHOCK;
         s.classificationReason = StringFormat("CVolatilityEngine reports SHOCK (acceleration %.1f%%)",s.volAccelerationPct);
        }
      else if(s.volAccelerationPct>=m_expansionAccelPct)
        {
         bool persistent = s.returnAutocorrelation>0;
         s.classification = persistent ? AX_VS_VOL_EXPANSION_TREND_ACCEL : AX_VS_VOL_EXPANSION_REVERSAL;
         s.classificationReason = StringFormat("Vol accelerating %.1f%% (>= %.1f%% expansion floor), autocorrelation %.2f",
                                                s.volAccelerationPct,m_expansionAccelPct,s.returnAutocorrelation);
        }
      else if(s.volState==AX_VOL_HIGH || s.volState==AX_VOL_EXTREME)
        {
         bool trending = s.returnAutocorrelation>0;
         s.classification = trending ? AX_VS_HIGH_VOL_TRENDING : AX_VS_HIGH_VOL_MEAN_REVERTING;
         s.classificationReason = StringFormat("Vol percentile %.0f (%s), autocorrelation %.2f, reversal freq %.0f%%",
                                                s.volPercentile,EnumToString(s.volState),
                                                s.returnAutocorrelation,s.reversalFrequencyPct);
        }
      else
        {
         //--- this branch also catches AX_VOL_NORMAL, not only AX_VOL_LOW - the 10X spec's own 7-state    ---
         //--- taxonomy is a strict low/high binary with no separate "normal vol" bucket, and this engine    ---
         //--- does not invent an 8th state beyond what was requested. AX_VS_LOW_VOL_PERSISTENT/RANDOM is       ---
         //--- therefore an approximation for NORMAL readings, same as R3 Range/Chop folding several base         ---
         //--- CRegimeEngine states together in RegimeClassifierEngine.mqh (code-review finding: an earlier         ---
         //--- draft did this without stating it, which could mislead a caller reading only the classification       ---
         //--- string, not the separate volState field, into believing volatility was genuinely LOW when              ---
         //--- CVolatilityEngine actually reported NORMAL - volState is always the ground truth; the                   ---
         //--- classificationReason string below always names the real EnumToString(s.volState) explicitly so            ---
         //--- the distinction is never actually hidden from a caller who reads the reason text). ---
         bool persistent = s.returnAutocorrelation>0;
         s.classification = persistent ? AX_VS_LOW_VOL_PERSISTENT : AX_VS_LOW_VOL_RANDOM;
         s.classificationReason = StringFormat("Vol percentile %.0f (%s), autocorrelation %.2f, directional persistence %.0f%%",
                                                s.volPercentile,EnumToString(s.volState),
                                                s.returnAutocorrelation,s.directionalPersistence);
        }

      m_lastSampledBarTime = lastClosedBarTime;
      out = s;
      return(true);
     }
  };
//+------------------------------------------------------------------+
#endif // AX_VOLATILITYSERIALITYENGINE_MQH
