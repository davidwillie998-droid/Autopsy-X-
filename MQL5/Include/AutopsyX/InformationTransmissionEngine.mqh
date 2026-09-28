//+------------------------------------------------------------------+
//|                              InformationTransmissionEngine.mqh|
//|  Information Transmission / Lead-Lag Engine (Phase 4A) -           |
//|  ENGINEERING DESIGN, not paper-sourced.                             |
//|                                                                    |
//|  TERMINOLOGY DISCIPLINE (deliberate, not an oversight): this file    |
//|  never uses the word "causal"/"causality" anywhere. Lagged             |
//|  correlation is INFORMATION TRANSMISSION / PREDICTIVE ASSOCIATION,       |
//|  not causal proof - it shows temporal precedence and statistical           |
//|  association, not a validated causal mechanism.                              |
//|                                                                    |
//|  This is the executable-verified port of                              |
//|  python/autopsy_research/lead_lag.py - same relationship as             |
//|  TickDirectionEngine.mqh has to trade_direction.py. The Python              |
//|  module is the reference implementation, tested under pytest                  |
//|  against all 12 synthetic scenarios this phase's own authorization              |
//|  requires (see python/tests/test_lead_lag.py and                                  |
//|  docs/PHASE4A_INFORMATION_TRANSMISSION_REPORT.md for the real,                       |
//|  actually-run results) - this MQL5 file mirrors its exact algorithm                    |
//|  and thresholds, since MQL5 itself cannot be executed/tested in this                      |
//|  build environment (no compiler available - see file footer).                              |
//|                                                                    |
//|  REPOSITORY AUDIT (before writing this file): no existing engine in     |
//|  this codebase does lagged cross-asset correlation. CMacroRegimeEngine     |
//|  (MacroRegime.mqh) reads ONE configurable cross-asset symbol for a          |
//|  simple zero-lag directional bias - not a lag scan, not a stability           |
//|  check, not regime bucketing. python/autopsy_research/correlation.py           |
//|  computes zero-lag Pearson correlation across return streams for a               |
//|  strategy-crowding purpose - reused conceptually (Pearson correlation             |
//|  as the base statistic) but not duplicated (no lag scan, no divergence              |
//|  detection, no confidence scoring there). var_model.py is a single-                   |
//|  INSTRUMENT VAR (quote-change vs net-order-flow), a different scope                      |
//|  entirely from cross-SYMBOL lead-lag. No shared statistics library                          |
//|  exists in MQL5/Include/AutopsyX/ beyond what's private to Regime.mqh                          |
//|  (linear regression) and DataIntegrity.mqh (rolling z-score) - this                              |
//|  file's own PearsonCorr()/NormalInverseCdf() are new, self-contained,                              |
//|  and not duplicating anything.                                                                       |
//|                                                                    |
//|  REGIME REUSE: does NOT create a competing regime taxonomy. Regime           |
//|  bucketing below uses the caller's ALREADY-COMPUTED ENUM_AX_REGIME_CLASS         |
//|  value (RegimeClassifierEngine.mqh, Phase 3) for the bar being sampled,            |
//|  tagged into this engine's own history alongside the return pair - never             |
//|  recomputed here.                                                                       |
//|                                                                    |
//|  ALIGNMENT CONVENTION (read before touching any index math): leader and   |
//|  receiver are sampled at the SAME reference bar-close event, using the        |
//|  LEADER symbol's own closed-bar time as the reference clock                        |
//|  (iTime(leaderSymbol, barTimeframe, 1)). At that event, BOTH symbols'                 |
//|  OWN CopyClose reads are attempted independently; if EITHER fails                        |
//|  (symbol unavailable, no bar at that position - e.g. differing trading                     |
//|  session calendars), the WHOLE pair is skipped, never fabricated from one                     |
//|  side alone. This is a deliberate simplification, not a general-purpose                          |
//|  multi-session aligner - true differing-trading-hours alignment (e.g. an                            |
//|  instrument that closes on a different calendar) is NOT implemented.                                    |
//|  Lag is a plain array-index offset into this shared reference sequence,                                    |
//|  never a raw timestamp computation.                                                                          |
//|                                                                    |
//|  LOOK-AHEAD DISCIPLINE: for lag>=0, the receiver observation at ring-       |
//|  buffer index i is compared against the leader observation at index          |
//|  i-lag - always at or before i, never after. lag==0 compares same-index         |
//|  (concurrent) already-closed bars - legitimate, not look-ahead, since both        |
//|  sides are already-closed, already-known observations at computation time.         |
//|  No code path here reads a ring-buffer slot past what has actually been              |
//|  pushed. See python/tests/test_lead_lag.py::test_12_lookahead_trap for the             |
//|  executable proof this port's own algorithm is mirroring.                                 |
//|                                                                    |
//|  STATISTICAL HONESTY: min_association is a FLOOR, not the only gate - the    |
//|  effective threshold is max(m_minAssociation, SignificanceFloor(...)), a        |
//|  sample-size-and-lag-count-aware, Bonferroni-corrected statistical               |
//|  minimum (NormalInverseCdf() below is Acklam's well-established rational           |
//|  approximation to the standard normal inverse CDF - MQL5 has no built-in              |
//|  statistical distribution functions). This exists because scanning                       |
//|  max_lag+1 lags and keeping the strongest is a "best of N" selection that                   |
//|  measurably inflates a purely noisy pair's apparent strength - an empirical                    |
//|  check in the Python reference module (100 independent unrelated pairs,                           |
//|  n=400, max_lag=10) found a 22% false-positive rate at a flat |r|>=0.15                              |
//|  threshold and 0% at 0.25, which is why the default below is 0.25, not a                               |
//|  number tuned to any single test's own random seed.                                                       |
//|                                                                    |
//|  This module measures information STRUCTURE, not trading usefulness.        |
//|  It does not claim predictive power from correlation alone, does not          |
//|  claim profitability, alpha, or causality, and does not claim a                    |
//|  relationship is economically exploitable merely because statistical                 |
//|  association exists.                                                                    |
//|                                                                    |
//|  BAR-LEVEL, NOT TICK-LEVEL: Sample() no-ops except on the first tick        |
//|  after a new leader bar closes - bounded rolling window, bounded lag           |
//|  range, no full-history recalculation, matching this codebase's own              |
//|  performance convention (MarketStateEngine.mqh/RegimeIntelligenceEngine.        |
//|  mqh/VolatilitySerialityEngine.mqh all establish this same pattern).                |
//|                                                                    |
//|  INDEPENDENCE: this class never references entry logic, risk, execution,     |
//|  trade management, journal, ICT/liquidity/sweep logic, VWAP, VP-MACD, or        |
//|  news defense - confirmed by grep, zero references either direction. It is         |
//|  an observational intelligence layer only, not wired into OnInit/OnTick/            |
//|  OnTimer as part of this phase.                                                          |
//|                                                                    |
//|  VERIFICATION STATUS: balance-checked and code-reviewed only.                |
//|  COMPILATION NOT VERIFIED - no MQL5 compiler available in this build             |
//|  environment. The 12 synthetic tests were run and passed against the               |
//|  Python reference implementation this file mirrors, NOT against this MQL5             |
//|  file itself, since MQL5 cannot be executed here - stated plainly rather                 |
//|  than claimed. No ablation test - no caller exists yet (see the Phase 4A                    |
//|  report for the full explanation).                                                              |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_INFORMATIONTRANSMISSIONENGINE_MQH
#define AX_INFORMATIONTRANSMISSIONENGINE_MQH
#include "Defs.mqh"
#include "RegimeClassifierEngine.mqh"

