//+------------------------------------------------------------------+
//|                                       AutopsyXFlipdemonX15.mq5    |
//|                    AUTOPSY X FLIPDEMON X15 -- Adaptive Risk Core  |
//|                                                                    |
//|  A journal-gated adaptive risk sizing engine: every external      |
//|  signal (VWAP trend, VP-MACD) is disabled by default and only     |
//|  ever scales position sizing UP once its OWN logged, out-of-      |
//|  sample track record on THIS instrument clears a real minimum     |
//|  sample size with positive expectancy. A backtest published on a  |
//|  different instrument is a hypothesis this file tests live, never|
//|  a credential it inherits.                                        |
//|                                                                    |
//|  RECONSTRUCTION NOTE: this file was built to satisfy a follow-up  |
//|  task set (originally numbered Task 6 onward, referring to "prior |
//|  Tasks 1-5") whose earlier tasks' exact prompt text was not       |
//|  available when this file was written. Nothing under this repo's |
//|  tracked branches contained a file with this name and this        |
//|  architecture (JournalEntry / ComputeStats / ComputeAdaptiveRisk /|
//|  RunDecision) to build on, so Tasks 1-5 (the VWAP Trend Engine's  |
//|  GetVWAP / ClassifyVWAPTrend / UseVWAPExit / VWAPAlignmentBonus   |
//|  plumbing) were reconstructed here from what the later, fully-    |
//|  specified tasks implied about their shape, then Tasks 6-12 were  |
//|  implemented against that reconstruction exactly as specified.    |
//|  Verify this matches what you already had in mind before trusting|
//|  it over a version you may have elsewhere.                        |
//|                                                                    |
//|  SCOPE: this file is a signal/decision/gating engine, not a full  |
//|  execution EA -- it never opens a NEW position on its own signal  |
//|  (GetCompositeDirection() is a stub returning 0) and never closes |
//|  or modifies an existing one. It tracks whatever positions        |
//|  already exist on its symbol (from a human, from another EA, or   |
//|  from a future entry engine wired in at the GetCompositeDirection |
//|  extension point below) purely to build its own trade journal and |
//|  gate its own risk multiplier off it.                             |
//|                                                                    |
//|  EXCEPTION (Pyramiding Engine, section 21): this file's ONE real   |
//|  order-placement path. It ONLY ever sends a same-direction         |
//|  volume-ADD to a position that is already open and already        |
//|  profitable by MinProfitRMultipleToAdd -- never a new position,    |
//|  never a close, never an SL/TP change beyond passing the existing  |
//|  SL/TP through unchanged. OFF by default (AllowPyramiding=false)   |
//|  and inert even when on until ExecutionModeLive=true. See the      |
//|  PYRAMIDING ENGINE section below for the full gate chain.          |
//|                                                                    |
//|  ASYMMETRY: News Defense (Tasks 13-18) is the one engine in this  |
//|  file that defaults ON. Every other engine here defaults OFF      |
//|  because it can only ever INCREASE risk (a sizing bonus) and must |
//|  earn that trust first. News Defense can only ever SUPPRESS a new |
//|  entry, never add risk -- its failure mode if the underlying      |
//|  research is wrong is "skipped a trade that would've been fine,"  |
//|  not "took on risk it shouldn't have." That asymmetry is why it   |
//|  defaults on where everything else defaults off; see its own      |
//|  header comment below for the full reasoning.                     |
//|                                                                    |
//|  LEARNING MACHINE: two things a "gate that clears or doesn't"      |
//|  still lacked, both added below. (1) PERSISTENCE -- the journal    |
//|  now loads from and saves to a CSV in the terminal's sandboxed     |
//|  MQL5/Files folder (LoadJournalFromFile/SaveJournalToFile), so     |
//|  earned trust survives an EA reattach, terminal restart, or VPS    |
//|  reboot instead of resetting to zero every time; the journal IS    |
//|  the model, there is no separate cached state to go stale against |
//|  it. (2) GRADED SIZING -- ComputeLearnedBonus() replaces "gate     |
//|  clears -> jump straight to the fixed ceiling" with a bonus that   |
//|  scales continuously with the ALIGNED subset's measured            |
//|  expectancy (BonusLearningRate R-per-multiplier-point), still      |
//|  hard-capped at the same ceiling inputs as before and still        |
//|  requiring the same sample-size gate to unlock at all -- so it     |
//|  keeps adjusting as evidence accumulates rather than snapping to   |
//|  one fixed value the instant 20 trades pass. News Defense gets a   |
//|  parallel, REPORT-ONLY per-event breakdown (ComputePerEventStats)  |
//|  -- it deliberately never auto-loosens the suppression itself;     |
//|  loosening a safety default off a self-logged small sample would   |
//|  invert this file's whole judgment, so that stays a human decision.|
//+------------------------------------------------------------------+
#property copyright "AUTOPSY X"
#property link      ""
#property version   "1.00"
#property strict

// <Trade/Trade.mqh> is a standard MQL5 library shipped with every terminal
// install -- this is not a dependency on this repo's other project files
// (this file still includes none of MQL5/Include/AutopsyX/*.mqh, preserving
// its single-file design), it's the same standard trade wrapper this
// repo's OWN sibling EA (AutopsyX_FlipDemon_Extreme.mq5's ExecutionEngine.mqh)
// already uses, ported here for the same reason: never assume an order
// filled, always confirm actual position state afterward.
#include <Trade/Trade.mqh>
CTrade g_trade;

//====================================================================
// SENTINEL / CLASSIFICATION CONVENTIONS (used throughout this file)
//====================================================================
// - A double signal/price value of -1.0 means "unavailable" (insufficient
//   history, bad symbol, undefined computation) -- never a real reading.
// - A string classification of "BULLISH" / "BEARISH" / "NEUTRAL" is used
//   by every engine below. "NEUTRAL" covers BOTH "genuinely no edge" and
//   "signal unavailable" -- callers never need to distinguish the two,
//   because neither case is ever allowed to count as "aligned" with a
//   trade direction. This is deliberate: it is the mechanism that keeps
//   the constraint "do not fabricate alignment when a signal was
//   unavailable" trivially true everywhere this convention is used.
// - direction: 1 = long/buy, -1 = short/sell. 0 is never a valid trade
//   direction in this file.

//====================================================================
// INPUTS
//====================================================================
input group "=== SCOPE ===";
input ulong   InpMagicNumberFilter        = 0;    // 0 = journal every position on this symbol regardless of source; nonzero = only positions carrying this magic number

input group "=== ADAPTIVE RISK CORE ===";
input double  InpBaseRiskPercent          = 0.5;  // base % of equity risked per trade before any adaptive multiplier
input double  InpAdaptiveRiskFloor        = 0.1;  // hard floor on the adaptive multiplier itself (never scales risk below this fraction of base)
input double  InpAdaptiveRiskCeiling      = 2.0;  // hard ceiling on the adaptive multiplier itself, independent of how many bonuses stack
input double  InpMaxRiskPct               = 2.0;  // absolute hard ceiling on risk % per trade, applied after the multiplier and after every bonus
input double  InpFlipRiskCapPct           = 1.0;  // tighter ceiling applied specifically when isFlipReentry is true
input int     MinTradesForStats           = 30;   // trades required before the OVERALL journal stats are reported as more than "insufficient sample"

input group "=== VWAP TREND ENGINE (Tasks 1-5, reconstructed) ===";
input bool    UseVWAPExit                 = false; // master switch: OFF by default. Also gates whether VWAP participates in the alignment bonus at all (Task 6)
input int     VWAPSessionResetHour        = 0;     // broker-server hour at which the session VWAP resets (0 = midnight server time)
input bool    VWAPContinuousMode          = false; // true: never reset -- single rolling VWAP over VWAPMaxBars instead of a daily session reset (for near-24h instruments)
input int     VWAPMaxBars                 = 1500;  // safety cap on how far back GetVWAP() will ever look, so it can't accumulate over the whole chart history unbounded
input double  VWAPAlignmentBonus          = 1.20;  // multiplier applied ONLY once the VWAP-aligned subset clears its own gate below (Task 6)
input int     MinVWAPAlignedTradesForBonus= 20;    // independent sample-size gate for the VWAP-aligned subset specifically (narrower question than MinTradesForStats, so a smaller-but-still-real minimum)

input group "=== VP-MACD ENGINE (Tasks 7-12) ===";
input bool    UseVPMACDEntry              = false; // master switch: OFF by default, same philosophy as UseVWAPExit
input int     VPMACDLookbackN             = 20;    // bars in the volume/volatility/structure-adjusted price window (Task 7)
input double  VPMACDLambda                = 0.9;   // buy-side sensitivity relaxation, calibrated 0.8-1.0 on U.S. equity indices in the source paper -- NOT verified for this EA's actual instruments; see the engine header comment below before trusting this default
input double  VPMACDAlignmentBonus        = 1.10;  // kept modest, smaller than VWAPAlignmentBonus -- this signal has less external validation behind it (see caveats below)
input int     MinVPMACDAlignedTradesForBonus = 20; // independent sample-size gate, mirrors MinVWAPAlignedTradesForBonus

input group "=== NEWS DEFENSE (Tasks 13-18) ===";
input bool    UseNewsDefense              = true;  // defaults ON -- see the ASYMMETRY note in the file header and the engine header comment below for why this one engine breaks the "default off" pattern
input int     NewsDefenseWindowMinutes    = 30;    // one-sided post-event window, per the paper's own finding (see engine header)
input bool    NewsDefenseFallbackForUnvalidatedCurrencies = true; // generic CALENDAR_IMPORTANCE_HIGH filter for GBP/EUR/JPY/CAD/CHF/NZD legs, which the paper does not validate -- set false to run the validated USD/AUD filter only

input group "=== LEARNING MACHINE ===";
input bool    UsePersistentJournal        = true;  // load/save the trade journal to a CSV in this terminal's sandboxed MQL5/Files folder, so earned track record survives an EA reattach or terminal restart instead of resetting to zero
input string  JournalFileNameOverride     = "";    // leave blank to auto-name as AutopsyX15_Journal_<SYMBOL>.csv
input double  BonusLearningRate           = 0.10;  // how much measured expectancy (in R) translates into bonus size once a gate clears -- e.g. 0.10 means 1R of measured edge adds +10% to position size, still capped at VWAPAlignmentBonus/VPMACDAlignmentBonus below. This rate itself is an arbitrary starting point, not derived from anything -- same "unproven until logged" status as every other number in this file
input int     MinTradesPerEventForReport  = 5;     // smallest per-event sample worth showing in the News Defense per-event breakdown -- reporting only, never feeds back into suppression (see the LEARNING MACHINE note above)

input group "=== PROVEN RUIN BOUND (Kelly) ===";
input double  RuinBoundAlpha              = 0.8;   // DRAWDOWN THRESHOLD this bound protects against, as a fraction of starting capital: 0.8 = "protect against wealth falling to 80% of where it started" (a 20% drawdown). Must be strictly between 0 and 1. Closer to 1.0 = guarding against a SMALLER drawdown (stricter).
input double  RuinBoundBeta               = 0.1;   // PROBABILITY TOLERANCE for that drawdown: 0.1 = "want less than a 10% chance of it happening." Must be strictly between 0 and 1. Smaller = wanting MORE confidence it won't happen (stricter).

input group "=== EXECUTION (new: pyramid adds are this file's first real order placement) ===";
input bool    ExecutionModeLive           = false; // false = PAPER (log what would have been sent, never call a real order function); true = LIVE (real orders via CTrade). Independent of AllowPyramiding below -- both must be true before anything real is sent, matching this file's "prove it before it's armed" pattern for every other engine.
input ulong   PyramidMagicNumber          = 1500001; // magic number tag for orders this file places
input int     PyramidDeviationPoints      = 20;      // max acceptable slippage in points before a live add is rejected by the broker

input group "=== ACCOUNT SAFETY GOVERNOR (new: required for any live execution) ===";
input double  DailyLossLimitPercent       = 5.0;   // circuit breaker: no pyramid adds once today's equity drawdown from day-start equity reaches this. This is a MINIMAL governor scoped to what pyramiding needs (daily loss only) -- the sibling AutopsyX_FlipDemon_Extreme.mq5's RiskEngine.mqh has a more complete one (consecutive-loss limits, rolling trade-rate limits, spread/margin checks) that was NOT ported here; only what this feature explicitly required.

input group "=== PYRAMIDING ENGINE (section 21) ===";
input bool    AllowPyramiding             = false; // OFF by default -- this is a new way to increase aggregate exposure, so like every other engine in this file, it earns activation explicitly rather than starting on
input int     MaxPyramidAdds              = 3;     // NOT specified in the originating task -- conservative default, flagged here explicitly, trivial to change
input double  MinProfitRMultipleToAdd     = 1.0;   // position must be at least this many R in profit (using the ORIGINAL entry's risk distance, the same yardstick as every other R-multiple in this file) before an add is even considered
input bool    RequireFreshConfirmation    = true;  // see CheckPyramidEligibility() -- adds require a NEW signal event, not just "price moved favorably since the last add"

//====================================================================
// CORE DATA TYPES
//====================================================================
// JournalEntry: one row per CLOSED trade. vwapAligned / vpMacdAligned are
// captured AT ENTRY (frozen for the life of the trade) by RecordEntryMeta()
// below, never recomputed at close -- recomputing at close would let
// hindsight leak into what's supposed to be a live, forward-looking read.
struct JournalEntry
  {
   datetime          closeTime;
   string            symbol;
   int               direction;      // 1 = long, -1 = short
   double            rMultiple;      // realized P&L expressed in R (risk units), using the SL distance that was actually set at entry
   bool              vwapAligned;    // Task 6: did VWAP trend agree with this trade's direction at entry? false if unavailable -- never guessed
   bool              vpMacdAligned;  // Task 11: same question for VP-MACD
   bool              nearValidatedNewsEvent; // Task 17: was a Task-14 whitelisted event within NewsDefenseWindowMinutes of this trade's entry? Recorded regardless of UseNewsDefense so the comparison sample keeps accumulating even while suppression is toggled during testing
   string            newsEventNameAtEntry; // learning-machine extension: the SPECIFIC validated event name matched at entry (e.g. "US Non-Farm Payrolls (USD)"), or "" if none -- powers ComputePerEventStats()'s report-only per-event breakdown
  };
