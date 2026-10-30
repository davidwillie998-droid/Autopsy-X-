//+------------------------------------------------------------------+
//|                                              NoiseAreaEngine.mqh|
//|  Noise Area intraday momentum - based on:                          |
//|  Zarattini, C., Aziz, A., and Barbon, A., "Beat the Market: An       |
//|  Effective Intraday Momentum Strategy for S&P500 ETF (SPY)," Swiss    |
//|  Finance Institute Research Paper N24-97, SSRN 4824172 (2024/2025).    |
//|                                                                    |
//|  PAPER-SOURCED (backtested on SPY, 2007-2024, 1,985% total return       |
//|  vs. 227% buy-and-hold in the paper's fully-refined version, Sharpe       |
//|  1.33, annualized alpha 19.6%, beta not statistically different from      |
//|  zero):                                                                     |
//|   - "Noise Area": a time-of-day-dependent band around the session's          |
//|     own open, defined from the average ABSOLUTE move (over a trailing         |
//|     lookback of sessions) recorded at that same point in the session,          |
//|     gap-adjusted using max/min of the session open and the PRIOR                |
//|     session's close (their own equations, reproduced in                          |
//|     ExpectedMoveFraction()/GetNoiseArea() below).                                  |
//|   - A crossing above the Upper Boundary signals abnormal buying                     |
//|     pressure (go/stay long); a crossing below the Lower Boundary                      |
//|     signals abnormal selling pressure (go/stay short). While price                     |
//|     stays inside the band, the market is in equilibrium and the                          |
//|     strategy holds no position.                                                            |
//|   - Trading decisions are evaluated only at fixed intervals (the paper                       |
//|     used HH:00/HH:30) rather than on every tick, specifically to avoid                         |
//|     reacting to fleeting spikes - this delay is a deliberate design                              |
//|     choice the paper itself credits with reducing false signals.                                   |
//|   - The paper's OWN reported refinement sequence (each step's real,                                   |
//|     reported result): (1) baseline stop at the OPPOSITE band - 178%                                    |
//|     total return, Sharpe 0.61; (2) trailing stop moved to the CURRENT                                    |
//|     band (tighter, same side as the position) - improves risk control                                     |
//|     but increases trade count/costs; (3) trailing stop refined to                                          |
//|     max(current band, VWAP) for a long / min(current band, VWAP) for a                                      |
//|     short - 380% total return, Sharpe 1.24 - see TrailingStopPrice()                                          |
//|     below, which reuses this EA's own already-live CVWAPEngine value,                                         |
//|     never recomputing VWAP itself (matches this codebase's "deliberately                                       |
//|     thin" convention); (4) additionally sizing exposure to a target daily                                        |
//|     volatility rather than constant full notional - 1,985% total return,                                          |
//|     Sharpe 1.33 in the paper's own backtest. See VolatilityTargetSizeMultiplier()                                   |
//|     below for why step (4) is NOT ported as the paper describes it.                                                    |
//|   - NR4 ("Narrow Range 4 days" - the day's range is the smallest of the                                                  |
//|     last 4 days) was the single most statistically significant of 8 daily                                                 |
//|     technical patterns the paper tested against this strategy (t-stat 5.14,                                                |
//|     average +22bps/day, vs. +12bps/day unconditional) - reproduced here as                                                  |
//|     a generalized IsNarrowRangeDay(N) helper, not hardcoded to N=4.                                                           |
//|                                                                    |
//|  ENGINEERING DESIGN (NOT in the paper - adapted for this EA's own 24-hour     |
//|  XAUUSD/FX instruments rather than SPY's single 9:30-16:00 US session):        |
//|   - "Time-of-day HH:MM" has no consistent meaning across this EA's own          |
//|     rotating 4-anchor session model (Sydney/Tokyo/London/New York - the           |
//|     same FindSessionAnchor() pattern already used by VWAPEngine.mqh/               |
//|     ORBEngine.mqh, reused here as its own separate copy per this codebase's         |
//|     "each engine owns its own read" convention). This engine instead indexes         |
//|     the historical-move lookup by ELAPSED SECONDS SINCE THE MOST RECENT               |
//|     ANCHOR, rounded down to m_bucketMinutes, and averages across the last              |
//|     m_lookbackSessions COMPLETED SESSIONS (of any of the 4 anchor types)                 |
//|     rather than "the same calendar time on the last N calendar days." A                    |
//|     simplifying assumption follows directly from this: every session anchor                  |
//|     (Sydney/Tokyo/London/NY) is treated as structurally interchangeable for                     |
//|     this purpose, since the paper never had to consider more than one session                     |
//|     type. This has NOT been tested for whether e.g. the London open's own                            |
//|     volatility-decay shape genuinely resembles Tokyo's - it is an explicit,                            |
//|     labeled simplification, not a validated equivalence.                                                 |
//|   - The paper's "trade only at HH:00/HH:30" throttle is reframed as "trade                                 |
//|     only at multiples of m_decisionIntervalMinutes elapsed since the current                               |
//|     session anchor" - wall-clock HH:00/HH:30 doesn't align consistently                                       |
//|     across 4 rotating anchors at different hours.                                                               |
//|   - VolatilityTargetSizeMultiplier() is a DELIBERATE, DOCUMENTED DIVERGENCE                                       |
//|     from the paper: the paper's own formula (leverage = min(4, target_vol/                                          |
//|     realized_vol)) can INCREASE exposure above 1x when realized volatility                                             |
//|     is low. That would directly violate this codebase's own audited, hard                                                |
//|     invariant (docs/RISK_INVARIANT_AUDIT.md: CAdaptiveFlipEngine's entire                                                   |
//|     multiplier stack is architecturally size-DOWN-ONLY, never up, from                                                        |
//|     CRiskEngine's already-hard-clamped risk percent). This port therefore                                                        |
//|     clamps the multiplier to [0, 1.0] - it can reduce exposure when realized                                                       |
//|     volatility runs hot, but can never amplify it when volatility is calm.                                                            |
//|     This is a safety-motivated departure from the paper's own tested                                                                    |
//|     formula, not an oversight, and it means this port's results would NOT                                                                  |
//|     be expected to reproduce the paper's own 1,985%/Sharpe-1.33 figure even                                                                  |
//|     if everything else transferred perfectly - that figure depended on the                                                                     |
//|     up-to-4x amplification this port deliberately refuses to carry over.                                                                          |
//|                                                                    |
//|  DELIBERATELY NOT PORTED, WITH REASONS (rather than silently skipped or        |
//|  silently force-fit):                                                            |
//|   - VIX-conditioned Sharpe-ratio analysis (the paper's Section 4.1): there         |
//|     is no VIX-equivalent index for XAUUSD/FX - CVolatilityEngine's own              |
//|     percentile-rank classification is this codebase's already-existing,              |
//|     genuinely analogous (though not identical) volatility-regime read; no              |
//|     new code was added here to duplicate it.                                             |
//|   - Day-of-week / FOMC-Wednesday seasonality (Section 4.3): the paper's own                |
//|     stated hypothesis for WHY Wednesday/Thursday/Friday outperform is tied                   |
//|     to US equity options-expiration mechanics - not something this codebase                    |
//|     has grounds to assume transfers to XAUUSD/FX without its own dedicated                        |
//|     test, which has not been run.                                                                    |
//|   - Dealer gamma-imbalance / 5-day-RSI proxy (Section 4.5): the paper's own                            |
//|     causal story is specifically about US equity index OPTIONS dealers'                                  |
//|     delta-hedging flow (calls purchased by institutional overwriters vs.                                    |
//|     puts sold to hedgers, concentrated near strikes) - a mechanism this feed                                  |
//|     has no visibility into for XAUUSD/FX options (which are OTC, opaque, and                                    |
//|     not read by any engine in this codebase - the same "no observable options-                                    |
//|     flow proxy" honesty already applied to CapacityCrowdingEngine.mqh's own                                          |
//|     crowding-proxy caveat). Relabeling a plain RSI filter as "gamma imbalance"                                          |
//|     for an instrument where that specific mechanism cannot be observed would                                             |
//|     be exactly the kind of borrowed, unearned causal story this codebase has                                                |
//|     avoided everywhere else - so it is left out entirely, not disguised as                                                     |
//|     something else.                                                                                                               |
//|                                                                    |
//|  SIGNAL, NOT ACTION: like every engine in this build, this class never       |
//|  calls CTrade or places an order. It is not wired into the live OnTick        |
//|  loop as part of this build.                                                    |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_NOISEAREAENGINE_MQH
#define AX_NOISEAREAENGINE_MQH
#include "Defs.mqh"

