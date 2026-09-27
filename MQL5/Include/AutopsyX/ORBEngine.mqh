//+------------------------------------------------------------------+
//|                                                     ORBEngine.mqh|
//|  Opening Range Breakout (ORB) Engine - based on:                   |
//|  Zarattini, C. and Aziz, A., "Can Day Trading Really Be            |
//|  Profitable? Evidence of Sustainable Long-term Profits from        |
//|  Opening Range Breakout (ORB) Day Trading Strategy vs. Benchmark    |
//|  in the US Stock Market," SSRN 4416622 (2023).                       |
//|                                                                    |
//|  PAPER-SOURCED (the paper's own 5-minute ORB rules, backtested on   |
//|  QQQ/TQQQ 2016-2023, 675%/1,484% total return vs. 169% buy-and-hold, |
//|  33%/48% annualized alpha, beta not statistically different from      |
//|  zero):                                                                |
//|   - Direction: if the opening-range candle is bullish (close>open),     |
//|     look LONG starting from the immediately following candle's open;    |
//|     if bearish, look SHORT; a doji (open==close) produces NO signal      |
//|     at all - the paper is explicit about this, not a detail this port     |
//|     invented.                                                              |
//|   - Stop (baseline test): the low of the opening-range candle for a         |
//|     long, the high for a short. This distance is called R.                   |
//|   - The paper's own "further investigation" section reports that the          |
//|     single BEST-performing combination they tested was a TIGHT stop (5%        |
//|     of the 14-day ATR, replacing the opening-range extreme) with NO fixed       |
//|     profit target at all - riding the trade to end-of-day liquidation           |
//|     only. Their own words: "cut losses quickly... let profits run." This         |
//|     is exposed here via UseAtrStop()/ENUM_AX_ORB_TARGET_MODE, not forced           |
//|     as this engine's default - see the honest caveat below.                        |
//|   - The paper's OWN caveat on that specific optimized result (carried              |
//|     into this port unchanged, not softened): it assumed zero slippage,              |
//|     and at real trading size a stop that tight can be narrower than the              |
//|     instrument's own spread, which the paper itself calls "unrealistic"                |
//|     beyond small size.                                                                  |
//|                                                                    |
//|  ENGINEERING DESIGN (NOT in the paper - adapted for this EA's own          |
//|  24-hour instruments, XAUUSD/major FX, rather than a single-session          |
//|  US-market open):                                                              |
//|   - "Opening range" assumes ONE well-defined session open (US market            |
//|     9:30am ET). This is the exact same adaptation problem VWAPEngine.mqh          |
//|     already solved for the OTHER Zarattini & Aziz paper cited in this              |
//|     codebase (SSRN 4631351) - reused here rather than re-invented: the              |
//|     opening range anchors to whichever of 4 configured FX/metals                     |
//|     liquidity-session opens (Sydney/Tokyo/London/New York) most recently               |
//|     passed, never a single fixed hour. FindSessionAnchor() below is a                   |
//|     deliberate, separate copy of VWAPEngine.mqh's own method (not a shared               |
//|     function) - matching this codebase's established "each engine owns its                |
//|     own read" convention (VolatilityEngine's own ATR handle, DrawdownEngine's                |
//|     own day/week rollover, etc.), so a future change to one doesn't silently                  |
//|     change the other.                                                                            |
//|   - "End of day" (the paper's literal US-market-close liquidation point) has                       |
//|     no equivalent in a 24-hour market. Re-defined here, as an engineering                            |
//|     choice, as "the next configured session anchor after this signal's own                            |
//|     range" - see ShouldLiquidateAtSessionEnd(). This is a substitution, not                             |
//|     something the paper specifies or would necessarily endorse.                                          |
//|   - The paper's position-sizing formula (a US-equities SHARE-COUNT formula                                |
//|     gated by FINRA's 4x day-trading margin cap, worked around by trading a                                  |
//|     3x leveraged ETF - TQQQ - to approximate uncapped exposure) has NO                                       |
//|     analogue here and is deliberately NOT reimplemented: a forex/CFD                                          |
//|     account's leverage is set directly by the broker (commonly far above                                       |
//|     4x already) and there is no "3x leveraged ETF of XAUUSD" to substitute.                                      |
//|     CRiskEngine's own risk-percent-based sizing (0.05%-2.0% of equity,                                             |
//|     hard-clamped - see docs/RISK_INVARIANT_AUDIT.md) is this codebase's own                                        |
//|     equivalent lever, and this engine does not duplicate or bypass it.                                               |
//|   - The paper's own "5% of 14-day ATR" figure was calibrated to TQQQ's                                                |
//|     specific price level and volatility in 2016-2023 - copying that exact                                             |
//|     percentage onto XAUUSD/FX without recalibration would be exactly the kind                                          |
//|     of unlabeled, borrowed-precision mistake this codebase has avoided                                                   |
//|     everywhere else. m_atrStopFraction is therefore a configurable input,                                                 |
//|     not a hardcoded 5%, and should be tuned per-instrument via this EA's own                                                |
//|     Python backtesting module (python/autopsy_research/backtest.py, Phase 11)                                              |
//|     before ever being trusted - this has NOT been done, and no default value                                                 |
//|     here should be read as validated.                                                                                          |
//|                                                                    |
//|  SIGNAL, NOT ACTION: like every engine in this build, this class never       |
//|  calls CTrade or places an order. Evaluate() produces a candidate direction,   |
//|  entry price, and stop distance for a caller to gate through CRiskEngine/       |
//|  CExecutionEligibility/etc, exactly like every other signal-generating          |
//|  engine in this codebase. It is not wired into the live OnTick loop as           |
//|  part of this build.                                                              |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_ORBENGINE_MQH
#define AX_ORBENGINE_MQH
#include "Defs.mqh"