JournalEntry g_journal[];

// StatsResult: same shape used by ComputeStats() and both *AlignedStats()
// functions below, so every consumer (ComputeAdaptiveRisk, RunDecision)
// treats "the whole journal" and "a filtered subset of it" identically.
struct StatsResult
  {
   double            winRate;     // fraction 0..1, or -1 if sampleSize == 0
   double            avgR;        // mean R multiple, or -1 if sampleSize == 0
   double            expectancy;  // per-trade expectancy in R units -- identical to avgR today; kept as a separate field in case cost/fee modeling is layered in later without changing this struct's shape
   int               sampleSize;
  };

// OpenPositionMeta: bookkeeping for positions that are still open, captured
// once at entry and consumed once at close. Never persisted beyond that.
//
// CORRECTNESS-CRITICAL, audited: `ticket` is captured ONCE, in
// RecordEntryMeta, from PositionGetTicket() at the position's true open.
// MQL5 distinguishes POSITION_TICKET (can CHANGE -- on a netting account,
// a position reversal changes it to the ticket of the reversing order)
// from POSITION_IDENTIFIER (fixed for the position's entire lifetime,
// defined as the ticket of the order that originally opened it). Because
// this field is captured once at true entry and never refreshed from a
// later poll, its value permanently equals that position's
// POSITION_IDENTIFIER -- which is what HistorySelectByPosition() actually
// needs to retrieve the position's full deal history, including a later
// DEAL_ENTRY_INOUT reversal deal. Do NOT "simplify" this by refreshing
// `ticket` to the current PositionGetTicket() value on each
// SyncOpenPositions poll -- that would silently break history lookups
// for any position that gets reversed on a netting account. (Verified
// against MQL5 documentation and community reference during a full-file
// audit; not verified against a live hedging/netting account in this
// environment, since no MT5 terminal is available here.)
struct OpenPositionMeta
  {
   ulong             ticket;
   int               direction;
   double            entryPrice;
   double            slPriceAtEntry;
   bool              vwapAligned;
   bool              vpMacdAligned;
   bool              nearValidatedNewsEvent;
   string            newsEventNameAtEntry;
  };
OpenPositionMeta g_openMeta[];
bool g_firstSyncDone = false; // flips true after SyncOpenPositions' first pass -- see RecordEntryMeta's isPreExisting handling

// Account safety governor state (ported/minimized from this repo's own
// RiskEngine.mqh daily-lockout pattern) -- see UpdateDailySafetyGovernor()
// and IsAccountHalted() near the pyramiding engine below.
double g_dayStartEquity = 0.0;
datetime g_dayStartTime = 0;

//====================================================================
// STATS
//====================================================================
StatsResult ComputeStatsResultFromRArray(double &rValues[])
  {
   StatsResult s;
   int n = ArraySize(rValues);
   s.sampleSize = n;
   if(n == 0)
     {
      s.winRate    = -1.0;
      s.avgR       = -1.0;
      s.expectancy = -1.0;
      return(s);
     }
   int wins = 0;
   double sumR = 0.0;
   for(int i = 0; i < n; i++)
     {
      if(rValues[i] > 0.0) wins++;
      sumR += rValues[i];
     }
   s.winRate    = (double)wins / (double)n;
   s.avgR       = sumR / (double)n;
   s.expectancy = s.avgR;
   return(s);
  }

StatsResult ComputeStats(void)
  {
   int n = ArraySize(g_journal);
   double rValues[];
   ArrayResize(rValues, n);
   for(int i = 0; i < n; i++) rValues[i] = g_journal[i].rMultiple;
   return(ComputeStatsResultFromRArray(rValues));
  }

// Task 6.2 -- parallel to ComputeStats() but filtered to vwapAligned==true.
StatsResult ComputeVWAPAlignedStats(void)
  {
   int n = ArraySize(g_journal);
   double rValues[];
   ArrayResize(rValues, n);
   int count = 0;
   for(int i = 0; i < n; i++)
     {
      if(g_journal[i].vwapAligned)
        {
         rValues[count] = g_journal[i].rMultiple;
         count++;
        }
     }
   ArrayResize(rValues, count);
   return(ComputeStatsResultFromRArray(rValues));
  }

// Task 11.2 -- parallel to ComputeVWAPAlignedStats(), filtered on vpMacdAligned.
StatsResult ComputeVPMACDAlignedStats(void)
  {
   int n = ArraySize(g_journal);
   double rValues[];
   ArrayResize(rValues, n);
   int count = 0;
   for(int i = 0; i < n; i++)
     {
      if(g_journal[i].vpMacdAligned)
        {
         rValues[count] = g_journal[i].rMultiple;
         count++;
        }
     }
   ArrayResize(rValues, count);
   return(ComputeStatsResultFromRArray(rValues));
  }

// Task 17 -- lets News Defense's specific claim (validated events carry
// real short-horizon volatility risk) get checked against this system's
// own logged experience over time, rather than taken on faith
// indefinitely. "near" only accumulates trades that were opened close to
// a validated event -- which only happens if UseNewsDefense was off, or
// the fallback/whitelist didn't cover that instance, at the time of entry.
struct NewsProximityStats
  {
   StatsResult       near;   // trades opened within NewsDefenseWindowMinutes of a validated whitelist event
   StatsResult       away;   // every other trade
  };

NewsProximityStats ComputeNewsProximityStats(void)
  {
   NewsProximityStats result;
   int n = ArraySize(g_journal);
   double nearR[]; ArrayResize(nearR, n); int nearCount = 0;
   double awayR[]; ArrayResize(awayR, n); int awayCount = 0;
   for(int i = 0; i < n; i++)
     {
      if(g_journal[i].nearValidatedNewsEvent) { nearR[nearCount] = g_journal[i].rMultiple; nearCount++; }
      else                                    { awayR[awayCount] = g_journal[i].rMultiple; awayCount++; }
     }
   ArrayResize(nearR, nearCount);
   ArrayResize(awayR, awayCount);
   result.near = ComputeStatsResultFromRArray(nearR);
   result.away = ComputeStatsResultFromRArray(awayR);
   return(result);
  }

// Learning-machine extension -- per-event breakdown, REPORT-ONLY. This
// deliberately does NOT feed back into IsWhitelistedEvent() or
// CheckNewsDefense()'s suppression logic: automatically loosening a safety
// default because one specific event "only" looks costly across a
// handful of self-logged trades would invert this file's whole judgment
// -- protective defaults don't relax on a small sample, even one the
// system logged itself. This exists purely so a human reviewing the
// dashboard can see which specific validated events are actually
// costing or helping THIS account's trades near them, as one more honest
// input into an eventual human decision to adjust IsWhitelistedEvent()'s
// patterns -- never an automatic one.
struct EventStatsRow
  {
   string            eventName;
   StatsResult       stats;
  };

int ComputePerEventStats(EventStatsRow &rows[])
  {
   string uniqueNames[];
   int uniqueCount = 0;
   int n = ArraySize(g_journal);
   for(int i = 0; i < n; i++)
     {
      if(g_journal[i].newsEventNameAtEntry == "") continue;
      bool known = false;
      for(int u = 0; u < uniqueCount; u++)
         if(uniqueNames[u] == g_journal[i].newsEventNameAtEntry) { known = true; break; }
      if(!known)
        {
         ArrayResize(uniqueNames, uniqueCount + 1);
         uniqueNames[uniqueCount] = g_journal[i].newsEventNameAtEntry;
         uniqueCount++;
        }
     }

   ArrayResize(rows, uniqueCount);
   for(int u = 0; u < uniqueCount; u++)
     {
      double rValues[]; int count = 0; ArrayResize(rValues, n);
      for(int i = 0; i < n; i++)
        {
         if(g_journal[i].newsEventNameAtEntry == uniqueNames[u])
           {
            rValues[count] = g_journal[i].rMultiple;
            count++;
           }
        }
      ArrayResize(rValues, count);
      rows[u].eventName = uniqueNames[u];
      rows[u].stats      = ComputeStatsResultFromRArray(rValues);
     }
   return(uniqueCount);
  }

string EvaluateOverallGate(StatsResult &s)
  {
   // sampleSize==0 checked explicitly and first, independent of
   // MinTradesForStats: with that input misconfigured to <=0 the gate
   // below would silently pass on an empty journal (0 < 0 is false), and
   // s.expectancy is the -1.0 "no data" sentinel at sampleSize==0 (see
   // ComputeStatsResultFromRArray), which would otherwise print as "FAIL
   // -- non-positive expectancy" -- a real, misleading label for "no
   // trades logged yet," not an actual failing track record.
   if(s.sampleSize == 0) return("INSUFFICIENT SAMPLE -- no trades logged yet");
   if(s.sampleSize < MinTradesForStats) return("INSUFFICIENT SAMPLE");
   if(s.expectancy <= 0.0) return("FAIL -- non-positive expectancy over " + IntegerToString(s.sampleSize) + " trades");
   return("TRACKING -- positive expectancy over " + IntegerToString(s.sampleSize) + " trades");
  }

//====================================================================
// VWAP TREND ENGINE  (Tasks 1-5, reconstructed)
//--------------------------------------------------------------------
// Session Volume Weighted Average Price, after Zarattini & Aziz, "VWAP:
// The Holy Grail for Day Trading Systems" (SSRN 4631351, 2023): long
// while price trades above the running session VWAP, short while below.
// The paper's own backtest is on QQQ/TQQQ 2018-2023 -- it is a real,
// published result on THAT instrument over THAT window, and nothing
// more, until this engine's own gate (below, and in ComputeAdaptiveRisk)
// says otherwise on this EA's actual instrument.
//====================================================================
double GetVWAP(string symbol)
  {
   // Recomputed fresh on every call (no persistent running state) so it is
   // always correct after a terminal restart, a symbol switch, or a gap in
   // ticks. Cost is O(bars-since-anchor) per call -- cheap at single-symbol
   // EA scale.
   MqlRates rates[];
   int barsAvailable = CopyRates(symbol, PERIOD_CURRENT, 0, VWAPMaxBars, rates);
   if(barsAvailable <= 1) return(-1.0); // not enough history to compute anything meaningful

   // CopyRates(symbol, period, start_pos, count, rates) returns bars oldest-
   // first: rates[0] is the oldest bar requested, rates[barsAvailable-1] is
   // the most recent -- the cumulative sum below assumes that ordering.

   int startIdx = 0;
   if(!VWAPContinuousMode)
     {
      MqlDateTime lastDt;
      TimeToStruct(rates[barsAvailable-1].time, lastDt);
      datetime sessionAnchor = rates[barsAvailable-1].time
                                - (lastDt.hour*3600 + lastDt.min*60 + lastDt.sec)
                                + VWAPSessionResetHour*3600;
      if(rates[barsAvailable-1].time < sessionAnchor) sessionAnchor -= 86400; // today's reset hour hasn't hit yet -- anchor was yesterday's
      startIdx = barsAvailable - 1;
      while(startIdx > 0 && rates[startIdx-1].time >= sessionAnchor) startIdx--;
     }

   double cumPV = 0.0, cumV = 0.0;
   for(int i = startIdx; i < barsAvailable; i++)
     {
      // real_volume when the broker actually reports it, tick_volume as the
      // fallback proxy otherwise -- forex/CFD venues generally don't report
      // real traded volume the way equities exchanges do.
      double vol = (rates[i].real_volume > 0) ? (double)rates[i].real_volume : (double)rates[i].tick_volume;
      double typicalPrice = (rates[i].high + rates[i].low + rates[i].close) / 3.0;
      cumPV += typicalPrice * vol;
      cumV  += vol;
     }
   if(cumV <= 0.0) return(-1.0);
   return(cumPV / cumV);
  }

string ClassifyVWAPTrend(string symbol)
  {
   double vwap = GetVWAP(symbol);
   if(vwap < 0.0) return("NEUTRAL"); // unavailable -- see sentinel convention above; never guessed as a direction

   double price = SymbolInfoDouble(symbol, SYMBOL_BID);
   if(price <= 0.0) return("NEUTRAL");

   if(price > vwap) return("BULLISH");
   if(price < vwap) return("BEARISH");
   return("NEUTRAL"); // exactly on VWAP -- genuinely flat, not an error
  }

// Usable exit-signal helper for whatever position-management loop this
// engine gets wired into -- returns true when UseVWAPExit is enabled and
// the VWAP trend has flipped against an open position's direction. This
// file does not call it itself (it places no orders and manages no
// positions); it is exposed as the natural integration point for an exit
// engine, following the same "wire your own signal here" pattern already
// used elsewhere in this repo's sibling EAs.
bool ShouldVWAPExit(string symbol, int positionDirection)
  {
   if(!UseVWAPExit) return(false);
   string trend = ClassifyVWAPTrend(symbol);
   if(trend == "NEUTRAL") return(false); // unavailable or flat -- never force an exit on an unreadable signal
   if(positionDirection == 1 && trend == "BEARISH") return(true);
   if(positionDirection == -1 && trend == "BULLISH") return(true);
   return(false);
  }