enum ENUM_AX_TRANSMISSION_STATE
  {
   AX_TS_UNKNOWN = 0,
   AX_TS_INSUFFICIENT_DATA,
   AX_TS_INACTIVE,
   AX_TS_LEADER,
   AX_TS_CONFIRMING,
   AX_TS_WEAKENING,
   AX_TS_DIVERGING,
   AX_TS_INVERTED
  };

string AxTransmissionStateToString(const ENUM_AX_TRANSMISSION_STATE s)
  {
   switch(s)
     {
      case AX_TS_INSUFFICIENT_DATA: return("INSUFFICIENT_DATA");
      case AX_TS_INACTIVE:          return("INACTIVE");
      case AX_TS_LEADER:            return("LEADER");
      case AX_TS_CONFIRMING:        return("CONFIRMING");
      case AX_TS_WEAKENING:         return("WEAKENING");
      case AX_TS_DIVERGING:         return("DIVERGING");
      case AX_TS_INVERTED:          return("INVERTED");
      case AX_TS_UNKNOWN:           return("UNKNOWN");
     }
   return("UNKNOWN");
  }

struct SAxInformationTransmissionSnapshot
  {
   datetime timestamp;
   bool     valid;
   string   leaderSymbol;
   string   receiverSymbol;

   ENUM_AX_TRANSMISSION_STATE state;
   int      direction;                 // +1 / -1 / 0
   int      bestLag;                   // -1 if no eligible lag
   double   associationStrength;       // 0..1, |r| - meaning depends on state, see file header
   double   responseMagnitude;
   double   stability;                 // 0..100
   int      sampleCount;
   double   confidence;                // 0..100

   bool     hasStrongestRegime;
   ENUM_AX_REGIME_CLASS strongestRegime;
   double   strongestRegimeCorrelation;

   bool     dataQualityOk;
   string   dataQualityReason;
  };