#define AX_NOISE_MAX_LOOKBACK_SESSIONS 60 // defensive cap on m_lookbackSessions - the paper's own
                                            // default is 14; this cap only bounds worst-case cost of
                                            // ExpectedMoveFraction()'s historical-session walk

struct SAxNoiseAreaState
  {
   datetime sessionAnchorTime;
   double   sessionOpen;
   double   upperBound;
   double   lowerBound;
   double   expectedMoveFraction; // sigma_t,HH:MM in the paper's own notation - 0.0 when insufficient
                                   // history exists yet (never fabricated)
   ENUM_AX_DIR breakoutDirection; // AX_DIR_BUY above upperBound, AX_DIR_SELL below lowerBound,
                                   // AX_DIR_NONE inside the band
   bool     isDecisionPoint;      // true only at a multiple of m_decisionIntervalMinutes since the
                                   // anchor - the paper's own "don't react to every tick" throttle
   string   reason;
  };

class CNoiseAreaEngine
  {
private:
   int      m_bucketMinutes;          // resolution of the time-of-day-conditioned lookup, e.g. 5
   int      m_lookbackSessions;       // paper's own default: 14
   double   m_volatilityMultiplier;   // paper's own "VM" - 1.0 is the paper's own non-optimized default,
                                        // explicitly chosen by the paper's authors to avoid overfitting
                                        // rather than the VM~1.5 their own retrospective analysis found
                                        // "more efficient" - this port keeps that same discipline
   int      m_decisionIntervalMinutes; // paper's own default: 30 (HH:00/HH:30)
   ENUM_TIMEFRAMES m_barTimeframe;
   int      m_sydneyHour,m_tokyoHour,m_londonHour,m_newYorkHour;

   //--- cache: ExpectedMoveFraction() is expensive (walks up to m_lookbackSessions historical         ---
   //--- sessions) - recomputed only when the current bucket index changes, not every tick, matching    ---
   //--- the same "sample at intervals, not every tick" fix already applied to DrawdownEngine.mqh/       ---
   //--- HiddenRiskDetector.mqh earlier in this build. ---
   datetime m_cachedBucketAnchor;
   int      m_cachedBucketIndex;
   double   m_cachedExpectedMoveFraction;

   //--- tracks the last decision-interval index actually observed, so isDecisionPoint fires on the     ---
   //--- transition into a new interval rather than requiring an exact elapsed-seconds modulo hit        ---
   //--- against a raw tick timestamp - see Evaluate()'s own comment. ---
   datetime m_lastDecisionAnchor;
   int      m_lastDecisionIntervalIndex;

   //--- deliberate, separate copy of VWAPEngine.mqh's/ORBEngine.mqh's own FindSessionAnchor() - see   ---
   //--- file header for why. ---
   datetime          FindSessionAnchor(const datetime now) const
     {
      MqlDateTime dt;
      TimeToStruct(now,dt);
      datetime todayStart = now-(dt.hour*3600+dt.min*60+dt.sec);

      int hours[4] = {m_sydneyHour,m_tokyoHour,m_londonHour,m_newYorkHour};
      for(int i=1;i<4;i++)
        {
         int key=hours[i]; int j=i-1;
         while(j>=0 && hours[j]>key) { hours[j+1]=hours[j]; j--; }
         hours[j+1]=key;
        }

      datetime bestAnchor = 0;
      for(int i=0;i<4;i++)
        {
         datetime candidate = todayStart+hours[i]*3600;
         if(candidate<=now && candidate>bestAnchor) bestAnchor=candidate;
        }
      if(bestAnchor==0) bestAnchor = todayStart-86400+hours[3]*3600;
      return(bestAnchor);
     }

   datetime          PreviousSessionAnchor(const datetime anchor) const
     {
      return(FindSessionAnchor(anchor-1));
     }

   //--- the anchor that STARTS the session immediately following `t` - i.e. the smallest configured   ---
   //--- session-anchor time strictly greater than `t`. Used to bound a historical session's own          ---
   //--- duration in ExpectedMoveFraction() (code-review finding: without this, a bucket checkpoint could  ---
   //--- land past a short historical session's own end and silently read into an unrelated LATER          ---
   //--- session's bar instead - the 4 configured anchors are not evenly spaced, e.g. Sydney->Tokyo can      ---
   //--- be as little as 2h while New York->Sydney can be 9h). ---
   datetime          NextSessionAnchor(const datetime t) const
     {
      MqlDateTime dt;
      TimeToStruct(t,dt);
      datetime todayStart = t-(dt.hour*3600+dt.min*60+dt.sec);

      int hours[4] = {m_sydneyHour,m_tokyoHour,m_londonHour,m_newYorkHour};
      for(int i=1;i<4;i++)
        {
         int key=hours[i]; int j=i-1;
         while(j>=0 && hours[j]>key) { hours[j+1]=hours[j]; j--; }
         hours[j+1]=key;
        }

      for(int i=0;i<4;i++)
        {
         datetime candidate = todayStart+hours[i]*3600;
         if(candidate>t) return(candidate);
        }
      // none of today's remaining anchors are after t - the next one is tomorrow's earliest
      return(todayStart+86400+hours[0]*3600);
     }

   //--- open price of the bar covering `t`, or -1 if unavailable - a small, single-purpose helper so ---
   //--- ExpectedMoveFraction()/GetNoiseArea() don't each re-derive this ---
   double            BarOpenAt(const string symbol,const datetime t) const
     {
      int shift = iBarShift(symbol,m_barTimeframe,t,false);
      if(shift<0) return(-1.0);
      MqlRates rates[];
      ArraySetAsSeries(rates,true);
      if(CopyRates(symbol,m_barTimeframe,shift,1,rates)<1) return(-1.0);
      return(rates[0].open);
     }

   double            BarCloseAt(const string symbol,const datetime t) const
     {
      int shift = iBarShift(symbol,m_barTimeframe,t,false);
      if(shift<0) return(-1.0);
      MqlRates rates[];
      ArraySetAsSeries(rates,true);
      if(CopyRates(symbol,m_barTimeframe,shift,1,rates)<1) return(-1.0);
      return(rates[0].close);
     }

   //--- the paper's own sigma_t,HH:MM: average, across the last m_lookbackSessions COMPLETED sessions ---
   //--- (see file header on why "session" replaces "calendar day" here), of the absolute move from     ---
   //--- that session's own open to the same elapsed-bucket checkpoint within that session. Skips any    ---
   //--- historical session whose bar data can't be read rather than fabricating a value for it - the     ---
   //--- average is over however many real sessions were actually readable, never a fixed denominator.     ---
   double            ExpectedMoveFraction(const string symbol,const datetime currentAnchor,const int bucketSeconds) const
     {
      double sum=0.0; int count=0;
      datetime walkAnchor = currentAnchor;
      int cap = MathMin(m_lookbackSessions,AX_NOISE_MAX_LOOKBACK_SESSIONS);
      for(int i=0;i<cap;i++)
        {
         walkAnchor = PreviousSessionAnchor(walkAnchor);
         //--- skip this historical session entirely if the bucket checkpoint falls at or past its OWN ---
         //--- end (the anchor that starts the NEXT session) - the 4 configured anchors are unevenly     ---
         //--- spaced, so a checkpoint valid deep into a long session (e.g. New York, up to ~9h) can       ---
         //--- otherwise land hours past a short historical session's end (e.g. Sydney, as little as 2h)    ---
         //--- and silently read a bar from an unrelated LATER session instead (code-review finding). ---
         datetime walkSessionEnd = NextSessionAnchor(walkAnchor);
         if(walkAnchor+bucketSeconds>=walkSessionEnd) continue;
         double histOpen = BarOpenAt(symbol,walkAnchor);
         if(histOpen<=0) continue;
         double histCheckpointClose = BarCloseAt(symbol,walkAnchor+bucketSeconds);
         if(histCheckpointClose<=0) continue;
         sum += MathAbs(histCheckpointClose/histOpen-1.0);
         count++;
        }
      if(count<=0) return(0.0); // no real history yet - neutral, never fabricated
      return(sum/count);
     }

public:
                     CNoiseAreaEngine(void)
     {
      m_bucketMinutes=5; m_lookbackSessions=14; m_volatilityMultiplier=1.0;
      m_decisionIntervalMinutes=30; m_barTimeframe=PERIOD_M1;
      m_sydneyHour=22; m_tokyoHour=0; m_londonHour=8; m_newYorkHour=13;
      m_cachedBucketAnchor=0; m_cachedBucketIndex=-1; m_cachedExpectedMoveFraction=0.0;
      m_lastDecisionAnchor=0; m_lastDecisionIntervalIndex=-1;
     }

   void              Configure(const int bucketMinutes,const int lookbackSessions,
                                const double volatilityMultiplier,const int decisionIntervalMinutes,
                                const ENUM_TIMEFRAMES barTimeframe,
                                const int sydneyHour,const int tokyoHour,
                                const int londonHour,const int newYorkHour)
     {
      m_bucketMinutes = MathMax(1,bucketMinutes);
      m_lookbackSessions = MathMax(1,MathMin(lookbackSessions,AX_NOISE_MAX_LOOKBACK_SESSIONS));
      m_volatilityMultiplier = MathMax(0.01,volatilityMultiplier);
      m_decisionIntervalMinutes = MathMax(1,decisionIntervalMinutes);
      m_barTimeframe = barTimeframe;
      m_sydneyHour  = (int)AxClampD(sydneyHour,0,23);
      m_tokyoHour   = (int)AxClampD(tokyoHour,0,23);
      m_londonHour  = (int)AxClampD(londonHour,0,23);
      m_newYorkHour = (int)AxClampD(newYorkHour,0,23);
      m_cachedBucketAnchor=0; m_cachedBucketIndex=-1; // invalidate cache - stale bucket data under a
                                                        // changed configuration must never be reused
      m_lastDecisionAnchor=0; m_lastDecisionIntervalIndex=-1; // same reasoning for the decision-point tracker
     }

   //--- call every tick. No lookahead: only ever reads bars at or before `now` for the CURRENT         ---
   //--- session's own open/checkpoint, and only historical (necessarily past) sessions for the          ---
   //--- expected-move average. ---
   SAxNoiseAreaState Evaluate(const string symbol,const datetime now,const double currentPrice)
     {
      SAxNoiseAreaState s;
      s.upperBound=0; s.lowerBound=0; s.expectedMoveFraction=0; s.breakoutDirection=AX_DIR_NONE;
      s.isDecisionPoint=false;

      datetime anchor = FindSessionAnchor(now);
      s.sessionAnchorTime = anchor;

      double sessionOpen = BarOpenAt(symbol,anchor);
      if(sessionOpen<=0)
        { s.reason="Could not read this session's own open"; return(s); }
      s.sessionOpen = sessionOpen;

      int elapsedSeconds = (int)(now-anchor);
      int bucketIndex = elapsedSeconds/(m_bucketMinutes*60);
      int bucketSeconds = bucketIndex*m_bucketMinutes*60;

      if(anchor!=m_cachedBucketAnchor || bucketIndex!=m_cachedBucketIndex)
        {
         m_cachedExpectedMoveFraction = ExpectedMoveFraction(symbol,anchor,bucketSeconds);
         m_cachedBucketAnchor=anchor; m_cachedBucketIndex=bucketIndex;
        }
      s.expectedMoveFraction = m_cachedExpectedMoveFraction;

      //--- gap adjustment per the paper's own revised equations: base off max/min of this session's   ---
      //--- own open and the PRIOR session's close, not the session open alone. The prior session's     ---
      //--- close is the close of the bar immediately preceding this session's own anchor bar. Guarded   ---
      //--- against PeriodSeconds()<=0 (code-review finding: ORBEngine.mqh's sibling code already          ---
      //--- hardens this identical construct - without the guard, a misconfigured m_barTimeframe would     ---
      //--- collapse `anchor-PeriodSeconds(...)` to `anchor` itself and silently read the anchor's OWN      ---
      //--- opening bar as if it were the prior session's close). ---
      int barSecondsForGap = PeriodSeconds(m_barTimeframe);
      double prevClose = (barSecondsForGap>0) ? BarCloseAt(symbol,anchor-barSecondsForGap) : -1.0;
      double baseUpper = (prevClose>0) ? MathMax(sessionOpen,prevClose) : sessionOpen;
      double baseLower = (prevClose>0) ? MathMin(sessionOpen,prevClose) : sessionOpen;

      double vmSigma = m_volatilityMultiplier*s.expectedMoveFraction;
      s.upperBound = baseUpper*(1.0+vmSigma);
      s.lowerBound = baseLower*(1.0-vmSigma);

      //--- isDecisionPoint fires on the first Evaluate() call that observes a NEW decision-interval    ---
      //--- index since the last call, not on an exact elapsed-seconds modulo hit against a raw tick       ---
      //--- timestamp (code-review finding: a tick-driven `now` at second resolution will rarely land      ---
      //--- on an exact multiple of decisionIntervalMinutes*60, so the original modulo check could           ---
      //--- silently never fire for an entire session). Mirrors the same "detect the transition, don't       ---
      //--- require an exact hit" fix already applied to the bucket cache above. ---
      int intervalIndex = elapsedSeconds/(m_decisionIntervalMinutes*60);
      if(anchor!=m_lastDecisionAnchor || intervalIndex!=m_lastDecisionIntervalIndex)
        {
         s.isDecisionPoint = true;
         m_lastDecisionAnchor=anchor; m_lastDecisionIntervalIndex=intervalIndex;
        }
      else
         s.isDecisionPoint = false;

      if(currentPrice>s.upperBound)      s.breakoutDirection=AX_DIR_BUY;
      else if(currentPrice<s.lowerBound) s.breakoutDirection=AX_DIR_SELL;
      else                                 s.breakoutDirection=AX_DIR_NONE;

      s.reason=StringFormat("NoiseArea [%.5f,%.5f] (VM=%.2f sigma=%.4f) price=%.5f -> %s%s",
                             s.lowerBound,s.upperBound,m_volatilityMultiplier,s.expectedMoveFraction,
                             currentPrice,AxDirToString(s.breakoutDirection),
                             s.isDecisionPoint?" [DECISION POINT]":"");
      return(s);
     }

   //--- the paper's own step-3 refinement (380% total return / Sharpe 1.24 in their backtest, vs.      ---
   //--- 178%/0.61 for a plain opposite-band stop): reuses this EA's own already-live VWAP value -       ---
   //--- never recomputed here, matching this codebase's "deliberately thin" convention. vwapValue<=0    ---
   //--- (VWAP not yet available) falls back to the band alone rather than fabricating a VWAP reading. ---
   double            TrailingStopPrice(const ENUM_AX_DIR direction,const double currentBandValue,
                                        const double vwapValue) const
     {
      if(vwapValue<=0) return(currentBandValue);
      return((direction==AX_DIR_BUY) ? MathMax(currentBandValue,vwapValue)
                                       : MathMin(currentBandValue,vwapValue));
     }

   //--- DELIBERATE, DOCUMENTED DIVERGENCE from the paper's own formula - see file header. The paper's  ---
   //--- own Shares_t formula uses min(4, target/realized) as a LEVERAGE multiplier that can exceed 1.0   ---
   //--- when realized volatility is below target; this port clamps to [0,1] so it can only ever REDUCE   ---
   //--- exposure, consistent with CAdaptiveFlipEngine's own audited size-down-only invariant             ---
   //--- (docs/RISK_INVARIANT_AUDIT.md). realizedVolPct<=0 (no real volatility reading yet) returns 1.0    ---
   //--- (no scaling applied) rather than a fabricated ratio. ---
   double            VolatilityTargetSizeMultiplier(const double targetDailyVolPct,const double realizedDailyVolPct) const
     {
      if(realizedDailyVolPct<=0 || targetDailyVolPct<=0) return(1.0);
      return(AxClampD(targetDailyVolPct/realizedDailyVolPct,0.0,1.0));
     }

   //--- generalized NR-N helper (paper's own NR4: N=4) - true when `ranges[0]` (the most recent        ---
   //--- CLOSED day's high-low range, caller-supplied so this engine doesn't own daily-bar aggregation)   ---
   //--- is the smallest of the last `lookback` ranges supplied in `ranges[]` (ranges[0]=most recent). ---
   bool              IsNarrowRangeDay(const double &ranges[],const int lookback) const
     {
      int n = MathMin(lookback,ArraySize(ranges));
      if(n<2) return(false);
      for(int i=1;i<n;i++)
         if(ranges[i]<=ranges[0]) return(false);
      return(true);
     }
  };
//+------------------------------------------------------------------+
#endif // AX_NOISEAREAENGINE_MQH