//====================================================================
// VP-MACD ENGINE  (Tasks 7-12)
//--------------------------------------------------------------------
// Volume-Price-adjusted MACD, after Lin, Lin, Zhang, Zheng & Wang, "A
// Volume-Price-Adjusted MACD Trading Strategy with Sensitivity
// Calibration for U.S. Equity Indices," arXiv:2604.26063 (2026). Two
// ideas: (1) replace the plain closing price feeding MACD with an
// "adjusted price" weighted by volume, a relative-volatility proxy, and
// candle-body-ratio (structure), so thin/indecisive bars contribute less
// than heavy, decisive ones; (2) a bounded sensitivity parameter lambda
// (0.8-1.0 in the paper) that lets the BUY trigger fire slightly before
// the strict crossover, trading a little noise-filtering for a little
// less lag, while the SELL/exit side stays at the standard, unrelaxed
// crossover.
//
// Caveats, restated plainly rather than left implicit:
//  - The paper's own out-of-sample test and its lambda calibration
//    (0.8-1.0) were done ONLY on U.S. equity indices (SPY, QQQ, DIA),
//    2023-Feb 2026. It has never been tested on gold or FX. The default
//    lambda below is a starting point on THIS engine's actual
//    instruments, not an imported fact.
//  - The authors are independent researchers (one Yale affiliation, the
//    rest unaffiliated) -- this has not been institutionally vetted the
//    way some of this repo's other cited research has been, and as of
//    this writing it has not been independently replicated or
//    stress-tested by anyone outside the original authors.
//  - The paper is itself honest that its own results were mixed across
//    the three indices tested: one index's filtered strategy went
//    negative before a later refinement fixed it, another's trade count
//    dropped to just 6 trades -- too few to draw a strong conclusion
//    from. This is a real, methodologically careful, but modest and
//    partially mixed result, not a uniformly strong one.
//
// Given all of that, this signal earns its way into position sizing
// exactly the way the VWAP signal does (Task 6 above / Task 11 below):
// through its own logged, out-of-sample performance on the instruments
// this EA actually trades -- never through the credibility of the paper
// it's based on.
//====================================================================
struct VPMACDResult
  {
   double            macd;
   double            signal;
   bool              available;
  };

// P*_t = sum(P_i * Volume_i * sigma_i * r_i, i = t-N..t-1) / sum(Volume_i, i = t-N..t-1)
// Operates on an already-fetched, oldest-first MqlRates array (totalBars
// entries) rather than calling CopyRates itself, so a caller building a
// whole P*_t series (GetVPMACD below) can fetch the underlying bars ONCE
// and slice this over it repeatedly instead of re-fetching overlapping
// ranges per point. shift follows this file's raw CopyRates shift
// convention relative to the END of the array (0 = rates[totalBars-1], the
// most recent bar in it); t = shift is deliberately EXCLUDED from the sum,
// matching the paper's i = t-N..t-1 range.
double ComputeVPAdjustedPriceFromRates(MqlRates &rates[], int totalBars, int shift, int lookbackN)
  {
   if(lookbackN <= 0 || shift < 0) return(-1.0);
   int endIdx   = totalBars - 1 - shift; // index of bar t (excluded from the sum below)
   int startIdx = endIdx - lookbackN;    // index of the oldest bar in the i=t-N..t-1 window
   if(startIdx < 0 || endIdx >= totalBars) return(-1.0); // insufficient history for this window -- never compute on a partial window

   double sumWeighted = 0.0, sumVolume = 0.0;
   for(int i = startIdx; i < endIdx; i++)
     {
      double closeP = rates[i].close;
      double openP  = rates[i].open;
      double highP  = rates[i].high;
      double lowP   = rates[i].low;
      double volume = (rates[i].real_volume > 0) ? (double)rates[i].real_volume : (double)rates[i].tick_volume;

      // sigma_i: relative-volatility proxy (range / close). REASONABLE
      // PROXY, NOT A VERIFIED MATCH to the paper's exact volatility
      // formula -- the source material available when this was written
      // did not fully specify their formula, so this is a real, computable,
      // clearly-flagged stand-in rather than a guess presented as fact.
      double sigma_i = (closeP != 0.0) ? (highP - lowP) / closeP : 0.0;

      // r_i: candle body ratio, guarded against High==Low.
      double range = highP - lowP;
      double r_i = (range > 0.0) ? (MathAbs(closeP - openP) / range) : 0.0;

      sumWeighted += closeP * volume * sigma_i * r_i;
      sumVolume   += volume;
     }

   if(sumVolume <= 0.0) return(-1.0);
   return(sumWeighted / sumVolume);
  }

// Single-shift convenience wrapper for external callers that just want one
// P*_t value -- fetches only the bars that one value needs. GetVPMACD below
// does NOT use this (it fetches the whole range once and calls
// ComputeVPAdjustedPriceFromRates directly, to avoid ~2x34 overlapping
// CopyRates calls per signal check).
double GetVPAdjustedPrice(string symbol, int shift, int lookbackN)
  {
   if(lookbackN <= 0 || shift < 0) return(-1.0);
   MqlRates rates[];
   int need = lookbackN + 1; // the N-bar window (i=t-N..t-1) plus bar t itself, which we fetch but exclude from the sum
   int got = CopyRates(symbol, PERIOD_CURRENT, shift, need, rates);
   if(got < need) return(-1.0);
   return(ComputeVPAdjustedPriceFromRates(rates, got, 0, lookbackN));
  }

// VP-MACD_t = EMA12(P*_t) - EMA26(P*_t); Signal_t = EMA9(VP-MACD_t).
// shift = 0 is "now" (the most recent bar CopyRates returns), shift = 1 is
// one bar back -- used by the crossover check below to compare t-1 vs t.
// NOTE: depending on when this is evaluated (once per tick vs once per
// confirmed bar close), shift=0 may be a still-forming current bar. A
// caller that wants a closed-bar-only signal should pass shift=1/2
// instead of 0/1 -- flagged here rather than silently assumed away.
VPMACDResult GetVPMACD(string symbol, int shift)
  {
   VPMACDResult result;
   result.macd = -1.0; result.signal = -1.0; result.available = false;
   if(shift < 0) return(result);

   const int emaFastPeriod   = 12;
   const int emaSlowPeriod   = 26;
   const int emaSignalPeriod = 9;

   // Real seeding math, not a guessed buffer size: need enough P*_t values
   // to SMA-seed EMA26, then still have emaSignalPeriod valid MACD points
   // left over to SMA-seed EMA9 the same way.
   int seriesLen = emaSlowPeriod + emaSignalPeriod - 1; // 34 P*_t values minimum

   int barsNeeded = shift + (seriesLen - 1) + VPMACDLookbackN + 1;
   int barsAvailable = Bars(symbol, PERIOD_CURRENT);
   if(barsAvailable < barsNeeded) return(result); // insufficient history -- unavailable, not a guess

   // One bulk fetch covering the whole range this call needs, instead of one
   // CopyRates per P*_t point (up to 34 of them) -- every point's window
   // overlaps almost entirely with its neighbors', so this replaces ~34
   // redundant terminal-history round trips with one.
   MqlRates allRates[];
   int gotAll = CopyRates(symbol, PERIOD_CURRENT, 0, barsNeeded, allRates);
   if(gotAll < barsNeeded) return(result);

   double pStar[];
   ArrayResize(pStar, seriesLen);
   for(int k = 0; k < seriesLen; k++)
     {
      int s = shift + (seriesLen - 1) - k; // pStar[0] = oldest, pStar[seriesLen-1] = at `shift`
      double p = ComputeVPAdjustedPriceFromRates(allRates, gotAll, s, VPMACDLookbackN);
      if(p < 0.0) return(result); // any missing bar in the window -- unavailable, don't interpolate
      pStar[k] = p;
     }

   double emaFast[]; ArrayResize(emaFast, seriesLen);
   double emaSlow[]; ArrayResize(emaSlow, seriesLen);
   double kFast = 2.0 / (emaFastPeriod + 1.0);
   double kSlow = 2.0 / (emaSlowPeriod + 1.0);

   double smaFastSeed = 0.0;
   for(int k = 0; k < emaFastPeriod; k++) smaFastSeed += pStar[k];
   smaFastSeed /= emaFastPeriod;
   emaFast[emaFastPeriod - 1] = smaFastSeed;
   for(int k = emaFastPeriod; k < seriesLen; k++)
      emaFast[k] = pStar[k]*kFast + emaFast[k-1]*(1.0 - kFast);

   double smaSlowSeed = 0.0;
   for(int k = 0; k < emaSlowPeriod; k++) smaSlowSeed += pStar[k];
   smaSlowSeed /= emaSlowPeriod;
   emaSlow[emaSlowPeriod - 1] = smaSlowSeed;
   for(int k = emaSlowPeriod; k < seriesLen; k++)
      emaSlow[k] = pStar[k]*kSlow + emaSlow[k-1]*(1.0 - kSlow);

   // VP-MACD line is only defined from emaSlowPeriod-1 onward (both EMAs seeded).
   int macdLen = seriesLen - (emaSlowPeriod - 1); // == emaSignalPeriod, by construction of seriesLen above
   double macdSeries[]; ArrayResize(macdSeries, macdLen);
   for(int k = 0; k < macdLen; k++)
     {
      int idx = (emaSlowPeriod - 1) + k;
      macdSeries[k] = emaFast[idx] - emaSlow[idx];
     }

   double smaSigSeed = 0.0;
   for(int k = 0; k < emaSignalPeriod; k++) smaSigSeed += macdSeries[k];
   smaSigSeed /= emaSignalPeriod;
   double emaSig = smaSigSeed;
   // With the minimum seeding buffer (macdLen == emaSignalPeriod exactly),
   // the SMA seed above IS the only signal value -- there is no further
   // EMA recursion step possible without more history than barsNeeded
   // required. This is the correct minimal case, not a shortcut.
   for(int k = emaSignalPeriod; k < macdLen; k++)
      emaSig = macdSeries[k]*(2.0/(emaSignalPeriod+1.0)) + emaSig*(1.0 - 2.0/(emaSignalPeriod+1.0));

   result.macd      = macdSeries[macdLen - 1];
   result.signal    = emaSig;
   result.available = true;
   return(result);
  }

bool CheckVPMACDBuySignal(string symbol)
  {
   VPMACDResult prev = GetVPMACD(symbol, 1); // t-1
   VPMACDResult curr = GetVPMACD(symbol, 0); // t
   if(!prev.available || !curr.available) return(false); // unavailable -- never guess a signal

   bool wasBelowOrEqual = (prev.macd <= VPMACDLambda * prev.signal);
   bool isAbove          = (curr.macd >  VPMACDLambda * curr.signal);
   return(wasBelowOrEqual && isAbove);
  }

bool CheckVPMACDSellSignal(string symbol)
  {
   VPMACDResult prev = GetVPMACD(symbol, 1);
   VPMACDResult curr = GetVPMACD(symbol, 0);
   if(!prev.available || !curr.available) return(false);

   // Deliberately NOT lambda-adjusted here -- the paper's sensitivity
   // relaxation is specifically for earlier ENTRY, not exit, so the
   // sell/exit side stays at the stricter standard crossover.
   bool wasAboveOrEqual = (prev.macd >= prev.signal);
   bool isBelow           = (curr.macd <  curr.signal);
   return(wasAboveOrEqual && isBelow);
  }

string ClassifyVPMACDSignal(string symbol)
  {
   bool buy  = CheckVPMACDBuySignal(symbol);
   bool sell = CheckVPMACDSellSignal(symbol);
   // buy/sell are complementary crossover directions and should never both
   // fire on the same read: if they somehow did, treat it as NEUTRAL
   // rather than guessing which one to trust.
   if(buy && !sell) return("BULLISH");
   if(sell && !buy) return("BEARISH");
   return("NEUTRAL");
  }

//====================================================================
// NEWS DEFENSE ENGINE  (Tasks 13-18)
//--------------------------------------------------------------------
// After Martins & Lopes, "What events matter for exchange rate
// volatility?", Quarterly Review of Economics and Finance (2025),
// originally arXiv:2411.16244. Using Bayesian spike-and-slab variable
// selection across hundreds of tracked macro announcements, the paper
// found only NINE events clear a 95% posterior probability of actually
// driving FX volatility -- all tied to the Taylor rule (rates, inflation,
// employment, output):
//   USD: FOMC Rate Decision, FOMC Meeting Minutes, US CPI,
//        US Non-Farm Payrolls, US Retail Sales
//   AUD: RBA Cash Rate, AU Employment Change, AU GDP, AU Retail Sales
// Critically, the effect is ONE-SIDED: the paper found no volatility
// increase BEFORE an announcement, only a spike immediately AFTER that
// dissipates within roughly 30 minutes -- different from most retail EA
// news filters, which pause symmetrically before AND after any event
// merely tagged "high impact."
//
// Caveats, restated plainly rather than left implicit:
//  - An independent review flagged that the paper "overclaims the
//    identity of the nine events and under-reports MCMC validation" --
//    treat this specific nine-event list as a strong, evidence-backed
//    prior, not a permanently settled fact. It is the default here, and
//    Task 17's ComputeNewsProximityStats() below exists specifically to
//    let this EA's own logged outcomes refine or challenge it over time,
//    the same as every other engine in this file.
//  - The paper's validated scope is USD and AUD events ONLY (tested on
//    AUD/USD, with CHF as a secondary case). It says nothing about GBP,
//    EUR, JPY, or CAD-specific events (BoE, ECB, BoJ decisions, etc.).
//    Those currencies get a clearly separate, clearly lower-confidence
//    fallback (generic CALENDAR_IMPORTANCE_HIGH filtering, no whitelist)
//    in CheckNewsDefense() below -- never silently folded into the
//    validated logic.
//
// ASYMMETRY / WHY THIS ENGINE DEFAULTS ON (see also the file header):
// every other engine added to this file defaults OFF because it can only
// ever INCREASE aggression -- unlocking a sizing bonus, or (Pyramiding)
// adding volume to a position -- and must earn that trust with its own
// track record first. News Defense is the opposite: it can only ever
// SUPPRESS a new entry, it never adds risk, and it never touches an
// existing position (see GetGatedEntryDirection() and CheckNewsDefense()
// below -- there is no code path anywhere in News Defense that force-
// closes or resizes a position; the only place this file ever sends a
// real order at all is the separately-gated Pyramiding Engine below,
// which News Defense has no interaction with). If the underlying
// research turns out to be wrong, the failure mode is "skipped a trade
// that would have been fine," not "took on risk it shouldn't have." That
// asymmetric downside is the deliberate, specific reason this one engine
// ships enabled while the rest of the file ships inert -- not an
// inconsistency with the file's usual pattern.
//====================================================================
struct NewsDefenseState
  {
   bool              active;
   string            reason;
   bool              isValidatedEvent; // only meaningful when active==true
  };