struct SAxLagResult
  {
   int      lag;
   double   correlation;
   int      sampleCount;
  };

class CInformationTransmissionEngine
  {
private:
   int               m_capacity;
   ENUM_TIMEFRAMES   m_barTimeframe;
   int               m_maxLag;
   int               m_minSampleSize;
   double            m_minAssociation;      // floor - see file header
   double            m_weakeningRatio;
   int               m_minRegimeSampleSize;
   double            m_significanceAlpha;

   double            m_leaderReturns[];
   double            m_receiverReturns[];
   int               m_regimeTags[];        // (int)ENUM_AX_REGIME_CLASS per observation
   int               m_count;
   int               m_head;
   datetime          m_lastSampledBarTime;

   int               RingIndex(const int back) const
     {
      int idx = m_head-1-back;
      while(idx<0) idx+=m_capacity;
      return(idx % m_capacity);
     }

   double            PearsonCorr(const double &x[],const int xStart,const double &y[],const int yStart,const int count) const
     {
      if(count<2) return(0.0);
      double sumX=0,sumY=0;
      for(int i=0;i<count;i++) { sumX+=x[xStart+i]; sumY+=y[yStart+i]; }
      double meanX=sumX/count, meanY=sumY/count;
      double sxy=0,sxx=0,syy=0;
      for(int i=0;i<count;i++)
        {
         double dx=x[xStart+i]-meanX, dy=y[yStart+i]-meanY;
         sxy+=dx*dy; sxx+=dx*dx; syy+=dy*dy;
        }
      if(sxx<=0 || syy<=0) return(0.0);
      return(AxClampD(sxy/MathSqrt(sxx*syy),-1.0,1.0));
     }

   //--- Acklam's rational approximation to the standard normal inverse CDF (well-established numerical   ---
   //--- method - Acklam, P.J., "An algorithm for computing the inverse normal cumulative distribution      ---
   //--- function", 2003 - not derived here, MQL5 has no built-in statistical distribution functions). ---
   double            NormalInverseCdf(const double p) const
     {
      if(p<=0.0) return(-8.0);
      if(p>=1.0) return(8.0);
      double a[6]={-3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02,
                    1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00};
      double b[5]={-5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02,
                    6.680131188771972e+01, -1.328068155288572e+01};
      double c[6]={-7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00,
                   -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00};
      double d[4]={7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00,
                   3.754408661907416e+00};
      double plow=0.02425, phigh=1.0-plow;
      double q,r,x;
      if(p<plow)
        {
         q=MathSqrt(-2.0*MathLog(p));
         x=(((((c[0]*q+c[1])*q+c[2])*q+c[3])*q+c[4])*q+c[5]) /
           ((((d[0]*q+d[1])*q+d[2])*q+d[3])*q+1.0);
        }
      else if(p<=phigh)
        {
         q=p-0.5; r=q*q;
         x=(((((a[0]*r+a[1])*r+a[2])*r+a[3])*r+a[4])*r+a[5])*q /
           (((((b[0]*r+b[1])*r+b[2])*r+b[3])*r+b[4])*r+1.0);
        }
      else
        {
         q=MathSqrt(-2.0*MathLog(1.0-p));
         x=-(((((c[0]*q+c[1])*q+c[2])*q+c[3])*q+c[4])*q+c[5]) /
            ((((d[0]*q+d[1])*q+d[2])*q+d[3])*q+1.0);
        }
      return(x);
     }

   //--- Bonferroni-corrected statistical noise floor for a "best of N lags" selection - see file header ---
   double            SignificanceFloor(const int n,const int numComparisons) const
     {
      if(n<4) return(1.0);
      double alphaAdjusted = m_significanceAlpha/MathMax(1,numComparisons);
      double z = NormalInverseCdf(1.0-alphaAdjusted/2.0);
      double se = 1.0/MathSqrt((double)(n-3));
      return(AxClampD(z*se,0.0,1.0));
     }

public:
                     CInformationTransmissionEngine(void)
     {
      m_capacity=500; m_barTimeframe=PERIOD_M5; m_maxLag=10; m_minSampleSize=30;
      m_minAssociation=0.25; m_weakeningRatio=0.5; m_minRegimeSampleSize=15; m_significanceAlpha=0.01;
      m_count=0; m_head=0; m_lastSampledBarTime=0;
      ArrayResize(m_leaderReturns,m_capacity);
      ArrayResize(m_receiverReturns,m_capacity);
      ArrayResize(m_regimeTags,m_capacity);
     }

   void              Configure(const int capacity,const ENUM_TIMEFRAMES barTimeframe,const int maxLag,
                                const int minSampleSize,const double minAssociation,const double weakeningRatio,
                                const int minRegimeSampleSize,const double significanceAlpha)
     {
      m_capacity = MathMax(30,capacity);
      m_barTimeframe = barTimeframe;
      m_maxLag = MathMax(0,maxLag);
      m_minSampleSize = MathMax(4,minSampleSize);
      m_minAssociation = AxClampD(minAssociation,0.0,1.0);
      m_weakeningRatio = AxClampD(weakeningRatio,0.0,1.0);
      m_minRegimeSampleSize = MathMax(2,minRegimeSampleSize);
      m_significanceAlpha = AxClampD(significanceAlpha,0.0001,0.5);
      ArrayResize(m_leaderReturns,m_capacity);
      ArrayResize(m_receiverReturns,m_capacity);
      ArrayResize(m_regimeTags,m_capacity);
      m_count=0; m_head=0; m_lastSampledBarTime=0;
     }

   //--- call every tick; no-ops (returns false) unless a NEW bar has closed on `m_barTimeframe`, using   ---
   //--- leaderSymbol's own bar-close time as the reference clock (file header). dataIntegrityOk is the     ---
   //--- caller's ALREADY-COMPUTED current-tick data-integrity read (not recomputed here - deliberately      ---
   //--- thin, matching every prior phase's own convention). currentRegime is the caller's ALREADY-COMPUTED    ---
   //--- Phase 3 CRegimeClassifierEngine classification for this same bar - reused, not recomputed. ---
   bool              Sample(const string leaderSymbol,const string receiverSymbol,
                             const bool dataIntegrityOk,const string dataIntegrityReason,
                             const ENUM_AX_REGIME_CLASS currentRegime,
                             SAxInformationTransmissionSnapshot &out)
     {
      datetime lastClosedBarTime = iTime(leaderSymbol,m_barTimeframe,1);
      if(lastClosedBarTime<=0) return(false);
      if(lastClosedBarTime==m_lastSampledBarTime) return(false);

      //--- must select both symbols before reading them - an unselected symbol's history often isn't    ---
      //--- synchronized on the terminal (same lesson already learned and fixed in ORBEngine.mqh's own      ---
      //--- cross-asset confirmation method, applied here proactively rather than rediscovered). ---
      bool leaderSelected = SymbolSelect(leaderSymbol,true);
      bool receiverSelected = SymbolSelect(receiverSymbol,true);

      double leaderCloses[], receiverCloses[];
      ArraySetAsSeries(leaderCloses,true);
      ArraySetAsSeries(receiverCloses,true);
      bool haveLeader = leaderSelected && (CopyClose(leaderSymbol,m_barTimeframe,1,2,leaderCloses)>=2)
                         && leaderCloses[0]>0 && leaderCloses[1]>0;
      bool haveReceiver = receiverSelected && (CopyClose(receiverSymbol,m_barTimeframe,1,2,receiverCloses)>=2)
                           && receiverCloses[0]>0 && receiverCloses[1]>0;

      //--- only mark this bar "processed" once BOTH reads actually succeed - a transient failure on        ---
      //--- either side must be retried on a later tick within the same bar interval, not silently and         ---
      //--- permanently skipped (same fix already applied in VolatilitySerialityEngine.mqh's own Sample()). ---
      if(!haveLeader || !haveReceiver) return(false);

      //--- only push this pair into the rolling window when the caller's current-tick data integrity is    ---
      //--- good - a bad-data bar must not silently contaminate every downstream correlation/stability          ---
      //--- reading for up to m_capacity future samples (same fix already applied in                             ---
      //--- VolatilitySerialityEngine.mqh's own Sample()). ---
      if(dataIntegrityOk)
        {
         double leaderReturn = MathLog(leaderCloses[0]/leaderCloses[1]);
         double receiverReturn = MathLog(receiverCloses[0]/receiverCloses[1]);
         m_leaderReturns[m_head] = leaderReturn;
         m_receiverReturns[m_head] = receiverReturn;
         m_regimeTags[m_head] = (int)currentRegime;
         m_head = (m_head+1) % m_capacity;
         if(m_count<m_capacity) m_count++;
        }

      SAxInformationTransmissionSnapshot s;
      s.timestamp = lastClosedBarTime;
      s.leaderSymbol = leaderSymbol;
      s.receiverSymbol = receiverSymbol;
      s.hasStrongestRegime=false; s.strongestRegime=AX_RC_UNAVAILABLE; s.strongestRegimeCorrelation=0.0;

      s.dataQualityOk = dataIntegrityOk && (m_count>=m_minSampleSize);
      if(!dataIntegrityOk)
         s.dataQualityReason = dataIntegrityReason;
      else if(m_count<m_minSampleSize)
         s.dataQualityReason = StringFormat("Insufficient observation history: %d (need %d)",m_count,m_minSampleSize);
      else
         s.dataQualityReason = "";

      if(!s.dataQualityOk)
        {
         s.valid=false; s.state=AX_TS_INSUFFICIENT_DATA; s.direction=0; s.bestLag=-1;
         s.associationStrength=0.0; s.responseMagnitude=0.0; s.stability=0.0;
         s.sampleCount=m_count; s.confidence=0.0;
         m_lastSampledBarTime = lastClosedBarTime;
         out = s;
         return(true);
        }

      //--- reconstruct the window in chronological order (oldest first) - the ring buffer's own storage  ---
      //--- order is insertion order, not time order, once it has wrapped (same pattern already            ---
      //--- established in VolatilitySerialityEngine.mqh's own window reconstruction) ---
      double leaderWindow[], receiverWindow[]; int regimeWindow[];
      ArrayResize(leaderWindow,m_count); ArrayResize(receiverWindow,m_count); ArrayResize(regimeWindow,m_count);
      for(int i=0;i<m_count;i++)
        {
         int idx = RingIndex(m_count-1-i); // i=0 -> oldest retained observation
         leaderWindow[i]=m_leaderReturns[idx]; receiverWindow[i]=m_receiverReturns[idx]; regimeWindow[i]=m_regimeTags[idx];
        }

      //--- lag scan: for lag in [0,maxLag], correlate leaderWindow[0..n-lag-1] against receiverWindow[lag..n-1] ---
      //--- - never reads leaderWindow at an index > i (look-ahead discipline, file header). ---
      int n = m_count;
      int lagCount = m_maxLag+1;
      SAxLagResult lagResults[];
      ArrayResize(lagResults,lagCount);
      int bestIdx=-1; double bestAbsCorr=-1.0;
      for(int lag=0;lag<lagCount;lag++)
        {
         int cnt = n-lag;
         if(cnt<2)
           {
            lagResults[lag].lag=lag; lagResults[lag].correlation=0.0; lagResults[lag].sampleCount=MathMax(0,cnt);
            continue;
           }
         double corr = PearsonCorr(leaderWindow,0,receiverWindow,lag,cnt);
         lagResults[lag].lag=lag; lagResults[lag].correlation=corr; lagResults[lag].sampleCount=cnt;
         if(cnt>=m_minSampleSize && MathAbs(corr)>bestAbsCorr) { bestAbsCorr=MathAbs(corr); bestIdx=lag; }
        }

      if(bestIdx<0)
        {
         s.valid=false; s.state=AX_TS_INSUFFICIENT_DATA; s.direction=0; s.bestLag=-1;
         s.associationStrength=0.0; s.responseMagnitude=0.0; s.stability=0.0;
         s.sampleCount=n; s.confidence=0.0;
         m_lastSampledBarTime = lastClosedBarTime;
         out = s;
         return(true);
        }

      int bestLag = lagResults[bestIdx].lag;
      double corrFull = lagResults[bestIdx].correlation;
      int m = n-bestLag;
      int half = m/2;

      double corrOlder, corrRecent; double stability;
      bool halfHasEnough = half >= MathMax(5,m_minSampleSize/4);
      if(half>=2)
        {
         corrOlder = PearsonCorr(leaderWindow,0,receiverWindow,bestLag,half);
         corrRecent = PearsonCorr(leaderWindow,m-half,receiverWindow,bestLag+(m-half),half);
         stability = AxClampD(100.0-100.0*MathAbs(corrOlder-corrRecent)/2.0,0.0,100.0);
        }
      else
        {
         corrOlder=corrFull; corrRecent=corrFull; stability=0.0;
        }

      //--- regime-dependence bucketing over all 9 ENUM_AX_REGIME_CLASS values - reuses the caller's own    ---
      //--- Phase 3 classification, recomputes no regime logic (file header) ---
      ENUM_AX_REGIME_CLASS strongestRegime=AX_RC_UNAVAILABLE; bool hasStrongest=false; double strongestCorr=0.0;
      for(int rv=0; rv<=8; rv++)
        {
         int cnt=0;
         for(int i=0;i<m;i++) if(regimeWindow[bestLag+i]==rv) cnt++;
         if(cnt<m_minRegimeSampleSize) continue;
         double bx[], by[]; ArrayResize(bx,cnt); ArrayResize(by,cnt);
         int k=0;
         for(int i=0;i<m;i++) if(regimeWindow[bestLag+i]==rv) { bx[k]=leaderWindow[i]; by[k]=receiverWindow[bestLag+i]; k++; }
         double bucketCorr = PearsonCorr(bx,0,by,0,cnt);
         //--- strict ">", never "!hasStrongest ||" - matching the Python reference exactly              ---
         //--- (strongest_regime_corr starts at 0.0 there too, so a bucket must have a NONZERO            ---
         //--- correlation to ever be promoted; a "!hasStrongest ||" short-circuit would instead            ---
         //--- unconditionally promote whichever sufficient bucket is scanned FIRST even at exactly           ---
         //--- corr==0.0, diverging from the reference this file claims to mirror - code-review finding). ---
         if(MathAbs(bucketCorr)>MathAbs(strongestCorr))
           { hasStrongest=true; strongestRegime=(ENUM_AX_REGIME_CLASS)rv; strongestCorr=bucketCorr; }
        }

      //--- transmission-state waterfall - IDENTICAL branch ordering to the Python reference (older-vs-    ---
      //--- recent checks BEFORE the corr_full-based INACTIVE gate - a clean inversion cancels corr_full        ---
      //--- toward zero by construction, so gating on it first would misclassify the exact scenario               ---
      //--- INVERTED exists to catch as INACTIVE instead - see python/autopsy_research/lead_lag.py's own              ---
      //--- comment on this exact bug, caught by test_8_relationship_inversion actually failing). ---
      double effectiveMinAssociation = MathMax(m_minAssociation,SignificanceFloor(m,lagCount));
      ENUM_AX_TRANSMISSION_STATE state;
      if(!halfHasEnough)
        {
         state = (MathAbs(corrFull)<effectiveMinAssociation) ? AX_TS_INACTIVE : AX_TS_LEADER;
        }
      else if(MathAbs(corrOlder)>=effectiveMinAssociation && MathAbs(corrRecent)>=effectiveMinAssociation
              && ((corrOlder>0)!=(corrRecent>0)))
        {
         state = AX_TS_INVERTED;
        }
      else if(MathAbs(corrOlder)>=effectiveMinAssociation && MathAbs(corrRecent)<effectiveMinAssociation)
        {
         state = AX_TS_DIVERGING;
        }
      else if(MathAbs(corrOlder)>=effectiveMinAssociation && MathAbs(corrRecent)<MathAbs(corrOlder)*m_weakeningRatio)
        {
         state = AX_TS_WEAKENING;
        }
      else if(MathAbs(corrFull)<effectiveMinAssociation)
        {
         state = AX_TS_INACTIVE;
        }
      else if(hasStrongest && m>0 && regimeWindow[bestLag+m-1]==(int)strongestRegime)
        {
         state = AX_TS_CONFIRMING;
        }
      else
        {
         state = AX_TS_LEADER;
        }

      int direction; double associationStrength;
      if(state==AX_TS_INVERTED)       { direction=(corrRecent>0)?1:-1; associationStrength=MathAbs(corrRecent); }
      else if(state==AX_TS_DIVERGING || state==AX_TS_WEAKENING)
                                       { direction=(corrOlder>0)?1:-1;  associationStrength=MathAbs(corrOlder); }
      else if(state==AX_TS_INACTIVE)  { direction=0;                   associationStrength=MathAbs(corrFull); }
      else                             { direction=(corrFull>0)?1:-1;  associationStrength=MathAbs(corrFull); }

      double responseMagnitude = 0.0;
      if(direction!=0)
        {
         double sum=0; for(int i=0;i<m;i++) sum+=receiverWindow[bestLag+i];
         responseMagnitude = (sum/m)*direction;
        }

      double confidence;
      if(state==AX_TS_INSUFFICIENT_DATA || state==AX_TS_INACTIVE || state==AX_TS_UNKNOWN)
        {
         confidence = 0.0;
        }
      else
        {
         int targetSample = m_minSampleSize*3;
         double sampleFactor = AxClampD(100.0*(m-m_minSampleSize)/MathMax(1,targetSample-m_minSampleSize),0.0,100.0);
         double strengthFactor = AxClampD(100.0*associationStrength,0.0,100.0);
         double stabilityFactor = halfHasEnough ? stability : 50.0;
         confidence = MathMin(sampleFactor,MathMin(strengthFactor,stabilityFactor));
         if(state==AX_TS_DIVERGING || state==AX_TS_WEAKENING || state==AX_TS_INVERTED) confidence*=0.5;
        }

      s.valid=true; s.state=state; s.direction=direction; s.bestLag=bestLag;
      s.associationStrength=associationStrength; s.responseMagnitude=responseMagnitude;
      s.stability=stability; s.sampleCount=m; s.confidence=confidence;
      s.hasStrongestRegime=hasStrongest; s.strongestRegime=strongestRegime; s.strongestRegimeCorrelation=strongestCorr;

      m_lastSampledBarTime = lastClosedBarTime;
      out = s;
      return(true);
     }

   int               Count(void) const { return(m_count); }
  };
//+------------------------------------------------------------------+
#endif // AX_INFORMATIONTRANSMISSIONENGINE_MQH