//--- profit-target mode for a signaled ORB trade - see file header for the paper's own finding      ---
//--- that EOD_ONLY combined with a tight ATR stop outperformed every fixed R-multiple tested in        ---
//--- their backtest, and this file's own caveat that this has NOT been validated for XAUUSD/FX yet. ---
enum ENUM_AX_ORB_TARGET_MODE
  {
   AX_ORB_TARGET_R_MULTIPLE = 0, // fixed target at N x the stop distance (R) - the paper's baseline test
   AX_ORB_TARGET_EOD_ONLY         // no fixed target - ride to session-end liquidation only (the paper's
                                    // own best-performing combination in their backtest, paired with a
                                    // tight ATR stop - see UseAtrStop())
  };

struct SAxOrbSignal
  {
   bool     hasSignal;
   ENUM_AX_DIR direction;
   datetime rangeStartTime;
   datetime rangeEndTime;      // rangeStartTime + configured range minutes
   double   rangeHigh;
   double   rangeLow;
   double   entryPrice;        // caller-supplied current price at the moment the range closes - see
                                 // Evaluate()'s own comment on why this differs slightly from the
                                 // paper's own OHLC-backtest "open of the next candle"
   double   stopPrice;
   double   riskPts;           // R, in points - always > 0 when hasSignal is true
   double   targetPrice;       // 0.0 (no fixed target) when m_targetMode==AX_ORB_TARGET_EOD_ONLY
   string   reason;
  };