// Task 14 -- the paper's nine validated events, matched by case-insensitive
// substring against the calendar's own event name. "Retail Sales" and
// "GDP" deliberately appear on both lists -- the paper's nine include both
// a USD and an AUD version of these fundamental categories.
string g_newsUsdWhitelist[] = {"Non-Farm", "Nonfarm", "Payrolls", "CPI", "Consumer Price Index", "Federal Funds Rate", "FOMC", "Retail Sales"};
string g_newsAudWhitelist[] = {"Cash Rate", "Employment Change", "GDP", "Gross Domestic Product", "Retail Sales"};

bool IsWhitelistedEvent(string eventName, string currency)
  {
   string nameUpper = eventName;
   StringToUpper(nameUpper);

   string patterns[];
   if(currency == "USD")      ArrayCopy(patterns, g_newsUsdWhitelist);
   else if(currency == "AUD") ArrayCopy(patterns, g_newsAudWhitelist);
   else return(false); // no validated whitelist for this currency -- see the fallback path in CheckNewsDefense()

   for(int i = 0; i < ArraySize(patterns); i++)
     {
      string patternUpper = patterns[i];
      StringToUpper(patternUpper);
      if(StringFind(nameUpper, patternUpper) >= 0) return(true);
     }
   return(false);
  }

// Task 15 -- parses a symbol's two currency legs. Prefers the broker's own
// SYMBOL_CURRENCY_BASE/SYMBOL_CURRENCY_PROFIT fields, which are correct
// regardless of how the broker names the symbol (a naive first-6-characters
// split silently breaks on any broker that prefixes symbols, e.g. "mEURUSD"
// or "iXAUUSD" -- those aren't parsed as EUR/USD or XAU/USD by a prefix
// split, and would silently fall through to News Defense's unvalidated
// fallback path forever on such a broker). Falls back to the prefix-split
// heuristic only if the broker-provided fields come back empty (seen on
// some synthetic/custom symbols) -- XAUUSD/XAGUSD fall out of the fallback
// naturally as base="XAU"/"XAG", quote="USD".
void GetTradeCurrencies(string symbol, string &base, string &quote)
  {
   base  = SymbolInfoString(symbol, SYMBOL_CURRENCY_BASE);
   quote = SymbolInfoString(symbol, SYMBOL_CURRENCY_PROFIT);
   if(base != "" && quote != "") return;

   base = ""; quote = "";
   if(StringLen(symbol) < 6) return;
   base  = StringSubstr(symbol, 0, 3);
   quote = StringSubstr(symbol, 3, 3);
  }

// Task 13 -- thin wrapper around the real, native MQL5 Economic Calendar
// API (CalendarValueHistory, available since a relatively recent MT5
// build -- verify the exact minimum build against MetaQuotes' own
// changelog before relying on this in production; not independently
// confirmed here). Returns the event count found, or -1 if the Calendar
// API is unavailable/restricted on this terminal. Callers MUST treat -1
// as "unavailable," never coerce it to "0 events found" -- some
// brokers/terminals don't expose calendar data at all, and silently
// treating that as "no news risk" would be exactly the false confidence
// this engine exists to avoid.
int GetRecentCalendarEvents(string currency, datetime lookbackFrom, datetime asOf, MqlCalendarValue &results[])
  {
   ResetLastError();
   // Currency filtering uses CalendarValueHistory's currency_code parameter
   // (5th argument), NOT country_code (4th) -- passing a currency string
   // like "USD" into the country_code slot would silently match nothing,
   // since MQL5 country codes ("US","AU",...) are a different vocabulary
   // from currency codes ("USD","AUD",...).
   int n = CalendarValueHistory(results, lookbackFrom, asOf, NULL, currency);
   if(n < 0 || GetLastError() != 0) return(-1);
   return(n);
  }

// Task 15/16 -- the defense window check itself, split into the validated
// USD/AUD whitelist path and the lower-confidence generic fallback for
// every other currency. A validated hit always takes priority over a
// fallback hit found on the trade's other currency leg.
NewsDefenseState CheckNewsDefense(string symbol)
  {
   NewsDefenseState state;
   state.active = false; state.reason = ""; state.isValidatedEvent = false;

   string base, quote;
   GetTradeCurrencies(symbol, base, quote);
   if(base == "" || quote == "")
     {
      state.reason = "unable to parse currency legs from symbol";
      return(state);
     }

   string legs[2]; legs[0] = base; legs[1] = quote;
   datetime asOf = TimeCurrent();
   datetime lookbackFrom = asOf - NewsDefenseWindowMinutes*60;
   bool calendarUnavailable = false;

   for(int L = 0; L < 2; L++)
     {
      string currency = legs[L];
      MqlCalendarValue values[];
      int n = GetRecentCalendarEvents(currency, lookbackFrom, asOf, values);
      if(n < 0) { calendarUnavailable = true; continue; } // unavailable for this leg -- not "no events"
      if(n <= 0) continue;

      bool isValidatedCurrency = (currency == "USD" || currency == "AUD");

      for(int i = 0; i < n; i++)
        {
         MqlCalendarEvent ev;
         if(!CalendarEventById((long)values[i].event_id, ev)) continue;

         if(isValidatedCurrency)
           {
            if(IsWhitelistedEvent(ev.name, currency))
              {
               state.active = true;
               state.isValidatedEvent = true;
               state.reason = ev.name + " (" + currency + ")";
               return(state); // validated hit takes priority -- return immediately
              }
           }
         else if(NewsDefenseFallbackForUnvalidatedCurrencies && !state.active)
           {
            if(ev.importance == CALENDAR_IMPORTANCE_HIGH)
              {
               state.active = true;
               state.isValidatedEvent = false;
               state.reason = ev.name + " (" + currency + ") (unvalidated currency -- generic high-importance filter, not the paper's specific list)";
               // don't return -- a validated hit on the OTHER leg, checked
               // in a later loop iteration, must still be able to overwrite this
              }
           }
        }
     }

   if(!state.active && calendarUnavailable) state.reason = "CALENDAR API UNAVAILABLE";
   return(state);
  }

//====================================================================
// ADAPTIVE RISK  (Tasks 6 + 11 gates, combined)
//====================================================================
// LEARNING MACHINE -- graded bonus sizing. Replaces the old binary "gate
// clears -> jump straight to the fixed ceiling" with a bonus that scales
// continuously with the aligned subset's OWN measured expectancy: more
// evidence of real edge earns a bigger bonus, up to the ceiling, rather
// than the ceiling being granted in full the instant the sample-size gate
// merely clears. Still requires the same minTrades gate and positive
// expectancy to unlock at all -- this changes HOW MUCH is earned once
// unlocked, not whether the gate itself can be skipped.
double ComputeLearnedBonus(StatsResult &stats, int minTrades, double bonusCeiling)
  {
   if(stats.sampleSize < minTrades || stats.expectancy <= 0.0) return(1.0); // gate not cleared -- no bonus, full stop
   double maxBonusAboveOne = MathMax(0.0, bonusCeiling - 1.0);
   // Floored at 0 as well as capped at the ceiling: a misconfigured negative
   // BonusLearningRate combined with a cleared, POSITIVE-expectancy gate
   // would otherwise produce a NEGATIVE learnedBonusAboveOne here, returning
   // a multiplier below 1.0 -- silently shrinking risk on a signal that just
   // cleared its edge gate. That would violate this file's own invariant
   // (every engine except News Defense can only ever INCREASE risk, never
   // decrease it), so both directions are clamped explicitly rather than
   // trusting BonusLearningRate's sign.
   double learnedBonusAboveOne = MathMax(0.0, MathMin(maxBonusAboveOne, stats.expectancy * BonusLearningRate));
   return(1.0 + learnedBonusAboveOne);
  }

// Formats a "n=X (need Y) -- INSUFFICIENT SAMPLE" / "... -- EXPECTANCY NOT
// POSITIVE" / "... -- learned bonus N.NNx (ceiling N.NNx)" line, matching
// the file's practice of making a gate's live state visible rather than
// only inferable from whether a bonus silently did or didn't apply. The
// printed multiplier is computed via the exact same ComputeLearnedBonus()
// call ComputeAdaptiveRisk uses, so the dashboard can never show a number
// that isn't what sizing would actually apply right now.
string BuildAlignedStatsLine(string label, StatsResult &s, int minTrades, double bonusCeiling)
  {
   if(s.sampleSize < minTrades)
      return(StringFormat("%s: n=%d (need %d) -- INSUFFICIENT SAMPLE", label, s.sampleSize, minTrades));
   if(s.expectancy <= 0.0)
      return(StringFormat("%s: n=%d, winRate=%.1f%%, expectancy=%.2fR -- EXPECTANCY NOT POSITIVE, bonus INACTIVE",
                           label, s.sampleSize, s.winRate*100.0, s.expectancy));
   double learned = ComputeLearnedBonus(s, minTrades, bonusCeiling);
   return(StringFormat("%s: n=%d, winRate=%.1f%%, expectancy=%.2fR -- learned bonus %.3fx (ceiling %.2fx)",
                        label, s.sampleSize, s.winRate*100.0, s.expectancy, learned, bonusCeiling));
  }

// Shared by both alignment-bonus blocks in ComputeAdaptiveRisk below, so a
// future change to the gating logic itself (e.g. tightening the expectancy
// check, adding a max-drawdown guard) is made once and provably applies to
// every signal that uses this pattern, instead of risking the two blocks
// drifting out of sync from a fix applied to only one of them. "signalAgrees"
// is the caller's own structural-agreement check (trend/classification vs.
// trade direction); this function only owns the statistical gate + learned
// multiply.
void ApplyAlignmentBonus(bool signalAgrees, StatsResult &stats, int minTrades, double bonusCeiling, double &multiplier)
  {
   if(!signalAgrees) return;
   multiplier *= ComputeLearnedBonus(stats, minTrades, bonusCeiling);
  }

double ComputeAdaptiveRisk(string symbol, int direction, bool isFlipReentry = false)
  {
   double multiplier = 1.0;

   // ---- Task 6: VWAP alignment bonus -----------------------------------
   // Structural presence (UseVWAPExit true AND the VWAP trend agreeing
   // with this trade's direction) is necessary but not sufficient. A
   // backtest on one instrument (QQQ/TQQQ) over one historical window
   // (Zarattini & Aziz, SSRN 4631351) is not evidence of edge on whatever
   // this EA actually trades -- a walk-forward critique of this same
   // author's other published work (Massaad et al., arXiv:2412.14361)
   // found exactly this kind of single-window strength repeatedly failing
   // to generalize once tested with a proper rolled 5yr-train/1yr-OOS
   // window, and a general walk-forward validation framework paper (Deep,
   // Deep & Lamptey, arXiv:2512.12924) makes the point explicit: modest,
   // often statistically insignificant results are the NORMAL, expected
   // outcome for interpretable signals under honest out-of-sample testing
   // -- not a failure of the validation. So this bonus additionally
   // requires the VWAP signal's OWN track record (not the file's general
   // journal stats) to clear a real minimum sample with positive
   // expectancy, full stop, regardless of how good the current setup
   // looks or how confident the raw VWAP trend read is.
   if(UseVWAPExit)
     {
      string vwapTrend = ClassifyVWAPTrend(symbol);
      bool vwapAgrees = (direction == 1  && vwapTrend == "BULLISH")
                      || (direction == -1 && vwapTrend == "BEARISH");
      StatsResult vwapStats = ComputeVWAPAlignedStats();
      ApplyAlignmentBonus(vwapAgrees, vwapStats, MinVWAPAlignedTradesForBonus, VWAPAlignmentBonus, multiplier);
     }

   // ---- Task 11: VP-MACD alignment bonus -------------------------------
   // Same gate, same philosophy, applied and earned independently of the
   // VWAP gate above -- this signal has even less external validation
   // behind it (independent-researcher authorship, untested on gold/FX,
   // mixed results even in the paper's own equity backtests: see the
   // VP-MACD engine header comment for the full caveats), so clearing the
   // VWAP gate buys it nothing here.
   if(UseVPMACDEntry)
     {
      string vpMacdSignal = ClassifyVPMACDSignal(symbol);
      bool vpMacdAgrees = (direction == 1  && vpMacdSignal == "BULLISH")
                        || (direction == -1 && vpMacdSignal == "BEARISH");
      StatsResult vpStats = ComputeVPMACDAlignedStats();
      ApplyAlignmentBonus(vpMacdAgrees, vpStats, MinVPMACDAlignedTradesForBonus, VPMACDAlignmentBonus, multiplier);
     }

   // ---- hard bounds: final word regardless of how many bonuses stacked --
   // (Task 11.6: bonuses compound as independent multipliers, but never
   // escape this ceiling/floor.)
   if(multiplier < InpAdaptiveRiskFloor)   multiplier = InpAdaptiveRiskFloor;
   if(multiplier > InpAdaptiveRiskCeiling) multiplier = InpAdaptiveRiskCeiling;

   double riskPct = InpBaseRiskPercent * multiplier;
   if(isFlipReentry && riskPct > InpFlipRiskCapPct) riskPct = InpFlipRiskCapPct;
   if(riskPct > InpMaxRiskPct) riskPct = InpMaxRiskPct;
   return(riskPct);
  }

