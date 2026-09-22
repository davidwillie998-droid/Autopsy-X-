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
//|  execution EA -- it never calls OrderSend. It tracks whatever     |
//|  positions already exist on its symbol (from a human, from        |
//|  another EA, or from a future entry engine wired in at the        |
//|  GetCompositeDirection() extension point below) purely to build   |
//|  its own trade journal and gate its own risk multiplier off it.   |
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
// ever INCREASE aggression -- unlocking a sizing bonus -- and must earn
// that trust with its own track record first. News Defense is the
// opposite: it can only ever SUPPRESS a new entry, it never adds risk,
// and it never touches an existing position (see GetGatedEntryDirection()
// and CheckNewsDefense() below -- there is no code path anywhere in this
// file that force-closes a position; this file places no orders and
// manages no positions at all, existing or otherwise). If the underlying
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
   double learnedBonusAboveOne = MathMin(maxBonusAboveOne, stats.expectancy * BonusLearningRate);
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
// manages, or closes an existing position: this file never calls
// OrderSend or any position-closing function for ANY reason, so the
// "existing positions must still be managed safely" requirement holds by
// construction, not by an extra check that could be silently omitted.
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
      meta.newsEventNameAtEntry = (newsAtEntry.active && newsAtEntry.isValidatedEvent) ? newsAtEntry.reason : "";
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
string GetJournalFileName(void)
  {
   if(JournalFileNameOverride != "") return(JournalFileNameOverride);
   return("AutopsyX15_Journal_" + _Symbol + ".csv");
  }

// Rewrites the WHOLE file from g_journal every time it's called (rather
// than appending), which trades a little I/O for a much simpler
// correctness argument: g_journal in memory is always the single source
// of truth, so the file can never drift from it or accumulate a
// malformed trailing row from an interrupted append.
void SaveJournalToFile(void)
  {
   if(!UsePersistentJournal) return;
   string fname = GetJournalFileName();
   int handle = FileOpen(fname, FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_SHARE_READ, ',');
   if(handle == INVALID_HANDLE)
     {
      PrintFormat("AUTOPSY X15: could not open journal file '%s' for writing (error %d) -- learned state will NOT persist past this session.", fname, GetLastError());
      return;
     }
   int n = ArraySize(g_journal);
   for(int i = 0; i < n; i++)
      FileWrite(handle, (long)g_journal[i].closeTime, g_journal[i].symbol, g_journal[i].direction,
                g_journal[i].rMultiple, g_journal[i].vwapAligned?1:0, g_journal[i].vpMacdAligned?1:0,
                g_journal[i].nearValidatedNewsEvent?1:0, g_journal[i].newsEventNameAtEntry);
   FileClose(handle);
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

   double riskDistance = (meta.direction == 1)
                          ? (meta.entryPrice - meta.slPriceAtEntry)
                          : (meta.slPriceAtEntry - meta.entryPrice);
   if(riskDistance <= 0.0)
     {
      PrintFormat("AUTOPSY X15: position %I64u had a non-positive risk distance (SL on the wrong side of entry?) -- skipping journal entry.", meta.ticket);
      return;
     }

   double rMultiple = (meta.direction == 1)
                       ? (closePrice - meta.entryPrice) / riskDistance
                       : (meta.entryPrice - closePrice) / riskDistance;

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

   s += "----------------------------------------\n";
   s += StringFormat("Open positions tracked: %d\n", ArraySize(g_openMeta));
   s += "This module reports and gates sizing only -- it never calls OrderSend.\n";
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

int OnInit(void)
  {
   LoadJournalFromFile(); // learning machine: repopulates g_journal from disk (or leaves it empty) -- always runs before SyncOpenPositions' first pass
   ArrayResize(g_openMeta, 0);
   g_firstSyncDone = false;
   g_lastBarTime = 0;
   PrintFormat("AUTOPSY X FLIPDEMON X15: initialized on %s %s. VWAP engine %s, VP-MACD engine %s, News Defense %s, persistent journal %s.",
               _Symbol, EnumToString((ENUM_TIMEFRAMES)Period()),
               UseVWAPExit ? "ENABLED" : "disabled",
               UseVPMACDEntry ? "ENABLED" : "disabled",
               UseNewsDefense ? "ENABLED (default)" : "disabled",
               UsePersistentJournal ? "ENABLED (default)" : "disabled");
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   Comment("");
  }

void OnTick(void)
  {
   SyncOpenPositions();
   if(IsNewBar())
      RunDecision();
  }
//+------------------------------------------------------------------+