class CORBEngine
  {
private:
   int      m_rangeMinutes;              // opening-range window length, e.g. 5 (the paper's own default)
   ENUM_TIMEFRAMES m_barTimeframe;        // must evenly divide m_rangeMinutes (e.g. M1 with rangeMinutes=5)
   int      m_sydneyHour, m_tokyoHour, m_londonHour, m_newYorkHour; // same 4-session-anchor convention
                                                                       // as VWAPEngine.mqh - see file header

   bool     m_useAtrStop;                // false = the paper's baseline (opening-range extreme as stop);
                                           // true = the paper's own "further investigation" finding
                                           // (a tight ATR-fraction stop instead) - NOT the default here,
                                           // since it is the less-tested, higher-execution-risk mode
   double   m_atrStopFraction;           // only used when m_useAtrStop - NOT hardcoded to the paper's
                                           // own 5%, since that number was calibrated to TQQQ - see header
   ENUM_AX_ORB_TARGET_MODE m_targetMode;
   double   m_targetRMultiple;           // only used when m_targetMode==AX_ORB_TARGET_R_MULTIPLE

   datetime m_lastSignaledRangeStart;    // guards against re-signaling the same opening range every tick

   //--- deliberate, separate copy of VWAPEngine.mqh's own FindSessionAnchor() - see file header for why ---
   datetime          FindSessionAnchor(const datetime now) const
     {
      MqlDateTime dt;
      TimeToStruct(now,dt);
      datetime todayStart = now-(dt.hour*3600+dt.min*60+dt.sec);

      int hours[4] = {m_sydneyHour,m_tokyoHour,m_londonHour,m_newYorkHour};
      for(int i=1;i<4;i++) // small insertion sort, ascending
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

public:
                     CORBEngine(void)
     {
      m_rangeMinutes=5; m_barTimeframe=PERIOD_M1;
      m_sydneyHour=22; m_tokyoHour=0; m_londonHour=8; m_newYorkHour=13;
      m_useAtrStop=false; m_atrStopFraction=0.05; m_targetMode=AX_ORB_TARGET_R_MULTIPLE;
      m_targetRMultiple=10.0; // the paper's own baseline-test values (10R or EoD, whichever first)
      m_lastSignaledRangeStart=0;
     }

   void              Configure(const int rangeMinutes,const ENUM_TIMEFRAMES barTimeframe,
                                const int sydneyHour,const int tokyoHour,
                                const int londonHour,const int newYorkHour,
                                const bool useAtrStop,const double atrStopFraction,
                                const ENUM_AX_ORB_TARGET_MODE targetMode,const double targetRMultiple)
     {
      m_rangeMinutes = MathMax(1,rangeMinutes);
      m_barTimeframe = barTimeframe;
      m_sydneyHour  = (int)AxClampD(sydneyHour,0,23);
      m_tokyoHour   = (int)AxClampD(tokyoHour,0,23);
      m_londonHour  = (int)AxClampD(londonHour,0,23);
      m_newYorkHour = (int)AxClampD(newYorkHour,0,23);
      m_useAtrStop = useAtrStop;
      //--- deliberately NOT clamped toward the paper's own 5% - only bounded to a sane, non-degenerate ---
      //--- range so a misconfigured 0 or negative value can't produce a zero/negative stop distance      ---
      //--- downstream; the actual value belongs to per-instrument backtesting, not this engine (header). ---
      m_atrStopFraction = AxClampD(atrStopFraction,0.001,5.0);
      m_targetMode = targetMode;
      m_targetRMultiple = MathMax(0.1,targetRMultiple);
     }

   //--- call every tick. Reads only bars fully CLOSED at or before `now` (no lookahead - same           ---
   //--- convention as StructureEngine.mqh/VWAPEngine.mqh). Returns hasSignal=false with a reason         ---
   //--- whenever the opening range isn't fully closed yet, was a doji, real bar data couldn't be read,    ---
   //--- or this exact opening range has already produced a signal (guards against re-signaling every      ---
   //--- tick for the rest of the session once the range has closed).                                       ---
   //--- atrPts: an already-computed ATR reading in points, reused from whichever engine already tracks it   ---
   //--- live (e.g. CRegimeEngine::CurrentAtr()) - never recomputed here, matching this codebase's            ---
   //--- "deliberately thin" convention. Only read when m_useAtrStop is true.                                  ---
   SAxOrbSignal      Evaluate(const string symbol,const datetime now,const double point,
                               const double currentPrice,const double atrPts)
     {
      SAxOrbSignal s;
      s.hasSignal=false; s.direction=AX_DIR_NONE; s.rangeHigh=0; s.rangeLow=0;
      s.entryPrice=0; s.stopPrice=0; s.riskPts=0; s.targetPrice=0;

      datetime anchor = FindSessionAnchor(now);
      s.rangeStartTime = anchor;
      s.rangeEndTime = anchor+m_rangeMinutes*60;

      if(anchor==m_lastSignaledRangeStart)
        { s.reason="This opening range has already produced a signal"; return(s); }
      if(now<s.rangeEndTime)
        { s.reason="Opening range not yet closed"; return(s); }
      if(point<=0)
        { s.reason="Invalid point size"; return(s); }

      int barSeconds = PeriodSeconds(m_barTimeframe);
      if(barSeconds<=0 || (m_rangeMinutes*60)%barSeconds!=0)
        { s.reason="Configured range minutes does not evenly divide the bar timeframe"; return(s); }
      int numRangeBars = (m_rangeMinutes*60)/barSeconds;

      //--- shift of the bar COVERING the anchor time - shift 0 is always the currently-forming bar,   ---
      //--- so this must be a genuinely closed bar (>=1) before the range can be trusted (same no-       ---
      //--- lookahead reasoning as VWAPEngine.mqh's GetSessionAnchoredVwap()). ---
      int anchorShift = iBarShift(symbol,m_barTimeframe,anchor,false);
      //--- iBarShift returns -1 on a hard error (no history for this symbol/timeframe) - rejected here  ---
      //--- EXPLICITLY, not by relying on the numeric coincidence that -1<numRangeBars for any real       ---
      //--- numRangeBars>=1 (code-review finding: VWAPEngine.mqh's own equivalent read already learned     ---
      //--- this lesson the hard way - a later change to the guard shape below could silently stop         ---
      //--- catching this case if it isn't checked on its own). ---
      if(anchorShift<0)
        { s.reason="No bar history available for this symbol/timeframe"; return(s); }
      if(anchorShift<numRangeBars)
        { s.reason="Not enough closed bars since the session anchor yet"; return(s); }

      MqlRates rates[];
      ArraySetAsSeries(rates,true);
      int copied = CopyRates(symbol,m_barTimeframe,anchorShift-numRangeBars+1,numRangeBars,rates);
      if(copied<numRangeBars)
        { s.reason="Could not read the opening-range bars"; return(s); }

      double rangeOpen  = rates[numRangeBars-1].open;  // oldest bar in the range = the range's own open
      double rangeClose = rates[0].close;               // most recent bar in the range = the range's own close
      double rangeHigh=rangeOpen, rangeLow=rangeOpen;
      for(int i=0;i<numRangeBars;i++)
        {
         if(rates[i].high>rangeHigh) rangeHigh=rates[i].high;
         if(rates[i].low<rangeLow)   rangeLow=rates[i].low;
        }
      s.rangeHigh=rangeHigh; s.rangeLow=rangeLow;

      //--- doji: the paper's own rule produces NO signal here, not a fallback direction guess ---
      if(rangeClose==rangeOpen)
        { s.reason="Opening range candle was a doji - no signal, per the paper's own rule"; return(s); }

      s.direction = (rangeClose>rangeOpen) ? AX_DIR_BUY : AX_DIR_SELL;

      //--- entryPrice: the CURRENT price at the moment the range closes, supplied by the caller (bid/  ---
      //--- ask as appropriate for the direction) - a live, tick-driven EA reacts the instant the range   ---
      //--- closes rather than waiting for a full backtest-style "next candle" to form and close, unlike  ---
      //--- the paper's own OHLC backtest which used the next candle's recorded open. This is an honest,   ---
      //--- unavoidable difference between live and backtested execution, not a paper-sourced detail. ---
      s.entryPrice = currentPrice;

      if(m_useAtrStop)
        {
         if(atrPts<=0) { s.reason="ATR-based stop requested but no real ATR reading available"; return(s); }
         double stopDistPts = atrPts*m_atrStopFraction;
         s.stopPrice = (s.direction==AX_DIR_BUY) ? s.entryPrice-stopDistPts*point
                                                   : s.entryPrice+stopDistPts*point;
        }
      else
        {
         s.stopPrice = (s.direction==AX_DIR_BUY) ? rangeLow : rangeHigh;
        }

      //--- range-extreme stop mode is derived from the CLOSED range, while entryPrice is a live tick -  ---
      //--- if price has already gapped/spiked past the range extreme by the time this call runs (a real  ---
      //--- possibility on XAUUSD/FX between the range closing and the next tick), the "stop" could sit    ---
      //--- on the WRONG side of entry (an inverted stop for the signaled direction) instead of being        ---
      //--- rejected (code-review finding). Checked for both stop modes, not just the range-extreme one,      ---
      //--- since a misconfigured ATR fraction could in principle do the same - fail closed rather than        ---
      //--- hand a caller a stop it can't trust the side of. ---
      bool stopOnCorrectSide = (s.direction==AX_DIR_BUY) ? (s.stopPrice<s.entryPrice) : (s.stopPrice>s.entryPrice);
      if(!stopOnCorrectSide)
        { s.reason="Computed stop is on the wrong side of entry (price gapped past the range) - refusing to signal"; return(s); }

      s.riskPts = MathAbs(s.entryPrice-s.stopPrice)/point;
      if(s.riskPts<=0)
        { s.reason="Computed zero or negative risk distance - refusing to signal"; return(s); }

      if(m_targetMode==AX_ORB_TARGET_R_MULTIPLE)
        {
         double targetDistPts = s.riskPts*m_targetRMultiple;
         s.targetPrice = (s.direction==AX_DIR_BUY) ? s.entryPrice+targetDistPts*point
                                                     : s.entryPrice-targetDistPts*point;
        }
      // AX_ORB_TARGET_EOD_ONLY: targetPrice stays 0.0 - "no fixed target" is a real, deliberate state,
      // not a fabricated price

      s.hasSignal=true;
      s.reason=StringFormat("ORB %s: range %.5f-%.5f, entry %.5f, stop %.5f, R=%.1fpts",
                             AxDirToString(s.direction),rangeLow,rangeHigh,s.entryPrice,s.stopPrice,s.riskPts);
      m_lastSignaledRangeStart = anchor;
      return(s);
     }

   //--- engineering substitution for the paper's literal US-market-close "EoD" liquidation - see file   ---
   //--- header. A position from a given range is liquidated once the NEXT session anchor after that     ---
   //--- range's own start has passed. ---
   bool              ShouldLiquidateAtSessionEnd(const datetime now,const datetime signalRangeStartTime) const
     {
      datetime currentAnchor = FindSessionAnchor(now);
      return(currentAnchor>signalRangeStartTime);
     }

   bool              UsingAtrStop(void) const { return(m_useAtrStop); }
   ENUM_AX_ORB_TARGET_MODE TargetMode(void) const { return(m_targetMode); }
  };
//+------------------------------------------------------------------+
#endif // AX_ORBENGINE_MQH