//====================================================================
// PROVEN RISK-OF-RUIN BOUND (Kelly)
//--------------------------------------------------------------------
// After Busseti, Ryu & Boyd, "Risk-Constrained Kelly Gambling,"
// arXiv:1603.06183 (2016), Section 4, equations 6-7. This is different IN
// KIND from every other check in this file -- it is not a heuristic, a
// proxy, or an approximation calibrated on hope. It is a real, proven
// bound from a stopping-time martingale argument: choose a drawdown
// threshold alpha in (0,1) and a probability tolerance beta in (0,1),
// compute lambda = log(beta)/log(alpha), and if the average of
// (1 + f*R)^(-lambda) over the return distribution is <= 1, the bound
// GUARANTEES the true probability of wealth ever falling below alpha (a
// (1-alpha) drawdown) is less than beta. The authors validated this
// against Monte Carlo simulation and found it conservative by roughly
// 30% -- meaning when it's wrong, it overstates danger, never
// understates it, which is the correct direction to be wrong in for a
// risk gate.
//
// The paper's own setting solves for an optimal bet VECTOR b across many
// simultaneous positions via convex optimization. This file doesn't need
// that: it already has one candidate risk fraction f (from
// ComputeAdaptiveRisk) for one instrument, so this is a direct
// evaluation of the bound against that single fraction using this
// system's own real, logged R-multiples as the empirical return
// distribution -- no solver, no vector optimization, just a pass/fail
// check against real history.
//
// INTEGRATION NOTE: this file has no "FLIP eligibility gate" or
// MonteCarloRuinProbability() function to slot alongside -- neither
// exists anywhere in this codebase, on any branch, as of this writing.
// If a two-factor gate combining this bound with an independent Monte
// Carlo check is wanted, that second check needs its own methodology
// specified before it can be built; fabricating one here would mean
// wiring a real proven bound together with an invented approximation
// and presenting the pair as equally rigorous, which is exactly the
// kind of false confidence this file's whole design exists to avoid.
// Until that's specified, ComputeKellyRuinBound() is exposed as its own
// callable check (see the dashboard line in RunDecision() below) for a
// future entry/exit engine to call directly against its own candidate
// risk fraction, the same "wire your own signal here" pattern used by
// GetCompositeDirection() above.
//====================================================================
struct RuinBoundResult
  {
   bool              available;      // false if sample too small (MinTradesForStats) or RuinBoundAlpha/Beta are outside (0,1) -- never a computed answer from bad inputs
   bool              ruinCertain;    // true if a SINGLE logged loss at this risk fraction would have wiped out (or gone negative on) the tested capital -- distinct from, and more severe than, "bound computed but exceeded 1.0"
   bool              boundSatisfied; // true only when available && !ruinCertain && averageTerm <= 1.0
   double            averageTerm;    // the computed average of (1+f*R)^(-lambda) -- how close to the 1.0 threshold, not just pass/fail. -1.0 when not available.
   double            lambda;         // computed lambda = log(beta)/log(alpha), for display/debugging. -1.0 when not available.
  };

RuinBoundResult ComputeKellyRuinBound(StatsResult &stats, double riskFractionPct)
  {
   RuinBoundResult result;
   result.available = false;
   result.ruinCertain = false;
   result.boundSatisfied = false;
   result.averageTerm = -1.0;
   result.lambda = -1.0;

   // Reuses the same overall sample-size gate as everywhere else in this
   // file (MinTradesForStats) rather than introducing a separate one --
   // never compute a "proven bound" from an inadequate sample and call it
   // real just because the math is real.
   if(stats.sampleSize < MinTradesForStats) return(result);

   // Self-defending guard, independent of MinTradesForStats: that input is
   // user-configurable with no lower bound enforced anywhere, so a
   // misconfigured MinTradesForStats<=0 would let the check above pass
   // with an EMPTY journal (0 < 0 is false). Without this, the sum/n
   // average below divides by n=0 -- IEEE754 gives NaN, which then
   // compares false against every threshold and silently renders as
   // "FAIL" with a meaningless average instead of the honest
   // "unavailable" this represents. Audited and fixed as part of the
   // full-file correctness audit (see the file's engineering log/commit
   // history) -- this is the one confirmed division-by-zero path found.
   if(ArraySize(g_journal) <= 0) return(result);

   // MathLog(RuinBoundAlpha) is undefined at alpha<=0 and MathLog(0) is
   // -inf; either input at or outside the (0,1) boundary makes lambda
   // meaningless (NaN, infinite, or a sign flip that silently inverts the
   // bound). Guard explicitly rather than let a bad input quietly produce
   // garbage that still looks like a number.
   if(RuinBoundAlpha <= 0.0 || RuinBoundAlpha >= 1.0 || RuinBoundBeta <= 0.0 || RuinBoundBeta >= 1.0)
     {
      Print("AUTOPSY X15: RuinBoundAlpha and RuinBoundBeta must both be strictly between 0 and 1 -- refusing to compute a ruin bound from invalid inputs.");
      return(result);
     }

   double lambda = MathLog(RuinBoundBeta) / MathLog(RuinBoundAlpha);
   result.lambda = lambda;

   double f = riskFractionPct / 100.0;
   double sum = 0.0;
   int n = ArraySize(g_journal); // same full-journal iteration ComputeStats() uses

   for(int i = 0; i < n; i++)
     {
      double term = 1.0 + f * g_journal[i].rMultiple;
      if(term <= 0.0)
        {
         // A single historical loss at this risk fraction would have
         // caused outright ruin -- do not raise a non-positive base to a
         // fractional/negative exponent (undefined / NaN in MathPow).
         // This is a distinct, more severe outcome than "bound computed
         // but exceeded 1.0" and is reported as such.
         result.ruinCertain = true;
         result.available = true;
         return(result);
        }
      sum += MathPow(term, -lambda);
     }

   result.averageTerm = sum / n;
   result.boundSatisfied = (result.averageTerm <= 1.0);
   result.available = true;
   return(result);
  }

//====================================================================
// ACCOUNT SAFETY GOVERNOR
//--------------------------------------------------------------------
// Minimal, real daily-loss circuit breaker -- ported and scoped down from
// this repo's own AutopsyX_FlipDemon_Extreme.mq5 / RiskEngine.mqh, which
// has a fuller version (consecutive-loss limits, rolling trade-rate caps,
// spread/margin checks) not duplicated here. This file never had any
// execution path before the pyramiding engine below, so it never needed
// an account-level halt state until now; this is the minimum real one
// that requirement needs, not a claim of parity with the sibling file's
// more complete governor.
//====================================================================
void UpdateDailySafetyGovernor(void)
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime dayStart = TimeCurrent() - (dt.hour*3600 + dt.min*60 + dt.sec);
   if(dayStart != g_dayStartTime)
     {
      g_dayStartTime = dayStart;
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
     }
   if(g_dayStartEquity <= 0.0) g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
  }

bool IsAccountHalted(string &reasonOut)
  {
   reasonOut = "";
   // g_dayStartEquity is only <=0 before UpdateDailySafetyGovernor() has
   // ever run once (e.g. OnInit hasn't ticked yet) -- fail OPEN only in
   // that specific startup instant, never as an ongoing state; OnTick
   // calls UpdateDailySafetyGovernor() before anything else every tick,
   // so this window is at most the first tick of a run.
   if(g_dayStartEquity <= 0.0) return(false);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPct = (g_dayStartEquity - equity) / g_dayStartEquity * 100.0;
   if(lossPct >= DailyLossLimitPercent)
     {
      reasonOut = StringFormat("Daily loss limit reached: -%.2f%% (limit %.2f%%) -- pyramid adds halted for the rest of the day", lossPct, DailyLossLimitPercent);
      return(true);
     }
   return(false);
  }

//====================================================================
// PYRAMIDING ENGINE  (section 21)
//--------------------------------------------------------------------
// Adds to already-open, already-PROFITABLE positions only -- structurally
// the opposite of martingale/averaging-down, which adds to LOSING
// positions to lower the average entry. A position that has never been
// profitable by MinProfitRMultipleToAdd can never receive an add here;
// there is no code path in CheckPyramidEligibility() that reads a
// negative or small-positive R and proceeds anyway.
//
// Every add is sized the SAME way a fresh trade would be sized: fresh
// call to ComputeAdaptiveRisk() against CURRENT account equity at the
// moment of the add, through the same real risk-to-lots math
// (CalculateLotSizeFromRisk, ported from this repo's own already-audited
// RiskEngine.CalculateLotSize) used everywhere else. There is no separate,
// looser, "it's just adding to a winner" sizing path. If the account
// already has more capital at risk elsewhere, or ComputeAdaptiveRisk's
// earned bonuses have since changed, an add can come out SMALLER than
// the original entry was -- that is correct behavior, not a bug, and is
// exactly the mechanism that keeps this from becoming an ever-growing,
// unhedged position the way an unconstrained pyramiding rule would.
//
// Aggregate risk across ALL legs of a pyramided position (not just the
// newest one) is recalculated and capped against InpMaxRiskPct before
// every single add, via ComputeAggregatePyramidRisk() + the cap inside
// SizePyramidAdd() -- an add that would push the WHOLE position's risk
// over that ceiling is shrunk to fit, the same reduce-not-reject
// convention RiskEngine.mqh's own CalculateLotSize() already uses for
// its max-exposure cap.
//
// Adds require FRESH structural confirmation, not merely "price moved
// favorably since the last add" -- but this file does not yet have the
// market-structure/BOS engine (design spec section 5) that language was
// originally written against; that engine has not been built in this
// file as of this writing. What DOES already exist as a genuine,
// discrete, non-persistent EVENT in this file is a VP-MACD crossover
// (CheckVPMACDBuySignal/SellSignal are true only on the bar the
// crossover happens, never on later bars where it's merely still true) --
// so RequireFreshConfirmation uses THAT as the fresh-event source, and
// says so honestly rather than silently treating "structure still
// agrees" as if it were a new signal. If UseVPMACDEntry is off, there is
// currently no other discrete/event-based signal in this file to satisfy
// RequireFreshConfirmation with, and eligibility is refused with a
// specific reason rather than silently falling back to something weaker.
//
// Pyramiding is scoped to NETTING accounts only (checked explicitly
// below) -- it relies on MT5 merging same-direction adds into one
// position with one blended volume/entry/SL, which is netting-account
// behavior. On a hedging account an "add" would open a SEPARATE
// position/ticket instead of merging, which is a materially different
// feature this file does not implement; this matches the sibling
// AutopsyX_FlipDemon_Extreme.mq5's own explicit netting-only design for
// the same underlying reason.
//====================================================================

// Ported from RiskEngine.mqh's NormalizeVolume -- floors to the broker's
// volume step, clamps to [min,max], rounds to the step's own decimal
// precision so the result is a clean, broker-acceptable lot value.
double NormalizeVolumeForSymbol(string symbol, double rawLots)
  {
   double volMin  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double volMax  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double volStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(volStep <= 0.0) volStep = 0.01;

   double vol = MathFloor(rawLots/volStep) * volStep;
   vol = MathMax(volMin, MathMin(volMax, vol));

   int stepDigits = 0;
   double s = volStep;
   while(MathAbs(s - MathRound(s)) > 1e-8 && stepDigits < 8) { s *= 10; stepDigits++; }
   return(NormalizeDouble(vol, stepDigits));
  }

// Ported from RiskEngine.mqh's CalculateLotSize -- risk-percent based,
// real symbol tick size/tick value, never a fixed or martingale-scaled
// formula. stopDistancePrice is a raw PRICE distance (not points); the
// caller is responsible for passing the right one (see SizePyramidAdd's
// comment on which distance is "the add's own stop").
double CalculateLotSizeFromRisk(string symbol, double riskPercent, double stopDistancePrice)
  {
   if(riskPercent <= 0.0 || stopDistancePrice <= 0.0) return(0.0);

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = equity * (riskPercent/100.0);

   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0) return(0.0);

   double valuePerLot = (stopDistancePrice/tickSize) * tickValue;
   if(valuePerLot <= 0.0) return(0.0);

   double lots = riskAmount / valuePerLot;
   // Refuse rather than round UP: NormalizeVolumeForSymbol clamps to the
   // broker's SYMBOL_VOLUME_MIN, so a risk-derived size below that minimum
   // would otherwise silently become a LARGER position than the risk budget
   // allows. (The sibling RiskEngine.mqh's NormalizeVolume has that same
   // clamp-up; it is deliberately not inherited here.)
   double volMin  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double volStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(volStep <= 0.0) volStep = 0.01;
   if(MathFloor(lots/volStep + 1e-9) * volStep < volMin - 1e-12) return(0.0);
   return(NormalizeVolumeForSymbol(symbol, lots));
  }

// Authoritative pyramid-add count for a position, derived from real MT5
// deal history rather than a broker comment string. DEAL_ENTRY_IN counts
// every volume-increasing deal on this position's identifier -- the
// original entry plus every same-direction add -- so add count = this - 1.
// (A human-readable "PYR:N" tag is still written into each order's
// comment via BuildPyramidComment() below, for visibility in the
// terminal's own position list -- but it is NOT what this file trusts as
// the count, since whether a broker/terminal reliably surfaces an
// UPDATED comment on a merged netting position across multiple orders is
// not something verifiable without a live MT5 terminal, which this
// environment does not have. Deriving the count from deal history instead
// sidesteps that uncertainty entirely and survives an EA/terminal restart
// natively, since deal history is the broker's own permanent record.)
int CountPositionEntryDeals(ulong positionIdentifier)
  {
   if(!HistorySelectByPosition((long)positionIdentifier)) return(0);
   int total = HistoryDealsTotal();
   int count = 0;
   for(int i = 0; i < total; i++)
     {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;
      long entryType = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if(entryType == DEAL_ENTRY_IN) count++;
     }
   return(count);
  }

string BuildPyramidComment(int addNumber)
  {
   return(StringFormat("X15 PYR:%d", addNumber));
  }

// Volume-weighted average price across every DEAL_ENTRY_IN deal on this
// position's identifier -- the original entry plus every same-direction
// add, each weighted by its own volume. This IS the aggregate position's
// true entry basis on a netting account (MT5 computes POSITION_PRICE_OPEN
// the same way for the still-open case; this recomputes it from deal
// history so it's also available for a position that has already closed,
// which is what AppendJournalFromClosedPosition below needs it for).
// Returns -1.0 if there is no usable deal history -- callers must not
// treat that as "entry price zero."
double ComputeBlendedEntryPrice(ulong positionIdentifier)
  {
   if(!HistorySelectByPosition((long)positionIdentifier)) return(-1.0);
   int total = HistoryDealsTotal();
   double sumPriceVolume = 0.0, sumVolume = 0.0;
   for(int i = 0; i < total; i++)
     {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;
      long entryType = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if(entryType != DEAL_ENTRY_IN) continue; // original entry + adds only -- never an OUT/OUT_BY/INOUT (closing/reversal) deal
      double dealVolume = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
      double dealPrice  = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
      sumPriceVolume += dealPrice * dealVolume;
      sumVolume      += dealVolume;
     }
   if(sumVolume <= 0.0) return(-1.0);
   return(sumPriceVolume / sumVolume);
  }

// Best-effort, NOT authoritative (see CountPositionEntryDeals's comment
// above) -- provided for symmetry with the task's original comment-
// tagging request and for display purposes only.
int ExtractPyramidCountFromComment(string comment)
  {
   int pos = StringFind(comment, "PYR:");
   if(pos < 0) return(-1);
   string tail = StringSubstr(comment, pos + 4);
   return((int)StringToInteger(tail));
  }

struct AggregatePyramidRisk
  {
   double totalLots;
   double blendedEntryPrice;
   double totalRiskAmount;         // account-currency $ at risk to the position's CURRENT SL, across its full current volume
   double totalRiskPercentOfEquity;
  };

// On a netting account MT5 already merges every same-direction add into
// ONE position record with one blended volume and one blended entry
// price -- PositionGetDouble() returns that aggregate directly. This
// function does not need to re-derive it deal-by-deal; it exists to turn
// that already-aggregate state into the risk-percent figure the pre-add
// cap check (inside SizePyramidAdd) needs.
AggregatePyramidRisk ComputeAggregatePyramidRisk(ulong positionTicket)
  {
   AggregatePyramidRisk agg;
   agg.totalLots = 0.0; agg.blendedEntryPrice = 0.0;
   agg.totalRiskAmount = 0.0; agg.totalRiskPercentOfEquity = 0.0;

   if(!PositionSelectByTicket(positionTicket)) return(agg);
   agg.totalLots = PositionGetDouble(POSITION_VOLUME);
   agg.blendedEntryPrice = PositionGetDouble(POSITION_PRICE_OPEN);

   double slPrice = PositionGetDouble(POSITION_SL);
   if(slPrice == 0.0) return(agg); // no SL -- risk undefined, leave totals at 0 rather than guess

   long posType = PositionGetInteger(POSITION_TYPE);
   int direction = (posType == POSITION_TYPE_BUY) ? 1 : -1;
   double riskDistancePrice = (direction == 1) ? (agg.blendedEntryPrice - slPrice) : (slPrice - agg.blendedEntryPrice);
   if(riskDistancePrice <= 0.0) return(agg);

   string symbol = PositionGetString(POSITION_SYMBOL);
   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0) return(agg);

   agg.totalRiskAmount = (riskDistancePrice/tickSize) * tickValue * agg.totalLots;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > 0.0) agg.totalRiskPercentOfEquity = (agg.totalRiskAmount/equity) * 100.0;

   return(agg);
  }

struct PyramidEligibility
  {
   bool   eligible;
   string reason;
  };

PyramidEligibility CheckPyramidEligibility(ulong positionTicket)
  {
   PyramidEligibility result;
   result.eligible = false;
   result.reason = "";

   if(!AllowPyramiding) { result.reason = "AllowPyramiding is OFF"; return(result); }

   string haltReason;
   if(IsAccountHalted(haltReason)) { result.reason = haltReason; return(result); }

   if(!PositionSelectByTicket(positionTicket)) { result.reason = "position not found"; return(result); }

   string symbol = PositionGetString(POSITION_SYMBOL);
   long posType = PositionGetInteger(POSITION_TYPE);
   int direction = (posType == POSITION_TYPE_BUY) ? 1 : -1;
   double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double slPrice = PositionGetDouble(POSITION_SL);
   double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);

   if(slPrice == 0.0) { result.reason = "no SL on this position -- undefined risk basis, cannot evaluate profit in R"; return(result); }

   double riskDistance = (direction == 1) ? (entryPrice - slPrice) : (slPrice - entryPrice);
   if(riskDistance <= 0.0) { result.reason = "SL on the wrong side of entry -- undefined risk basis"; return(result); }

   double currentR = (direction == 1) ? (currentPrice - entryPrice)/riskDistance : (entryPrice - currentPrice)/riskDistance;
   if(currentR < MinProfitRMultipleToAdd)
     {
      result.reason = StringFormat("position at %.2fR, needs >= %.2fR to add", currentR, MinProfitRMultipleToAdd);
      return(result);
     }

   int addsSoFar = CountPositionEntryDeals((ulong)PositionGetInteger(POSITION_IDENTIFIER)) - 1; // identifier, not ticket: they diverge after a netting reversal
   if(addsSoFar < 0) addsSoFar = 0;
   if(addsSoFar >= MaxPyramidAdds)
     {
      result.reason = StringFormat("already at max adds (%d/%d)", addsSoFar, MaxPyramidAdds);
      return(result);
     }

   if(RequireFreshConfirmation)
     {
      if(!UseVPMACDEntry)
        {
         result.reason = "RequireFreshConfirmation needs UseVPMACDEntry enabled -- no other discrete, event-based confirmation signal exists in this file yet";
         return(result);
        }
      bool freshBuy  = CheckVPMACDBuySignal(symbol);
      bool freshSell = CheckVPMACDSellSignal(symbol);
      bool freshConfirmed = (direction == 1 && freshBuy) || (direction == -1 && freshSell);
      if(!freshConfirmed)
        {
         result.reason = "no fresh VP-MACD crossover confirmation in the position's direction on this bar";
         return(result);
        }
     }

   result.eligible = true;
   result.reason = "eligible";
   return(result);
  }

// Sizes one add exactly like a fresh trade would be sized -- see the
// engine header comment above for why. The stop distance used here is
// CURRENT PRICE to the position's EXISTING SL, not the original entry's
// distance: this reflects what the NEW lot itself would actually lose if
// stopped out from where it's about to fill, which is the risk this
// specific add introduces, not the risk the position as a whole has
// already proven it can absorb.
double SizePyramidAdd(ulong positionTicket, string symbol, int direction)
  {
   if(!PositionSelectByTicket(positionTicket)) return(0.0);
   double slPrice = PositionGetDouble(POSITION_SL);
   if(slPrice == 0.0) return(0.0);

   double currentPrice = SymbolInfoDouble(symbol, direction == 1 ? SYMBOL_ASK : SYMBOL_BID);
   if(currentPrice <= 0.0) return(0.0);

   double stopDistancePrice = (direction == 1) ? (currentPrice - slPrice) : (slPrice - currentPrice);
   if(stopDistancePrice <= 0.0) return(0.0); // current price is already through the existing SL -- do not add

   double riskPct = ComputeAdaptiveRisk(symbol, direction, false); // false: an add is not a flip re-entry
   double rawLots = CalculateLotSizeFromRisk(symbol, riskPct, stopDistancePrice);
   if(rawLots <= 0.0) return(0.0);

   // Aggregate-risk cap: if adding rawLots would push the WHOLE position's
   // risk-to-current-SL over InpMaxRiskPct, shrink the add to fit rather
   // than reject it outright -- the same reduce-not-reject convention
   // RiskEngine.mqh's own CalculateLotSize() already uses for its max-
   // exposure cap (MathMin(lots, m_maxExposureLots)).
   AggregatePyramidRisk aggBefore = ComputeAggregatePyramidRisk(positionTicket);
   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0) return(0.0);

   double addRiskAmount = (stopDistancePrice/tickSize) * tickValue * rawLots;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0.0) return(0.0);

   double projectedTotalRiskPct = ((aggBefore.totalRiskAmount + addRiskAmount) / equity) * 100.0;
   if(projectedTotalRiskPct > InpMaxRiskPct)
     {
      double allowedAddRiskAmount = MathMax(0.0, equity*(InpMaxRiskPct/100.0) - aggBefore.totalRiskAmount);
      double allowedAddRiskPct = (allowedAddRiskAmount/equity) * 100.0;
      rawLots = CalculateLotSizeFromRisk(symbol, allowedAddRiskPct, stopDistancePrice);
     }

   return(rawLots);
  }

struct PyramidAddResult
  {
   bool   sent;         // true only if a LIVE order was actually confirmed placed
   bool   isPaper;
   double lots;
   double price;
   string errorReason;
  };

PyramidAddResult SendPyramidAdd(ulong positionTicket)
  {
   PyramidAddResult result;
   result.sent = false; result.isPaper = !ExecutionModeLive;
   result.lots = 0.0; result.price = 0.0; result.errorReason = "";

   if(!PositionSelectByTicket(positionTicket)) { result.errorReason = "position not found"; return(result); }
   string symbol = PositionGetString(POSITION_SYMBOL);
   long posType = PositionGetInteger(POSITION_TYPE);
   int direction = (posType == POSITION_TYPE_BUY) ? 1 : -1;
   double existingSl = PositionGetDouble(POSITION_SL);
   double existingTp = PositionGetDouble(POSITION_TP);

   double addLots = SizePyramidAdd(positionTicket, symbol, direction);
   if(addLots <= 0.0)
     {
      result.errorReason = "sized add rounds to zero lots (risk too small relative to the volume step, or the aggregate risk cap is already saturated)";
      return(result);
     }

   int addsSoFar = CountPositionEntryDeals((ulong)PositionGetInteger(POSITION_IDENTIFIER)) - 1; // identifier, not ticket: they diverge after a netting reversal
   if(addsSoFar < 0) addsSoFar = 0;
   string comment = BuildPyramidComment(addsSoFar + 1);
   result.lots = addLots;

   if(!ExecutionModeLive)
     {
      PrintFormat("AUTOPSY X15 [PAPER]: would add %.2f lots to %s position %I64u (%s), preserving SL=%.5f TP=%.5f, comment='%s'. Nothing sent -- ExecutionModeLive=false.",
                  addLots, symbol, positionTicket, direction == 1 ? "BUY" : "SELL", existingSl, existingTp, comment);
      return(result);
     }

   // LIVE: a real order. existingSl/existingTp are passed through EXACTLY
   // as read above, unchanged -- CRITICAL, not cosmetic. On a netting
   // account, the SL/TP carried on ANY order against a symbol with an
   // already-open position typically becomes that position's new SL/TP.
   // Passing anything other than the position's own current values here
   // would be a real, silent way to lose stop-loss protection on the
   // WHOLE blended position because of an add meant to only add volume.
   bool ok = (direction == 1)
             ? g_trade.Buy(addLots, symbol, 0.0, existingSl, existingTp, comment)
             : g_trade.Sell(addLots, symbol, 0.0, existingSl, existingTp, comment);

   if(!ok)
     {
      result.errorReason = StringFormat("OrderSend failed: %u %s", g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
      PrintFormat("AUTOPSY X15 [LIVE]: pyramid add FAILED for position %I64u: %s", positionTicket, result.errorReason);
      return(result);
     }

   result.sent = true;
   result.price = g_trade.ResultPrice();
   PrintFormat("AUTOPSY X15 [LIVE]: pyramid add SENT for position %I64u: %.2f lots %s %s @ ~%.5f, SL=%.5f TP=%.5f, comment='%s'.",
               positionTicket, addLots, symbol, direction == 1 ? "BUY" : "SELL", result.price, existingSl, existingTp, comment);
   return(result);
  }

// Called once per new bar from OnTick (see LIFECYCLE below) -- scans this
// symbol's currently open positions, checks eligibility, and sends any
// eligible add. Netting-account-only (see engine header comment).
void ProcessPyramidOpportunities(void)
  {
   if(!AllowPyramiding) return;

   long marginMode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(marginMode != ACCOUNT_MARGIN_MODE_RETAIL_NETTING) return;

   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(InpMagicNumberFilter != 0 && (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumberFilter) continue;

      PyramidEligibility elig = CheckPyramidEligibility(ticket);
      if(!elig.eligible) continue;

      SendPyramidAdd(ticket);
     }
  }

//====================================================================
// EXTENSION POINT -- wire your own entry/regime/structure signal here.
// This file provides the adaptive-risk gating layer, not full signal
// generation or order placement (see the file header). Returns 1/-1 for
// a directional call, 0 for no signal.
//====================================================================
int GetCompositeDirection(string symbol)
  {
   return(0); // stub -- deliberately no opinion. Wire real entry logic here.
  }

// Task 16 -- suppression layer, wrapping GetCompositeDirection(). This is
// the ONLY place News Defense ever touches trade direction, and it only
// ever turns a signal INTO 0 (no new trade) -- it can never manufacture a
// direction of its own. It has no code path anywhere that references,
// manages, or closes an existing position, and GetCompositeDirection()
// itself is a stub that never fires a real new-position order (see its
// own comment above) -- so this function's own "existing positions must
// still be managed safely" requirement holds by construction. The one
// place in this file that DOES send a real order is the Pyramiding
// Engine below, which is a completely separate code path (its own
// eligibility gate, its own execution function) that this function never
// calls into and has no influence over.
int GetGatedEntryDirection(string symbol)
  {
   int rawDirection = GetCompositeDirection(symbol);
   if(rawDirection == 0) return(0);

   if(UseNewsDefense)
     {
      NewsDefenseState news = CheckNewsDefense(symbol);
      if(news.active) return(0); // suppress the NEW entry only
     }
   return(rawDirection);
  }

//====================================================================
// TRADE LIFECYCLE -- journal population
//====================================================================
int FindOpenMetaIndex(ulong ticket)
  {
   for(int i = 0; i < ArraySize(g_openMeta); i++)
      if(g_openMeta[i].ticket == ticket) return(i);
   return(-1);
  }

void RemoveOpenMetaAt(int idx)
  {
   int n = ArraySize(g_openMeta);
   for(int i = idx; i < n - 1; i++) g_openMeta[i] = g_openMeta[i+1];
   ArrayResize(g_openMeta, n - 1);
  }

// Captures the VWAP/VP-MACD/News alignment reads AT ENTRY (frozen for the
// trade's life) plus the entry price and SL actually set on the position,
// which is the real risk basis used to compute the closed trade's
// R-multiple later.
//
// isPreExisting: true when this ticket was already open the very first
// time this EA ever synced positions (i.e. it existed before this run
// started -- attached to a chart with a position already open, or a
// terminal/EA restart mid-trade). In that case "at entry" is unknowable:
// reading the signals NOW would silently violate the "captured at entry,
// frozen" invariant every alignment stat in this file depends on, by
// stamping a position with a signal read from hours or days after it
// actually opened. Rather than fabricate that, all three alignment flags
// are forced false (== "unknown," same convention as an unavailable
// signal) and this is logged plainly rather than done silently.
void RecordEntryMeta(ulong ticket, bool isPreExisting)
  {
   if(!PositionSelectByTicket(ticket)) return;

   OpenPositionMeta meta;
   meta.ticket         = ticket;
   long posType        = PositionGetInteger(POSITION_TYPE);
   meta.direction       = (posType == POSITION_TYPE_BUY) ? 1 : -1;
   meta.entryPrice      = PositionGetDouble(POSITION_PRICE_OPEN);
   meta.slPriceAtEntry  = PositionGetDouble(POSITION_SL);

   if(isPreExisting)
     {
      meta.vwapAligned = false;
      meta.vpMacdAligned = false;
      meta.nearValidatedNewsEvent = false;
      meta.newsEventNameAtEntry = "";
      PrintFormat("AUTOPSY X15: position %I64u was already open when this EA started tracking -- its true entry-time signal state is unknown, so VWAP/VP-MACD/news alignment are recorded as unknown (false) rather than read from the CURRENT signal state.", ticket);
     }
   else
     {
      string symbol = PositionGetString(POSITION_SYMBOL);

      string vwapClass = UseVWAPExit ? ClassifyVWAPTrend(symbol) : "NEUTRAL";
      meta.vwapAligned = (meta.direction == 1  && vwapClass == "BULLISH")
                      || (meta.direction == -1 && vwapClass == "BEARISH");
      // NEUTRAL (whether genuinely flat or unavailable) never matches BULLISH/
      // BEARISH above, so meta.vwapAligned is false in both cases -- satisfies
      // "log as unknown/false rather than guessing" without a separate branch.

      string vpMacdClass = UseVPMACDEntry ? ClassifyVPMACDSignal(symbol) : "NEUTRAL";
      meta.vpMacdAligned = (meta.direction == 1  && vpMacdClass == "BULLISH")
                        || (meta.direction == -1 && vpMacdClass == "BEARISH");

      // Task 17 -- computed unconditionally (NOT gated behind UseNewsDefense
      // the way the two alignment reads above are gated behind their own
      // engine toggles): this is a pure observation for later comparison,
      // not an action-triggering read, so it needs to keep accumulating
      // data even while News Defense's suppression is toggled during testing.
      NewsDefenseState newsAtEntry = CheckNewsDefense(symbol);
      meta.nearValidatedNewsEvent = newsAtEntry.isValidatedEvent; // false unless a validated whitelist event actually matched -- never guessed true
      // Learning-machine extension -- only captures the specific name for a
      // VALIDATED hit (never the generic fallback's synthetic reason string),
      // so ComputePerEventStats()'s breakdown stays scoped to the paper's
      // actual named events rather than mixing in unrelated fallback text.
      meta.newsEventNameAtEntry = (newsAtEntry.active && newsAtEntry.isValidatedEvent) ? SanitizeForCsv(newsAtEntry.reason) : "";
     }

   int idx = ArraySize(g_openMeta);
   ArrayResize(g_openMeta, idx + 1);
   g_openMeta[idx] = meta;
  }

//====================================================================
// LEARNING MACHINE -- PERSISTENCE
//--------------------------------------------------------------------
// The journal itself IS the model: every gate, every learned bonus, every
// per-event stat in this file is recomputed fresh from g_journal on every
// call, nothing is cached separately. So making the journal durable is
// all persistence has to do -- there is no second piece of "learned
// state" that could ever go stale against it. Written the same way
// TradeAutopsy-style CSV logs elsewhere in this repo are: FileOpen with
// no FILE_COMMON flag, so it stays in this terminal's own sandboxed
// MQL5/Files folder, never a machine-wide shared one.
//====================================================================
// The one field in JournalEntry that ever holds uncontrolled external text
// is newsEventNameAtEntry (sourced from the broker's Economic Calendar,
// which this file does not control the formatting of). Every other field
// is either numeric or a value this file itself constructs (symbol,
// "BULLISH"/"BEARISH"/"NEUTRAL", etc.). Sanitizing at the single point
// that field enters the journal (RecordEntryMeta, below) means the CSV
// round-trip never has to trust that a calendar event name is free of the
// delimiter -- a comma or embedded newline in an event title would
// otherwise misalign every field after it for the rest of the reloaded
// file, corrupting closeTime/direction/rMultiple/alignment flags for every
// later row and silently feeding garbage into ComputeLearnedBonus.
string SanitizeForCsv(string s)
  {
   StringReplace(s, ",", ";");
   StringReplace(s, "\n", " ");
   StringReplace(s, "\r", " ");
   return(s);
  }

string GetJournalFileName(void)
  {
   if(JournalFileNameOverride != "") return(JournalFileNameOverride);
   return("AutopsyX15_Journal_" + _Symbol + ".csv");
  }

// Rewrites the WHOLE file from g_journal every time it's called (rather
// than appending), which trades a little I/O for a much simpler
// correctness argument: g_journal in memory is always the single source
// of truth, so the file can never drift from it or accumulate a
// malformed trailing row from an interrupted append. Trade volume this
// file expects (per-trade closes, not per-tick) keeps that O(n) rewrite
// cheap in practice -- even several thousand rows is a sub-millisecond
// write. If this journal is ever run somewhere that accumulates far
// more history than that, this rewrite-per-close approach is the first
// thing to revisit; it was chosen for correctness-simplicity, not scale.
//
// Writes to a TEMPORARY file first and only replaces the real journal via
// FileMove once that write has fully succeeded -- writing directly to
// the real file with FILE_WRITE would truncate it to zero bytes before a
// single row is rewritten, so a crash or power loss mid-write (exactly
// the "VPS reboot" scenario this feature exists to survive) would leave
// the on-disk journal empty or partial instead of just missing the one
// newest trade. With the temp-file approach, the real file is only ever
// touched by one atomic-ish rename once a complete, valid replacement
// already exists on disk -- an interruption during the write leaves the
// previous, fully-intact journal untouched.
void SaveJournalToFile(void)
  {
   if(!UsePersistentJournal) return;
   string fname    = GetJournalFileName();
   string tmpFname = fname + ".tmp";

   int handle = FileOpen(tmpFname, FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_SHARE_READ, ',');
   if(handle == INVALID_HANDLE)
     {
      PrintFormat("AUTOPSY X15: could not open temp journal file '%s' for writing (error %d) -- learned state will NOT persist past this session.", tmpFname, GetLastError());
      return;
     }
   int n = ArraySize(g_journal);
   for(int i = 0; i < n; i++)
      FileWrite(handle, (long)g_journal[i].closeTime, g_journal[i].symbol, g_journal[i].direction,
                g_journal[i].rMultiple, g_journal[i].vwapAligned?1:0, g_journal[i].vpMacdAligned?1:0,
                g_journal[i].nearValidatedNewsEvent?1:0, g_journal[i].newsEventNameAtEntry);
   FileClose(handle);

   if(!FileMove(tmpFname, 0, fname, FILE_REWRITE))
      PrintFormat("AUTOPSY X15: wrote temp journal file '%s' but could not move it into place as '%s' (error %d) -- the previous on-disk journal is untouched, but this session's newest trade did not persist.", tmpFname, fname, GetLastError());
  }

// Called once from OnInit, before any new trade is processed this run.
// Replaces g_journal wholesale with whatever was on disk (or leaves it
// empty if there's nothing there yet / persistence is off) -- this always
// runs before SyncOpenPositions' first pass, so a position that was
// already open at startup is still correctly handled as isPreExisting
// regardless of what history was just loaded.
void LoadJournalFromFile(void)
  {
   ArrayResize(g_journal, 0);
   if(!UsePersistentJournal) return;

   string fname = GetJournalFileName();
   if(!FileIsExist(fname))
     {
      PrintFormat("AUTOPSY X15: no existing journal file '%s' -- starting with an empty learned track record.", fname);
      return;
     }

   int handle = FileOpen(fname, FILE_READ|FILE_CSV|FILE_ANSI|FILE_SHARE_READ, ',');
   if(handle == INVALID_HANDLE)
     {
      PrintFormat("AUTOPSY X15: found journal file '%s' but could not open it for reading (error %d) -- starting empty rather than guessing its contents.", fname, GetLastError());
      return;
     }

   int loaded = 0;
   while(!FileIsEnding(handle))
     {
      long closeTimeRaw = (long)FileReadNumber(handle);
      if(FileIsEnding(handle)) break; // trailing blank line at EOF -- stop cleanly rather than parse a partial row

      JournalEntry entry;
      entry.closeTime               = (datetime)closeTimeRaw;
      entry.symbol                  = FileReadString(handle);
      entry.direction               = (int)FileReadNumber(handle);
      entry.rMultiple               = FileReadNumber(handle);
      entry.vwapAligned             = (FileReadNumber(handle) != 0);
      entry.vpMacdAligned           = (FileReadNumber(handle) != 0);
      entry.nearValidatedNewsEvent  = (FileReadNumber(handle) != 0);
      entry.newsEventNameAtEntry    = FileReadString(handle);

      int idx = ArraySize(g_journal);
      ArrayResize(g_journal, idx + 1);
      g_journal[idx] = entry;
      loaded++;
     }
   FileClose(handle);
   PrintFormat("AUTOPSY X15: loaded %d journal entries from disk -- learned state carries over from before this run.", loaded);
  }

// Sums realized P&L for a fully-closed position via its deal history, then
// converts to an R-multiple using the SL distance captured at entry. If no
// SL was set at entry, the risk basis is undefined -- the trade is NOT
// journaled for stats purposes rather than fabricating a risk basis for it.
void AppendJournalFromClosedPosition(OpenPositionMeta &meta)
  {
   if(meta.slPriceAtEntry == 0.0)
     {
      PrintFormat("AUTOPSY X15: position %I64u closed with no SL recorded at entry -- skipping journal entry (undefined risk basis, not fabricated).", meta.ticket);
      return;
     }

   if(!HistorySelectByPosition((long)meta.ticket)) return;
   int total = HistoryDealsTotal();
   double sumExitPriceVolume = 0.0, sumExitVolume = 0.0;
   datetime closeTime = 0;
   bool found = false;
   for(int i = 0; i < total; i++)
     {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;
      long entryType = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      // OUT / OUT_BY covers ordinary and closed-by-opposite-order closes;
      // INOUT covers a netting-account flip (close old direction + open new
      // one in the same deal) -- all three are "this deal closed some or all
      // of the position we're journaling," and are volume-weighted together
      // below so a scaled-out close (multiple OUT deals at different prices)
      // doesn't get reduced to just its last exit price.
      if(entryType != DEAL_ENTRY_OUT && entryType != DEAL_ENTRY_OUT_BY && entryType != DEAL_ENTRY_INOUT) continue;
      double dealVolume = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
      double dealPrice  = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
      sumExitPriceVolume += dealPrice * dealVolume;
      sumExitVolume       += dealVolume;
      closeTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME); // last matching deal's time -- the moment the position actually reached flat
      found = true;
     }
   if(!found || sumExitVolume <= 0.0) return;
   double closePrice = sumExitPriceVolume / sumExitVolume; // volume-weighted across every exit/flip deal, not just the last one

   // AGGREGATE entry basis, not just the original leg: if this position
   // received pyramid adds, meta.entryPrice is only the FIRST leg's price.
   // ComputeBlendedEntryPrice() volume-weights across every DEAL_ENTRY_IN
   // deal (original entry + every add), so a position that was pyramided
   // gets journaled against its true blended entry -- the R-multiple this
   // file logs (and every stat/bonus computed from the journal downstream)
   // reflects the whole aggregate position, not an artifact of only ever
   // looking at where it first opened. Falls back to meta.entryPrice if
   // deal history is unavailable (e.g. very old closed history pruned by
   // the terminal) rather than skipping the journal entry outright.
   double entryPriceForR = ComputeBlendedEntryPrice(meta.ticket);
   if(entryPriceForR <= 0.0) entryPriceForR = meta.entryPrice;

   double riskDistance = (meta.direction == 1)
                          ? (entryPriceForR - meta.slPriceAtEntry)
                          : (meta.slPriceAtEntry - entryPriceForR);
   if(riskDistance <= 0.0)
     {
      PrintFormat("AUTOPSY X15: position %I64u had a non-positive risk distance (SL on the wrong side of entry?) -- skipping journal entry.", meta.ticket);
      return;
     }

   double rMultiple = (meta.direction == 1)
                       ? (closePrice - entryPriceForR) / riskDistance
                       : (entryPriceForR - closePrice) / riskDistance;

   JournalEntry entry;
   entry.closeTime     = closeTime;
   entry.symbol        = _Symbol;
   entry.direction     = meta.direction;
   entry.rMultiple     = rMultiple;
   entry.vwapAligned   = meta.vwapAligned;
   entry.vpMacdAligned = meta.vpMacdAligned;
   entry.nearValidatedNewsEvent = meta.nearValidatedNewsEvent;
   entry.newsEventNameAtEntry   = meta.newsEventNameAtEntry;

   int idx = ArraySize(g_journal);
   ArrayResize(g_journal, idx + 1);
   g_journal[idx] = entry;

   SaveJournalToFile(); // learning-machine persistence -- every closed trade is durable the instant it's journaled, not just for the rest of this session
  }

// Polling-based sync, called once per tick: cheap at single-symbol EA
// scale, and avoids depending on the finer edge cases of
// OnTradeTransaction's deal-type semantics for something this file can't
// compile-verify. Picks up ANY open position on this symbol (filtered by
// InpMagicNumberFilter if set) regardless of what opened it -- a human, a
// different EA, or a future entry engine wired into GetCompositeDirection().
void SyncOpenPositions(void)
  {
   // 1) discover currently-open tickets on this symbol/magic scope
   ulong liveTickets[];
   int liveCount = 0;
   int total = PositionsTotal();
   ArrayResize(liveTickets, total);
   for(int i = 0; i < total; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(InpMagicNumberFilter != 0 && (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumberFilter) continue;
      liveTickets[liveCount] = ticket;
      liveCount++;
     }

   // 2) any live ticket not yet tracked -> capture entry meta. On the very
   // first sync of this run, every live ticket found is by definition
   // PRE-EXISTING (this EA hasn't been running long enough to have opened
   // or watched anything open yet) -- RecordEntryMeta() handles that case
   // by recording unknown/false alignment instead of reading current
   // signal state as if it were the entry-time read. g_firstSyncDone flips
   // once, after this pass, so every later newly-discovered ticket is
   // treated as a genuine new entry.
   for(int i = 0; i < liveCount; i++)
     {
      if(FindOpenMetaIndex(liveTickets[i]) < 0)
         RecordEntryMeta(liveTickets[i], !g_firstSyncDone);
     }
   g_firstSyncDone = true;

   // 3) any tracked ticket no longer live -> closed, journal it and drop it
   for(int i = ArraySize(g_openMeta) - 1; i >= 0; i--)
     {
      bool stillLive = false;
      for(int j = 0; j < liveCount; j++)
         if(liveTickets[j] == g_openMeta[i].ticket) { stillLive = true; break; }
      if(!stillLive)
        {
         AppendJournalFromClosedPosition(g_openMeta[i]);
         RemoveOpenMetaAt(i);
        }
     }
  }

//====================================================================
// REPORTING  (Task 10)
//====================================================================
string RunDecision(void)
  {
   string s = "";
   s += "AUTOPSY X FLIPDEMON X15 -- " + _Symbol + " " + EnumToString((ENUM_TIMEFRAMES)Period()) + "\n";
   s += TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES) + "\n";
   s += "----------------------------------------\n";

   StatsResult overall = ComputeStats();
   s += StringFormat("Journal: n=%d, winRate=%.1f%%, expectancy=%.2fR -- %s\n",
                      overall.sampleSize,
                      (overall.sampleSize > 0 ? overall.winRate*100.0 : 0.0),
                      (overall.sampleSize > 0 ? overall.expectancy : 0.0),
                      EvaluateOverallGate(overall));

   // Proven Kelly ruin bound (Busseti, Ryu & Boyd, arXiv:1603.06183),
   // evaluated at the configured base risk fraction as a representative
   // reference point -- not wired into any entry/exit decision here (see
   // this function's header comment for why). A future entry engine
   // should call ComputeKellyRuinBound() directly against its own
   // ACTUAL candidate risk fraction (from ComputeAdaptiveRisk) before
   // firing, not rely on this dashboard line, which is informational only.
   RuinBoundResult ruinBound = ComputeKellyRuinBound(overall, InpBaseRiskPercent);
   if(!ruinBound.available)
      s += StringFormat("Kelly ruin bound: n=%d (need %d), or alpha/beta invalid -- UNAVAILABLE\n", overall.sampleSize, MinTradesForStats);
   else if(ruinBound.ruinCertain)
      s += StringFormat("Kelly ruin bound: RUIN CERTAIN AT %.2f%% RISK -- a single logged loss would exceed capital\n", InpBaseRiskPercent);
   else if(ruinBound.boundSatisfied)
      s += StringFormat("Kelly ruin bound: PASS (avg=%.3f, need <=1.0) at %.2f%% risk -- Prob(drawdown past %.0f%%) < %.0f%% is proven, not estimated\n",
                         ruinBound.averageTerm, InpBaseRiskPercent, (1.0-RuinBoundAlpha)*100.0, RuinBoundBeta*100.0);
   else
      s += StringFormat("Kelly ruin bound: FAIL (avg=%.3f, need <=1.0) at %.2f%% risk -- bound does NOT guarantee Prob(drawdown past %.0f%%) < %.0f%%\n",
                         ruinBound.averageTerm, InpBaseRiskPercent, (1.0-RuinBoundAlpha)*100.0, RuinBoundBeta*100.0);

   s += "VWAP trend: " + (UseVWAPExit ? ClassifyVWAPTrend(_Symbol) : "DISABLED (UseVWAPExit=false)") + "\n";
   if(UseVWAPExit)
     {
      StatsResult vwapStats = ComputeVWAPAlignedStats();
      s += BuildAlignedStatsLine("VWAP-aligned trades", vwapStats, MinVWAPAlignedTradesForBonus, VWAPAlignmentBonus) + "\n";
     }

   s += "VP-MACD signal: " + (UseVPMACDEntry ? ClassifyVPMACDSignal(_Symbol) : "DISABLED (UseVPMACDEntry=false)") + "\n";
   if(UseVPMACDEntry)
     {
      StatsResult vpStats = ComputeVPMACDAlignedStats();
      s += BuildAlignedStatsLine("VP-MACD-aligned trades", vpStats, MinVPMACDAlignedTradesForBonus, VPMACDAlignmentBonus) + "\n";
     }

   if(UseNewsDefense)
     {
      NewsDefenseState news = CheckNewsDefense(_Symbol);
      if(news.reason == "CALENDAR API UNAVAILABLE")
         s += "News Defense: CALENDAR API UNAVAILABLE\n";
      else if(news.active)
         s += "News Defense: ACTIVE -- " + (news.isValidatedEvent ? "[VALIDATED] " : "[UNVALIDATED FALLBACK] ") + news.reason + " -- new entries suppressed, existing positions untouched\n";
      else
         s += "News Defense: CLEAR\n";
     }
   else
     {
      s += "News Defense: DISABLED (UseNewsDefense=false)\n";
     }

   NewsProximityStats newsProx = ComputeNewsProximityStats();
   if(newsProx.near.sampleSize < MinTradesForStats || newsProx.away.sampleSize < MinTradesForStats)
      s += StringFormat("Trades near validated news events: n=%d, away: n=%d -- INSUFFICIENT SAMPLE (need %d each)\n",
                         newsProx.near.sampleSize, newsProx.away.sampleSize, MinTradesForStats);
   else
      s += StringFormat("Trades near validated news events: n=%d, expectancy=%.2fR vs. n=%d away from events, expectancy=%.2fR\n",
                         newsProx.near.sampleSize, newsProx.near.expectancy,
                         newsProx.away.sampleSize, newsProx.away.expectancy);

   // Learning-machine per-event breakdown -- report-only, see
   // ComputePerEventStats()'s header comment for why this never
   // auto-adjusts the whitelist itself.
   EventStatsRow eventRows[];
   int eventRowCount = ComputePerEventStats(eventRows);
   bool printedEventHeader = false;
   for(int ev = 0; ev < eventRowCount; ev++)
     {
      if(eventRows[ev].stats.sampleSize < MinTradesPerEventForReport) continue;
      if(!printedEventHeader) { s += "Per-event breakdown (report-only, does not auto-adjust the whitelist):\n"; printedEventHeader = true; }
      s += StringFormat("  %s: n=%d, winRate=%.1f%%, expectancy=%.2fR\n",
                         eventRows[ev].eventName, eventRows[ev].stats.sampleSize,
                         eventRows[ev].stats.winRate*100.0, eventRows[ev].stats.expectancy);
     }

   s += StringFormat("Pyramiding: %s\n",
                      !AllowPyramiding ? "DISABLED (AllowPyramiding=false)"
                      : (ExecutionModeLive ? "ENABLED -- LIVE execution armed" : "ENABLED -- PAPER (ExecutionModeLive=false, logs only, sends nothing)"));
   if(AllowPyramiding)
     {
      bool printedPyrHeader = false;
      for(int i = 0; i < ArraySize(g_openMeta); i++)
        {
         ulong pTicket = g_openMeta[i].ticket;
         int addsSoFar = CountPositionEntryDeals(pTicket) - 1;
         if(addsSoFar <= 0) continue; // only positions that actually received an add -- an un-pyramided open position isn't "pyramided"
         if(!PositionSelectByTicket(pTicket)) continue;

         double blendedEntry = ComputeBlendedEntryPrice(pTicket);
         if(blendedEntry <= 0.0) blendedEntry = g_openMeta[i].entryPrice; // deal history unavailable -- fall back to the original leg rather than show a bogus 0.0
         double aggLots = PositionGetDouble(POSITION_VOLUME);
         double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);

         double riskDistance = (g_openMeta[i].direction == 1)
                                ? (blendedEntry - g_openMeta[i].slPriceAtEntry)
                                : (g_openMeta[i].slPriceAtEntry - blendedEntry);
         double currentR = 0.0;
         if(riskDistance > 0.0)
            currentR = (g_openMeta[i].direction == 1)
                       ? (currentPrice - blendedEntry) / riskDistance
                       : (blendedEntry - currentPrice) / riskDistance;

         if(!printedPyrHeader)
           {
            s += "Pyramided positions (adds made / aggregate lots / blended entry / current aggregate R, vs. original entry's SL basis):\n";
            printedPyrHeader = true;
           }
         s += StringFormat("  ticket %I64u: %d add%s, %.2f lots, blended entry %.5f, current %.2fR (original entry was %.5f)\n",
                            pTicket, addsSoFar, addsSoFar == 1 ? "" : "s", aggLots, blendedEntry, currentR, g_openMeta[i].entryPrice);
        }
     }

   s += "----------------------------------------\n";
   s += StringFormat("Open positions tracked: %d\n", ArraySize(g_openMeta));
   s += "This module gates sizing and, only via the separately-armed Pyramiding Engine above, adds volume to an already-open, already-profitable position -- it never opens a brand-new position on its own signal and never closes or otherwise modifies an existing one.\n";
   s += "Wire GetCompositeDirection() / ComputeAdaptiveRisk() into your own entry engine.\n";

   Comment(s);
   return(s);
  }

//====================================================================
// LIFECYCLE
//====================================================================
datetime g_lastBarTime = 0;

bool IsNewBar(void)
  {
   datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(t != g_lastBarTime)
     {
      g_lastBarTime = t;
      return(true);
     }
   return(false);
  }

// Mirrors ExecutionEngine.mqh's own DetectFillingMode() (this repo's
// sibling EA) -- same real broker-capability probe, ported rather than
// re-invented, since g_trade is the same standard CTrade wrapper used
// there. FOK preferred, IOC next, ORDER_FILLING_RETURN as the universal
// fallback every broker accepts.
ENUM_ORDER_TYPE_FILLING DetectFillingMode(const string symbol)
  {
   int filling = (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) != 0) return(ORDER_FILLING_FOK);
   if((filling & SYMBOL_FILLING_IOC) != 0) return(ORDER_FILLING_IOC);
   return(ORDER_FILLING_RETURN);
  }

int OnInit(void)
  {
   LoadJournalFromFile(); // learning machine: repopulates g_journal from disk (or leaves it empty) -- always runs before SyncOpenPositions' first pass
   ArrayResize(g_openMeta, 0);
   g_firstSyncDone = false;
   g_lastBarTime = 0;

   // g_trade is only ever actually called from SendPyramidAdd(), and only
   // when AllowPyramiding && ExecutionModeLive are both true -- but it is
   // configured unconditionally here, cheaply, so it is never left in an
   // unconfigured state on the one code path that does need it.
   g_trade.SetExpertMagicNumber(PyramidMagicNumber);
   g_trade.SetDeviationInPoints(PyramidDeviationPoints);
   g_trade.SetTypeFilling(DetectFillingMode(_Symbol));
   g_trade.SetAsyncMode(false); // always wait for and confirm the actual send result -- never fire-and-forget on a real order

   // Account safety governor: reset so a fresh EA (re)start begins a new
   // "day" baseline immediately on the first OnTick call to
   // UpdateDailySafetyGovernor(), rather than carrying over a stale
   // baseline from a previous run/recompile.
   g_dayStartEquity = 0.0;
   g_dayStartTime   = 0;

   PrintFormat("AUTOPSY X FLIPDEMON X15: initialized on %s %s. VWAP engine %s, VP-MACD engine %s, News Defense %s, persistent journal %s, Pyramiding %s (%s).",
               _Symbol, EnumToString((ENUM_TIMEFRAMES)Period()),
               UseVWAPExit ? "ENABLED" : "disabled",
               UseVPMACDEntry ? "ENABLED" : "disabled",
               UseNewsDefense ? "ENABLED (default)" : "disabled",
               UsePersistentJournal ? "ENABLED (default)" : "disabled",
               AllowPyramiding ? "ENABLED" : "disabled",
               ExecutionModeLive ? "LIVE" : "PAPER");
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   Comment("");
  }

void OnTick(void)
  {
   UpdateDailySafetyGovernor(); // every tick, before anything else -- keeps IsAccountHalted() current for CheckPyramidEligibility()
   SyncOpenPositions();
   if(IsNewBar())
     {
      RunDecision();
      ProcessPyramidOpportunities(); // once per confirmed bar close, same cadence as RunDecision() -- no reason to re-evaluate add eligibility intra-bar
     }
  }
//+------------------------------------------------------------------+
