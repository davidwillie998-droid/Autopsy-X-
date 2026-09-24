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
//|  SCOPE (autonomous robot): a full EA whose layers run strictly in  |
//|  order -- DATA -> MARKET INTELLIGENCE (structure, liquidity,       |
//|  regime, session, news gate) -> SIGNALS (VWAP, VP-MACD) ->         |
//|  COMPOSITE DECISION -> EXECUTION ELIGIBILITY -> RISK -> ORDER ->   |
//|  POSITION MANAGEMENT -> JOURNAL -> ADAPTATION. No layer is         |
//|  bypassed: an order is only ever built from an ELIGIBLE decision.  |
//|                                                                    |
//|  EXECUTION MODE defaults to ANALYSIS_ONLY: it analyses, validates  |
//|  and reports, and sends nothing. PAPER_EXECUTION runs virtual      |
//|  fills through the same management and journal; LIVE_EXECUTION    |
//|  sends real orders via CTrade. THIS FILE HAS NOT BEEN COMPILED OR  |
//|  RUN IN THE STRATEGY TESTER BY ITS AUTHOR (no MetaEditor was       |
//|  available): compile it, backtest it, forward-test it on PAPER    |
//|  and demo before ever selecting LIVE_EXECUTION.                    |
//|                                                                    |
//|  PROHIBITED BY CONSTRUCTION: martingale, grid recovery, averaging  |
//|  down, doubling after losses, automatic opposite trades after a    |
//|  loss, duplicate entries on one setup, news generating direction,  |
//|  bonuses / Kelly / Monte Carlo raising risk past the hard limits.  |
//|  The only add-on logic (Pyramiding) adds solely to positions       |
//|  already in profit, and is off by default.                         |
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
// ENUMERATIONS  (autonomous-robot layers)
//====================================================================
enum ENUM_X15_EXEC_MODE
  {
   X15_ANALYSIS_ONLY   = 0, // ANALYSIS_ONLY: analyse and report, never place anything
   X15_PAPER_EXECUTION = 1, // PAPER_EXECUTION: virtual fills, managed and journaled like real ones
   X15_LIVE_EXECUTION  = 2  // LIVE_EXECUTION: real MT5 orders via CTrade
  };

enum ENUM_X15_DIR_STATE
  {
   X15_DIR_LONG,
   X15_DIR_SHORT,
   X15_DIR_NEUTRAL,
   X15_DIR_BLOCKED,
   X15_DIR_DATA_UNAVAILABLE,
   X15_DIR_INSUFFICIENT_EVIDENCE
  };

enum ENUM_X15_ELIGIBILITY
  {
   X15_ELIGIBLE_LONG,
   X15_ELIGIBLE_SHORT,
   X15_NOT_ELIGIBLE,
   X15_BLOCKED,
   X15_ELIG_DATA_UNAVAILABLE,
   X15_ELIG_INSUFFICIENT_EVIDENCE
  };

enum ENUM_X15_REGIME
  {
   X15_REGIME_TRENDING,
   X15_REGIME_RANGING,
   X15_REGIME_COMPRESSED,
   X15_REGIME_EXPANDING,
   X15_REGIME_HIGH_VOLATILITY,
   X15_REGIME_LOW_VOLATILITY,
   X15_REGIME_EVENT_DRIVEN,
   X15_REGIME_UNKNOWN
  };

enum ENUM_X15_STATE
  {
   X15_ST_INITIALIZING,
   X15_ST_DATA_CHECK,
   X15_ST_MARKET_ANALYSIS,
   X15_ST_SETUP_SEARCH,
   X15_ST_VALIDATION,
   X15_ST_RISK_CHECK,
   X15_ST_EXECUTION,
   X15_ST_POSITION_MANAGEMENT,
   X15_ST_JOURNAL_UPDATE,
   X15_ST_LEARNING,
   X15_ST_WAIT,
   X15_ST_ERROR,
   X15_ST_BLOCKED,
   X15_ST_DATA_UNAVAILABLE
  };

enum ENUM_X15_SESSION
  {
   X15_SESSION_OFF,
   X15_SESSION_ASIAN,
   X15_SESSION_LONDON,
   X15_SESSION_NEWYORK,
   X15_SESSION_OVERLAP
  };

enum ENUM_X15_STRUCT_EVENT
  {
   X15_EVT_NONE,
   X15_EVT_BOS_UP,
   X15_EVT_BOS_DOWN,
   X15_EVT_MSS_UP,
   X15_EVT_MSS_DOWN
  };

enum ENUM_X15_SETUP_TYPE
  {
   X15_SETUP_NONE,
   X15_SETUP_SWEEP_REVERSAL,
   X15_SETUP_CONTINUATION
  };

enum ENUM_X15_LIQ_TYPE
  {
   X15_LIQ_PDH,
   X15_LIQ_PDL,
   X15_LIQ_PWH,
   X15_LIQ_PWL,
   X15_LIQ_ASIA_HIGH,
   X15_LIQ_ASIA_LOW,
   X15_LIQ_LONDON_HIGH,
   X15_LIQ_LONDON_LOW,
   X15_LIQ_EQUAL_HIGHS,
   X15_LIQ_EQUAL_LOWS,
   X15_LIQ_SWING_HIGH,
   X15_LIQ_SWING_LOW,
   X15_LIQ_HTF_SWING_HIGH,
   X15_LIQ_HTF_SWING_LOW
  };

enum ENUM_X15_ENTRY_ORDER
  {
   X15_ENTRY_MARKET, // market order on the bar after confirmation
   X15_ENTRY_STOP    // BUY STOP / SELL STOP beyond the confirmation bar
  };

enum ENUM_X15_TP_MODE
  {
   X15_TP_NEAREST_LIQUIDITY, // nearest unswept opposing liquidity; no trade if its R:R is too small
   X15_TP_FIXED_R            // fixed R multiple
  };

enum ENUM_X15_TRAIL_MODE
  {
   X15_TRAIL_NONE,
   X15_TRAIL_STRUCTURE,
   X15_TRAIL_ATR,
   X15_TRAIL_FIXED_R,
   X15_TRAIL_VWAP
  };

enum ENUM_X15_VWAP_EXIT
  {
   X15_VWAP_EXIT_OFF,
   X15_VWAP_EXIT_IMMEDIATE,                    // live price beyond the closed-bar VWAP, intrabar
   X15_VWAP_EXIT_CONFIRMED_CROSS,              // a closed bar crossed VWAP against the position
   X15_VWAP_EXIT_CONFIRMED_CROSS_PLUS_STRUCTURE // confirmed cross AND an opposite structure break since entry
  };

// Every broker answer to an order request is classified into exactly one
// of these; only the three "not executed" classes may ever be retried.
enum ENUM_X15_SEND_OUTCOME
  {
   X15_SEND_FILLED,
   X15_SEND_PLACED,           // pending order accepted
   X15_SEND_REJECTED,
   X15_SEND_REQUOTE,          // not executed: safe to retry once
   X15_SEND_PRICE_CHANGED,    // not executed: safe to retry once
   X15_SEND_OFF_QUOTES,       // not executed: safe to retry once
   X15_SEND_TIMEOUT,          // may have executed: never resent
   X15_SEND_CONNECTION_ERROR, // may have executed: never resent
   X15_SEND_UNCERTAIN,        // success code without a deal/order ticket, or no answer: never resent
   X15_SEND_OTHER_ERROR
  };

enum ENUM_X15_NEWS_EMERGENCY
  {
   X15_NEWS_EMERG_NONE,
   X15_NEWS_EMERG_MOVE_TO_BE,
   X15_NEWS_EMERG_CLOSE
  };

enum ENUM_X15_LEARN_SOURCE
  {
   X15_LEARN_LIVE_ONLY,      // only real-money (or Strategy Tester) trades placed by this EA
   X15_LEARN_LIVE_AND_PAPER, // plus this EA's paper trades
   X15_LEARN_ALL_OWN         // plus imported legacy journal rows (not recommended: source unverifiable)
  };

enum ENUM_X15_KELLY_STATUS
  {
   X15_KELLY_VALID,
   X15_KELLY_INSUFFICIENT_SAMPLE,
   X15_KELLY_BOUND_FAILED,
   X15_KELLY_INVALID_INPUT,
   X15_KELLY_RUIN_CONDITION
  };

enum ENUM_X15_LOG_LEVEL
  {
   X15_LOG_ERRORS_ONLY,
   X15_LOG_NORMAL,
   X15_LOG_VERBOSE
  };

enum ENUM_X15_TRADE_SOURCE
  {
   X15_SRC_LIVE,
   X15_SRC_PAPER,
   X15_SRC_TESTER,
   X15_SRC_EXTERNAL,
   X15_SRC_LEGACY
  };

enum ENUM_X15_EXIT_REASON
  {
   X15_EXIT_NONE,
   X15_EXIT_STOP_LOSS,
   X15_EXIT_TAKE_PROFIT,
   X15_EXIT_BREAKEVEN_STOP,
   X15_EXIT_TRAIL_STOP,
   X15_EXIT_INVALIDATION,
   X15_EXIT_TIME,
   X15_EXIT_NEWS_EMERGENCY,
   X15_EXIT_CLOSE_ALL,
   X15_EXIT_VWAP,
   X15_EXIT_STOP_OUT,
   X15_EXIT_MANUAL,
   X15_EXIT_UNKNOWN
  };

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
input bool    InpNewsUnavailableBlocksLive   = true;  // live/demo: calendar data unavailable -> block new entries (fail closed)
input bool    InpNewsUnavailableBlocksTester = false; // Strategy Tester has no economic calendar at all; true would make backtesting impossible. Trades journal the state as BACKTEST_UNAVAILABLE -- nothing is fabricated

input group "=== LEARNING MACHINE ===";
input bool    UsePersistentJournal        = true;  // true: earned track record carries across restarts. false: the journal file is STILL kept (the loss-streak pause, cooldown and paper loss limits must survive a restart) but learning ignores trades closed before this run started
input string  JournalFileNameOverride     = "";    // leave blank to auto-name as AutopsyX15_Journal_<SYMBOL>.csv
input double  BonusLearningRate           = 0.10;  // how much measured expectancy (in R) translates into bonus size once a gate clears -- e.g. 0.10 means 1R of measured edge adds +10% to position size, still capped at VWAPAlignmentBonus/VPMACDAlignmentBonus below. This rate itself is an arbitrary starting point, not derived from anything -- same "unproven until logged" status as every other number in this file
input int     MinTradesPerEventForReport  = 5;     // smallest per-event sample worth showing in the News Defense per-event breakdown -- reporting only, never feeds back into suppression (see the LEARNING MACHINE note above)

input group "=== PROVEN RUIN BOUND (Kelly) ===";
input double  RuinBoundAlpha              = 0.8;   // DRAWDOWN THRESHOLD this bound protects against, as a fraction of starting capital: 0.8 = "protect against wealth falling to 80% of where it started" (a 20% drawdown). Must be strictly between 0 and 1. Closer to 1.0 = guarding against a SMALLER drawdown (stricter).
input double  RuinBoundBeta               = 0.1;   // PROBABILITY TOLERANCE for that drawdown: 0.1 = "want less than a 10% chance of it happening." Must be strictly between 0 and 1. Smaller = wanting MORE confidence it won't happen (stricter).

input group "=== EXECUTION MODE & MANUAL OVERRIDES ===";
input ENUM_X15_EXEC_MODE InpExecutionMode = X15_ANALYSIS_ONLY; // stays ANALYSIS_ONLY until this file has been compiled and passed Strategy Tester runs
input ulong   InpMagicNumber              = 1500015; // this EA's orders and positions; everything else on the account is 'external'
input bool    InpEnableTrading            = true;    // master switch for NEW entries and adds (open positions are always still managed)
input bool    InpEnableLong               = true;
input bool    InpEnableShort              = true;
input double  InpMaxRiskOverridePct       = 0;       // >0 caps per-trade risk at this % -- can only LOWER risk, never raise it past the hard limits
input bool    InpEmergencyStop            = false;   // true: no new entries or adds, immediately. Open positions keep their stops and are still managed
input bool    InpCloseAllManagedPositions = false;   // true: close every position and delete every pending order carrying InpMagicNumber on this symbol, each tick, until none remain
input ENUM_X15_ENTRY_ORDER InpEntryOrderType = X15_ENTRY_MARKET;
input int     InpPendingExpiryBars        = 3;       // stop-entry orders are cancelled after this many exec bars
input double  InpStopEntryBufferATR       = 0.05;    // stop-entry trigger sits this x ATR beyond the confirmation bar's extreme
input int     InpMaxSlippagePoints        = 30;      // CTrade deviation for market orders
input int     InpPaperSlippagePoints      = 0;       // PAPER only: adverse slippage applied to every market-priced fill (entries, SL/manual exits); TP fills at its level

input group "=== HARD RISK LIMITS (no adaptive bonus, override or evidence score can pass these) ===";
input int     InpMaxPositionsTotal        = 3;     // this EA's positions + pending orders, all symbols (a pending order is a potential position)
input int     InpMaxPendingOrders         = 3;     // this EA's pending stop-entry orders, all symbols
input int     InpMaxPositionsPerSymbol    = 1;
input int     InpMaxPositionsPerDirection = 1;     // per symbol, per direction
input double  InpMaxTotalOpenRiskPct      = 3.0;   // this EA's money-at-risk-to-SL across all symbols, including the new trade
input double  InpMaxDailyLossPct          = 4.0;   // account-wide, realized today + floating, from deal history (a restart cannot reset it)
input double  InpMaxWeeklyLossPct         = 8.0;   // same, since Monday 00:00 server time
input int     InpMaxConsecutiveLosses     = 4;     // this EA's own closed trades, from the persisted journal
input int     InpConsecutiveLossPauseHours= 24;    // entries pause this long after the loss that hit the limit
input double  InpMaxSpreadPoints          = 0;     // absolute spread cap in points, 0 = off
input double  InpMaxSpreadATRFraction     = 0.15;  // spread must also be <= this x execution ATR (symbol-agnostic)
input double  InpSpreadAbnormalMultiple   = 2.5;   // spread > this x its recent average = abnormal execution conditions
input double  InpMaxMarginUsagePct        = 30.0;  // used margin after the new order must stay <= this % of equity
input int     InpMaxTickAgeSeconds        = 60;    // last quote older than this = stale, no entry
input int     InpMaxPingMs                = 0;     // 0 = off; otherwise block entries while the terminal's last ping exceeds this

input group "=== FLIP / RE-ENTRY ===";
input bool    InpAllowFlip                = true;  // an opposite-direction entry soon after a close is allowed ONLY as a fresh, fully re-validated setup at InpFlipRiskCapPct
input int     InpFlipWindowBars           = 6;     // an opposite-direction entry within this many exec bars of a close counts as a flip
input int     InpCooldownBarsAfterClose   = 1;     // no new entry on this symbol for this many exec bars after any close

input group "=== POSITION MANAGEMENT ===";
input bool    InpUseBreakEven             = true;
input double  InpBreakEvenAtR             = 1.0;
input double  InpBreakEvenLockR           = 0.1;   // SL moves to entry + this many R
input bool    InpUsePartialClose          = true;
input double  InpPartialAtR               = 1.5;
input double  InpPartialClosePercent      = 50.0;
input ENUM_X15_TRAIL_MODE InpTrailMode    = X15_TRAIL_STRUCTURE;
input ENUM_X15_VWAP_EXIT InpVWAPExitMode  = X15_VWAP_EXIT_OFF; // independent of trailing; confirmed modes use CLOSED bars only
input double  InpTrailStartR              = 1.5;
input double  InpTrailATRMultiple         = 2.0;
input double  InpTrailFixedR              = 1.0;
input bool    InpUseInvalidationExit      = true;  // before break-even: close when a closed bar closes beyond the setup's invalidation level
input int     InpMaxHoldBars              = 0;     // 0 = off
input ENUM_X15_NEWS_EMERGENCY InpNewsEmergencyAction = X15_NEWS_EMERG_NONE; // default: never touch positions for news
input int     InpNewsEmergencyLeadMinutes = 15;

input group "=== LEARNING / EVIDENCE TIERS ===";
input ENUM_X15_LEARN_SOURCE InpLearningSource = X15_LEARN_LIVE_ONLY;
input datetime InpOutOfSampleStart        = D'2000.01.01 00:00'; // own trades closing on/after this form the OUT-OF-SAMPLE tier; earlier ones TRAINING. Reported separately, never merged silently

input group "=== MONTE CARLO (report-only) ===";
input bool    InpMonteCarloEnabled        = true;
input int     InpMonteCarloSims           = 1000;
input int     InpMonteCarloTradesPerSim   = 100;
input int     InpMonteCarloSeed           = 15;    // fixed seed: the same journal always produces the same report
input double  InpMonteCarloDDThreshold1R  = 5.0;
input double  InpMonteCarloDDThreshold2R  = 10.0;
input double  InpMonteCarloDDThreshold3R  = 20.0;

input group "=== PYRAMIDING ENGINE (section 21) ===";
input bool    AllowPyramiding             = false; // OFF by default -- this is a new way to increase aggregate exposure, so like every other engine in this file, it earns activation explicitly rather than starting on
input int     MaxPyramidAdds              = 3;     // NOT specified in the originating task -- conservative default, flagged here explicitly, trivial to change
input double  MinProfitRMultipleToAdd     = 1.0;   // position must be at least this many R in profit (using the ORIGINAL entry's risk distance, the same yardstick as every other R-multiple in this file) before an add is even considered
input bool    RequireFreshConfirmation    = true;  // adds require a NEW VP-MACD crossover event (checked in CheckExecutionEligibility's add mode), not just "price moved favorably since the last add"

input group "=== TIMEFRAMES & MARKET STRUCTURE ===";
input ENUM_TIMEFRAMES InpExecTF           = PERIOD_M15; // execution/setup timeframe -- deliberately NOT the chart's timeframe, so switching the chart never changes a decision
input ENUM_TIMEFRAMES InpHTF1             = PERIOD_D1;  // higher-timeframe bias voter 1 (weekly is shown and feeds PWH/PWL but never votes)
input ENUM_TIMEFRAMES InpHTF2             = PERIOD_H4;  // bias voter 2
input ENUM_TIMEFRAMES InpHTF3             = PERIOD_H1;  // bias voter 3 (also supplies external HTF swing liquidity)
input int     InpStructureBars            = 300;   // closed bars analysed per timeframe
input int     InpSwingStrengthExec        = 2;     // fractal wing on the execution TF: a swing needs this many CLOSED bars on each side before it exists
input int     InpSwingStrengthHTF         = 2;
input int     InpATRPeriod                = 14;
input double  InpDisplacementBodyATR      = 1.2;   // displacement candle: body >= this x ATR at that bar ...
input double  InpDisplacementBodyRatio    = 0.6;   // ... and body >= this fraction of the candle's full range
input double  InpConsolidationRangeATR    = 3.0;   // total range of the last 20 closed bars <= this x ATR -> consolidating

input group "=== LIQUIDITY ===";
input double  InpEqualLevelTolATR         = 0.10;  // two swings within this x ATR of each other form equal highs/lows
input int     InpSweepLookbackBars        = 20;    // a sweep older than this many closed exec bars cannot anchor a setup
input double  InpTargetMinDistanceATR     = 0.25;  // an opposing level closer than this x ATR to entry is treated as at-price noise, not the target -- explicit and visible, not a way to stretch TP

input group "=== SETUP / ENTRY MODEL ===";
input bool    InpUseSweepReversal         = true;  // primary: liquidity sweep -> displacement -> MSS -> retrace into FVG/OB -> confirmation -> entry
input bool    InpUseContinuation          = true;  // optional: aligned HTF trend -> BOS -> pullback into FVG/OB/discount -> confirmation -> entry
input bool    InpRequireZoneRetest        = true;  // entry only after a CLOSED bar retraces into the zone and closes back out in the trade direction
input int     InpSetupMaxAgeBars          = 12;    // the structure break anchoring a setup must be at most this many closed exec bars old
input int     InpMinEvidenceScore         = 4;     // soft-evidence components that must PASS (of up to 8). Never overrides a hard gate
input bool    InpRequireHTFAlignment      = true;  // hard gate: no trade against, or amid conflicting, higher-timeframe structure
input bool    InpAllowRangeHTFReversal    = true;  // sweep-reversal setups may trade when HTF has no clear bias (never when it is CONFLICTING or OPPOSED)
input bool    InpVWAPCountsAsEvidence     = true;  // VWAP state is one soft-evidence component (it can never raise risk from here)
input bool    InpVPMACDCountsAsEvidence   = true;  // VP-MACD state is one soft-evidence component

input group "=== STOP LOSS / TAKE PROFIT ===";
input double  InpSLATRBuffer              = 0.25;  // ATR fraction placed beyond the structural SL reference (swept extreme / zone edge)
input double  InpMaxSLATR                 = 3.0;   // SL distance above this x ATR -> no trade (never shrunk to fit)
input double  InpMaxSLPoints              = 0;     // optional absolute SL cap in points, 0 = off
input ENUM_X15_TP_MODE InpTPMode          = X15_TP_NEAREST_LIQUIDITY;
input double  InpFixedTPR                 = 2.0;   // used only when InpTPMode = FIXED_R
input double  InpMinRR                    = 1.5;   // the nearest realistic target must give at least this R:R, or no trade

input group "=== REGIME ===";
input bool    InpBlockHighVolatility      = true;
input bool    InpBlockEventDriven         = true;
input bool    InpBlockUnknownRegime       = true;
input bool    InpBlockCompressed          = false;
input double  InpHighVolRiskScale         = 0.5;   // risk multiplier in HIGH_VOLATILITY when not blocked -- clamped to <= 1.0, so regime can only ever REDUCE risk

input group "=== SESSIONS (broker SERVER hours 0-23, end exclusive -- defaults assume a GMT+2/+3 server) ===";
input int     InpAsiaStartHour            = 1;
input int     InpAsiaEndHour              = 9;
input int     InpLondonStartHour          = 10;
input int     InpLondonEndHour            = 19;
input int     InpNewYorkStartHour         = 15;
input int     InpNewYorkEndHour           = 23;
input bool    InpTradeAsia                = false; // XAUUSD: Asia is typically thin -- off by default
input bool    InpTradeLondon              = true;
input bool    InpTradeNewYork             = true;
input bool    InpTradeOverlapOnly         = false; // restrict to the London/New York overlap

input group "=== DIAGNOSTICS ===";
input ENUM_X15_LOG_LEVEL InpLogLevel      = X15_LOG_NORMAL;
input bool    InpShowDashboard            = true;

//====================================================================
// CORE DATA TYPES
//====================================================================
// JournalEntry: one row per CLOSED position (spec 21) -- never one per
// partial close, so a scale-out cannot turn one trade into two samples.
// Alignment flags and every *State string are captured AT ENTRY and frozen;
// recomputing them at close would let hindsight leak into what is supposed
// to be a forward-looking read. positionId + source is the dedupe key that
// keeps a restart, a repeated trade event or a reconcile pass from ever
// journaling the same position twice.
struct JournalEntry
  {
   datetime          closeTime;
   string            symbol;
   int               direction;      // 1 = long, -1 = short
   double            rMultiple;      // own trades: net realized P&L / money at risk at entry. External/legacy: price-based, from blended entry and entry SL
   bool              vwapAligned;    // Task 6: did VWAP trend agree with this trade's direction at entry? false if unavailable -- never guessed
   bool              vpMacdAligned;  // Task 11: same question for VP-MACD
   bool              nearValidatedNewsEvent; // Task 17: was a Task-14 whitelisted event within NewsDefenseWindowMinutes of this trade's entry? Recorded regardless of UseNewsDefense so the comparison sample keeps accumulating even while suppression is toggled during testing
   string            newsEventNameAtEntry; // learning-machine extension: the SPECIFIC validated event name matched at entry (e.g. "US Non-Farm Payrolls (USD)"), or "" if none -- powers ComputePerEventStats()'s report-only per-event breakdown
   // --- v2 fields (spec 21) ---
   ulong             positionId;     // POSITION_IDENTIFIER (live/tester) or synthetic id (paper); 0 for legacy rows
   ENUM_X15_TRADE_SOURCE source;
   bool              valid;          // false = recorded for audit but never learned from
   string            invalidReason;
   string            setupId;
   ENUM_X15_SETUP_TYPE setupType;
   datetime          entryTime;
   double            entryPrice;     // volume-weighted across every entry deal
   double            sl;             // original SL at entry
   double            tp;             // original TP at entry
   double            volume;         // peak volume held
   double            riskPct;
   double            riskMoney;
   datetime          exitTimeFirst;  // first exit deal (a partial), = closeTime when there was none
   double            exitPrice;      // volume-weighted across every exit deal
   double            grossProfit;
   double            commission;     // entry + exit commissions and fees
   double            swap;
   double            netProfit;
   double            spreadAtEntryPts;
   string            vwapState;
   string            vpmacdState;
   string            newsState;
   string            compositeState;
   string            regime;
   string            structureState;
   string            liquidityState;
   string            session;
   string            entryReason;
   ENUM_X15_EXIT_REASON exitReason;
   bool              isFlip;
   int               evidenceScore;
   double            slippagePts;    // first fill vs requested price, in points; positive = adverse
  };
JournalEntry g_journal[];

// StatsResult: same shape used by ComputeStats() and both *AlignedStats()
// functions below, so every consumer (ComputeAdaptiveRisk, the dashboard)
// treats "the whole journal" and "a filtered subset of it" identically.
struct StatsResult
  {
   double            winRate;     // fraction 0..1, or -1 if sampleSize == 0
   double            avgR;        // mean R multiple, or -1 if sampleSize == 0
   double            expectancy;  // per-trade expectancy in R units -- identical to avgR today; kept as a separate field in case cost/fee modeling is layered in later without changing this struct's shape
   int               sampleSize;
  };

// X15Position: the registry row for every position this file tracks --
// its own (live or paper) and, for journaling only, external ones.
//
// CORRECTNESS-CRITICAL: positions are keyed by `positionId` =
// POSITION_IDENTIFIER, never POSITION_TICKET. The ticket can CHANGE (on a
// netting account a reversal changes it to the reversing order's ticket);
// the identifier is fixed for the position's life and is what
// HistorySelectByPosition() needs. `ticket` below is only a cache of the
// CURRENT ticket, refreshed on every reconcile, and is used only for
// PositionModify/PositionClose calls.
struct X15Position
  {
   ulong             positionId;
   ulong             ticket;
   bool              isOwn;
   bool              isPaper;
   bool              isPreExisting;   // was already open when this EA started and had no persisted context: entry-time signals UNKNOWN
   string            setupId;
   ENUM_X15_SETUP_TYPE setupType;
   int               direction;
   datetime          entryTime;
   datetime          entryBarTime;
   double            entryPrice;      // first fill
   double            avgEntryPrice;   // blended after pyramid adds
   double            volume;
   double            peakVolume;
   double            originalSL;      // as placed at entry -- never moved by break-even/trailing, so R stays anchored
   double            originalTP;
   double            currentSL;
   double            currentTP;
   double            riskPct;
   double            riskMoney;       // money at risk at entry (+ each add's)
   double            invalidation;
   double            spreadAtEntryPts;
   bool              beDone;
   bool              partialDone;
   int               modifyFailCount;
   datetime          lastModifyTime;
   datetime          firstExitTime;
   ENUM_X15_EXIT_REASON pendingExitReason; // set just before this EA itself closes, so the journal records WHY
   bool              isFlip;
   int               evidenceScore;
   bool              vwapAligned;
   bool              vpMacdAligned;
   bool              nearValidatedNewsEvent;
   string            newsEventNameAtEntry;
   string            vwapState;
   string            vpmacdState;
   string            newsState;
   string            compositeState;
   string            regime;
   string            structureState;
   string            liquidityState;
   string            session;
   string            entryReason;
   // paper-only accounting (a live position's are read from deal history)
   double            paperExitPriceVolume;
   double            paperExitVolume;
   double            paperGross;
   bool              closed;
   bool              isPendingOrder;  // paper stop-entry not yet triggered
   double            pendingPrice;
   datetime          pendingExpiry;
   int               finalizeAttempts;
   bool              valuationFailed; // paper P&L could not be valued by OrderCalcProfit: journaled as invalid
   double            requestedPrice;  // price the entry was requested at (market quote or stop level): slippage basis
   bool              vwapFavorableSeen; // runtime only
   datetime          lastCloseAttempt;  // runtime only: close/partial retry backoff
   int               closeFailCount;    // runtime only
  };
X15Position g_positions[];
bool g_firstSyncDone = false; // flips true after the first reconcile pass -- positions found on that pass pre-date this run

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
   // learnable rows only (spec 22): see IsLearnable() -- external, legacy,
   // invalid and duplicate records never feed a gate, bonus or bound
   int n = ArraySize(g_journal);
   double rValues[];
   ArrayResize(rValues, n);
   int count = 0;
   for(int i = 0; i < n; i++)
      if(IsLearnable(g_journal[i])) { rValues[count] = g_journal[i].rMultiple; count++; }
   ArrayResize(rValues, count);
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
      if(g_journal[i].vwapAligned && IsLearnable(g_journal[i]))
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
      if(g_journal[i].vpMacdAligned && IsLearnable(g_journal[i]))
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
      if(!IsLearnable(g_journal[i])) continue;
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
      if(g_journal[i].newsEventNameAtEntry == "" || !IsLearnable(g_journal[i])) continue;
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
         if(g_journal[i].newsEventNameAtEntry == uniqueNames[u] && IsLearnable(g_journal[i]))
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
// Timeframe: InpExecTF, not PERIOD_CURRENT. Tied to the chart, a chart
// timeframe switch would silently change every VWAP read (and the
// alignment flags journaled from it).
double GetVWAP(string symbol)
  {
   // Recomputed fresh on every call (no persistent running state) so it is
   // always correct after a terminal restart, a symbol switch, or a gap in
   // ticks. Cost is O(bars-since-anchor) per call -- cheap at single-symbol
   // EA scale.
   MqlRates rates[];
   int barsAvailable = CopyRates(symbol, InpExecTF, 0, VWAPMaxBars, rates);
   if(barsAvailable <= 1) return(-1.0); // not enough history to compute anything meaningful
   return(ComputeSessionVWAP(rates, barsAvailable));
  }

// Session (or continuous) VWAP over an oldest-first rates array. Shared by
// the live read above (includes the forming bar) and the closed-bar
// decision read (ClassifyVWAPClosedBar), so both use one formula.
double ComputeSessionVWAP(MqlRates &rates[], int barsAvailable)
  {
   if(barsAvailable <= 1) return(-1.0);
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

// Live-read exit helper: true when UseVWAPExit is enabled and the VWAP
// trend has flipped against the position. The position manager's own
// VWAP trailing mode uses the CLOSED-bar read (ClassifyVWAPClosedBar)
// instead, so an intrabar wobble cannot close a trade; this helper remains
// for callers that explicitly want the live read.
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
   int got = CopyRates(symbol, InpExecTF, shift, need, rates);
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
   int barsAvailable = Bars(symbol, InpExecTF);
   if(barsAvailable < barsNeeded) return(result); // insufficient history -- unavailable, not a guess

   // One bulk fetch covering the whole range this call needs, instead of one
   // CopyRates per P*_t point (up to 34 of them) -- every point's window
   // overlaps almost entirely with its neighbors', so this replaces ~34
   // redundant terminal-history round trips with one.
   MqlRates allRates[];
   int gotAll = CopyRates(symbol, InpExecTF, 0, barsNeeded, allRates);
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
// existing position (EvaluateNewsGate() below outputs only ALLOW or BLOCK
// for NEW entries and adds; there is no code path anywhere in News Defense
// that closes or resizes a position -- the optional pre-event position
// action is a separate, off-by-default input, InpNewsEmergencyAction,
// owned by the position manager). If the underlying
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
// The robot keeps this bound REPORT-ONLY (spec 24): it is shown on the
// dashboard with an explicit VALID / INSUFFICIENT_SAMPLE / BOUND_FAILED /
// INVALID_INPUT / RUIN_CONDITION status (KellyStatus()) and is never
// converted into position size. The Monte Carlo report now exists too
// (RunMonteCarlo()), but as a separate report-only layer, not paired with
// this bound into a gate.
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
   int n = 0; // learnable rows only -- the same set ComputeStats() uses

   for(int i = 0; i < ArraySize(g_journal); i++)
     {
      if(!IsLearnable(g_journal[i])) continue;
      n++;
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

   if(n <= 0) return(result); // no learnable rows: unavailable, never a NaN average
   result.averageTerm = sum / n;
   result.boundSatisfied = (result.averageTerm <= 1.0);
   result.available = true;
   return(result);
  }

//====================================================================
// DIAGNOSTIC LOGGING  (spec 35)
//--------------------------------------------------------------------
// [AX15][CATEGORY] lines. An identical category+message pair is printed at
// most once per 5 minutes of server time, so a condition that persists
// across thousands of ticks (spread too wide, data unavailable) produces
// one line, not a flood.
//====================================================================
#define X15_LOG_THROTTLE_SLOTS 64
string   g_logKeys[X15_LOG_THROTTLE_SLOTS];
datetime g_logTimes[X15_LOG_THROTTLE_SLOTS];
int      g_logNext = 0;

void X15Log(string category, string message, bool isError = false, bool verboseOnly = false)
  {
   if(!isError && InpLogLevel == X15_LOG_ERRORS_ONLY) return;
   if(verboseOnly && InpLogLevel != X15_LOG_VERBOSE) return;
   string key = category + "|" + message;
   datetime now = TimeCurrent();
   for(int i = 0; i < X15_LOG_THROTTLE_SLOTS; i++)
      if(g_logKeys[i] == key && now - g_logTimes[i] < 300) return;
   g_logKeys[g_logNext]  = key;
   g_logTimes[g_logNext] = now;
   g_logNext = (g_logNext + 1) % X15_LOG_THROTTLE_SLOTS;
   PrintFormat("[AX15][%s] %s", category, message);
  }

string EnumLabel(string raw, string prefix)
  {
   StringReplace(raw, prefix, "");
   return(raw);
  }

string DirLabel(int direction)
  {
   if(direction == 1)  return("LONG");
   if(direction == -1) return("SHORT");
   return("NONE");
  }

//====================================================================
// LAYER 1 -- DATA
//--------------------------------------------------------------------
// Every symbol property is read live from the broker (spec 27): nothing in
// sizing, stops or spread logic assumes a gold, FX or index contract.
//====================================================================
struct X15SymbolSpec
  {
   bool              valid;
   string            reason;
   int               digits;
   double            point;
   double            tickSize;
   double            tickValue;
   double            tickValueLoss;
   double            contractSize;
   double            volMin;
   double            volMax;
   double            volStep;
   int               stopsLevelPts;
   int               freezeLevelPts;
   long              tradeMode;
   long              fillingMode;
   long              expirationMode;
  };
X15SymbolSpec g_spec;

bool RefreshSymbolSpec(X15SymbolSpec &s)
  {
   s.valid          = false;
   s.reason         = "";
   s.digits         = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   s.point          = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   s.tickSize       = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   s.tickValue      = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   s.tickValueLoss  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   s.contractSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   s.volMin         = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   s.volMax         = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   s.volStep        = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   s.stopsLevelPts  = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   s.freezeLevelPts = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   s.tradeMode      = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   s.fillingMode    = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   s.expirationMode = SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE);
   if(s.point <= 0.0 || s.tickSize <= 0.0 || s.tickValue <= 0.0)
     {
      s.reason = "symbol point / tick size / tick value unavailable";
      return(false);
     }
   if(s.volStep <= 0.0 || s.volMin <= 0.0 || s.volMax < s.volMin)
     {
      s.reason = "symbol volume limits unavailable";
      return(false);
     }
   s.valid = true;
   return(true);
  }

#define X15_SPREAD_SAMPLES 300
double   g_spreadSamples[X15_SPREAD_SAMPLES];
int      g_spreadCount = 0;
int      g_spreadHead  = 0;
datetime g_lastSpreadSample = 0;

double CurrentSpreadPoints(void)
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0 || g_spec.point <= 0.0) return(-1.0);
   return((ask - bid) / g_spec.point);
  }

// At most one sample per server second, so a burst of ticks cannot drown
// out the rest of the window.
void SampleSpread(void)
  {
   datetime now = TimeCurrent();
   if(now == g_lastSpreadSample) return;
   double sp = CurrentSpreadPoints();
   if(sp < 0.0) return;
   g_lastSpreadSample = now;
   g_spreadSamples[g_spreadHead] = sp;
   g_spreadHead = (g_spreadHead + 1) % X15_SPREAD_SAMPLES;
   if(g_spreadCount < X15_SPREAD_SAMPLES) g_spreadCount++;
  }

double RecentAverageSpreadPoints(void)
  {
   if(g_spreadCount < 20) return(-1.0);
   double sum = 0.0;
   for(int i = 0; i < g_spreadCount; i++) sum += g_spreadSamples[i];
   return(sum / g_spreadCount);
  }

// Indicator handles are created once in OnInit and released in OnDeinit
// (spec 28) -- never per tick.
int g_atrExec = INVALID_HANDLE;
int g_atrHTF[3];

bool CreateIndicatorHandles(void)
  {
   g_atrExec = iATR(_Symbol, InpExecTF, InpATRPeriod);
   g_atrHTF[0] = iATR(_Symbol, InpHTF1, InpATRPeriod);
   g_atrHTF[1] = iATR(_Symbol, InpHTF2, InpATRPeriod);
   g_atrHTF[2] = iATR(_Symbol, InpHTF3, InpATRPeriod);
   return(g_atrExec != INVALID_HANDLE && g_atrHTF[0] != INVALID_HANDLE
          && g_atrHTF[1] != INVALID_HANDLE && g_atrHTF[2] != INVALID_HANDLE);
  }

void ReleaseIndicatorHandles(void)
  {
   if(g_atrExec != INVALID_HANDLE) IndicatorRelease(g_atrExec);
   g_atrExec = INVALID_HANDLE;
   for(int i = 0; i < 3; i++)
     {
      if(g_atrHTF[i] != INVALID_HANDLE) IndicatorRelease(g_atrHTF[i]);
      g_atrHTF[i] = INVALID_HANDLE;
     }
  }

struct X15DataQuality
  {
   bool              ok;
   string            reason;
   double            tickAgeSec;
  };
X15DataQuality g_dq;

void EvaluateDataQuality(X15DataQuality &dq)
  {
   dq.ok = false;
   dq.reason = "";
   dq.tickAgeSec = -1.0;
   if(!RefreshSymbolSpec(g_spec)) { dq.reason = g_spec.reason; return; }

   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t) || t.bid <= 0.0 || t.ask <= 0.0) { dq.reason = "no valid tick"; return; }
   if(t.ask < t.bid) { dq.reason = "crossed quote (ask below bid)"; return; }
   dq.tickAgeSec = (double)(TimeCurrent() - t.time);

   ENUM_TIMEFRAMES tfs[4];
   tfs[0] = InpExecTF; tfs[1] = InpHTF1; tfs[2] = InpHTF2; tfs[3] = InpHTF3;
   for(int i = 0; i < 4; i++)
     {
      if(!SeriesInfoInteger(_Symbol, tfs[i], SERIES_SYNCHRONIZED))
        { dq.reason = EnumToString(tfs[i]) + " history not synchronized"; return; }
      if(Bars(_Symbol, tfs[i]) < 60)
        { dq.reason = EnumToString(tfs[i]) + " has fewer than 60 bars"; return; }
     }
   dq.ok = true;
  }

//====================================================================
// LAYER 2 -- MARKET INTELLIGENCE: STRUCTURE  (spec 6)
//--------------------------------------------------------------------
// Closed bars only: every CopyRates here starts at shift 1, so the forming
// bar never enters a swing, a break or a displacement read.
//
// Swings are fractals needing `k` closed bars on each side. A swing is
// therefore only KNOWN k bars after it prints, and the BOS/MSS walk below
// honours that: at bar j it only uses swings confirmed by bar j. That is
// what keeps the break history free of lookahead -- a naive version that
// labels breaks against the final swing list would "know" swings before
// they existed.
//
// BOS = close beyond the latest confirmed swing in the direction of the
// current break bias; MSS (a.k.a. CHoCH) = the same close when the prior
// bias was the OTHER way. The very first break has no prior bias and is
// labelled BOS.
//====================================================================
#define X15_MAX_SWINGS 40

struct X15Swing
  {
   datetime          time;
   double            price;
   bool              isHigh;
   int               label;   // +2 HH, +1 HL, -1 LH, -2 LL, 0 first/equal
  };

struct X15Structure
  {
   ENUM_TIMEFRAMES   tf;
   bool              available;
   string            unavailableReason;
   datetime          lastClosedBarTime;
   bool              atrAvailable;
   double            atr;
   int               trend;           // 1 HH+HL, -1 LH+LL, 0 mixed/undetermined
   int               bias;            // direction of the most recent break
   string            trendLabel;
   int               swingCount;
   X15Swing          swings[X15_MAX_SWINGS]; // oldest first, alternating high/low
   double            lastSwingHigh;
   datetime          lastSwingHighTime;
   double            lastSwingLow;
   datetime          lastSwingLowTime;
   ENUM_X15_STRUCT_EVENT lastEvent;
   datetime          lastEventTime;
   double            lastEventLevel;
   ENUM_X15_STRUCT_EVENT lastUpEvent;
   datetime          lastUpEventTime;
   double            lastUpEventLevel;
   ENUM_X15_STRUCT_EVENT lastDownEvent;
   datetime          lastDownEventTime;
   double            lastDownEventLevel;
   datetime          lastBullDisplacementTime;
   datetime          lastBearDisplacementTime;
   double            compressionRatio; // avg range of last 10 closed bars / last 50
   bool              compressed;
   bool              expanding;
   bool              consolidating;
  };

void ResetStructure(X15Structure &st, ENUM_TIMEFRAMES tf)
  {
   st.tf = tf;
   st.available = false;
   st.unavailableReason = "";
   st.lastClosedBarTime = 0;
   st.atrAvailable = false;
   st.atr = 0.0;
   st.trend = 0;
   st.bias = 0;
   st.trendLabel = "UNKNOWN";
   st.swingCount = 0;
   st.lastSwingHigh = 0.0; st.lastSwingHighTime = 0;
   st.lastSwingLow  = 0.0; st.lastSwingLowTime  = 0;
   st.lastEvent = X15_EVT_NONE;     st.lastEventTime = 0;     st.lastEventLevel = 0.0;
   st.lastUpEvent = X15_EVT_NONE;   st.lastUpEventTime = 0;   st.lastUpEventLevel = 0.0;
   st.lastDownEvent = X15_EVT_NONE; st.lastDownEventTime = 0; st.lastDownEventLevel = 0.0;
   st.lastBullDisplacementTime = 0;
   st.lastBearDisplacementTime = 0;
   st.compressionRatio = 0.0;
   st.compressed = false;
   st.expanding = false;
   st.consolidating = false;
  }

bool IsDisplacementBar(MqlRates &r[], double &atr[], int j, int dir)
  {
   if(j < 0 || j >= ArraySize(atr) || atr[j] <= 0.0) return(false);
   double body  = r[j].close - r[j].open;
   double range = r[j].high - r[j].low;
   if(range <= 0.0) return(false);
   if(dir == 1 && body <= 0.0) return(false);
   if(dir == -1 && body >= 0.0) return(false);
   double absBody = MathAbs(body);
   return(absBody >= InpDisplacementBodyATR * atr[j] && absBody / range >= InpDisplacementBodyRatio);
  }

// Keeps the compressed swing list alternating: two highs in a row keep the
// higher one, two lows the lower one. Used for LABELLING only; the break
// walk uses the raw list so it stays causal.
void X15PushCompressedSwing(int &idx[], bool &isHigh[], double &price[], int &count, int barIdx, bool high, double p)
  {
   if(count > 0 && isHigh[count-1] == high)
     {
      bool moreExtreme = high ? (p >= price[count-1]) : (p <= price[count-1]);
      if(moreExtreme) { idx[count-1] = barIdx; price[count-1] = p; }
      return;
     }
   idx[count] = barIdx; isHigh[count] = high; price[count] = p;
   count++;
  }

bool AnalyzeStructure(ENUM_TIMEFRAMES tf, int atrHandle, int k, X15Structure &st, MqlRates &r[], double &atr[])
  {
   ResetStructure(st, tf);
   if(k < 1) k = 1;
   ArraySetAsSeries(r, false);
   int want = MathMax(InpStructureBars, 60);
   int got = CopyRates(_Symbol, tf, 1, want, r);
   if(got < 4*k + 50)
     {
      st.unavailableReason = StringFormat("%s: only %d closed bars", EnumLabel(EnumToString(tf), "PERIOD_"), got);
      ArrayResize(r, 0);
      ArrayResize(atr, 0);
      return(false);
     }
   st.lastClosedBarTime = r[got-1].time;

   ArrayResize(atr, got);
   ArrayInitialize(atr, 0.0);
   if(atrHandle != INVALID_HANDLE)
     {
      double tmp[];
      ArraySetAsSeries(tmp, false);
      if(CopyBuffer(atrHandle, 0, 1, got, tmp) == got)
        {
         ArrayCopy(atr, tmp);
         if(atr[got-1] > 0.0 && atr[got-1] != EMPTY_VALUE)
           {
            st.atrAvailable = true;
            st.atr = atr[got-1];
           }
        }
     }

   // raw fractal swings, oldest first
   int    rIdx[];   bool rHigh[];   double rPrice[];   int rc = 0;
   ArrayResize(rIdx, 2*got); ArrayResize(rHigh, 2*got); ArrayResize(rPrice, 2*got);
   for(int i = k; i < got - k; i++)
     {
      bool isH = true, isL = true;
      for(int w = 1; w <= k; w++)
        {
         if(!(r[i].high >  r[i-w].high && r[i].high >= r[i+w].high)) isH = false;
         if(!(r[i].low  <  r[i-w].low  && r[i].low  <= r[i+w].low))  isL = false;
        }
      if(isH) { rIdx[rc] = i; rHigh[rc] = true;  rPrice[rc] = r[i].high; rc++; }
      if(isL) { rIdx[rc] = i; rHigh[rc] = false; rPrice[rc] = r[i].low;  rc++; }
     }

   // compressed alternating list for labels and display
   int    cIdx[];   bool cHigh[];   double cPrice[];   int cc = 0;
   ArrayResize(cIdx, rc + 1); ArrayResize(cHigh, rc + 1); ArrayResize(cPrice, rc + 1);
   for(int i = 0; i < rc; i++) X15PushCompressedSwing(cIdx, cHigh, cPrice, cc, rIdx[i], rHigh[i], rPrice[i]);

   int first = MathMax(0, cc - X15_MAX_SWINGS);
   double prevHigh = 0.0, prevLow = 0.0;
   int lastHighLabel = 0, lastLowLabel = 0;
   for(int i = 0; i < cc; i++)
     {
      int label = 0;
      if(cHigh[i])
        {
         if(prevHigh > 0.0) label = (cPrice[i] > prevHigh) ? 2 : ((cPrice[i] < prevHigh) ? -1 : 0);
         prevHigh = cPrice[i];
         lastHighLabel = label;
         st.lastSwingHigh = cPrice[i];
         st.lastSwingHighTime = r[cIdx[i]].time;
        }
      else
        {
         if(prevLow > 0.0) label = (cPrice[i] > prevLow) ? 1 : ((cPrice[i] < prevLow) ? -2 : 0);
         prevLow = cPrice[i];
         lastLowLabel = label;
         st.lastSwingLow = cPrice[i];
         st.lastSwingLowTime = r[cIdx[i]].time;
        }
      if(i >= first)
        {
         int s = st.swingCount;
         st.swings[s].time   = r[cIdx[i]].time;
         st.swings[s].price  = cPrice[i];
         st.swings[s].isHigh = cHigh[i];
         st.swings[s].label  = label;
         st.swingCount++;
        }
     }
   if(lastHighLabel == 2 && lastLowLabel == 1)        { st.trend = 1;  st.trendLabel = "BULLISH (HH/HL)"; }
   else if(lastHighLabel == -1 && lastLowLabel == -2) { st.trend = -1; st.trendLabel = "BEARISH (LH/LL)"; }
   else                                               { st.trend = 0;  st.trendLabel = "RANGE/MIXED"; }

   // causal BOS/MSS walk: at bar j only swings confirmed by bar j exist
   int nextSwing = 0;
   double refHigh = 0.0, refLow = 0.0;
   bool refHighLive = false, refLowLive = false;
   int bias = 0;
   for(int j = 0; j < got; j++)
     {
      while(nextSwing < rc && rIdx[nextSwing] + k <= j)
        {
         if(rHigh[nextSwing]) { refHigh = rPrice[nextSwing]; refHighLive = true; }
         else                 { refLow  = rPrice[nextSwing]; refLowLive  = true; }
         nextSwing++;
        }
      if(refHighLive && r[j].close > refHigh)
        {
         ENUM_X15_STRUCT_EVENT ev = (bias < 0) ? X15_EVT_MSS_UP : X15_EVT_BOS_UP;
         st.lastUpEvent = ev; st.lastUpEventTime = r[j].time; st.lastUpEventLevel = refHigh;
         st.lastEvent   = ev; st.lastEventTime   = r[j].time; st.lastEventLevel   = refHigh;
         bias = 1;
         refHighLive = false;
        }
      if(refLowLive && r[j].close < refLow)
        {
         ENUM_X15_STRUCT_EVENT ev = (bias > 0) ? X15_EVT_MSS_DOWN : X15_EVT_BOS_DOWN;
         st.lastDownEvent = ev; st.lastDownEventTime = r[j].time; st.lastDownEventLevel = refLow;
         st.lastEvent     = ev; st.lastEventTime     = r[j].time; st.lastEventLevel     = refLow;
         bias = -1;
         refLowLive = false;
        }
      if(IsDisplacementBar(r, atr, j, 1))  st.lastBullDisplacementTime = r[j].time;
      if(IsDisplacementBar(r, atr, j, -1)) st.lastBearDisplacementTime = r[j].time;
     }
   st.bias = bias;

   double sum10 = 0.0, sum50 = 0.0;
   for(int j = got - 10; j < got; j++) sum10 += r[j].high - r[j].low;
   for(int j = got - 50; j < got; j++) sum50 += r[j].high - r[j].low;
   st.compressionRatio = (sum50 > 0.0) ? (sum10 / 10.0) / (sum50 / 50.0) : 0.0;
   st.compressed = (st.compressionRatio > 0.0 && st.compressionRatio <= 0.6);
   st.expanding  = (st.compressionRatio >= 1.5);
   double hi20 = r[got-20].high, lo20 = r[got-20].low;
   for(int j = got - 20; j < got; j++) { hi20 = MathMax(hi20, r[j].high); lo20 = MathMin(lo20, r[j].low); }
   st.consolidating = (st.atrAvailable && (hi20 - lo20) <= InpConsolidationRangeATR * st.atr);

   st.available = true;
   return(true);
  }

//--------------------------------------------------------------------
// HIGHER-TIMEFRAME BIAS
// Three voters (InpHTF1..3). Any two voters with OPPOSITE trends is a
// CONFLICT, which is a no-trade condition (spec 30), not something to
// average away. Two or more agreeing voters with no opposition is ALIGNED.
//--------------------------------------------------------------------
struct X15HTFBias
  {
   bool              available;
   int               bias;     // 1 / -1 when aligned, else 0
   bool              conflict;
   string            state;    // ALIGNED_LONG / ALIGNED_SHORT / CONFLICT / RANGE / UNAVAILABLE
   string            detail;
  };

void EvaluateHTFBias(X15Structure &h1, X15Structure &h2, X15Structure &h3, X15HTFBias &b)
  {
   b.available = false; b.bias = 0; b.conflict = false; b.state = "UNAVAILABLE"; b.detail = "";
   if(!h1.available || !h2.available || !h3.available)
     {
      b.detail = "higher-timeframe structure unavailable";
      return;
     }
   int t[3];
   t[0] = h1.trend; t[1] = h2.trend; t[2] = h3.trend;
   int ups = 0, downs = 0;
   for(int i = 0; i < 3; i++) { if(t[i] == 1) ups++; if(t[i] == -1) downs++; }
   b.available = true;
   b.detail = StringFormat("%s %s | %s %s | %s %s",
                           EnumLabel(EnumToString(h1.tf), "PERIOD_"), DirLabel(t[0]),
                           EnumLabel(EnumToString(h2.tf), "PERIOD_"), DirLabel(t[1]),
                           EnumLabel(EnumToString(h3.tf), "PERIOD_"), DirLabel(t[2]));
   if(ups > 0 && downs > 0) { b.conflict = true; b.state = "CONFLICT"; return; }
   if(ups >= 2)   { b.bias = 1;  b.state = "ALIGNED_LONG";  return; }
   if(downs >= 2) { b.bias = -1; b.state = "ALIGNED_SHORT"; return; }
   b.state = "RANGE";
  }

//====================================================================
// LAYER 2 -- MARKET INTELLIGENCE: LIQUIDITY  (spec 7)
//--------------------------------------------------------------------
// A level is a CANDIDATE, never a promise of a reaction. Every level
// carries the time it became knowable; its first later breach on a closed
// exec bar decides its fate: wick through and close back = SWEEP (a real
// liquidity event); close beyond = TAKEN (broken, no longer a target).
// Levels whose source data is unavailable are simply absent -- a missing
// PDH is never replaced by a guess.
//====================================================================
#define X15_MAX_LEVELS 48

struct X15LiqLevel
  {
   double            price;
   ENUM_X15_LIQ_TYPE type;
   bool              buySide;     // above price: stops of shorts / breakout buyers
   bool              external;    // dealing-range / daily / weekly / HTF level
   datetime          formed;
   bool              taken;
   bool              sweptEvent;  // first breach closed back inside
   datetime          takenTime;
   double            takenExtreme;
  };

struct X15Liquidity
  {
   bool              available;
   string            reason;
   int               count;
   X15LiqLevel       levels[X15_MAX_LEVELS];
   double            pdh, pdl, pwh, pwl;
   double            asiaHigh, asiaLow, londonHigh, londonLow;
   double            dealingHigh, dealingLow, equilibrium;
   bool              bullSweep;   // sell-side swept -> bullish reversal candidate
   datetime          bullSweepTime;
   double            bullSweepLevel;
   double            bullSweepExtreme;
   string            bullSweepName;
   bool              bearSweep;
   datetime          bearSweepTime;
   double            bearSweepLevel;
   double            bearSweepExtreme;
   string            bearSweepName;
   double            drawLongPrice;
   string            drawLongName;
   double            drawShortPrice;
   string            drawShortName;
  };

void ResetLiquidity(X15Liquidity &L)
  {
   L.available = false; L.reason = ""; L.count = 0;
   L.pdh = 0.0; L.pdl = 0.0; L.pwh = 0.0; L.pwl = 0.0;
   L.asiaHigh = 0.0; L.asiaLow = 0.0; L.londonHigh = 0.0; L.londonLow = 0.0;
   L.dealingHigh = 0.0; L.dealingLow = 0.0; L.equilibrium = 0.0;
   L.bullSweep = false; L.bullSweepTime = 0; L.bullSweepLevel = 0.0; L.bullSweepExtreme = 0.0; L.bullSweepName = "";
   L.bearSweep = false; L.bearSweepTime = 0; L.bearSweepLevel = 0.0; L.bearSweepExtreme = 0.0; L.bearSweepName = "";
   L.drawLongPrice = 0.0; L.drawLongName = ""; L.drawShortPrice = 0.0; L.drawShortName = "";
  }

void AddLiqLevel(X15Liquidity &L, double price, ENUM_X15_LIQ_TYPE type, bool buySide, bool external, datetime formed)
  {
   if(price <= 0.0 || L.count >= X15_MAX_LEVELS) return;
   int i = L.count;
   L.levels[i].price = price;
   L.levels[i].type = type;
   L.levels[i].buySide = buySide;
   L.levels[i].external = external;
   L.levels[i].formed = formed;
   L.levels[i].taken = false;
   L.levels[i].sweptEvent = false;
   L.levels[i].takenTime = 0;
   L.levels[i].takenExtreme = 0.0;
   L.count++;
  }

string LiqName(ENUM_X15_LIQ_TYPE t)
  {
   return(EnumLabel(EnumToString(t), "X15_LIQ_"));
  }

bool HourInWindow(int h, int startH, int endH)
  {
   if(startH == endH) return(false);
   if(startH < endH) return(h >= startH && h < endH);
   return(h >= startH || h < endH); // window crosses midnight
  }

MqlRates g_execRates[];
double   g_execAtr[];
int      g_execGot = 0;
X15Structure g_structExec;
X15Structure g_structHTF[3];
X15Structure g_structW1;
X15HTFBias   g_htfBias;
X15Liquidity g_liq;

void BuildLiquidity(X15Liquidity &L)
  {
   ResetLiquidity(L);
   int got = g_execGot;
   if(got < 50 || !g_structExec.available) { L.reason = "execution structure unavailable"; return; }
   int period = PeriodSeconds(InpExecTF);
   datetime todayStart = iTime(_Symbol, PERIOD_D1, 0);
   datetime weekStart  = iTime(_Symbol, PERIOD_W1, 0);

   MqlRates d1[];
   if(CopyRates(_Symbol, PERIOD_D1, 1, 1, d1) == 1) { L.pdh = d1[0].high; L.pdl = d1[0].low; }
   MqlRates w1[];
   if(CopyRates(_Symbol, PERIOD_W1, 1, 1, w1) == 1) { L.pwh = w1[0].high; L.pwl = w1[0].low; }
   AddLiqLevel(L, L.pdh, X15_LIQ_PDH, true,  true, todayStart);
   AddLiqLevel(L, L.pdl, X15_LIQ_PDL, false, true, todayStart);
   AddLiqLevel(L, L.pwh, X15_LIQ_PWH, true,  true, weekStart);
   AddLiqLevel(L, L.pwl, X15_LIQ_PWL, false, true, weekStart);

   // today's Asian / London ranges -- only once the session has finished,
   // since an unfinished session's high is just the current high
   MqlDateTime nowDt;
   TimeToStruct(TimeCurrent(), nowDt);
   datetime asiaLast = 0, londonLast = 0;
   for(int j = 0; j < got; j++)
     {
      if(g_execRates[j].time < todayStart) continue;
      MqlDateTime dt;
      TimeToStruct(g_execRates[j].time, dt);
      if(HourInWindow(dt.hour, InpAsiaStartHour, InpAsiaEndHour))
        {
         L.asiaHigh = (L.asiaHigh == 0.0) ? g_execRates[j].high : MathMax(L.asiaHigh, g_execRates[j].high);
         L.asiaLow  = (L.asiaLow  == 0.0) ? g_execRates[j].low  : MathMin(L.asiaLow,  g_execRates[j].low);
         asiaLast = g_execRates[j].time;
        }
      if(HourInWindow(dt.hour, InpLondonStartHour, InpLondonEndHour))
        {
         L.londonHigh = (L.londonHigh == 0.0) ? g_execRates[j].high : MathMax(L.londonHigh, g_execRates[j].high);
         L.londonLow  = (L.londonLow  == 0.0) ? g_execRates[j].low  : MathMin(L.londonLow,  g_execRates[j].low);
         londonLast = g_execRates[j].time;
        }
     }
   if(asiaLast > 0 && !HourInWindow(nowDt.hour, InpAsiaStartHour, InpAsiaEndHour))
     {
      AddLiqLevel(L, L.asiaHigh, X15_LIQ_ASIA_HIGH, true,  false, asiaLast + period);
      AddLiqLevel(L, L.asiaLow,  X15_LIQ_ASIA_LOW,  false, false, asiaLast + period);
     }
   else { L.asiaHigh = 0.0; L.asiaLow = 0.0; }
   if(londonLast > 0 && !HourInWindow(nowDt.hour, InpLondonStartHour, InpLondonEndHour))
     {
      AddLiqLevel(L, L.londonHigh, X15_LIQ_LONDON_HIGH, true,  false, londonLast + period);
      AddLiqLevel(L, L.londonLow,  X15_LIQ_LONDON_LOW,  false, false, londonLast + period);
     }
   else { L.londonHigh = 0.0; L.londonLow = 0.0; }

   // execution-TF swings: most recent 10, plus equal highs/lows among them
   int confirmSec = (InpSwingStrengthExec + 1) * period; // swing bar + k confirming bars, all closed
   int firstSwing = MathMax(0, g_structExec.swingCount - 10);
   double tol = g_structExec.atrAvailable ? InpEqualLevelTolATR * g_structExec.atr : 0.0;
   for(int i = firstSwing; i < g_structExec.swingCount; i++)
     {
      X15Swing sw = g_structExec.swings[i];
      AddLiqLevel(L, sw.price, sw.isHigh ? X15_LIQ_SWING_HIGH : X15_LIQ_SWING_LOW, sw.isHigh, false, sw.time + confirmSec);
      if(tol <= 0.0) continue;
      for(int j = i + 1; j < g_structExec.swingCount; j++)
        {
         X15Swing sw2 = g_structExec.swings[j];
         if(sw2.isHigh != sw.isHigh || MathAbs(sw2.price - sw.price) > tol) continue;
         double eqPrice = sw.isHigh ? MathMax(sw.price, sw2.price) : MathMin(sw.price, sw2.price);
         AddLiqLevel(L, eqPrice, sw.isHigh ? X15_LIQ_EQUAL_HIGHS : X15_LIQ_EQUAL_LOWS, sw.isHigh, false, sw2.time + confirmSec);
        }
     }

   // external HTF swings from the lowest bias voter
   if(g_structHTF[2].available)
     {
      int htfConfirm = (InpSwingStrengthHTF + 1) * PeriodSeconds(g_structHTF[2].tf);
      for(int i = MathMax(0, g_structHTF[2].swingCount - 4); i < g_structHTF[2].swingCount; i++)
         AddLiqLevel(L, g_structHTF[2].swings[i].price,
                     g_structHTF[2].swings[i].isHigh ? X15_LIQ_HTF_SWING_HIGH : X15_LIQ_HTF_SWING_LOW,
                     g_structHTF[2].swings[i].isHigh, true, g_structHTF[2].swings[i].time + htfConfirm);
     }

   // dealing range and equilibrium (premium / discount)
   L.dealingHigh = g_structExec.lastSwingHigh;
   L.dealingLow  = g_structExec.lastSwingLow;
   double lastClose = g_execRates[got-1].close;
   if(L.dealingHigh > 0.0 && L.dealingLow > 0.0 && (lastClose > L.dealingHigh || lastClose < L.dealingLow))
     {
      for(int i = MathMax(0, g_structExec.swingCount - 6); i < g_structExec.swingCount; i++)
        {
         if(g_structExec.swings[i].isHigh) L.dealingHigh = MathMax(L.dealingHigh, g_structExec.swings[i].price);
         else                              L.dealingLow  = MathMin(L.dealingLow,  g_structExec.swings[i].price);
        }
     }
   if(L.dealingHigh > L.dealingLow && L.dealingLow > 0.0) L.equilibrium = (L.dealingHigh + L.dealingLow) / 2.0;

   // resolve each level against later closed bars
   for(int i = 0; i < L.count; i++)
     {
      for(int j = 0; j < got; j++)
        {
         if(g_execRates[j].time < L.levels[i].formed) continue;
         bool breach = L.levels[i].buySide ? (g_execRates[j].high > L.levels[i].price) : (g_execRates[j].low < L.levels[i].price);
         if(!breach) continue;
         L.levels[i].taken = true;
         L.levels[i].takenTime = g_execRates[j].time;
         L.levels[i].takenExtreme = L.levels[i].buySide ? g_execRates[j].high : g_execRates[j].low;
         L.levels[i].sweptEvent = L.levels[i].buySide ? (g_execRates[j].close < L.levels[i].price)
                                                      : (g_execRates[j].close > L.levels[i].price);
         break;
        }
     }

   // most recent sweep on each side within the lookback
   datetime lookbackStart = g_execRates[MathMax(0, got - InpSweepLookbackBars)].time;
   for(int i = 0; i < L.count; i++)
     {
      if(!L.levels[i].sweptEvent || L.levels[i].takenTime < lookbackStart) continue;
      if(L.levels[i].buySide)
        {
         if(!L.bearSweep || L.levels[i].takenTime > L.bearSweepTime)
           {
            L.bearSweep = true; L.bearSweepTime = L.levels[i].takenTime;
            L.bearSweepLevel = L.levels[i].price; L.bearSweepExtreme = L.levels[i].takenExtreme;
            L.bearSweepName = LiqName(L.levels[i].type);
           }
        }
      else
        {
         if(!L.bullSweep || L.levels[i].takenTime > L.bullSweepTime)
           {
            L.bullSweep = true; L.bullSweepTime = L.levels[i].takenTime;
            L.bullSweepLevel = L.levels[i].price; L.bullSweepExtreme = L.levels[i].takenExtreme;
            L.bullSweepName = LiqName(L.levels[i].type);
           }
        }
     }

   // current draw on liquidity each way, for display
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   for(int i = 0; i < L.count; i++)
     {
      if(L.levels[i].taken) continue;
      if(L.levels[i].buySide && L.levels[i].price > bid && (L.drawLongPrice == 0.0 || L.levels[i].price < L.drawLongPrice))
        { L.drawLongPrice = L.levels[i].price; L.drawLongName = LiqName(L.levels[i].type); }
      if(!L.levels[i].buySide && L.levels[i].price < bid && (L.drawShortPrice == 0.0 || L.levels[i].price > L.drawShortPrice))
        { L.drawShortPrice = L.levels[i].price; L.drawShortName = LiqName(L.levels[i].type); }
     }
   L.available = true;
  }

// Nearest untaken opposing level beyond `fromPrice` by at least minDist.
bool FindNearestTarget(X15Liquidity &L, int dir, double fromPrice, double minDist, double &priceOut, string &nameOut)
  {
   priceOut = 0.0; nameOut = "";
   for(int i = 0; i < L.count; i++)
     {
      if(L.levels[i].taken) continue;
      if(dir == 1)
        {
         if(!L.levels[i].buySide || L.levels[i].price <= fromPrice + minDist) continue;
         if(priceOut == 0.0 || L.levels[i].price < priceOut) { priceOut = L.levels[i].price; nameOut = LiqName(L.levels[i].type); }
        }
      else
        {
         if(L.levels[i].buySide || L.levels[i].price >= fromPrice - minDist) continue;
         if(priceOut == 0.0 || L.levels[i].price > priceOut) { priceOut = L.levels[i].price; nameOut = LiqName(L.levels[i].type); }
        }
     }
   return(priceOut > 0.0);
  }

//====================================================================
// LAYER 2 -- MARKET INTELLIGENCE: NEWS GATE, REGIME, SESSION
//====================================================================
// News Defense's ONLY outputs are ALLOW or BLOCK (spec 9). This struct has
// no direction field by design -- there is nothing here that could ever be
// read as BUY or SELL.
struct X15NewsGate
  {
   bool              blocks;
   bool              eventActive;
   bool              validated;
   string            state;   // ALLOW / BLOCK / DISABLED / UNAVAILABLE / BACKTEST_UNAVAILABLE
   string            detail;
  };
X15NewsGate g_newsGate;

void EvaluateNewsGate(X15NewsGate &g)
  {
   g.blocks = false; g.eventActive = false; g.validated = false; g.state = "ALLOW"; g.detail = "";
   if(!UseNewsDefense) { g.state = "DISABLED"; return; }
   if(MQLInfoInteger(MQL_TESTER))
     {
      g.state  = "BACKTEST_UNAVAILABLE";
      g.detail = "no economic calendar in the Strategy Tester -- nothing is fabricated";
      g.blocks = InpNewsUnavailableBlocksTester;
      return;
     }
   NewsDefenseState nd = CheckNewsDefense(_Symbol);
   if(nd.active)
     {
      g.state = "BLOCK"; g.blocks = true; g.eventActive = true;
      g.validated = nd.isValidatedEvent; g.detail = nd.reason;
      return;
     }
   if(nd.reason != "")
     {
      g.state  = "UNAVAILABLE";
      g.detail = nd.reason;
      g.blocks = InpNewsUnavailableBlocksLive;
      return;
     }
   g.state = "ALLOW";
  }

// Regime thresholds below are fixed, UNVALIDATED defaults. That is exactly
// why regime may only block a setup or REDUCE risk -- never raise it
// (spec 10).
struct X15RegimeInfo
  {
   bool              available;
   ENUM_X15_REGIME   regime;
   double            volRatio;
   double            efficiency;
   double            compressionRatio;
   string            detail;
  };
X15RegimeInfo g_regime;

void ClassifyRegime(X15RegimeInfo &ri, bool eventActive)
  {
   ri.available = false;
   ri.regime = X15_REGIME_UNKNOWN;
   ri.volRatio = 0.0;
   ri.efficiency = 0.0;
   ri.compressionRatio = g_structExec.compressionRatio;
   ri.detail = "";
   int got = g_execGot;
   if(!g_structExec.available || !g_structExec.atrAvailable || got < 120)
     {
      ri.detail = "insufficient execution data or ATR";
      return;
     }
   double sum = 0.0;
   int cnt = 0;
   for(int j = got - 100; j < got; j++)
      if(g_execAtr[j] > 0.0 && g_execAtr[j] != EMPTY_VALUE) { sum += g_execAtr[j]; cnt++; }
   if(cnt < 50) { ri.detail = "ATR history too short"; return; }
   ri.volRatio = g_execAtr[got-1] / (sum / cnt);
   double path = 0.0;
   for(int j = got - 20; j < got; j++) path += MathAbs(g_execRates[j].close - g_execRates[j-1].close);
   ri.efficiency = (path > 0.0) ? MathAbs(g_execRates[got-1].close - g_execRates[got-21].close) / path : 0.0;
   ri.available = true;

   if(eventActive)                                         ri.regime = X15_REGIME_EVENT_DRIVEN;
   else if(ri.volRatio >= 1.8)                             ri.regime = X15_REGIME_HIGH_VOLATILITY;
   else if(ri.volRatio <= 0.5)                             ri.regime = X15_REGIME_LOW_VOLATILITY;
   else if(g_structExec.compressed)                        ri.regime = X15_REGIME_COMPRESSED;
   else if(g_structExec.expanding)                         ri.regime = X15_REGIME_EXPANDING;
   else if(ri.efficiency >= 0.35 && g_structExec.trend != 0) ri.regime = X15_REGIME_TRENDING;
   else                                                    ri.regime = X15_REGIME_RANGING;
   ri.detail = StringFormat("ATR %.2fx avg, efficiency %.2f, range ratio %.2f", ri.volRatio, ri.efficiency, ri.compressionRatio);
  }

// A regime that is blocked outright makes the whole opportunity ineligible;
// this answers the narrower "does this setup TYPE fit this regime" question
// used as one soft-evidence component.
bool RegimeFitsSetup(ENUM_X15_REGIME r, ENUM_X15_SETUP_TYPE t)
  {
   if(r == X15_REGIME_HIGH_VOLATILITY || r == X15_REGIME_EVENT_DRIVEN || r == X15_REGIME_UNKNOWN) return(false);
   if(t == X15_SETUP_CONTINUATION) return(r == X15_REGIME_TRENDING || r == X15_REGIME_EXPANDING);
   return(true);
  }

bool RegimeBlocked(ENUM_X15_REGIME r, string &why)
  {
   why = "";
   if(r == X15_REGIME_HIGH_VOLATILITY && InpBlockHighVolatility) why = "regime HIGH_VOLATILITY is blocked";
   if(r == X15_REGIME_EVENT_DRIVEN && InpBlockEventDriven)       why = "regime EVENT_DRIVEN is blocked";
   if(r == X15_REGIME_UNKNOWN && InpBlockUnknownRegime)          why = "regime UNKNOWN is blocked";
   if(r == X15_REGIME_COMPRESSED && InpBlockCompressed)          why = "regime COMPRESSED is blocked";
   return(why != "");
  }

ENUM_X15_SESSION SessionAt(datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   bool london  = HourInWindow(dt.hour, InpLondonStartHour, InpLondonEndHour);
   bool newYork = HourInWindow(dt.hour, InpNewYorkStartHour, InpNewYorkEndHour);
   if(london && newYork) return(X15_SESSION_OVERLAP);
   if(london)  return(X15_SESSION_LONDON);
   if(newYork) return(X15_SESSION_NEWYORK);
   if(HourInWindow(dt.hour, InpAsiaStartHour, InpAsiaEndHour)) return(X15_SESSION_ASIAN);
   return(X15_SESSION_OFF);
  }

// "The market is open" is not the same as "this session is tradable"
// (spec 25): off-session hours are never tradable here.
bool SessionTradable(ENUM_X15_SESSION s, string &why)
  {
   why = "";
   if(InpTradeOverlapOnly)
     {
      if(s == X15_SESSION_OVERLAP) return(true);
      why = "outside the London/New York overlap (overlap-only mode)";
      return(false);
     }
   if(s == X15_SESSION_OVERLAP && (InpTradeLondon || InpTradeNewYork)) return(true);
   if(s == X15_SESSION_LONDON  && InpTradeLondon)  return(true);
   if(s == X15_SESSION_NEWYORK && InpTradeNewYork) return(true);
   if(s == X15_SESSION_ASIAN   && InpTradeAsia)    return(true);
   why = "session " + EnumLabel(EnumToString(s), "X15_SESSION_") + " is not enabled for trading";
   return(false);
  }

//====================================================================
// LAYER 3 -- SIGNAL STATES AT DECISION TIME
//--------------------------------------------------------------------
// Decisions use closed-bar reads only. VP-MACD's P*_t already sums bars
// t-N..t-1, so GetVPMACD(shift 0) touches no forming-bar data.
//====================================================================
// Per-bar VWAP state, set once per new closed exec bar by RunMarketAnalysis:
// the decision read and every VWAP exit use these same values.
string g_vwapClosedState = "UNAVAILABLE";
double g_vwapClosed      = -1.0;  // VWAP through the last closed bar
bool   g_vwapCrossDown   = false; // previous closed bar at/above its VWAP, last closed bar below
bool   g_vwapCrossUp     = false; // previous closed bar at/below its VWAP, last closed bar above

string ClassifyVWAPClosedBar(void)
  {
   g_vwapClosed = -1.0;
   g_vwapCrossDown = false;
   g_vwapCrossUp = false;
   MqlRates rates[];
   int n = CopyRates(_Symbol, InpExecTF, 1, VWAPMaxBars, rates);
   if(n <= 2) return("UNAVAILABLE");
   double vwap = ComputeSessionVWAP(rates, n);
   if(vwap < 0.0) return("UNAVAILABLE");
   g_vwapClosed = vwap;
   double vwapPrev = ComputeSessionVWAP(rates, n - 1); // VWAP as it stood at the previous bar's close
   double c = rates[n-1].close;
   if(vwapPrev > 0.0)
     {
      g_vwapCrossDown = (rates[n-2].close >= vwapPrev && c < vwap);
      g_vwapCrossUp   = (rates[n-2].close <= vwapPrev && c > vwap);
     }
   if(c > vwap) return("BULLISH");
   if(c < vwap) return("BEARISH");
   return("NEUTRAL");
  }

string ClassifyVPMACDState(void)
  {
   VPMACDResult cur = GetVPMACD(_Symbol, 0);
   if(!cur.available) return("UNAVAILABLE");
   if(cur.macd > cur.signal) return("BULLISH");
   if(cur.macd < cur.signal) return("BEARISH");
   return("NEUTRAL");
  }

//====================================================================
// LAYER 4 -- SETUP ENGINE  (spec 8, 13, 14, 15)
//--------------------------------------------------------------------
// A setup may only TRIGGER on the most recent closed exec bar. A setup that
// was valid three bars ago and was not taken is gone -- that single rule is
// what keeps stale signals from firing late, and (with the setup ID below)
// what makes "the same signal is still true on the next tick" harmless.
//====================================================================
struct X15Setup
  {
   bool              valid;
   ENUM_X15_SETUP_TYPE type;
   int               direction;
   string            rejectReason;
   datetime          triggerBarTime;
   datetime          sweepTime;
   double            sweepLevel;
   double            sweepExtreme;
   string            sweepLevelName;
   datetime          structureTime;
   ENUM_X15_STRUCT_EVENT structureEvent;
   double            structureLevel;
   bool              displacement;
   datetime          displacementTime;
   string            zoneType;      // FVG / OB / DISCOUNT / PREMIUM / NONE
   double            zoneTop;
   double            zoneBottom;
   datetime          zoneFormedTime;
   double            entryRef;
   double            sl;
   double            tp;
   double            rr;
   string            tpLevelName;
   double            invalidation;
   string            setupId;
  };

void ResetSetup(X15Setup &s)
  {
   s.valid = false; s.type = X15_SETUP_NONE; s.direction = 0; s.rejectReason = "";
   s.triggerBarTime = 0;
   s.sweepTime = 0; s.sweepLevel = 0.0; s.sweepExtreme = 0.0; s.sweepLevelName = "";
   s.structureTime = 0; s.structureEvent = X15_EVT_NONE; s.structureLevel = 0.0;
   s.displacement = false; s.displacementTime = 0;
   s.zoneType = "NONE"; s.zoneTop = 0.0; s.zoneBottom = 0.0; s.zoneFormedTime = 0;
   s.entryRef = 0.0; s.sl = 0.0; s.tp = 0.0; s.rr = 0.0; s.tpLevelName = ""; s.invalidation = 0.0;
   s.setupId = "";
  }

int IndexOfBarTime(MqlRates &r[], int got, datetime t)
  {
   for(int i = got - 1; i >= 0; i--) if(r[i].time == t) return(i);
   return(-1);
  }

bool FindDisplacement(MqlRates &r[], double &atr[], int got, int dir, datetime fromTime, datetime toTime, datetime &timeOut)
  {
   timeOut = 0;
   for(int j = got - 1; j >= 0; j--)
     {
      if(r[j].time > toTime) continue;
      if(r[j].time < fromTime) break;
      if(IsDisplacementBar(r, atr, j, dir)) { timeOut = r[j].time; return(true); }
     }
   return(false);
  }

// Most recent fair value gap whose middle candle lies in [fromTime,toTime]
// and that no later close has invalidated (closed through its far edge).
bool FindFVG(MqlRates &r[], int got, int dir, datetime fromTime, datetime toTime, double &top, double &bottom, datetime &formedTime)
  {
   for(int i = got - 1; i >= 2; i--)
     {
      datetime mid = r[i-1].time;
      if(mid > toTime) continue;
      if(mid < fromTime) break;
      bool gap = (dir == 1) ? (r[i].low > r[i-2].high) : (r[i].high < r[i-2].low);
      if(!gap) continue;
      double t = (dir == 1) ? r[i].low    : r[i-2].low;
      double b = (dir == 1) ? r[i-2].high : r[i].high;
      bool invalid = false;
      for(int k = i + 1; k < got; k++)
         if((dir == 1 && r[k].close < b) || (dir == -1 && r[k].close > t)) { invalid = true; break; }
      if(invalid) continue;
      top = t; bottom = b; formedTime = r[i].time;
      return(true);
     }
   return(false);
  }

// Last opposite-colour candle within 5 bars before the displacement bar.
bool FindOrderBlock(MqlRates &r[], int got, int dir, datetime displacementTime, double &top, double &bottom, datetime &formedTime)
  {
   int d = IndexOfBarTime(r, got, displacementTime);
   if(d < 1) return(false);
   for(int j = d - 1; j >= MathMax(0, d - 5); j--)
     {
      bool opposite = (dir == 1) ? (r[j].close < r[j].open) : (r[j].close > r[j].open);
      if(!opposite) continue;
      for(int k = j + 1; k < got; k++)
         if((dir == 1 && r[k].close < r[j].low) || (dir == -1 && r[k].close > r[j].high)) return(false);
      top = r[j].high; bottom = r[j].low; formedTime = displacementTime;
      return(true);
     }
   return(false);
  }

uint Fnv1a32(string s)
  {
   uint h = (uint)2166136261;
   int n = StringLen(s);
   for(int i = 0; i < n; i++)
     {
      h ^= (uint)StringGetCharacter(s, i);
      h *= (uint)16777619;
     }
   return(h);
  }

// Deterministic identity of the SETUP, not of the bar that triggered it:
// symbol, direction, model, the sweep and the structure break that define
// it, and its anchor level. A later bar retesting the same zone after the
// first entry was stopped out yields the SAME ID, so one setup can be
// executed once -- ever -- across ticks, bars, restarts and chart changes.
// (A retest that was blocked by a gate was never executed, so a later
// retest of that setup is still allowed.)
string BuildSetupId(X15Setup &s)
  {
   double anchor = (s.type == X15_SETUP_SWEEP_REVERSAL) ? s.sweepLevel : s.structureLevel;
   string raw = StringFormat("%s|%d|%d|%I64d|%I64d|%s", _Symbol, s.direction, (int)s.type,
                             (long)s.sweepTime, (long)s.structureTime, DoubleToString(anchor, g_spec.digits));
   return(StringFormat("%08X", Fnv1a32(raw)));
  }

// Entry reference, target and R:R. The target is the NEAREST realistic
// opposing liquidity; if that gives too little R:R the answer is no trade --
// the code never walks out to a farther level to manufacture R:R (spec 15).
bool CompleteSetupTargets(X15Setup &s)
  {
   int dir = s.direction;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0) { s.rejectReason = "no live quote"; return(false); }
   s.entryRef = (dir == 1) ? ask : bid;
   double risk = (dir == 1) ? s.entryRef - s.sl : s.sl - s.entryRef;
   if(risk <= 0.0) { s.rejectReason = "price is already beyond the structural stop"; return(false); }
   double spreadPrice = ask - bid;
   if(InpTPMode == X15_TP_FIXED_R)
     {
      s.tp = (dir == 1) ? s.entryRef + InpFixedTPR * risk : s.entryRef - InpFixedTPR * risk;
      s.tpLevelName = StringFormat("FIXED_%.1fR", InpFixedTPR);
     }
   else
     {
      double level = 0.0;
      string name = "";
      if(!FindNearestTarget(g_liq, dir, s.entryRef, InpTargetMinDistanceATR * g_structExec.atr, level, name))
        { s.rejectReason = "no unswept opposing liquidity to target"; return(false); }
      // TP fills on the far side of the spread, so it sits one spread short of the level
      s.tp = (dir == 1) ? level - spreadPrice : level + spreadPrice;
      s.tpLevelName = name;
     }
   double reward = (dir == 1) ? s.tp - s.entryRef : s.entryRef - s.tp;
   s.rr = reward / risk;
   if(s.rr < InpMinRR)
     {
      s.rejectReason = StringFormat("R:R %.2f to %s is below the %.2f minimum", s.rr, s.tpLevelName, InpMinRR);
      return(false);
     }
   s.setupId = BuildSetupId(s);
   s.valid = true;
   return(true);
  }

// Retest-and-confirm on the last closed bar: it traded into the zone and
// closed back out of it in the trade direction, as a directional candle.
bool ZoneRetestConfirmed(int dir, double zoneTop, double zoneBottom)
  {
   int b = g_execGot - 1;
   if(b < 0) return(false);
   if(dir == 1)
      return(g_execRates[b].low <= zoneTop && g_execRates[b].close > zoneBottom && g_execRates[b].close > g_execRates[b].open);
   return(g_execRates[b].high >= zoneBottom && g_execRates[b].close < zoneTop && g_execRates[b].close < g_execRates[b].open);
  }

// PRIMARY MODEL: sweep -> displacement -> MSS/BOS -> retrace into FVG/OB -> confirmation.
bool EvaluateSweepReversal(int dir, X15Setup &s)
  {
   ResetSetup(s);
   s.type = X15_SETUP_SWEEP_REVERSAL;
   s.direction = dir;
   int got = g_execGot;
   if(got < 50) { s.rejectReason = "execution data unavailable"; return(false); }
   if(!g_structExec.atrAvailable) { s.rejectReason = "ATR unavailable"; return(false); }

   bool swept = (dir == 1) ? g_liq.bullSweep : g_liq.bearSweep;
   if(!swept)
     {
      s.rejectReason = (dir == 1) ? "no sell-side liquidity sweep in lookback" : "no buy-side liquidity sweep in lookback";
      return(false);
     }
   s.sweepTime      = (dir == 1) ? g_liq.bullSweepTime    : g_liq.bearSweepTime;
   s.sweepLevel     = (dir == 1) ? g_liq.bullSweepLevel   : g_liq.bearSweepLevel;
   s.sweepExtreme   = (dir == 1) ? g_liq.bullSweepExtreme : g_liq.bearSweepExtreme;
   s.sweepLevelName = (dir == 1) ? g_liq.bullSweepName    : g_liq.bearSweepName;

   ENUM_X15_STRUCT_EVENT ev = (dir == 1) ? g_structExec.lastUpEvent : g_structExec.lastDownEvent;
   datetime te = (dir == 1) ? g_structExec.lastUpEventTime : g_structExec.lastDownEventTime;
   if(ev == X15_EVT_NONE || te < s.sweepTime) { s.rejectReason = "no structure break after the sweep"; return(false); }
   int teIdx = IndexOfBarTime(g_execRates, got, te);
   int age = (teIdx < 0) ? -1 : got - 1 - teIdx;
   if(age < 0 || age > InpSetupMaxAgeBars)
     {
      s.rejectReason = StringFormat("structure break is %d bars old (max %d)", age, InpSetupMaxAgeBars);
      return(false);
     }
   s.structureTime  = te;
   s.structureEvent = ev;
   s.structureLevel = (dir == 1) ? g_structExec.lastUpEventLevel : g_structExec.lastDownEventLevel;
   s.displacement   = FindDisplacement(g_execRates, g_execAtr, got, dir, s.sweepTime, te, s.displacementTime);

   double zt = 0.0, zb = 0.0;
   datetime zf = 0;
   if(FindFVG(g_execRates, got, dir, s.sweepTime, te, zt, zb, zf))
     { s.zoneType = "FVG"; s.zoneTop = zt; s.zoneBottom = zb; s.zoneFormedTime = zf; }
   else if(s.displacement && FindOrderBlock(g_execRates, got, dir, s.displacementTime, zt, zb, zf))
     { s.zoneType = "OB"; s.zoneTop = zt; s.zoneBottom = zb; s.zoneFormedTime = zf; }

   int b = got - 1;
   if(InpRequireZoneRetest)
     {
      if(s.zoneType == "NONE") { s.rejectReason = "no FVG/OB zone in the displacement leg"; return(false); }
      if(g_execRates[b].time <= te || g_execRates[b].time <= s.zoneFormedTime)
        { s.rejectReason = "awaiting retracement into the zone"; return(false); }
      if(!ZoneRetestConfirmed(dir, s.zoneTop, s.zoneBottom))
        { s.rejectReason = "last closed bar did not retest the zone with a confirming close"; return(false); }
     }
   else if(g_execRates[b].time != te)
     {
      s.rejectReason = "structure break is not the last closed bar (entry would be stale)";
      return(false);
     }
   s.triggerBarTime = g_execRates[b].time;

   double ref = s.sweepExtreme;
   if(s.zoneType != "NONE") ref = (dir == 1) ? MathMin(ref, s.zoneBottom) : MathMax(ref, s.zoneTop);
   double buffer = InpSLATRBuffer * g_structExec.atr;
   s.sl = (dir == 1) ? ref - buffer : ref + buffer;
   s.invalidation = (s.zoneType != "NONE") ? ((dir == 1) ? s.zoneBottom : s.zoneTop) : s.sweepExtreme;
   return(CompleteSetupTargets(s));
  }

// OPTIONAL MODEL: aligned HTF trend -> BOS with displacement -> pullback
// into FVG/OB, or into the discount/premium half of the break leg ->
// confirmation. A pullback is inherent to this model, so it always needs
// the retest, whatever InpRequireZoneRetest says.
bool EvaluateContinuation(int dir, X15Setup &s)
  {
   ResetSetup(s);
   s.type = X15_SETUP_CONTINUATION;
   s.direction = dir;
   int got = g_execGot;
   if(got < 50) { s.rejectReason = "execution data unavailable"; return(false); }
   if(!g_structExec.atrAvailable) { s.rejectReason = "ATR unavailable"; return(false); }
   if(g_htfBias.bias != dir) { s.rejectReason = "continuation needs HTF bias aligned with the trade"; return(false); }

   ENUM_X15_STRUCT_EVENT ev = (dir == 1) ? g_structExec.lastUpEvent : g_structExec.lastDownEvent;
   datetime te = (dir == 1) ? g_structExec.lastUpEventTime : g_structExec.lastDownEventTime;
   if(ev == X15_EVT_NONE) { s.rejectReason = "no structure break in the trend direction"; return(false); }
   int teIdx = IndexOfBarTime(g_execRates, got, te);
   int age = (teIdx < 0) ? -1 : got - 1 - teIdx;
   if(age < 1 || age > InpSetupMaxAgeBars)
     {
      s.rejectReason = (age == 0) ? "break is the last closed bar -- awaiting a pullback"
                                  : StringFormat("structure break is %d bars old (max %d)", age, InpSetupMaxAgeBars);
      return(false);
     }
   s.structureTime  = te;
   s.structureEvent = ev;
   s.structureLevel = (dir == 1) ? g_structExec.lastUpEventLevel : g_structExec.lastDownEventLevel;
   datetime dispFrom = g_execRates[MathMax(0, teIdx - 3)].time;
   s.displacement = FindDisplacement(g_execRates, g_execAtr, got, dir, dispFrom, te, s.displacementTime);

   int b = got - 1;
   double legLow = g_execRates[teIdx].low, legHigh = g_execRates[teIdx].high;
   for(int j = MathMax(0, teIdx - 10); j <= teIdx; j++)
     {
      legLow  = MathMin(legLow,  g_execRates[j].low);
      legHigh = MathMax(legHigh, g_execRates[j].high);
     }
   double pullbackExtreme = (dir == 1) ? g_execRates[b].low : g_execRates[b].high;
   for(int j = teIdx + 1; j <= b; j++)
     {
      if(dir == 1) { legHigh = MathMax(legHigh, g_execRates[j].high); pullbackExtreme = MathMin(pullbackExtreme, g_execRates[j].low); }
      else         { legLow  = MathMin(legLow,  g_execRates[j].low);  pullbackExtreme = MathMax(pullbackExtreme, g_execRates[j].high); }
     }

   double zt = 0.0, zb = 0.0;
   datetime zf = 0;
   if(FindFVG(g_execRates, got, dir, dispFrom, te, zt, zb, zf))
     { s.zoneType = "FVG"; s.zoneTop = zt; s.zoneBottom = zb; s.zoneFormedTime = zf; }
   else if(s.displacement && FindOrderBlock(g_execRates, got, dir, s.displacementTime, zt, zb, zf))
     { s.zoneType = "OB"; s.zoneTop = zt; s.zoneBottom = zb; s.zoneFormedTime = zf; }
   else
     {
      double mid = (legHigh + legLow) / 2.0;
      s.zoneType = (dir == 1) ? "DISCOUNT" : "PREMIUM";
      s.zoneTop    = (dir == 1) ? mid : legHigh;
      s.zoneBottom = (dir == 1) ? legLow : mid;
      s.zoneFormedTime = te;
     }
   if(g_execRates[b].time <= s.zoneFormedTime) { s.rejectReason = "awaiting pullback into the zone"; return(false); }
   if(!ZoneRetestConfirmed(dir, s.zoneTop, s.zoneBottom))
     { s.rejectReason = "last closed bar did not retest the pullback zone with a confirming close"; return(false); }
   s.triggerBarTime = g_execRates[b].time;

   double ref = (dir == 1) ? MathMin(pullbackExtreme, s.zoneBottom) : MathMax(pullbackExtreme, s.zoneTop);
   double buffer = InpSLATRBuffer * g_structExec.atr;
   s.sl = (dir == 1) ? ref - buffer : ref + buffer;
   s.invalidation = (dir == 1) ? s.zoneBottom : s.zoneTop;
   return(CompleteSetupTargets(s));
  }

//====================================================================
// LAYER 4 -- COMPOSITE DECISION ENGINE  (spec 6, 9, 12)
//--------------------------------------------------------------------
// Transparent evidence, not an "AI confidence": every component is a named
// PASS / FAIL / UNAVAILABLE / N/A with the reason attached. UNAVAILABLE is
// never counted as a pass (spec 39: unavailable data is never
// confirmation). Hard components veto regardless of the soft score.
//====================================================================
#define X15_MAX_COMPONENTS 16
#define X15_PASS         1
#define X15_FAIL         0
#define X15_UNAVAILABLE -1
#define X15_NA           2

struct X15Component
  {
   string            name;
   int               status;
   string            detail;
   bool              hard;
  };

struct X15Decision
  {
   datetime          barTime;
   bool              computed;
   ENUM_X15_DIR_STATE state;
   string            stateReason;
   X15Setup          setup;
   string            longReject;
   string            shortReject;
   int               componentCount;
   X15Component      comps[X15_MAX_COMPONENTS];
   int               evidenceScore;
   int               evidenceMax;
   string            vwapState;
   string            vpmacdState;
  };
X15Decision g_decision;

void ResetDecision(X15Decision &d)
  {
   d.barTime = 0; d.computed = false;
   d.state = X15_DIR_NEUTRAL; d.stateReason = "";
   ResetSetup(d.setup);
   d.longReject = ""; d.shortReject = "";
   d.componentCount = 0;
   d.evidenceScore = 0; d.evidenceMax = 0;
   d.vwapState = "UNAVAILABLE"; d.vpmacdState = "UNAVAILABLE";
  }

void AddComponent(X15Decision &d, string name, int status, string detail, bool hard)
  {
   if(d.componentCount >= X15_MAX_COMPONENTS) return;
   int i = d.componentCount;
   d.comps[i].name = name;
   d.comps[i].status = status;
   d.comps[i].detail = detail;
   d.comps[i].hard = hard;
   d.componentCount++;
   if(!hard && status != X15_NA)
     {
      d.evidenceMax++;
      if(status == X15_PASS) d.evidenceScore++;
     }
  }

string StatusLabel(int status)
  {
   if(status == X15_PASS) return("PASS");
   if(status == X15_FAIL) return("FAIL");
   if(status == X15_UNAVAILABLE) return("UNAVAILABLE");
   return("N/A");
  }

// HTF hard gate for one candidate setup; empty string = passes.
string HTFGateFailure(X15Setup &s)
  {
   if(!InpRequireHTFAlignment) return("");
   if(!g_htfBias.available) return("higher-timeframe structure unavailable");
   if(g_htfBias.conflict) return("conflicting higher-timeframe structure (" + g_htfBias.detail + ")");
   if(g_htfBias.bias == -s.direction) return("setup opposes the higher-timeframe bias");
   if(g_htfBias.bias == 0)
     {
      if(s.type == X15_SETUP_SWEEP_REVERSAL && InpAllowRangeHTFReversal) return("");
      return("higher timeframe has no clear bias");
     }
   return("");
  }

int SignalAgreement(string state, int dir)
  {
   if(state == "UNAVAILABLE") return(X15_UNAVAILABLE);
   if((dir == 1 && state == "BULLISH") || (dir == -1 && state == "BEARISH")) return(X15_PASS);
   return(X15_FAIL);
  }

void BuildEvidence(X15Decision &d, X15Setup &s)
  {
   d.componentCount = 0; d.evidenceScore = 0; d.evidenceMax = 0;
   int dir = s.direction;
   string structTxt = EnumLabel(EnumToString(s.structureEvent), "X15_EVT_") + " @ " + DoubleToString(s.structureLevel, g_spec.digits);

   // hard components
   AddComponent(d, "STRUCTURE", (s.structureEvent != X15_EVT_NONE) ? X15_PASS : X15_FAIL, structTxt, true);
   string htfFail = HTFGateFailure(s);
   AddComponent(d, "HTF_GATE", (htfFail == "") ? X15_PASS : X15_FAIL, (htfFail == "") ? g_htfBias.state : htfFail, true);
   AddComponent(d, "NEWS", g_newsGate.blocks ? X15_FAIL : X15_PASS, g_newsGate.state + (g_newsGate.detail != "" ? " " + g_newsGate.detail : ""), true);
   AddComponent(d, "R:R", (s.rr >= InpMinRR) ? X15_PASS : X15_FAIL, StringFormat("%.2f to %s (min %.2f)", s.rr, s.tpLevelName, InpMinRR), true);

   // soft evidence
   AddComponent(d, "HTF_ALIGNED", (g_htfBias.bias == dir) ? X15_PASS : X15_FAIL, g_htfBias.state, false);
   if(s.type == X15_SETUP_SWEEP_REVERSAL)
      AddComponent(d, "LIQUIDITY_SWEEP", X15_PASS, s.sweepLevelName + " @ " + DoubleToString(s.sweepLevel, g_spec.digits), false);
   else
     {
      bool sweptToo = (dir == 1) ? g_liq.bullSweep : g_liq.bearSweep;
      AddComponent(d, "LIQUIDITY_SWEEP", sweptToo ? X15_PASS : X15_FAIL, sweptToo ? "recent sweep supports the move" : "no recent sweep", false);
     }
   AddComponent(d, "DISPLACEMENT", !g_structExec.atrAvailable ? X15_UNAVAILABLE : (s.displacement ? X15_PASS : X15_FAIL),
                s.displacement ? TimeToString(s.displacementTime, TIME_DATE|TIME_MINUTES) : "none in leg", false);
   bool zoneReal = (s.zoneType == "FVG" || s.zoneType == "OB");
   AddComponent(d, "FVG_OB_ZONE", zoneReal ? X15_PASS : X15_FAIL,
                s.zoneType + " " + DoubleToString(s.zoneBottom, g_spec.digits) + "-" + DoubleToString(s.zoneTop, g_spec.digits), false);
   if(g_liq.equilibrium <= 0.0)
      AddComponent(d, "PREMIUM_DISCOUNT", X15_UNAVAILABLE, "dealing range unavailable", false);
   else
     {
      bool ok = (dir == 1) ? (s.entryRef < g_liq.equilibrium) : (s.entryRef > g_liq.equilibrium);
      AddComponent(d, "PREMIUM_DISCOUNT", ok ? X15_PASS : X15_FAIL,
                   StringFormat("entry %s equilibrium %s", (s.entryRef < g_liq.equilibrium) ? "below" : "above",
                                DoubleToString(g_liq.equilibrium, g_spec.digits)), false);
     }
   AddComponent(d, "VWAP", InpVWAPCountsAsEvidence ? SignalAgreement(d.vwapState, dir) : X15_NA, d.vwapState, false);
   AddComponent(d, "VP_MACD", InpVPMACDCountsAsEvidence ? SignalAgreement(d.vpmacdState, dir) : X15_NA, d.vpmacdState, false);
   AddComponent(d, "REGIME", !g_regime.available ? X15_UNAVAILABLE : (RegimeFitsSetup(g_regime.regime, s.type) ? X15_PASS : X15_FAIL),
                EnumLabel(EnumToString(g_regime.regime), "X15_REGIME_"), false);
  }

// The previously stubbed extension point, now a real decision engine.
// Returns one of LONG / SHORT / NEUTRAL / BLOCKED / DATA_UNAVAILABLE /
// INSUFFICIENT_EVIDENCE and fills `d` with the setup and every reason.
ENUM_X15_DIR_STATE GetCompositeDirection(X15Decision &d)
  {
   ResetDecision(d);
   d.barTime = (g_execGot > 0) ? g_execRates[g_execGot-1].time : 0;
   d.computed = true;
   if(!g_dq.ok) { d.state = X15_DIR_DATA_UNAVAILABLE; d.stateReason = g_dq.reason; return(d.state); }
   if(!g_structExec.available) { d.state = X15_DIR_DATA_UNAVAILABLE; d.stateReason = g_structExec.unavailableReason; return(d.state); }
   if(!g_htfBias.available) { d.state = X15_DIR_DATA_UNAVAILABLE; d.stateReason = g_htfBias.detail; return(d.state); }
   if(!g_liq.available) { d.state = X15_DIR_DATA_UNAVAILABLE; d.stateReason = g_liq.reason; return(d.state); }

   d.vwapState   = g_vwapClosedState;
   d.vpmacdState = ClassifyVPMACDState();

   // every model x direction; a candidate survives only if it also clears the HTF hard gate
   X15Setup cands[4];
   int nValid = 0;
   int dirs[2];
   dirs[0] = 1; dirs[1] = -1;
   for(int di = 0; di < 2; di++)
     {
      int dir = dirs[di];
      string rejects = "";
      X15Setup a, c;
      if(InpUseSweepReversal)
        {
         if(EvaluateSweepReversal(dir, a))
           {
            string htf = HTFGateFailure(a);
            if(htf == "") { cands[nValid] = a; nValid++; }
            else rejects += "reversal: " + htf + "; ";
           }
         else rejects += "reversal: " + a.rejectReason + "; ";
        }
      if(InpUseContinuation)
        {
         if(EvaluateContinuation(dir, c))
           {
            string htf = HTFGateFailure(c);
            if(htf == "") { cands[nValid] = c; nValid++; }
            else rejects += "continuation: " + htf + "; ";
           }
         else rejects += "continuation: " + c.rejectReason + "; ";
        }
      if(dir == 1) d.longReject = rejects; else d.shortReject = rejects;
     }

   if(nValid == 0)
     {
      d.state = X15_DIR_NEUTRAL;
      d.stateReason = "no valid setup";
      return(d.state);
     }
   bool anyLong = false, anyShort = false;
   for(int i = 0; i < nValid; i++) { if(cands[i].direction == 1) anyLong = true; else anyShort = true; }
   if(anyLong && anyShort)
     {
      d.state = X15_DIR_NEUTRAL;
      d.stateReason = "valid long AND short setups on the same bar -- conflicting, no trade";
      return(d.state);
     }

   // same direction from both models: keep the one with more evidence (ties -> the primary model)
   int best = 0, bestScore = -1;
   for(int i = 0; i < nValid; i++)
     {
      BuildEvidence(d, cands[i]);
      if(d.evidenceScore > bestScore) { bestScore = d.evidenceScore; best = i; }
     }
   d.setup = cands[best];
   BuildEvidence(d, d.setup);

   if(g_newsGate.blocks)
     {
      d.state = X15_DIR_BLOCKED;
      d.stateReason = "News Defense: " + g_newsGate.state + (g_newsGate.detail != "" ? " -- " + g_newsGate.detail : "");
      return(d.state);
     }
   if(d.evidenceScore < InpMinEvidenceScore)
     {
      d.state = X15_DIR_INSUFFICIENT_EVIDENCE;
      d.stateReason = StringFormat("evidence %d/%d below minimum %d", d.evidenceScore, d.evidenceMax, InpMinEvidenceScore);
      return(d.state);
     }
   d.state = (d.setup.direction == 1) ? X15_DIR_LONG : X15_DIR_SHORT;
   d.stateReason = StringFormat("%s %s, evidence %d/%d, R:R %.2f",
                                EnumLabel(EnumToString(d.setup.type), "X15_SETUP_"), DirLabel(d.setup.direction),
                                d.evidenceScore, d.evidenceMax, d.setup.rr);
   return(d.state);
  }

//====================================================================
// MARKET ANALYSIS ORCHESTRATION -- once per new closed execution bar
//====================================================================
ENUM_X15_STATE   g_state   = X15_ST_INITIALIZING;
ENUM_X15_SESSION g_session = X15_SESSION_OFF;
datetime         g_lastAnalysisTime = 0;

void RefreshHTFStructure(int slot, ENUM_TIMEFRAMES tf)
  {
   datetime lastClosed = iTime(_Symbol, tf, 1);
   if(g_structHTF[slot].available && g_structHTF[slot].lastClosedBarTime == lastClosed) return; // nothing new closed on this TF
   MqlRates r[];
   double a[];
   AnalyzeStructure(tf, g_atrHTF[slot], InpSwingStrengthHTF, g_structHTF[slot], r, a);
  }

void RunMarketAnalysis(void)
  {
   g_state = X15_ST_DATA_CHECK;
   EvaluateDataQuality(g_dq);
   g_session = SessionAt(TimeCurrent());
   if(!g_dq.ok)
     {
      g_state = X15_ST_DATA_UNAVAILABLE;
      ResetDecision(g_decision);
      g_decision.computed = true;
      g_decision.state = X15_DIR_DATA_UNAVAILABLE;
      g_decision.stateReason = g_dq.reason;
      X15Log("DATA", "data unavailable: " + g_dq.reason);
      return;
     }

   g_state = X15_ST_MARKET_ANALYSIS;
   if(!AnalyzeStructure(InpExecTF, g_atrExec, InpSwingStrengthExec, g_structExec, g_execRates, g_execAtr))
      X15Log("STRUCTURE", "execution structure unavailable: " + g_structExec.unavailableReason);
   g_execGot = ArraySize(g_execRates);
   RefreshHTFStructure(0, InpHTF1);
   RefreshHTFStructure(1, InpHTF2);
   RefreshHTFStructure(2, InpHTF3);
   if(!g_structW1.available || g_structW1.lastClosedBarTime != iTime(_Symbol, PERIOD_W1, 1))
     {
      MqlRates r[];
      double a[];
      AnalyzeStructure(PERIOD_W1, INVALID_HANDLE, 2, g_structW1, r, a);
     }
   EvaluateHTFBias(g_structHTF[0], g_structHTF[1], g_structHTF[2], g_htfBias);
   BuildLiquidity(g_liq);
   EvaluateNewsGate(g_newsGate);
   ClassifyRegime(g_regime, g_newsGate.eventActive);
   g_vwapClosedState = ClassifyVWAPClosedBar();

   g_state = X15_ST_SETUP_SEARCH;
   GetCompositeDirection(g_decision);
   g_lastAnalysisTime = TimeCurrent();
   X15Log("SIGNAL", StringFormat("%s -- %s", EnumLabel(EnumToString(g_decision.state), "X15_DIR_"), g_decision.stateReason), false, true);
  }

//====================================================================
// EXECUTION-LAYER STATE
//====================================================================
bool     g_reconcileRequested = true;
bool     g_stateDirty = false;
bool     g_perfDirty = true;
bool     g_sendInFlight = false;
datetime g_lastTradeTime = 0;
string   g_lastError = "";
datetime g_lastErrorTime = 0;
ulong    g_paperCounter = 0;
datetime g_runStartTime = 0;

void X15Error(string category, string message)
  {
   g_lastError = "[" + category + "] " + message;
   g_lastErrorTime = TimeCurrent();
   X15Log(category, message, true);
  }

bool IsTester(void)
  {
   return(MQLInfoInteger(MQL_TESTER) != 0);
  }

bool IsNettingAccount(void)
  {
   return(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
  }

// Journal source for trades this run places itself.
ENUM_X15_TRADE_SOURCE OwnTradeSource(void)
  {
   if(InpExecutionMode == X15_PAPER_EXECUTION) return(X15_SRC_PAPER);
   if(IsTester()) return(X15_SRC_TESTER);
   return(X15_SRC_LIVE);
  }

string SourceLabel(ENUM_X15_TRADE_SOURCE s)
  {
   return(EnumLabel(EnumToString(s), "X15_SRC_"));
  }

string ExitReasonLabel(ENUM_X15_EXIT_REASON r)
  {
   return(EnumLabel(EnumToString(r), "X15_EXIT_"));
  }

double NormalizePriceToTick(double price)
  {
   if(g_spec.tickSize <= 0.0) return(NormalizeDouble(price, g_spec.digits));
   return(NormalizeDouble(MathRound(price / g_spec.tickSize) * g_spec.tickSize, g_spec.digits));
  }

int VolumeDigits(void)
  {
   int d = 0;
   double s = g_spec.volStep;
   while(s > 0.0 && MathAbs(s - MathRound(s)) > 1e-8 && d < 8) { s *= 10.0; d++; }
   return(d);
  }

// Floors to the broker volume step. Below the broker minimum it returns 0:
// a position is never rounded UP into more risk than was budgeted.
double FloorLots(double rawLots)
  {
   double step = (g_spec.volStep > 0.0) ? g_spec.volStep : 0.01;
   double v = MathFloor(rawLots / step + 1e-9) * step;
   v = MathMin(v, g_spec.volMax);
   if(v < g_spec.volMin - 1e-12) return(0.0);
   return(NormalizeDouble(v, VolumeDigits()));
  }

// Broker stops level and freeze level, whichever is larger. Stops placed at
// least this far away can also be modified later without hitting the freeze.
double MinStopDistancePrice(void)
  {
   return(MathMax(g_spec.stopsLevelPts, g_spec.freezeLevelPts) * g_spec.point);
  }

//====================================================================
// POSITION REGISTRY
//====================================================================
void ResetPosition(X15Position &p)
  {
   p.positionId = 0; p.ticket = 0; p.isOwn = false; p.isPaper = false; p.isPreExisting = false;
   p.setupId = ""; p.setupType = X15_SETUP_NONE; p.direction = 0;
   p.entryTime = 0; p.entryBarTime = 0; p.entryPrice = 0.0; p.avgEntryPrice = 0.0;
   p.volume = 0.0; p.peakVolume = 0.0;
   p.originalSL = 0.0; p.originalTP = 0.0; p.currentSL = 0.0; p.currentTP = 0.0;
   p.riskPct = 0.0; p.riskMoney = 0.0; p.invalidation = 0.0; p.spreadAtEntryPts = 0.0;
   p.beDone = false; p.partialDone = false; p.modifyFailCount = 0; p.lastModifyTime = 0;
   p.firstExitTime = 0; p.pendingExitReason = X15_EXIT_NONE;
   p.isFlip = false; p.evidenceScore = 0;
   p.vwapAligned = false; p.vpMacdAligned = false; p.nearValidatedNewsEvent = false; p.newsEventNameAtEntry = "";
   p.vwapState = "UNKNOWN"; p.vpmacdState = "UNKNOWN"; p.newsState = "UNKNOWN"; p.compositeState = "UNKNOWN";
   p.regime = "UNKNOWN"; p.structureState = "UNKNOWN"; p.liquidityState = "UNKNOWN"; p.session = "UNKNOWN";
   p.entryReason = "";
   p.paperExitPriceVolume = 0.0; p.paperExitVolume = 0.0; p.paperGross = 0.0;
   p.closed = false; p.isPendingOrder = false; p.pendingPrice = 0.0; p.pendingExpiry = 0;
   p.finalizeAttempts = 0;
   p.valuationFailed = false;
   p.requestedPrice = 0.0;
   p.vwapFavorableSeen = false;
   p.lastCloseAttempt = 0;
   p.closeFailCount = 0;
  }

int FindPositionIndex(ulong positionId, bool isPaper)
  {
   for(int i = 0; i < ArraySize(g_positions); i++)
      if(g_positions[i].positionId == positionId && g_positions[i].isPaper == isPaper) return(i);
   return(-1);
  }

void RemovePositionAt(int idx)
  {
   int n = ArraySize(g_positions);
   if(idx < 0 || idx >= n) return;
   for(int i = idx; i < n - 1; i++) g_positions[i] = g_positions[i+1];
   ArrayResize(g_positions, n - 1);
   g_stateDirty = true;
  }

void AppendPosition(X15Position &p)
  {
   int n = ArraySize(g_positions);
   ArrayResize(g_positions, n + 1);
   g_positions[n] = p;
   g_stateDirty = true;
  }

// Finds the live position by its immutable identifier and leaves it
// SELECTED; ticketOut is its current (possibly changed) ticket.
bool SelectLivePositionById(ulong positionId, ulong &ticketOut)
  {
   ticketOut = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if((ulong)PositionGetInteger(POSITION_IDENTIFIER) == positionId) { ticketOut = t; return(true); }
     }
   return(false);
  }

int OwnOpenPositionCount(void)
  {
   int c = 0;
   for(int i = 0; i < ArraySize(g_positions); i++)
      if(g_positions[i].isOwn && !g_positions[i].closed && !g_positions[i].isPendingOrder) c++;
   return(c);
  }

//====================================================================
// LEARNING FILTER  (spec 22)
//--------------------------------------------------------------------
// Only completed, valid trades this EA placed itself are learned from.
// External positions (manual, other EAs) and rejected/incomplete records
// are journaled for audit but never feed a gate, a bonus or the Kelly
// bound. Legacy v1 rows could have come from any position on the symbol,
// so they are excluded unless the operator explicitly opts in.
//====================================================================
bool IsLearnable(JournalEntry &e)
  {
   if(!e.valid) return(false);
   if(!UsePersistentJournal && e.closeTime < g_runStartTime) return(false); // learning starts fresh; the file is kept for the hard limits
   if(e.source == X15_SRC_EXTERNAL) return(false);
   if(e.source == X15_SRC_LEGACY) return(InpLearningSource == X15_LEARN_ALL_OWN);
   if(e.source == X15_SRC_PAPER) return(InpLearningSource != X15_LEARN_LIVE_ONLY);
   return(true); // LIVE, TESTER
  }

bool JournalHasPosition(ulong positionId, ENUM_X15_TRADE_SOURCE source)
  {
   if(positionId == 0) return(false);
   for(int i = ArraySize(g_journal) - 1; i >= 0; i--)
      if(g_journal[i].positionId == positionId && g_journal[i].source == source) return(true);
   return(false);
  }

// Most recent close of this EA's own trades on this symbol (for cooldown and flip detection).
bool LastOwnClose(datetime &closeTime, int &direction)
  {
   closeTime = 0; direction = 0;
   ENUM_X15_TRADE_SOURCE src = OwnTradeSource();
   for(int i = ArraySize(g_journal) - 1; i >= 0; i--)
     {
      if(g_journal[i].source != src || g_journal[i].symbol != _Symbol) continue;
      closeTime = g_journal[i].closeTime;
      direction = g_journal[i].direction;
      return(true);
     }
   return(false);
  }

// Trailing streak of losing own trades. Read from the persisted journal, so
// neither a restart nor a new day resets it -- the pause expires only with
// time (InpConsecutiveLossPauseHours) or a winning trade.
int ConsecutiveOwnLosses(datetime &lastLossTime)
  {
   lastLossTime = 0;
   ENUM_X15_TRADE_SOURCE src = OwnTradeSource();
   int streak = 0;
   for(int i = ArraySize(g_journal) - 1; i >= 0; i--)
     {
      if(g_journal[i].source != src || g_journal[i].symbol != _Symbol || !g_journal[i].valid) continue;
      if(g_journal[i].netProfit < 0.0)
        {
         streak++;
         if(lastLossTime == 0) lastLossTime = g_journal[i].closeTime;
        }
      else if(g_journal[i].netProfit > 0.0) break;
     }
   return(streak);
  }

//====================================================================
// ACCOUNT LOSS LIMITS  (spec 5, 17)
//--------------------------------------------------------------------
// Derived from deal history, not from an equity snapshot taken at EA start:
// with a snapshot, restarting the EA after a losing morning would reset
// the day's baseline and quietly re-open the daily loss budget.
//====================================================================
struct X15LossMetrics
  {
   bool              available;
   double            dailyPnL;
   double            dailyLossPct;
   double            weeklyPnL;
   double            weeklyLossPct;
   string            detail;
  };
X15LossMetrics g_loss;

datetime ServerDayStart(datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return(t - (dt.hour*3600 + dt.min*60 + dt.sec));
  }

datetime ServerWeekStart(datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   int daysSinceMonday = (dt.day_of_week + 6) % 7;
   return(ServerDayStart(t) - daysSinceMonday * 86400);
  }

double PaperFloatingPnL(void)
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID), ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double total = 0.0;
   for(int i = 0; i < ArraySize(g_positions); i++)
     {
      if(!g_positions[i].isPaper || g_positions[i].closed || g_positions[i].isPendingOrder) continue;
      double exitPx = (g_positions[i].direction == 1) ? bid : ask;
      double pr = 0.0;
      if(OrderCalcProfit(g_positions[i].direction == 1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol,
                         g_positions[i].volume, g_positions[i].avgEntryPrice, exitPx, pr))
         total += pr;
     }
   return(total);
  }

void ComputeLossMetrics(X15LossMetrics &m)
  {
   m.available = false;
   m.dailyPnL = 0.0; m.dailyLossPct = 0.0; m.weeklyPnL = 0.0; m.weeklyLossPct = 0.0; m.detail = "";
   datetime now = TimeCurrent();
   datetime dayStart = ServerDayStart(now);
   datetime weekStart = ServerWeekStart(now);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0.0) { m.detail = "account balance unavailable"; return; }
   double realizedDay = 0.0, realizedWeek = 0.0, floating = 0.0;
   bool paper = (InpExecutionMode == X15_PAPER_EXECUTION);
   if(paper)
     {
      for(int i = 0; i < ArraySize(g_journal); i++)
        {
         if(g_journal[i].source != X15_SRC_PAPER) continue;
         if(g_journal[i].closeTime >= weekStart) realizedWeek += g_journal[i].netProfit;
         if(g_journal[i].closeTime >= dayStart)  realizedDay  += g_journal[i].netProfit;
        }
      floating = PaperFloatingPnL();
     }
   else
     {
      if(!HistorySelect(weekStart, now + 60)) { m.detail = "deal history unavailable"; return; }
      int n = HistoryDealsTotal();
      for(int i = 0; i < n; i++)
        {
         ulong d = HistoryDealGetTicket(i);
         if(d == 0) continue;
         long type = HistoryDealGetInteger(d, DEAL_TYPE);
         if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue; // deposits, withdrawals and credits are not trading results
         double pnl = HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_COMMISSION)
                      + HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_FEE);
         datetime t = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
         realizedWeek += pnl;
         if(t >= dayStart) realizedDay += pnl;
        }
      floating = AccountInfoDouble(ACCOUNT_EQUITY) - balance;
     }
   double dayBase  = paper ? balance : balance - realizedDay;
   double weekBase = paper ? balance : balance - realizedWeek;
   m.dailyPnL  = realizedDay + floating;
   m.weeklyPnL = realizedWeek + floating;
   m.dailyLossPct  = (dayBase  > 0.0) ? MathMax(0.0, -m.dailyPnL)  / dayBase  * 100.0 : 0.0;
   m.weeklyLossPct = (weekBase > 0.0) ? MathMax(0.0, -m.weeklyPnL) / weekBase * 100.0 : 0.0;
   m.available = true;
  }

//====================================================================
// EXPOSURE  (spec 4, 5)
//--------------------------------------------------------------------
// Counts THIS EA's positions and pending orders (by magic number) plus its
// paper positions. Risk is the money lost if every one of them hit its
// current SL, valued with the broker's own OrderCalcProfit.
//====================================================================
struct X15Exposure
  {
   int               total;
   int               symbolTotal;
   int               symbolLong;
   int               symbolShort;
   int               pending;
   bool              foreignOnSymbol;
   bool              unprotected;     // an own position with no SL: undefined risk
   double            openRiskMoney;
  };

void AddRiskToSL(X15Exposure &e, string sym, int dir, double volume, double openPrice, double sl)
  {
   if(sl <= 0.0) { e.unprotected = true; return; }
   double pr = 0.0;
   if(OrderCalcProfit(dir == 1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, sym, volume, openPrice, sl, pr) && pr < 0.0)
      e.openRiskMoney += -pr;
  }

void ComputeExposure(X15Exposure &e)
  {
   e.total = 0; e.symbolTotal = 0; e.symbolLong = 0; e.symbolShort = 0; e.pending = 0;
   e.foreignOnSymbol = false; e.unprotected = false; e.openRiskMoney = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0) continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
        {
         if(sym == _Symbol) e.foreignOnSymbol = true;
         continue;
        }
      int dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      e.total++;
      if(sym == _Symbol) { e.symbolTotal++; if(dir == 1) e.symbolLong++; else e.symbolShort++; }
      AddRiskToSL(e, sym, dir, PositionGetDouble(POSITION_VOLUME), PositionGetDouble(POSITION_PRICE_OPEN), PositionGetDouble(POSITION_SL));
     }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0 || (ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      string sym = OrderGetString(ORDER_SYMBOL);
      long type = OrderGetInteger(ORDER_TYPE);
      int dir = (type == ORDER_TYPE_BUY || type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_BUY_STOP_LIMIT) ? 1 : -1;
      e.total++; e.pending++;
      if(sym == _Symbol) { e.symbolTotal++; if(dir == 1) e.symbolLong++; else e.symbolShort++; }
      AddRiskToSL(e, sym, dir, OrderGetDouble(ORDER_VOLUME_CURRENT), OrderGetDouble(ORDER_PRICE_OPEN), OrderGetDouble(ORDER_SL));
     }
   for(int i = 0; i < ArraySize(g_positions); i++)
     {
      if(!g_positions[i].isPaper || g_positions[i].closed) continue;
      int dir = g_positions[i].direction;
      e.total++; e.symbolTotal++;
      if(dir == 1) e.symbolLong++; else e.symbolShort++;
      if(g_positions[i].isPendingOrder)
        {
         e.pending++;
         AddRiskToSL(e, _Symbol, dir, g_positions[i].volume, g_positions[i].pendingPrice, g_positions[i].currentSL);
        }
      else AddRiskToSL(e, _Symbol, dir, g_positions[i].volume, g_positions[i].avgEntryPrice, g_positions[i].currentSL);
     }
  }

//====================================================================
// BROKER, MARKET AND EXECUTION-QUALITY CHECKS  (spec 3, 25, 26)
//====================================================================
bool TradingPermitted(int dir, bool needLivePermissions, string &why)
  {
   why = "";
   if(needLivePermissions)
     {
      if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) { why = "terminal AutoTrading is disabled"; return(false); }
      if(!MQLInfoInteger(MQL_TRADE_ALLOWED))           { why = "algo trading is not allowed for this EA"; return(false); }
      if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))   { why = "trading is not allowed on this account"; return(false); }
      if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))    { why = "the broker does not allow EA trading on this account"; return(false); }
     }
   long mode = g_spec.tradeMode;
   if(mode == SYMBOL_TRADE_MODE_DISABLED)                { why = "trading is disabled on this symbol"; return(false); }
   if(mode == SYMBOL_TRADE_MODE_CLOSEONLY)               { why = "symbol is close-only"; return(false); }
   if(mode == SYMBOL_TRADE_MODE_LONGONLY && dir == -1)   { why = "symbol is long-only"; return(false); }
   if(mode == SYMBOL_TRADE_MODE_SHORTONLY && dir == 1)   { why = "symbol is short-only"; return(false); }
   return(true);
  }

// Inside one of the broker's own trading sessions for the symbol today.
bool SymbolSessionOpenNow(string &why)
  {
   why = "";
   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);
   int secOfDay = dt.hour*3600 + dt.min*60 + dt.sec;
   bool anySession = false;
   for(uint s = 0; s < 16; s++)
     {
      datetime from = 0, to = 0;
      if(!SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)dt.day_of_week, s, from, to)) break;
      anySession = true;
      int f = (int)from, e = (int)to;
      if(e <= f) e += 86400;
      if(secOfDay >= f && secOfDay < e) return(true);
     }
   why = anySession ? "outside the symbol's trading session" : "no trading session for the symbol today";
   return(false);
  }

bool SpreadAcceptable(string &why)
  {
   why = "";
   double sp = CurrentSpreadPoints();
   if(sp < 0.0) { why = "spread unavailable"; return(false); }
   if(InpMaxSpreadPoints > 0.0 && sp > InpMaxSpreadPoints)
     { why = StringFormat("spread %.0f pts above cap %.0f", sp, InpMaxSpreadPoints); return(false); }
   if(g_structExec.atrAvailable && g_spec.point > 0.0)
     {
      double atrPts = g_structExec.atr / g_spec.point;
      if(sp > InpMaxSpreadATRFraction * atrPts)
        { why = StringFormat("spread %.0f pts > %.2f x ATR (%.0f pts)", sp, InpMaxSpreadATRFraction, atrPts); return(false); }
     }
   double avg = RecentAverageSpreadPoints();
   if(avg > 0.0 && sp > InpSpreadAbnormalMultiple * avg)
     { why = StringFormat("spread %.0f pts abnormal (%.1fx recent average %.1f)", sp, sp / avg, avg); return(false); }
   return(true);
  }

bool ExecutionQualityOk(string &why)
  {
   why = "";
   if(!IsTester() && (g_dq.tickAgeSec < 0.0 || g_dq.tickAgeSec > InpMaxTickAgeSeconds))
     { why = StringFormat("stale quote (%.0f s old, max %d)", g_dq.tickAgeSec, InpMaxTickAgeSeconds); return(false); }
   if(InpMaxPingMs > 0 && !IsTester())
     {
      double pingMs = TerminalInfoInteger(TERMINAL_PING_LAST) / 1000.0;
      if(pingMs > InpMaxPingMs) { why = StringFormat("terminal ping %.0f ms above %d", pingMs, InpMaxPingMs); return(false); }
     }
   if(!TerminalInfoInteger(TERMINAL_CONNECTED) && !IsTester()) { why = "terminal is not connected to the trade server"; return(false); }
   return(true);
  }

//====================================================================
// LAYER 6 -- RISK ENGINE  (spec 16, 17)
//--------------------------------------------------------------------
// Base risk -> evidence bonuses -> adaptive multiplier clamps -> flip cap
// -> max risk (all inside ComputeAdaptiveRisk) -> regime REDUCTION ->
// manual override (can only lower) -> hard cap -> volume. Nothing on this
// path reads the loss streak, so a loss can never raise the next trade's
// risk.
//====================================================================
double ComputeFinalRiskPct(int dir, bool isFlip, string &trace)
  {
   double r = ComputeAdaptiveRisk(_Symbol, dir, isFlip);
   trace = StringFormat("adaptive %.3f%%", r);
   if(g_regime.regime == X15_REGIME_HIGH_VOLATILITY)
     {
      double scale = MathMax(0.0, MathMin(1.0, InpHighVolRiskScale));
      r *= scale;
      trace += StringFormat(" x%.2f high-vol", scale);
     }
   if(InpMaxRiskOverridePct > 0.0 && r > InpMaxRiskOverridePct) { r = InpMaxRiskOverridePct; trace += " -> manual cap"; }
   if(r > InpMaxRiskPct) { r = InpMaxRiskPct; trace += " -> hard cap"; }
   trace += StringFormat(" = %.3f%%", r);
   return(r);
  }

// Volume from risk: tick value (loss side) estimate first, then the money
// actually at risk is VALIDATED with the broker's own OrderCalcProfit (which
// handles contract size and account-currency conversion) and the volume is
// stepped down until it fits the budget. If the broker cannot value it, or
// even the minimum lot exceeds the budget: no trade.
bool SizeForRisk(int dir, double entry, double sl, double riskPct, double &lots, double &riskMoney, string &why)
  {
   lots = 0.0; riskMoney = 0.0; why = "";
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0.0) { why = "account equity unavailable"; return(false); }
   double budget = equity * riskPct / 100.0;
   double dist = MathAbs(entry - sl);
   double tv = (g_spec.tickValueLoss > 0.0) ? g_spec.tickValueLoss : g_spec.tickValue;
   double perLot = (g_spec.tickSize > 0.0) ? dist / g_spec.tickSize * tv : 0.0;
   if(dist <= 0.0 || perLot <= 0.0) { why = "stop distance cannot be valued"; return(false); }
   double v = FloorLots(budget / perLot);
   if(v <= 0.0)
     {
      why = StringFormat("risk budget %.2f buys %.4f lots, below the broker minimum %.2f -- not rounding up", budget, budget / perLot, g_spec.volMin);
      return(false);
     }
   ENUM_ORDER_TYPE type = (dir == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   for(int guard = 0; guard < 1000; guard++)
     {
      double profit = 0.0;
      if(!OrderCalcProfit(type, _Symbol, v, entry, sl, profit)) { why = "OrderCalcProfit failed -- monetary risk cannot be validated"; return(false); }
      double loss = -profit;
      if(loss <= 0.0) { why = "stop is not on the losing side of entry"; return(false); }
      if(loss <= budget * (1.0 + 1e-9))
        {
         lots = v;
         riskMoney = loss;
         return(true);
        }
      v = FloorLots(v - g_spec.volStep);
      if(v <= 0.0) { why = "validated risk exceeds the budget even at the minimum volume"; return(false); }
     }
   why = "volume sizing did not converge";
   return(false);
  }

bool MarginAcceptable(int dir, double lots, double price, string &why)
  {
   why = "";
   double margin = 0.0;
   if(!OrderCalcMargin(dir == 1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, lots, price, margin))
     { why = "OrderCalcMargin failed -- margin cannot be validated"; return(false); }
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double usedMargin = AccountInfoDouble(ACCOUNT_MARGIN);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(margin > freeMargin) { why = StringFormat("insufficient free margin (%.2f needed, %.2f free)", margin, freeMargin); return(false); }
   if(equity <= 0.0 || (usedMargin + margin) / equity * 100.0 > InpMaxMarginUsagePct)
     { why = StringFormat("margin usage would reach %.1f%% of equity (max %.1f%%)", (equity > 0.0 ? (usedMargin + margin) / equity * 100.0 : 0.0), InpMaxMarginUsagePct); return(false); }
   return(true);
  }

//====================================================================
// SETUP STORE -- duplicate-order protection  (spec 4)
//--------------------------------------------------------------------
// Every setup ID this EA has ever acted on (sent, filled, rejected, or
// UNCERTAIN) is recorded here BEFORE the order is sent and persisted to
// disk. A setup ID present in the store is never traded again: not on the
// next tick, not after a restart, not after a reconnect. The store is also
// rebuilt from the broker's own orders/positions/history on start-up, so
// even a lost file cannot re-open an executed setup.
//====================================================================
#define X15_MAX_SETUP_RECORDS 500

struct X15SetupRecord
  {
   string            setupId;
   datetime          time;
   int               direction;
   string            status;   // SENDING, FILLED, PENDING, PAPER, REJECTED, UNCERTAIN, CANCELLED, FROM_BROKER, ...
   ulong             ticket;
  };
X15SetupRecord g_setups[];

string SetupStoreFileName(void)
  {
   return(StringFormat("AutopsyX15_Setups_%s_%I64u%s.csv", _Symbol, InpMagicNumber, IsTester() ? "_TESTER" : ""));
  }

int FindSetupRecord(string setupId)
  {
   if(setupId == "") return(-1);
   for(int i = ArraySize(g_setups) - 1; i >= 0; i--)
      if(g_setups[i].setupId == setupId) return(i);
   return(-1);
  }

bool IsSetupConsumed(string setupId)
  {
   return(FindSetupRecord(setupId) >= 0);
  }

void SaveSetupStore(void)
  {
   string fname = SetupStoreFileName();
   string tmp = fname + ".tmp";
   int h = FileOpen(tmp, FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_SHARE_READ, ',');
   if(h == INVALID_HANDLE) { X15Error("JOURNAL", StringFormat("cannot write setup store '%s' (error %d)", tmp, GetLastError())); return; }
   for(int i = 0; i < ArraySize(g_setups); i++)
      FileWrite(h, g_setups[i].setupId, (long)g_setups[i].time, g_setups[i].direction, g_setups[i].status, (long)g_setups[i].ticket);
   FileClose(h);
   if(!FileMove(tmp, 0, fname, FILE_REWRITE))
      X15Error("JOURNAL", StringFormat("cannot move setup store into place (error %d)", GetLastError()));
  }

void RecordSetupStatus(string setupId, int direction, string status, ulong ticket, bool persist = true)
  {
   if(setupId == "") return;
   int idx = FindSetupRecord(setupId);
   if(idx < 0)
     {
      int n = ArraySize(g_setups);
      if(n >= X15_MAX_SETUP_RECORDS)
        {
         for(int i = 0; i < n - 1; i++) g_setups[i] = g_setups[i+1];
         n--;
        }
      ArrayResize(g_setups, n + 1);
      idx = n;
      g_setups[idx].setupId = setupId;
      g_setups[idx].direction = direction;
     }
   g_setups[idx].time = TimeCurrent();
   g_setups[idx].status = status;
   if(ticket != 0) g_setups[idx].ticket = ticket;
   if(persist) SaveSetupStore();
  }

// The tester never loads a previous run's store: its file sandbox persists
// between runs, and a re-run of the same period would otherwise see its
// own "future" executions as already consumed.
void LoadSetupStore(void)
  {
   ArrayResize(g_setups, 0);
   if(IsTester()) return;
   string fname = SetupStoreFileName();
   if(!FileIsExist(fname)) return;
   int h = FileOpen(fname, FILE_READ|FILE_CSV|FILE_ANSI|FILE_SHARE_READ, ',');
   if(h == INVALID_HANDLE) { X15Error("JOURNAL", StringFormat("cannot read setup store '%s' (error %d)", fname, GetLastError())); return; }
   while(!FileIsEnding(h))
     {
      string id = FileReadString(h);
      if(FileIsEnding(h) && id == "") break;
      X15SetupRecord r;
      r.setupId = id;
      r.time = (datetime)StringToInteger(FileReadString(h));
      r.direction = (int)StringToInteger(FileReadString(h));
      r.status = FileReadString(h);
      r.ticket = (ulong)StringToInteger(FileReadString(h));
      if(r.setupId == "") continue;
      int n = ArraySize(g_setups);
      ArrayResize(g_setups, n + 1);
      g_setups[n] = r;
     }
   FileClose(h);
  }

// "AX15|L|9F3A2C1B|XAUUSD": the setup ID sits BEFORE the symbol, so if a
// broker truncates the comment (31 chars) it loses the symbol, never the ID.
string BuildOrderComment(string kind, string setupId)
  {
   string c = "AX15|" + kind + "|" + setupId + "|" + _Symbol;
   if(StringLen(c) > 31) c = StringSubstr(c, 0, 31);
   return(c);
  }

string ExtractSetupIdFromComment(string comment)
  {
   string parts[];
   int n = StringSplit(comment, StringGetCharacter("|", 0), parts);
   if(n >= 3 && parts[0] == "AX15" && StringLen(parts[2]) == 8) return(parts[2]);
   return("");
  }

// True if any live position or pending order of this EA carries the ID.
bool BrokerHasSetup(string setupId)
  {
   if(setupId == "") return(false);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(ExtractSetupIdFromComment(PositionGetString(POSITION_COMMENT)) == setupId) return(true);
     }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0 || (ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      if(ExtractSetupIdFromComment(OrderGetString(ORDER_COMMENT)) == setupId) return(true);
     }
   return(false);
  }

bool BrokerHistoryHasSetup(string setupId, int days)
  {
   if(setupId == "") return(false);
   datetime now = TimeCurrent();
   if(!HistorySelect(now - days * 86400, now + 60)) return(false);
   int n = HistoryOrdersTotal();
   for(int i = n - 1; i >= 0; i--)
     {
      ulong t = HistoryOrderGetTicket(i);
      if(t == 0 || (ulong)HistoryOrderGetInteger(t, ORDER_MAGIC) != InpMagicNumber) continue;
      if(ExtractSetupIdFromComment(HistoryOrderGetString(t, ORDER_COMMENT)) == setupId) return(true);
     }
   return(false);
  }

// A send whose result is not known -- SENDING left behind by a crash, or an
// UNCERTAIN / TIMEOUT / CONNECTION_ERROR answer -- is resolved ONLY by
// searching the broker (open positions, open orders, recent order
// history). It is never resent; an unresolved record stays consumed.
datetime g_lastUnconfirmedCheck = 0;

void ResolveUnconfirmedSetups(bool force)
  {
   if(!force && TimeCurrent() - g_lastUnconfirmedCheck < 15) return;
   g_lastUnconfirmedCheck = TimeCurrent();
   for(int i = 0; i < ArraySize(g_setups); i++)
     {
      string st = g_setups[i].status;
      bool unconfirmed = (st == "UNCERTAIN" || st == "TIMEOUT" || st == "CONNECTION_ERROR"
                          || (st == "SENDING" && (force || TimeCurrent() - g_setups[i].time > 30)));
      if(!unconfirmed) continue;
      string id = g_setups[i].setupId;
      if(BrokerHasSetup(id) || BrokerHistoryHasSetup(id, 3))
        {
         RecordSetupStatus(id, g_setups[i].direction, "RESOLVED_EXECUTED", 0);
         X15Log("EXECUTION", "unconfirmed send of setup " + id + " WAS executed by the broker -- tracked, not resent");
        }
      else if(TimeCurrent() - g_setups[i].time > 3600)
        {
         RecordSetupStatus(id, g_setups[i].direction, "RESOLVED_NOT_FOUND", 0);
         X15Log("EXECUTION", "unconfirmed send of setup " + id + " not found at the broker after 1 h -- setup stays consumed, never resent");
        }
     }
  }

// Restart safety (spec 37.4): every setup ID found on this EA's open
// orders, open positions and last 14 days of order history is marked
// consumed, whatever the local file says.
void RebuildSetupStoreFromBroker(void)
  {
   if(IsTester()) return;
   int added = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0 || (ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      string id = ExtractSetupIdFromComment(OrderGetString(ORDER_COMMENT));
      if(id != "" && !IsSetupConsumed(id)) { RecordSetupStatus(id, 0, "FROM_BROKER_ORDER", t, false); added++; }
     }
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      string id = ExtractSetupIdFromComment(PositionGetString(POSITION_COMMENT));
      if(id != "" && !IsSetupConsumed(id)) { RecordSetupStatus(id, 0, "FROM_BROKER_POSITION", t, false); added++; }
     }
   datetime now = TimeCurrent();
   if(HistorySelect(now - 14 * 86400, now + 60))
     {
      int n = HistoryOrdersTotal();
      for(int i = 0; i < n; i++)
        {
         ulong t = HistoryOrderGetTicket(i);
         if(t == 0 || (ulong)HistoryOrderGetInteger(t, ORDER_MAGIC) != InpMagicNumber) continue;
         string id = ExtractSetupIdFromComment(HistoryOrderGetString(t, ORDER_COMMENT));
         if(id != "" && !IsSetupConsumed(id)) { RecordSetupStatus(id, 0, "FROM_BROKER_HISTORY", t, false); added++; }
        }
     }
   if(added > 0)
     {
      SaveSetupStore();
      X15Log("JOURNAL", StringFormat("restart safety: %d executed setup ID(s) recovered from the broker's own records", added));
     }
  }

//====================================================================
// LAYER 5 -- EXECUTION ELIGIBILITY  (spec 11)
//--------------------------------------------------------------------
// Fail closed, in a fixed order. The first failing gate decides the state
// and its reason is kept verbatim for the dashboard and the log -- a NO
// TRADE always says exactly why. No score, bonus or override can move a
// gate from FAIL to PASS.
//====================================================================
struct X15ExecDecision
  {
   datetime          barTime;
   bool              computed;
   ENUM_X15_ELIGIBILITY state;
   int               direction;
   string            blockingGate;
   string            reason;
   string            passedGates;
   bool              isFlip;
   double            entryPrice;
   double            sl;
   double            tp;
   double            rr;
   double            riskPct;
   string            riskTrace;
   double            lots;
   double            riskMoney;
   string            executionResult;
  };
X15ExecDecision g_exec;

void ResetExecDecision(X15ExecDecision &ed)
  {
   ed.barTime = 0; ed.computed = false; ed.state = X15_NOT_ELIGIBLE; ed.direction = 0;
   ed.blockingGate = ""; ed.reason = ""; ed.passedGates = ""; ed.isFlip = false;
   ed.entryPrice = 0.0; ed.sl = 0.0; ed.tp = 0.0; ed.rr = 0.0;
   ed.riskPct = 0.0; ed.riskTrace = ""; ed.lots = 0.0; ed.riskMoney = 0.0;
   ed.executionResult = "";
  }

void GateFail(X15ExecDecision &ed, ENUM_X15_ELIGIBILITY st, string gate, string why)
  {
   ed.state = st;
   ed.blockingGate = gate;
   ed.reason = why;
  }

void GatePass(X15ExecDecision &ed, string gate)
  {
   ed.passedGates += (ed.passedGates == "" ? "" : " ") + gate;
  }

double IntendedEntryPrice(X15Setup &s)
  {
   if(InpEntryOrderType == X15_ENTRY_STOP && g_execGot > 0 && g_structExec.atrAvailable)
     {
      int b = g_execGot - 1;
      double buf = InpStopEntryBufferATR * g_structExec.atr;
      return(NormalizePriceToTick(s.direction == 1 ? g_execRates[b].high + buf : g_execRates[b].low - buf));
     }
   return(s.direction == 1 ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID));
  }

// The ONE authorization function for every order that opens or adds
// exposure. addIdx < 0: a new entry from decision `d`. addIdx >= 0: a
// pyramid add to own position g_positions[addIdx] -- same account, market
// and risk gates; the setup-specific gates are replaced by the add rules.
// No code path sends an opening order without an ELIGIBLE result from here.
X15ExecDecision CheckExecutionEligibility(X15Decision &d, int addIdx = -1)
  {
   X15ExecDecision ed;
   ResetExecDecision(ed);
   ed.computed = true;
   ed.barTime = d.barTime;
   bool isAdd = (addIdx >= 0);
   string why = "";

   if(InpEmergencyStop)            { GateFail(ed, X15_BLOCKED, "EMERGENCY_STOP", "emergency stop is active"); return(ed); }
   if(InpCloseAllManagedPositions) { GateFail(ed, X15_BLOCKED, "CLOSE_ALL", "close-all is active"); return(ed); }
   if(!InpEnableTrading)           { GateFail(ed, X15_BLOCKED, "ENABLE_TRADING", "new entries disabled (InpEnableTrading=false)"); return(ed); }
   GatePass(ed, "OVERRIDES");

   if(!g_dq.ok) { GateFail(ed, X15_ELIG_DATA_UNAVAILABLE, "DATA", g_dq.reason); return(ed); }
   GatePass(ed, "DATA");

   int dir = 0;
   ulong addTicket = 0;
   if(!isAdd)
     {
      if(d.state == X15_DIR_DATA_UNAVAILABLE)      { GateFail(ed, X15_ELIG_DATA_UNAVAILABLE, "COMPOSITE", d.stateReason); return(ed); }
      if(d.state == X15_DIR_BLOCKED)               { GateFail(ed, X15_BLOCKED, "COMPOSITE", d.stateReason); return(ed); }
      if(d.state == X15_DIR_INSUFFICIENT_EVIDENCE) { GateFail(ed, X15_ELIG_INSUFFICIENT_EVIDENCE, "COMPOSITE", d.stateReason); return(ed); }
      if(d.state != X15_DIR_LONG && d.state != X15_DIR_SHORT) { GateFail(ed, X15_NOT_ELIGIBLE, "COMPOSITE", d.stateReason); return(ed); }
      dir = d.setup.direction;
      GatePass(ed, "COMPOSITE");
     }
   else
     {
      if(!AllowPyramiding) { GateFail(ed, X15_NOT_ELIGIBLE, "PYRAMID", "AllowPyramiding is OFF"); return(ed); }
      if(!IsNettingAccount()) { GateFail(ed, X15_NOT_ELIGIBLE, "PYRAMID", "pyramiding is netting-only"); return(ed); }
      if(!g_positions[addIdx].isOwn || g_positions[addIdx].isPaper || g_positions[addIdx].closed)
        { GateFail(ed, X15_NOT_ELIGIBLE, "PYRAMID", "not an open live position of this EA"); return(ed); }
      if(!SelectLivePositionById(g_positions[addIdx].positionId, addTicket)) { GateFail(ed, X15_NOT_ELIGIBLE, "PYRAMID", "position not found"); return(ed); }
      dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      GatePass(ed, "PYRAMID_TARGET");
     }
   ed.direction = dir;

   if(dir == 1 && !InpEnableLong)   { GateFail(ed, X15_BLOCKED, "DIRECTION", "long entries disabled"); return(ed); }
   if(dir == -1 && !InpEnableShort) { GateFail(ed, X15_BLOCKED, "DIRECTION", "short entries disabled"); return(ed); }
   GatePass(ed, "DIRECTION");

   if(!TradingPermitted(dir, InpExecutionMode == X15_LIVE_EXECUTION, why)) { GateFail(ed, X15_BLOCKED, "PERMISSIONS", why); return(ed); }
   GatePass(ed, "PERMISSIONS");
   if(!SymbolSessionOpenNow(why)) { GateFail(ed, X15_NOT_ELIGIBLE, "MARKET_OPEN", why); return(ed); }
   GatePass(ed, "MARKET_OPEN");
   if(!ExecutionQualityOk(why)) { GateFail(ed, X15_BLOCKED, "EXECUTION_QUALITY", why); return(ed); }
   GatePass(ed, "EXECUTION_QUALITY");
   if(!SessionTradable(g_session, why)) { GateFail(ed, X15_NOT_ELIGIBLE, "SESSION", why); return(ed); }
   GatePass(ed, "SESSION");
   if(g_newsGate.blocks) { GateFail(ed, X15_BLOCKED, "NEWS", g_newsGate.state + " " + g_newsGate.detail); return(ed); }
   GatePass(ed, "NEWS");
   if(!SpreadAcceptable(why)) { GateFail(ed, X15_BLOCKED, "SPREAD", why); return(ed); }
   GatePass(ed, "SPREAD");
   if(RegimeBlocked(g_regime.regime, why)) { GateFail(ed, X15_NOT_ELIGIBLE, "REGIME", why); return(ed); }
   GatePass(ed, "REGIME");

   X15Exposure ex;
   if(!isAdd)
     {
      if(g_execGot == 0 || d.setup.triggerBarTime != g_execRates[g_execGot-1].time)
        { GateFail(ed, X15_NOT_ELIGIBLE, "FRESHNESS", "decision does not belong to the last closed bar"); return(ed); }
      if(IsSetupConsumed(d.setup.setupId) || BrokerHasSetup(d.setup.setupId))
        { GateFail(ed, X15_NOT_ELIGIBLE, "DUPLICATE", "setup " + d.setup.setupId + " was already executed"); return(ed); }
      GatePass(ed, "NOT_DUPLICATE");

      datetime lastClose = 0;
      int lastDir = 0;
      if(LastOwnClose(lastClose, lastDir))
        {
         int period = PeriodSeconds(InpExecTF);
         int barsSince = (period > 0) ? (int)((TimeCurrent() - lastClose) / period) : 0;
         if(barsSince < InpCooldownBarsAfterClose)
           { GateFail(ed, X15_NOT_ELIGIBLE, "COOLDOWN", StringFormat("%d bar(s) since the last close, cooldown %d", barsSince, InpCooldownBarsAfterClose)); return(ed); }
         if(lastDir == -dir && barsSince < InpFlipWindowBars)
           {
            if(!InpAllowFlip) { GateFail(ed, X15_NOT_ELIGIBLE, "FLIP", "opposite entry this soon after a close is a flip, and flips are disabled"); return(ed); }
            // a flip is a NEW trade: new structure (and, for a reversal, a new sweep) that formed after the close
            if(d.setup.structureTime <= lastClose)
              { GateFail(ed, X15_NOT_ELIGIBLE, "FLIP", "a flip needs a structure break that formed AFTER the previous close"); return(ed); }
            if(d.setup.type == X15_SETUP_SWEEP_REVERSAL && d.setup.sweepTime <= lastClose)
              { GateFail(ed, X15_NOT_ELIGIBLE, "FLIP", "a reversal flip needs a liquidity sweep that happened AFTER the previous close"); return(ed); }
            ed.isFlip = true;
           }
        }
      GatePass(ed, "COOLDOWN_FLIP");

      ComputeExposure(ex);
      if(ex.unprotected) { GateFail(ed, X15_BLOCKED, "EXPOSURE", "an open position of this EA has no stop loss"); return(ed); }
      if(ex.total >= InpMaxPositionsTotal) { GateFail(ed, X15_NOT_ELIGIBLE, "EXPOSURE", StringFormat("%d/%d positions+orders open", ex.total, InpMaxPositionsTotal)); return(ed); }
      if(InpEntryOrderType == X15_ENTRY_STOP && ex.pending >= InpMaxPendingOrders)
        { GateFail(ed, X15_NOT_ELIGIBLE, "EXPOSURE", StringFormat("%d/%d pending orders open", ex.pending, InpMaxPendingOrders)); return(ed); }
      if(ex.symbolTotal >= InpMaxPositionsPerSymbol) { GateFail(ed, X15_NOT_ELIGIBLE, "EXPOSURE", StringFormat("%d/%d on this symbol", ex.symbolTotal, InpMaxPositionsPerSymbol)); return(ed); }
      if((dir == 1 ? ex.symbolLong : ex.symbolShort) >= InpMaxPositionsPerDirection)
        { GateFail(ed, X15_NOT_ELIGIBLE, "EXPOSURE", "max positions in this direction reached"); return(ed); }
      if(InpExecutionMode != X15_PAPER_EXECUTION && IsNettingAccount() && (ex.symbolTotal > 0 || ex.foreignOnSymbol))
        { GateFail(ed, X15_NOT_ELIGIBLE, "EXPOSURE", "netting account: a position already exists on this symbol and would be merged/reduced"); return(ed); }
      GatePass(ed, "EXPOSURE");
     }
   else
     {
      // add rules: only ever onto a proven winner, never more than the configured count
      if(!SelectLivePositionById(g_positions[addIdx].positionId, addTicket)) { GateFail(ed, X15_NOT_ELIGIBLE, "PYRAMID", "position not found"); return(ed); }
      double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
      if(PositionGetDouble(POSITION_SL) <= 0.0) { GateFail(ed, X15_BLOCKED, "PYRAMID", "position has no SL -- undefined risk"); return(ed); }
      double entry = g_positions[addIdx].entryPrice, origSL = g_positions[addIdx].originalSL;
      double riskDistance = (dir == 1) ? (entry - origSL) : (origSL - entry);
      if(riskDistance <= 0.0) { GateFail(ed, X15_NOT_ELIGIBLE, "PYRAMID", "original SL on the wrong side of entry -- undefined risk basis"); return(ed); }
      double currentR = (dir == 1) ? (currentPrice - entry) / riskDistance : (entry - currentPrice) / riskDistance;
      if(currentR < MinProfitRMultipleToAdd)
        { GateFail(ed, X15_NOT_ELIGIBLE, "PYRAMID", StringFormat("position at %.2fR, needs >= %.2fR to add", currentR, MinProfitRMultipleToAdd)); return(ed); }
      int addsSoFar = MathMax(0, CountPositionEntryDeals(g_positions[addIdx].positionId) - 1);
      if(addsSoFar >= MaxPyramidAdds) { GateFail(ed, X15_NOT_ELIGIBLE, "PYRAMID", StringFormat("already at max adds (%d/%d)", addsSoFar, MaxPyramidAdds)); return(ed); }
      if(IsSetupConsumed(PyramidAddKey(addIdx, addsSoFar + 1))) { GateFail(ed, X15_NOT_ELIGIBLE, "DUPLICATE", "this add was already attempted"); return(ed); }
      if(RequireFreshConfirmation)
        {
         if(!UseVPMACDEntry) { GateFail(ed, X15_NOT_ELIGIBLE, "PYRAMID", "RequireFreshConfirmation needs UseVPMACDEntry: no other event-based confirmation exists"); return(ed); }
         bool fresh = (dir == 1) ? CheckVPMACDBuySignal(_Symbol) : CheckVPMACDSellSignal(_Symbol);
         if(!fresh) { GateFail(ed, X15_NOT_ELIGIBLE, "PYRAMID", "no fresh VP-MACD crossover in the position's direction on this bar"); return(ed); }
        }
      ComputeExposure(ex);
      if(ex.unprotected) { GateFail(ed, X15_BLOCKED, "EXPOSURE", "an open position of this EA has no stop loss"); return(ed); }
      GatePass(ed, "PYRAMID_RULES");
     }

   ComputeLossMetrics(g_loss);
   if(!g_loss.available) { GateFail(ed, X15_BLOCKED, "LOSS_LIMITS", "loss metrics unavailable: " + g_loss.detail); return(ed); }
   if(g_loss.dailyLossPct >= InpMaxDailyLossPct)
     { GateFail(ed, X15_BLOCKED, "DAILY_LOSS", StringFormat("daily loss %.2f%% >= limit %.2f%%", g_loss.dailyLossPct, InpMaxDailyLossPct)); return(ed); }
   if(g_loss.weeklyLossPct >= InpMaxWeeklyLossPct)
     { GateFail(ed, X15_BLOCKED, "WEEKLY_LOSS", StringFormat("weekly loss %.2f%% >= limit %.2f%%", g_loss.weeklyLossPct, InpMaxWeeklyLossPct)); return(ed); }
   datetime lastLoss = 0;
   int streak = ConsecutiveOwnLosses(lastLoss);
   if(InpMaxConsecutiveLosses > 0 && streak >= InpMaxConsecutiveLosses && TimeCurrent() - lastLoss < InpConsecutiveLossPauseHours * 3600)
     { GateFail(ed, X15_BLOCKED, "LOSS_STREAK", StringFormat("%d consecutive losses: paused until %s", streak, TimeToString(lastLoss + InpConsecutiveLossPauseHours * 3600, TIME_DATE|TIME_MINUTES))); return(ed); }
   GatePass(ed, "LOSS_LIMITS");

   if(isAdd)
     {
      ed.lots = SizePyramidAdd(addIdx, dir, ed.riskMoney, why);
      if(ed.lots <= 0.0) { GateFail(ed, X15_NOT_ELIGIBLE, "VOLUME", why); return(ed); }
      if(!SelectLivePositionById(g_positions[addIdx].positionId, addTicket)) { GateFail(ed, X15_NOT_ELIGIBLE, "PYRAMID", "position not found"); return(ed); }
      ed.sl = PositionGetDouble(POSITION_SL);
      ed.tp = PositionGetDouble(POSITION_TP);
      ed.entryPrice = SymbolInfoDouble(_Symbol, dir == 1 ? SYMBOL_ASK : SYMBOL_BID);
      double equityNow = AccountInfoDouble(ACCOUNT_EQUITY);
      ed.riskPct = (equityNow > 0.0) ? ed.riskMoney / equityNow * 100.0 : 0.0;
      GatePass(ed, "VOLUME");
     }
   else
     {
      ed.entryPrice = IntendedEntryPrice(d.setup);
      ed.sl = NormalizePriceToTick(d.setup.sl);
      ed.tp = NormalizePriceToTick(d.setup.tp);
      double risk = (dir == 1) ? ed.entryPrice - ed.sl : ed.sl - ed.entryPrice;
      if(ed.entryPrice <= 0.0 || risk <= 0.0) { GateFail(ed, X15_NOT_ELIGIBLE, "STOP_LOSS", "entry price is at or beyond the stop"); return(ed); }
      double spreadPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(risk < MinStopDistancePrice() + spreadPrice)
        { GateFail(ed, X15_NOT_ELIGIBLE, "STOP_LOSS", "SL closer than the broker stops/freeze level plus spread"); return(ed); }
      if(g_structExec.atrAvailable && risk > InpMaxSLATR * g_structExec.atr)
        { GateFail(ed, X15_NOT_ELIGIBLE, "STOP_LOSS", StringFormat("SL %.2f x ATR exceeds the %.2f maximum", risk / g_structExec.atr, InpMaxSLATR)); return(ed); }
      if(InpMaxSLPoints > 0.0 && risk / g_spec.point > InpMaxSLPoints)
        { GateFail(ed, X15_NOT_ELIGIBLE, "STOP_LOSS", StringFormat("SL %.0f pts exceeds the %.0f maximum", risk / g_spec.point, InpMaxSLPoints)); return(ed); }
      GatePass(ed, "STOP_LOSS");

      double reward = (dir == 1) ? ed.tp - ed.entryPrice : ed.entryPrice - ed.tp;
      ed.rr = reward / risk;
      if(ed.rr < InpMinRR) { GateFail(ed, X15_NOT_ELIGIBLE, "REWARD_RISK", StringFormat("R:R %.2f at the actual entry is below %.2f", ed.rr, InpMinRR)); return(ed); }
      GatePass(ed, "REWARD_RISK");

      ed.riskPct = ComputeFinalRiskPct(dir, ed.isFlip, ed.riskTrace);
      if(ed.riskPct <= 0.0) { GateFail(ed, X15_NOT_ELIGIBLE, "RISK", "final risk is zero"); return(ed); }
      if(!SizeForRisk(dir, ed.entryPrice, ed.sl, ed.riskPct, ed.lots, ed.riskMoney, why)) { GateFail(ed, X15_NOT_ELIGIBLE, "VOLUME", why); return(ed); }
      GatePass(ed, "VOLUME");

      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(ex.openRiskMoney + ed.riskMoney > equity * InpMaxTotalOpenRiskPct / 100.0)
        {
         GateFail(ed, X15_NOT_ELIGIBLE, "TOTAL_RISK", StringFormat("open risk %.2f + new %.2f exceeds %.2f%% of equity", ex.openRiskMoney, ed.riskMoney, InpMaxTotalOpenRiskPct));
         return(ed);
        }
      GatePass(ed, "TOTAL_RISK");
     }
   if(!MarginAcceptable(dir, ed.lots, ed.entryPrice, why)) { GateFail(ed, X15_NOT_ELIGIBLE, "MARGIN", why); return(ed); }
   GatePass(ed, "MARGIN");

   ed.state = (dir == 1) ? X15_ELIGIBLE_LONG : X15_ELIGIBLE_SHORT;
   ed.reason = StringFormat("%s%s %.2f lots, risk %.2f (%.2f%%)%s%s", isAdd ? "ADD " : "", DirLabel(dir), ed.lots, ed.riskMoney, ed.riskPct,
                            isAdd ? "" : StringFormat(", R:R %.2f", ed.rr), ed.isFlip ? ", FLIP" : "");
   return(ed);
  }

//====================================================================
// ENTRY CONTEXTS
//--------------------------------------------------------------------
// The decision snapshot (setup, evidence, signal states) is captured the
// moment an order is sent and held here, keyed by setup ID, until the
// resulting position appears -- then it is attached to that position.
// Contexts are persisted with the position state, so a crash between send
// and fill still ends with a correctly-attributed position.
//====================================================================
X15Position g_entryContexts[];
X15Position g_dormantPaper[]; // paper positions persisted by a PAPER session, kept untouched while another mode runs

int FindEntryContext(string setupId)
  {
   if(setupId == "") return(-1);
   for(int i = 0; i < ArraySize(g_entryContexts); i++)
      if(g_entryContexts[i].setupId == setupId) return(i);
   return(-1);
  }

void AddEntryContext(X15Position &ctx)
  {
   int idx = FindEntryContext(ctx.setupId);
   if(idx < 0)
     {
      idx = ArraySize(g_entryContexts);
      ArrayResize(g_entryContexts, idx + 1);
     }
   g_entryContexts[idx] = ctx;
   g_stateDirty = true;
  }

void RemoveEntryContext(string setupId)
  {
   int idx = FindEntryContext(setupId);
   if(idx < 0) return;
   int n = ArraySize(g_entryContexts);
   for(int i = idx; i < n - 1; i++) g_entryContexts[i] = g_entryContexts[i+1];
   ArrayResize(g_entryContexts, n - 1);
   g_stateDirty = true;
  }

// Contexts whose order never produced a position (rejected at the broker
// after a restart, expired pending order) are dropped after a day.
void PruneEntryContexts(void)
  {
   for(int i = ArraySize(g_entryContexts) - 1; i >= 0; i--)
      if(TimeCurrent() - g_entryContexts[i].entryBarTime > 86400 && !BrokerHasSetup(g_entryContexts[i].setupId))
         RemoveEntryContext(g_entryContexts[i].setupId);
  }

string AlignmentState(string state, int dir)
  {
   if((dir == 1 && state == "BULLISH") || (dir == -1 && state == "BEARISH")) return(state + " (aligned)");
   if(state == "UNAVAILABLE" || state == "NEUTRAL") return(state);
   return(state + " (opposed)");
  }

void BuildEntryContext(X15Decision &d, X15ExecDecision &ed, X15Position &ctx)
  {
   ResetPosition(ctx);
   ctx.isOwn = true;
   ctx.isPaper = (InpExecutionMode == X15_PAPER_EXECUTION);
   ctx.setupId = d.setup.setupId;
   ctx.setupType = d.setup.type;
   ctx.direction = d.setup.direction;
   ctx.entryBarTime = d.setup.triggerBarTime;
   ctx.originalSL = ed.sl;
   ctx.originalTP = ed.tp;
   ctx.currentSL = ed.sl;
   ctx.currentTP = ed.tp;
   ctx.riskPct = ed.riskPct;
   ctx.riskMoney = ed.riskMoney;
   ctx.volume = ed.lots;
   ctx.invalidation = d.setup.invalidation;
   ctx.spreadAtEntryPts = CurrentSpreadPoints();
   ctx.isFlip = ed.isFlip;
   ctx.evidenceScore = d.evidenceScore;

   // Same reads the pre-robot RecordEntryMeta() used, so the learned VWAP /
   // VP-MACD bonuses keep measuring exactly what they always measured.
   int dir = ctx.direction;
   string vwapClass = UseVWAPExit ? ClassifyVWAPTrend(_Symbol) : "NEUTRAL";
   ctx.vwapAligned = (dir == 1 && vwapClass == "BULLISH") || (dir == -1 && vwapClass == "BEARISH");
   string vpClass = UseVPMACDEntry ? ClassifyVPMACDSignal(_Symbol) : "NEUTRAL";
   ctx.vpMacdAligned = (dir == 1 && vpClass == "BULLISH") || (dir == -1 && vpClass == "BEARISH");
   if(!IsTester())
     {
      NewsDefenseState nd = CheckNewsDefense(_Symbol);
      ctx.nearValidatedNewsEvent = nd.isValidatedEvent;
      ctx.newsEventNameAtEntry = (nd.active && nd.isValidatedEvent) ? SanitizeForCsv(nd.reason) : "";
     }

   ctx.vwapState = AlignmentState(d.vwapState, dir);
   ctx.vpmacdState = AlignmentState(d.vpmacdState, dir);
   ctx.newsState = g_newsGate.state;
   ctx.compositeState = EnumLabel(EnumToString(d.state), "X15_DIR_");
   ctx.regime = EnumLabel(EnumToString(g_regime.regime), "X15_REGIME_");
   ctx.structureState = StringFormat("%s %s; HTF %s", g_structExec.trendLabel,
                                     EnumLabel(EnumToString(d.setup.structureEvent), "X15_EVT_"), g_htfBias.state);
   ctx.liquidityState = (d.setup.sweepLevelName != "" ? "swept " + d.setup.sweepLevelName + "; " : "") + "target " + d.setup.tpLevelName;
   ctx.session = EnumLabel(EnumToString(g_session), "X15_SESSION_");
   ctx.entryReason = StringFormat("%s %s zone %s, evidence %d/%d, R:R %.2f",
                                  EnumLabel(EnumToString(d.setup.type), "X15_SETUP_"), DirLabel(dir),
                                  d.setup.zoneType, d.evidenceScore, d.evidenceMax, ed.rr);
   // SanitizeForCsv on every free-text field: these go straight into CSV rows
   ctx.structureState = SanitizeForCsv(ctx.structureState);
   ctx.liquidityState = SanitizeForCsv(ctx.liquidityState);
   ctx.entryReason = SanitizeForCsv(ctx.entryReason);
  }

//====================================================================
// LAYER 7 -- ORDER ENGINE  (spec 3)
//====================================================================
struct X15OrderRequest
  {
   int               direction;
   bool              isPending;
   ENUM_ORDER_TYPE   type;
   double            price;
   double            volume;
   double            sl;
   double            tp;
   ulong             magic;
   string            comment;
   string            setupId;      // signal identifier
   string            strategyId;   // setup model
   ENUM_ORDER_TYPE_TIME typeTime;
   datetime          expiration;
  };

void BuildOrderRequest(X15Decision &d, X15ExecDecision &ed, X15OrderRequest &rq)
  {
   int dir = d.setup.direction;
   rq.direction = dir;
   rq.isPending = (InpEntryOrderType == X15_ENTRY_STOP);
   if(rq.isPending) rq.type = (dir == 1) ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP;
   else             rq.type = (dir == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   rq.price = rq.isPending ? ed.entryPrice
                           : (dir == 1 ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID));
   rq.volume = ed.lots;
   rq.sl = ed.sl;
   rq.tp = ed.tp;
   rq.magic = InpMagicNumber;
   rq.setupId = d.setup.setupId;
   rq.strategyId = EnumLabel(EnumToString(d.setup.type), "X15_SETUP_");
   rq.comment = BuildOrderComment(dir == 1 ? "L" : "S", rq.setupId);
   rq.typeTime = ORDER_TIME_GTC;
   rq.expiration = 0;
   if(rq.isPending && (g_spec.expirationMode & SYMBOL_EXPIRATION_SPECIFIED) != 0)
     {
      rq.typeTime = ORDER_TIME_SPECIFIED;
      rq.expiration = TimeCurrent() + InpPendingExpiryBars * PeriodSeconds(InpExecTF);
     }
  }

// Broker-side validity: normalized prices, SL/TP on the correct sides, at
// least the stops/freeze distance from the relevant price, volume inside
// the broker's limits and on its step, and -- for live orders -- the
// terminal's own OrderCheck() (margin, trade permissions, parameters).
bool ValidateOrderRequest(X15OrderRequest &rq, bool runOrderCheck, string &why)
  {
   why = "";
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID), ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0) { why = "no live quote"; return(false); }
   rq.price = NormalizePriceToTick(rq.price);
   rq.sl = NormalizePriceToTick(rq.sl);
   rq.tp = NormalizePriceToTick(rq.tp);
   if(rq.volume < g_spec.volMin - 1e-12 || rq.volume > g_spec.volMax + 1e-12) { why = "volume outside the broker's limits"; return(false); }
   double steps = rq.volume / g_spec.volStep;
   if(MathAbs(steps - MathRound(steps)) > 1e-6) { why = "volume is not a multiple of the volume step"; return(false); }
   if(rq.sl <= 0.0 || rq.tp <= 0.0) { why = "every order must carry both SL and TP"; return(false); }
   double minDist = MinStopDistancePrice();
   if(rq.direction == 1)
     {
      if(!(rq.sl < rq.price && rq.tp > rq.price)) { why = "SL/TP on the wrong side of entry"; return(false); }
      if(rq.isPending)
        {
         if(rq.price - ask < minDist || rq.price <= ask) { why = "stop-entry price is too close to, or already through, the market"; return(false); }
         if(rq.price - rq.sl < minDist || rq.tp - rq.price < minDist) { why = "SL/TP closer than the broker stops level"; return(false); }
        }
      else if(bid - rq.sl < minDist || rq.tp - bid < minDist) { why = "SL/TP closer than the broker stops/freeze level"; return(false); }
     }
   else
     {
      if(!(rq.sl > rq.price && rq.tp < rq.price)) { why = "SL/TP on the wrong side of entry"; return(false); }
      if(rq.isPending)
        {
         if(bid - rq.price < minDist || rq.price >= bid) { why = "stop-entry price is too close to, or already through, the market"; return(false); }
         if(rq.sl - rq.price < minDist || rq.price - rq.tp < minDist) { why = "SL/TP closer than the broker stops level"; return(false); }
        }
      else if(rq.sl - ask < minDist || ask - rq.tp < minDist) { why = "SL/TP closer than the broker stops/freeze level"; return(false); }
     }
   if(!runOrderCheck) return(true);

   MqlTradeRequest req;
   MqlTradeCheckResult chk;
   ZeroMemory(req);
   ZeroMemory(chk);
   req.action = rq.isPending ? TRADE_ACTION_PENDING : TRADE_ACTION_DEAL;
   req.symbol = _Symbol;
   req.volume = rq.volume;
   req.type = rq.type;
   req.price = rq.price;
   req.sl = rq.sl;
   req.tp = rq.tp;
   req.deviation = (ulong)InpMaxSlippagePoints;
   req.magic = rq.magic;
   req.comment = rq.comment;
   req.type_filling = rq.isPending ? ORDER_FILLING_RETURN : DetectFillingMode(_Symbol);
   req.type_time = rq.typeTime;
   req.expiration = rq.expiration;
   if(!OrderCheck(req, chk))
     {
      why = StringFormat("OrderCheck rejected: %u %s", chk.retcode, chk.comment);
      return(false);
     }
   return(true);
  }

bool RetcodeSucceeded(uint rc)
  {
   return(rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED || rc == TRADE_RETCODE_DONE_PARTIAL);
  }

// "Request sent" is never treated as "filled": a success retcode must also
// come with the ticket that proves it -- a deal for a market order, an
// order for a pending one. A success code without that proof is UNCERTAIN.
ENUM_X15_SEND_OUTCOME ClassifySendResult(bool callOk, uint rc, bool isPending, ulong orderTicket, ulong dealTicket)
  {
   if(callOk && RetcodeSucceeded(rc))
     {
      if(isPending) return(orderTicket > 0 ? X15_SEND_PLACED : X15_SEND_UNCERTAIN);
      if(rc == TRADE_RETCODE_PLACED) return(X15_SEND_UNCERTAIN); // accepted, not yet executed: the position is confirmed by reconciliation
      return(dealTicket > 0 ? X15_SEND_FILLED : X15_SEND_UNCERTAIN);
     }
   if(rc == TRADE_RETCODE_REQUOTE)       return(X15_SEND_REQUOTE);
   if(rc == TRADE_RETCODE_PRICE_CHANGED) return(X15_SEND_PRICE_CHANGED);
   if(rc == TRADE_RETCODE_PRICE_OFF)     return(X15_SEND_OFF_QUOTES);
   if(rc == TRADE_RETCODE_TIMEOUT)       return(X15_SEND_TIMEOUT);
   if(rc == TRADE_RETCODE_CONNECTION)    return(X15_SEND_CONNECTION_ERROR);
   if(rc == 0 || rc == TRADE_RETCODE_ERROR) return(X15_SEND_UNCERTAIN);
   if(rc == TRADE_RETCODE_REJECT)        return(X15_SEND_REJECTED);
   return(X15_SEND_OTHER_ERROR);
  }

string SendOutcomeLabel(ENUM_X15_SEND_OUTCOME o)
  {
   return(EnumLabel(EnumToString(o), "X15_SEND_"));
  }

// Definitively not executed -- the only outcomes that may ever be retried.
bool SendOutcomeRetryable(ENUM_X15_SEND_OUTCOME o)
  {
   return(o == X15_SEND_REQUOTE || o == X15_SEND_PRICE_CHANGED || o == X15_SEND_OFF_QUOTES);
  }

// May have executed server-side: never resent, reconciled against the broker instead.
bool SendOutcomeMayHaveExecuted(ENUM_X15_SEND_OUTCOME o)
  {
   return(o == X15_SEND_TIMEOUT || o == X15_SEND_CONNECTION_ERROR || o == X15_SEND_UNCERTAIN);
  }

ENUM_X15_SEND_OUTCOME SendLiveOrder(X15OrderRequest &rq, ulong &orderTicket, double &fillPrice, string &why)
  {
   orderTicket = 0; fillPrice = 0.0; why = "";
   g_trade.SetExpertMagicNumber(rq.magic);
   g_trade.SetDeviationInPoints(InpMaxSlippagePoints);
   g_trade.SetTypeFilling(rq.isPending ? ORDER_FILLING_RETURN : DetectFillingMode(_Symbol));
   ENUM_X15_SEND_OUTCOME outcome = X15_SEND_OTHER_ERROR;
   for(int attempt = 0; attempt < 2; attempt++)
     {
      if(attempt > 0)
        {
         // before the single permitted retry, the broker is searched first: never a second order
         if(BrokerHasSetup(rq.setupId)) { why = "order found on the broker after a requote"; return(X15_SEND_UNCERTAIN); }
         if(!rq.isPending) rq.price = (rq.direction == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(!ValidateOrderRequest(rq, true, why)) return(X15_SEND_REJECTED);
        }
      bool ok;
      if(rq.isPending)
         ok = (rq.direction == 1)
              ? g_trade.BuyStop(rq.volume, rq.price, _Symbol, rq.sl, rq.tp, rq.typeTime, rq.expiration, rq.comment)
              : g_trade.SellStop(rq.volume, rq.price, _Symbol, rq.sl, rq.tp, rq.typeTime, rq.expiration, rq.comment);
      else
         ok = (rq.direction == 1)
              ? g_trade.Buy(rq.volume, _Symbol, 0.0, rq.sl, rq.tp, rq.comment)
              : g_trade.Sell(rq.volume, _Symbol, 0.0, rq.sl, rq.tp, rq.comment);
      uint rc = g_trade.ResultRetcode();
      orderTicket = g_trade.ResultOrder();
      fillPrice = g_trade.ResultPrice();
      outcome = ClassifySendResult(ok, rc, rq.isPending, orderTicket, g_trade.ResultDeal());
      why = StringFormat("%s (%u %s, order #%I64u, deal #%I64u)", SendOutcomeLabel(outcome), rc, g_trade.ResultRetcodeDescription(),
                         orderTicket, g_trade.ResultDeal());
      if(!SendOutcomeRetryable(outcome)) return(outcome);
     }
   return(outcome);
  }

ulong NewPaperId(void)
  {
   g_paperCounter++;
   return((ulong)TimeCurrent() * 1000 + (g_paperCounter % 1000));
  }

void OpenPaperPosition(X15OrderRequest &rq, X15Position &ctx)
  {
   X15Position p = ctx;
   p.positionId = NewPaperId();
   p.isPaper = true;
   p.volume = rq.volume;
   p.peakVolume = rq.volume;
   if(rq.isPending)
     {
      p.isPendingOrder = true;
      p.pendingPrice = rq.price;
      p.pendingExpiry = TimeCurrent() + InpPendingExpiryBars * PeriodSeconds(InpExecTF);
     }
   else
     {
      double fill = PaperFillPrice(rq.direction, true);
      p.entryTime = TimeCurrent();
      p.requestedPrice = rq.price;
      p.entryPrice = fill;
      p.avgEntryPrice = fill;
      double pr = 0.0;
      if(OrderCalcProfit(rq.direction == 1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, p.volume, fill, p.originalSL, pr) && pr < 0.0)
         p.riskMoney = -pr; // money at risk from the actual (slipped) fill
     }
   AppendPosition(p);
   X15Log("EXECUTION", StringFormat("[PAPER] %s %s %.2f lots @ %s SL %s TP %s setup %s",
                                    rq.isPending ? "placed stop-entry" : "filled", DirLabel(rq.direction), rq.volume,
                                    DoubleToString(rq.price, g_spec.digits), DoubleToString(rq.sl, g_spec.digits),
                                    DoubleToString(rq.tp, g_spec.digits), rq.setupId));
  }

void ExecuteEntry(X15Decision &d, X15ExecDecision &ed)
  {
   if(g_sendInFlight) return;
   string id = d.setup.setupId;
   if(IsSetupConsumed(id) || BrokerHasSetup(id))
     {
      ed.executionResult = "skipped: setup already executed";
      return;
     }
   X15OrderRequest rq;
   BuildOrderRequest(d, ed, rq);
   bool live = (InpExecutionMode == X15_LIVE_EXECUTION);
   string why = "";
   if(!ValidateOrderRequest(rq, live, why))
     {
      RecordSetupStatus(id, rq.direction, "REJECTED_LOCAL", 0);
      ed.executionResult = "order rejected before sending: " + why;
      X15Log("EXECUTION", ed.executionResult);
      return;
     }
   X15Position ctx;
   BuildEntryContext(d, ed, ctx);
   ctx.requestedPrice = rq.price;

   if(!live)
     {
      RecordSetupStatus(id, rq.direction, "PAPER", 0);
      OpenPaperPosition(rq, ctx);
      ed.executionResult = "PAPER " + (rq.isPending ? "stop-entry placed" : "filled");
      g_lastTradeTime = TimeCurrent();
      return;
     }

   // write-ahead: the setup is consumed on disk BEFORE the order exists, so
   // a crash mid-send can never be followed by a resend of the same setup
   RecordSetupStatus(id, rq.direction, "SENDING", 0);
   AddEntryContext(ctx);
   SavePositionState();

   g_sendInFlight = true;
   ulong order = 0;
   double fill = 0.0;
   ENUM_X15_SEND_OUTCOME outcome = SendLiveOrder(rq, order, fill, why);
   g_sendInFlight = false;
   RecordSetupStatus(id, rq.direction, SendOutcomeLabel(outcome), order);
   g_reconcileRequested = true;

   if(outcome == X15_SEND_FILLED || outcome == X15_SEND_PLACED)
     {
      ed.executionResult = StringFormat("%s #%I64u %s %.2f lots @ %s", outcome == X15_SEND_PLACED ? "stop-entry PLACED" : "FILLED",
                                        order, DirLabel(rq.direction), rq.volume, DoubleToString(fill > 0.0 ? fill : rq.price, g_spec.digits));
      g_lastTradeTime = TimeCurrent();
      X15Log("EXECUTION", "[LIVE] " + ed.executionResult + " setup " + id);
     }
   else if(SendOutcomeMayHaveExecuted(outcome))
     {
      ed.executionResult = "result " + why + " -- setup blocked, reconciling against the broker, never resent";
      X15Error("EXECUTION", ed.executionResult);
     }
   else
     {
      RemoveEntryContext(id);
      ed.executionResult = "not executed: " + why;
      X15Error("EXECUTION", ed.executionResult);
     }
  }

// Runs once per new execution bar, after analysis and position management.
void ProcessEntryOpportunity(void)
  {
   g_state = X15_ST_VALIDATION;
   g_exec = CheckExecutionEligibility(g_decision);
   bool eligible = (g_exec.state == X15_ELIGIBLE_LONG || g_exec.state == X15_ELIGIBLE_SHORT);
   X15Log("VALIDATION", StringFormat("%s -- %s%s", EnumLabel(EnumToString(g_exec.state), "X15_"),
                                     g_exec.blockingGate != "" ? g_exec.blockingGate + ": " : "", g_exec.reason),
          false, !eligible);
   if(!eligible)
     {
      if(g_exec.state == X15_BLOCKED) g_state = X15_ST_BLOCKED;
      else if(g_exec.state == X15_ELIG_DATA_UNAVAILABLE) g_state = X15_ST_DATA_UNAVAILABLE;
      else g_state = X15_ST_WAIT;
      return;
     }
   g_state = X15_ST_RISK_CHECK;
   X15Log("RISK", g_exec.riskTrace + StringFormat(", %.2f lots, money at risk %.2f", g_exec.lots, g_exec.riskMoney));
   if(InpExecutionMode == X15_ANALYSIS_ONLY)
     {
      g_exec.executionResult = "ANALYSIS_ONLY: would have entered, nothing sent";
      g_state = X15_ST_WAIT;
      return;
     }
   g_state = X15_ST_EXECUTION;
   ExecuteEntry(g_decision, g_exec);
   g_state = X15_ST_WAIT;
  }

//====================================================================
// PENDING STOP-ENTRY ORDERS
//--------------------------------------------------------------------
// Cancelled when they expire (belt and braces over ORDER_TIME_SPECIFIED,
// which not every broker supports) or when price reaches their SL before
// triggering -- the setup is invalid by then.
//====================================================================
datetime g_lastPendingDeleteFail = 0;

void ManagePendingOrders(void)
  {
   if(TimeCurrent() - g_lastPendingDeleteFail < 10) return; // a failed delete is retried after 10 s, not every tick
   int period = PeriodSeconds(InpExecTF);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID), ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0 || (ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber || OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      long type = OrderGetInteger(ORDER_TYPE);
      datetime setup = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      double sl = OrderGetDouble(ORDER_SL);
      bool expired = (TimeCurrent() - setup >= InpPendingExpiryBars * period);
      bool invalid = (type == ORDER_TYPE_BUY_STOP && sl > 0.0 && bid <= sl) || (type == ORDER_TYPE_SELL_STOP && sl > 0.0 && ask >= sl);
      if(!expired && !invalid && !InpCloseAllManagedPositions) continue;
      string id = ExtractSetupIdFromComment(OrderGetString(ORDER_COMMENT));
      if(g_trade.OrderDelete(t))
        {
         RecordSetupStatus(id, 0, expired ? "EXPIRED" : (invalid ? "INVALIDATED" : "CANCELLED"), t);
         RemoveEntryContext(id);
         X15Log("EXECUTION", StringFormat("pending order #%I64u deleted (%s)", t, expired ? "expired" : (invalid ? "price reached SL first" : "close-all")));
        }
      else
        {
         g_lastPendingDeleteFail = TimeCurrent();
         X15Error("EXECUTION", StringFormat("could not delete pending order #%I64u: %u %s", t, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
        }
     }
  }

// Paper stop-entries: fill when price trades through, cancel on expiry or
// when price reaches the SL first.
void ManagePaperPending(int idx)
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID), ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int dir = g_positions[idx].direction;
   bool triggered = (dir == 1) ? (ask >= g_positions[idx].pendingPrice) : (bid <= g_positions[idx].pendingPrice);
   bool invalid = (dir == 1) ? (bid <= g_positions[idx].currentSL) : (ask >= g_positions[idx].currentSL);
   bool expired = (TimeCurrent() >= g_positions[idx].pendingExpiry);
   if(invalid || expired || InpCloseAllManagedPositions)
     {
      RecordSetupStatus(g_positions[idx].setupId, dir, expired ? "EXPIRED" : "INVALIDATED", 0);
      X15Log("EXECUTION", "[PAPER] stop-entry cancelled for setup " + g_positions[idx].setupId);
      g_positions[idx].closed = true;
      return;
     }
   if(!triggered) return;
   double fill = PaperFillPrice(dir, true);
   g_positions[idx].requestedPrice = g_positions[idx].pendingPrice;
   g_positions[idx].isPendingOrder = false;
   g_positions[idx].entryTime = TimeCurrent();
   g_positions[idx].entryPrice = fill;
   g_positions[idx].avgEntryPrice = fill;
   double pr = 0.0;
   if(OrderCalcProfit(dir == 1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, g_positions[idx].volume, fill, g_positions[idx].originalSL, pr) && pr < 0.0)
      g_positions[idx].riskMoney = -pr; // actual fill, not the planned trigger price
   g_stateDirty = true;
   g_lastTradeTime = TimeCurrent();
   X15Log("EXECUTION", StringFormat("[PAPER] stop-entry filled %s @ %s", DirLabel(dir), DoubleToString(fill, g_spec.digits)));
  }

//====================================================================
// LAYER 8 -- POSITION MANAGEMENT  (spec 19)
//--------------------------------------------------------------------
// Tick-level: SL/TP hits for paper positions, break-even, partial, ATR and
// fixed-R trailing. Bar-level (new closed exec bar only): structure and
// VWAP trailing, invalidation and time exits. Stops only ever TIGHTEN.
// A live close is only SENT here; the journal entry is written by
// reconciliation once the broker's deal history shows the position closed
// -- so the journal records what happened, not what was requested.
//====================================================================
void PaperClose(X15Position &p, double vol, double exitPrice);

// PAPER fills at the real bid/ask, moved AGAINST the trade by
// InpPaperSlippagePoints -- opening a long or closing a short buys at the
// ask, the other two sell at the bid.
double PaperFillPrice(int dir, bool opening)
  {
   double slip = MathMax(0, InpPaperSlippagePoints) * g_spec.point;
   bool buying = (opening && dir == 1) || (!opening && dir == -1);
   return(buying ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) + slip : SymbolInfoDouble(_Symbol, SYMBOL_BID) - slip);
  }

// Failed broker requests are retried with backoff, never every tick: 10 s,
// then once per bar after 10 consecutive failures (the position keeps its
// broker-side SL/TP meanwhile).
bool CloseRetryAllowed(X15Position &p)
  {
   int wait = (p.closeFailCount >= 10) ? MathMax(60, PeriodSeconds(InpExecTF)) : 10;
   return(TimeCurrent() - p.lastCloseAttempt >= wait);
  }

bool ModifyStops(X15Position &p, double newSL, double newTP, string tag)
  {
   newSL = NormalizePriceToTick(newSL);
   newTP = NormalizePriceToTick(newTP);
   int minGap = (p.modifyFailCount >= 5) ? MathMax(60, PeriodSeconds(InpExecTF)) : 5;
   if(!p.isPaper && TimeCurrent() - p.lastModifyTime < minGap) return(false);
   if(!p.isPaper && !SelectLivePositionById(p.positionId, p.ticket)) return(false);
   // broker constraints apply to paper too, so paper management cannot do what a live account would refuse
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID), ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double exitPx = (p.direction == 1) ? bid : ask;
   double minDist = MinStopDistancePrice();
   double freeze = g_spec.freezeLevelPts * g_spec.point;
   if(freeze > 0.0)
     {
      if(p.currentSL > 0.0 && MathAbs(exitPx - p.currentSL) <= freeze) return(false); // inside the freeze zone: the broker would refuse
      if(p.currentTP > 0.0 && MathAbs(exitPx - p.currentTP) <= freeze) return(false);
     }
   if(p.direction == 1 && (bid - newSL < minDist || (newTP > 0.0 && newTP - bid < minDist))) return(false);
   if(p.direction == -1 && (newSL - ask < minDist || (newTP > 0.0 && ask - newTP < minDist))) return(false);
   // never widen: a new SL must be at least as protective as the current one
   if(p.currentSL > 0.0 && ((p.direction == 1 && newSL < p.currentSL) || (p.direction == -1 && newSL > p.currentSL))) return(false);
   p.lastModifyTime = TimeCurrent();
   if(p.isPaper)
     {
      p.currentSL = newSL; p.currentTP = newTP;
      g_stateDirty = true;
      X15Log("POSITION", StringFormat("[PAPER] %s: SL %s TP %s", tag, DoubleToString(newSL, g_spec.digits), DoubleToString(newTP, g_spec.digits)), false, true);
      return(true);
     }
   if(!g_trade.PositionModify(p.ticket, newSL, newTP))
     {
      p.modifyFailCount++;
      X15Error("POSITION", StringFormat("%s modify failed on #%I64u: %u %s (%d in a row)", tag, p.ticket,
                                        g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription(), p.modifyFailCount));
      return(false);
     }
   p.modifyFailCount = 0;
   p.currentSL = newSL;
   p.currentTP = newTP;
   g_stateDirty = true;
   X15Log("POSITION", StringFormat("%s: #%I64u SL %s TP %s", tag, p.ticket, DoubleToString(newSL, g_spec.digits), DoubleToString(newTP, g_spec.digits)));
   return(true);
  }

bool CloseManagedPosition(X15Position &p, ENUM_X15_EXIT_REASON reason)
  {
   g_stateDirty = true;
   if(p.isPaper)
     {
      p.pendingExitReason = reason;
      PaperClose(p, p.volume, PaperFillPrice(p.direction, false));
      return(true);
     }
   if(!CloseRetryAllowed(p)) return(false);
   if(!SelectLivePositionById(p.positionId, p.ticket)) return(false);
   p.lastCloseAttempt = TimeCurrent();
   p.pendingExitReason = reason;
   if(!g_trade.PositionClose(p.ticket, (ulong)InpMaxSlippagePoints))
     {
      p.pendingExitReason = X15_EXIT_NONE; // the close did not happen: a later broker-side SL/TP must be journaled as what it is
      p.closeFailCount++;
      X15Error("POSITION", StringFormat("close (%s) failed on #%I64u: %u %s (%d in a row)", ExitReasonLabel(reason), p.ticket,
                                        g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription(), p.closeFailCount));
      return(false);
     }
   p.closeFailCount = 0;
   g_reconcileRequested = true;
   X15Log("POSITION", StringFormat("close sent (%s) #%I64u", ExitReasonLabel(reason), p.ticket));
   return(true);
  }

bool PartialCloseManaged(X15Position &p, double vol)
  {
   if(p.isPaper)
     {
      PaperClose(p, vol, PaperFillPrice(p.direction, false));
      return(true);
     }
   if(!CloseRetryAllowed(p)) return(false);
   if(!SelectLivePositionById(p.positionId, p.ticket)) return(false);
   p.lastCloseAttempt = TimeCurrent();
   if(!g_trade.PositionClosePartial(p.ticket, vol, (ulong)InpMaxSlippagePoints))
     {
      p.closeFailCount++;
      X15Error("POSITION", StringFormat("partial close failed on #%I64u: %u %s (%d in a row)", p.ticket, g_trade.ResultRetcode(),
                                        g_trade.ResultRetcodeDescription(), p.closeFailCount));
      return(false);
     }
   p.closeFailCount = 0;
   g_reconcileRequested = true;
   X15Log("POSITION", StringFormat("partial close %.2f lots on #%I64u", vol, p.ticket));
   return(true);
  }

// Forward look for a whitelisted (validated) event on either currency leg
// within the lead window. Live only: the tester has no calendar.
datetime g_newsAheadCheckedAt = 0;
bool     g_newsAheadHit = false;
string   g_newsAheadName = "";

// Cached for 60 s: it is consulted per tick per position, and each refresh
// costs two calendar queries plus one lookup per event.
bool UpcomingValidatedEvent(int leadMinutes, string &nameOut)
  {
   nameOut = "";
   if(IsTester() || leadMinutes <= 0) return(false);
   if(TimeCurrent() - g_newsAheadCheckedAt < 60) { nameOut = g_newsAheadName; return(g_newsAheadHit); }
   g_newsAheadCheckedAt = TimeCurrent();
   g_newsAheadHit = RefreshUpcomingValidatedEvent(leadMinutes, g_newsAheadName);
   nameOut = g_newsAheadName;
   return(g_newsAheadHit);
  }

bool RefreshUpcomingValidatedEvent(int leadMinutes, string &nameOut)
  {
   nameOut = "";
   string base, quote;
   GetTradeCurrencies(_Symbol, base, quote);
   string legs[2];
   legs[0] = base; legs[1] = quote;
   datetime now = TimeCurrent();
   for(int L = 0; L < 2; L++)
     {
      if(legs[L] == "") continue;
      MqlCalendarValue values[];
      int n = GetRecentCalendarEvents(legs[L], now, now + leadMinutes * 60, values);
      for(int i = 0; i < n; i++)
        {
         MqlCalendarEvent ev;
         if(!CalendarEventById((long)values[i].event_id, ev)) continue;
         if(IsWhitelistedEvent(ev.name, legs[L])) { nameOut = ev.name + " (" + legs[L] + ")"; return(true); }
        }
     }
   return(false);
  }

// Returns true when the position is gone (closed or its close was sent).
bool ManageOnePosition(X15Position &p, bool newBar)
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID), ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0) return(false);
   if(!p.isPaper)
     {
      if(!SelectLivePositionById(p.positionId, p.ticket)) return(false); // reconciliation will journal it
      p.currentSL = PositionGetDouble(POSITION_SL);
      p.currentTP = PositionGetDouble(POSITION_TP);
      p.volume = PositionGetDouble(POSITION_VOLUME);
      p.avgEntryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
     }
   int dir = p.direction;
   double exitPx = (dir == 1) ? bid : ask;

   if(p.isPaper)
     {
      bool slHit = (p.currentSL > 0.0) && ((dir == 1) ? bid <= p.currentSL : ask >= p.currentSL);
      bool tpHit = (p.currentTP > 0.0) && ((dir == 1) ? bid >= p.currentTP : ask <= p.currentTP);
      if(slHit)
        {
         bool locked = (dir == 1) ? (p.currentSL >= p.avgEntryPrice) : (p.currentSL <= p.avgEntryPrice);
         p.pendingExitReason = !locked ? X15_EXIT_STOP_LOSS : (p.beDone && MathAbs(p.currentSL - p.avgEntryPrice) > (InpBreakEvenLockR + 0.05) * MathAbs(p.entryPrice - p.originalSL) ? X15_EXIT_TRAIL_STOP : X15_EXIT_BREAKEVEN_STOP);
         PaperClose(p, p.volume, PaperFillPrice(dir, false)); // at the (slipped) market price, so a gap through the SL costs what it would really cost
         return(true);
        }
      if(tpHit)
        {
         p.pendingExitReason = X15_EXIT_TAKE_PROFIT;
         PaperClose(p, p.volume, p.currentTP);
         return(true);
        }
     }

   if(InpCloseAllManagedPositions) return(CloseManagedPosition(p, X15_EXIT_CLOSE_ALL));

   double risk = MathAbs(p.entryPrice - p.originalSL);
   if(risk <= 0.0) return(false); // no defined risk basis: nothing R-based to manage
   double rNow = (exitPx - p.entryPrice) * dir / risk;

   if(InpNewsEmergencyAction != X15_NEWS_EMERG_NONE)
     {
      string evName;
      if(UpcomingValidatedEvent(InpNewsEmergencyLeadMinutes, evName))
        {
         if(InpNewsEmergencyAction == X15_NEWS_EMERG_CLOSE)
           {
            X15Log("POSITION", "news emergency close ahead of " + evName);
            return(CloseManagedPosition(p, X15_EXIT_NEWS_EMERGENCY));
           }
         bool slBelowEntry = (dir == 1) ? (p.currentSL < p.avgEntryPrice) : (p.currentSL > p.avgEntryPrice || p.currentSL == 0.0);
         if(rNow > 0.0 && slBelowEntry) ModifyStops(p, p.avgEntryPrice, p.currentTP, "news break-even ahead of " + evName);
        }
     }

   if(newBar && g_execGot > 0)
     {
      double lastClose = g_execRates[g_execGot-1].close;
      datetime lastBar = g_execRates[g_execGot-1].time;
      if(InpUseInvalidationExit && !p.beDone && p.invalidation > 0.0 && lastBar > p.entryBarTime
         && ((dir == 1 && lastClose < p.invalidation) || (dir == -1 && lastClose > p.invalidation)))
        {
         X15Log("POSITION", StringFormat("thesis invalidated: closed %s beyond %s", DoubleToString(lastClose, g_spec.digits), DoubleToString(p.invalidation, g_spec.digits)));
         return(CloseManagedPosition(p, X15_EXIT_INVALIDATION));
        }
      if(InpMaxHoldBars > 0 && p.entryTime > 0 && TimeCurrent() - p.entryTime >= InpMaxHoldBars * PeriodSeconds(InpExecTF))
         return(CloseManagedPosition(p, X15_EXIT_TIME));
      // confirmed VWAP exits: a CLOSED bar that lies entirely after entry crossed VWAP against the
      // position. A cross (not merely "below VWAP") is required, so an entry taken on the far side
      // of VWAP -- normal for a sweep reversal -- cannot be stopped out by its own starting position.
      bool barAfterEntry = (p.entryTime > 0 && lastBar >= p.entryTime);
      bool crossAgainst = (dir == 1) ? g_vwapCrossDown : g_vwapCrossUp;
      if(barAfterEntry && crossAgainst)
        {
         bool structureAgainst = (dir == 1) ? (g_structExec.lastDownEventTime >= p.entryTime) : (g_structExec.lastUpEventTime >= p.entryTime);
         if(InpVWAPExitMode == X15_VWAP_EXIT_CONFIRMED_CROSS
            || (InpVWAPExitMode == X15_VWAP_EXIT_CONFIRMED_CROSS_PLUS_STRUCTURE && structureAgainst)
            || (InpTrailMode == X15_TRAIL_VWAP && rNow >= InpTrailStartR))
            return(CloseManagedPosition(p, X15_EXIT_VWAP));
        }
     }

   // IMMEDIATE: intrabar, against the closed-bar VWAP -- only after price has been on the
   // favourable side of VWAP since entry, so it too needs a real cross, not a starting position
   if(InpVWAPExitMode == X15_VWAP_EXIT_IMMEDIATE && g_vwapClosed > 0.0)
     {
      bool favourable = (dir == 1) ? (exitPx > g_vwapClosed) : (exitPx < g_vwapClosed);
      if(favourable) p.vwapFavorableSeen = true;
      else if(p.vwapFavorableSeen && ((dir == 1 && exitPx < g_vwapClosed) || (dir == -1 && exitPx > g_vwapClosed)))
         return(CloseManagedPosition(p, X15_EXIT_VWAP));
     }

   if(InpUseBreakEven && !p.beDone && rNow >= InpBreakEvenAtR)
     {
      double target = p.avgEntryPrice + dir * InpBreakEvenLockR * risk;
      bool improves = (dir == 1) ? (target > p.currentSL) : (p.currentSL == 0.0 || target < p.currentSL);
      if(!improves) p.beDone = true;
      else if(ModifyStops(p, target, p.currentTP, "break-even")) p.beDone = true;
     }

   if(InpUsePartialClose && !p.partialDone && rNow >= InpPartialAtR)
     {
      double vol = FloorLots(p.volume * InpPartialClosePercent / 100.0);
      // never close MORE than asked because the slice or the remainder would fall below the broker minimum
      if(vol <= 0.0 || p.volume - vol < g_spec.volMin - 1e-12) p.partialDone = true;
      else if(PartialCloseManaged(p, vol)) p.partialDone = true;
      if(p.closed) return(true);
     }

   if(InpTrailMode != X15_TRAIL_NONE && InpTrailMode != X15_TRAIL_VWAP && rNow >= InpTrailStartR)
     {
      double cand = 0.0;
      if(InpTrailMode == X15_TRAIL_ATR && g_structExec.atrAvailable) cand = exitPx - dir * InpTrailATRMultiple * g_structExec.atr;
      if(InpTrailMode == X15_TRAIL_FIXED_R) cand = exitPx - dir * InpTrailFixedR * risk;
      if(InpTrailMode == X15_TRAIL_STRUCTURE && newBar && g_structExec.available)
        {
         double buffer = g_structExec.atrAvailable ? InpSLATRBuffer * g_structExec.atr : 0.0;
         if(dir == 1 && g_structExec.lastSwingLowTime > p.entryTime)   cand = g_structExec.lastSwingLow - buffer;
         if(dir == -1 && g_structExec.lastSwingHighTime > p.entryTime) cand = g_structExec.lastSwingHigh + buffer;
        }
      if(cand > 0.0)
        {
         double minStep = 0.05 * risk; // ignore sub-5%-of-R nudges: they only generate broker traffic
         bool improves = (dir == 1) ? (cand > p.currentSL + minStep) : (p.currentSL == 0.0 || cand < p.currentSL - minStep);
         double spreadPrice = ask - bid;
         bool roomy = (dir == 1) ? (bid - cand >= MinStopDistancePrice() + spreadPrice) : (cand - ask >= MinStopDistancePrice() + spreadPrice);
         if(improves && roomy) ModifyStops(p, cand, p.currentTP, "trail " + EnumLabel(EnumToString(InpTrailMode), "X15_TRAIL_"));
        }
     }
   return(p.closed);
  }

void ManagePositions(bool newBar)
  {
   if(OwnOpenPositionCount() == 0 && ArraySize(g_positions) == 0) return;
   ENUM_X15_STATE before = g_state;
   g_state = X15_ST_POSITION_MANAGEMENT;
   for(int i = ArraySize(g_positions) - 1; i >= 0; i--)
     {
      if(!g_positions[i].isOwn || g_positions[i].closed) continue;
      // ANALYSIS_ONLY sends nothing and PAPER sends nothing real: a live position left over from a
      // LIVE session is tracked and journaled, but never modified or closed outside LIVE mode.
      // Its broker-side SL/TP keep protecting it.
      if(!g_positions[i].isPaper && InpExecutionMode != X15_LIVE_EXECUTION)
        {
         X15Log("POSITION", StringFormat("live position %I64u is tracked but NOT managed in %s mode -- its broker-side SL/TP still apply",
                                         g_positions[i].positionId, EnumLabel(EnumToString(InpExecutionMode), "X15_")));
         continue;
        }
      if(g_positions[i].isPaper && g_positions[i].isPendingOrder) ManagePaperPending(i);
      else ManageOnePosition(g_positions[i], newBar);
     }
   // paper positions finalize themselves on close; drop them from the registry
   for(int i = ArraySize(g_positions) - 1; i >= 0; i--)
      if(g_positions[i].isPaper && g_positions[i].closed) RemovePositionAt(i);
   g_state = before;
  }

//====================================================================
// LAYER 9 -- JOURNAL  (spec 21)
//--------------------------------------------------------------------
// The journal itself IS the learned model: every gate, bonus and stat is
// recomputed from g_journal, nothing is cached beside it. Files live in
// this terminal's own sandboxed MQL5/Files folder (no FILE_COMMON) and
// are written temp-file-then-FileMove, so a crash mid-write leaves the
// previous complete file intact.
//
// v2 format: a marker row, then one row per CLOSED position. A v1 file (8
// columns, no marker) is still read and imported as LEGACY rows.
//
// Strategy Tester: persisted files are never LOADED -- the tester's file
// sandbox survives between runs, so loading would let a re-run of a period
// learn from its own future. Tester runs write to *_TESTER files for
// post-run inspection only.
//====================================================================
#define X15_JOURNAL_MARKER "AX15_JOURNAL_V2"

// The only JournalEntry fields holding uncontrolled external text are the
// calendar event name and the free-text state strings; commas and line
// breaks in them would misalign every later field of the row on reload.
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
   return("AutopsyX15_Journal_v2_" + _Symbol + (IsTester() ? "_TESTER" : "") + ".csv");
  }

string GetLegacyJournalFileName(void)
  {
   return("AutopsyX15_Journal_" + _Symbol + ".csv");
  }

void ResetJournalEntry(JournalEntry &e)
  {
   e.closeTime = 0; e.symbol = _Symbol; e.direction = 0; e.rMultiple = 0.0;
   e.vwapAligned = false; e.vpMacdAligned = false; e.nearValidatedNewsEvent = false; e.newsEventNameAtEntry = "";
   e.positionId = 0; e.source = X15_SRC_LEGACY; e.valid = true; e.invalidReason = "";
   e.setupId = ""; e.setupType = X15_SETUP_NONE; e.entryTime = 0; e.entryPrice = 0.0; e.sl = 0.0; e.tp = 0.0;
   e.volume = 0.0; e.riskPct = 0.0; e.riskMoney = 0.0; e.exitTimeFirst = 0; e.exitPrice = 0.0;
   e.grossProfit = 0.0; e.commission = 0.0; e.swap = 0.0; e.netProfit = 0.0; e.spreadAtEntryPts = 0.0;
   e.vwapState = ""; e.vpmacdState = ""; e.newsState = ""; e.compositeState = ""; e.regime = "";
   e.structureState = ""; e.liquidityState = ""; e.session = ""; e.entryReason = "";
   e.exitReason = X15_EXIT_UNKNOWN; e.isFlip = false; e.evidenceScore = 0;
   e.slippagePts = 0.0;
  }

string D8(double v)
  {
   return(DoubleToString(v, 8));
  }

void SaveJournalToFile(void)
  {
   string fname = GetJournalFileName();
   string tmpFname = fname + ".tmp";
   int handle = FileOpen(tmpFname, FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_SHARE_READ, ',');
   if(handle == INVALID_HANDLE)
     {
      X15Error("JOURNAL", StringFormat("could not open temp journal '%s' (error %d) -- the newest trade will NOT persist", tmpFname, GetLastError()));
      return;
     }
   FileWrite(handle, X15_JOURNAL_MARKER, "closeTime", "symbol", "direction", "rMultiple", "vwapAligned", "vpMacdAligned",
             "nearValidatedNews", "newsEvent", "positionId", "source", "valid", "invalidReason", "setupId", "setupType",
             "entryTime", "entryPrice", "sl", "tp", "volume", "riskPct", "riskMoney", "firstExitTime", "exitPrice",
             "gross", "commission", "swap", "net", "spreadPts", "vwapState", "vpmacdState", "newsState", "composite",
             "regime", "structure", "liquidity", "session", "entryReason", "exitReason", "isFlip", "evidence", "slippagePts");
   int n = ArraySize(g_journal);
   for(int i = 0; i < n; i++)
     {
      JournalEntry e = g_journal[i];
      FileWrite(handle, "R", (long)e.closeTime, e.symbol, e.direction, D8(e.rMultiple), e.vwapAligned ? 1 : 0, e.vpMacdAligned ? 1 : 0,
                e.nearValidatedNewsEvent ? 1 : 0, SanitizeForCsv(e.newsEventNameAtEntry), (long)e.positionId, (int)e.source,
                e.valid ? 1 : 0, SanitizeForCsv(e.invalidReason), e.setupId, (int)e.setupType, (long)e.entryTime,
                D8(e.entryPrice), D8(e.sl), D8(e.tp), D8(e.volume), D8(e.riskPct), D8(e.riskMoney), (long)e.exitTimeFirst,
                D8(e.exitPrice), D8(e.grossProfit), D8(e.commission), D8(e.swap), D8(e.netProfit), D8(e.spreadAtEntryPts),
                SanitizeForCsv(e.vwapState), SanitizeForCsv(e.vpmacdState), SanitizeForCsv(e.newsState),
                SanitizeForCsv(e.compositeState), SanitizeForCsv(e.regime), SanitizeForCsv(e.structureState),
                SanitizeForCsv(e.liquidityState), SanitizeForCsv(e.session), SanitizeForCsv(e.entryReason),
                (int)e.exitReason, e.isFlip ? 1 : 0, e.evidenceScore, D8(e.slippagePts));
     }
   FileClose(handle);
   if(!FileMove(tmpFname, 0, fname, FILE_REWRITE))
      X15Error("JOURNAL", StringFormat("wrote '%s' but could not move it into place (error %d) -- the previous journal is untouched", tmpFname, GetLastError()));
  }

void SkipRestOfLine(int h)
  {
   while(!FileIsLineEnding(h) && !FileIsEnding(h)) FileReadString(h);
  }

bool ReadJournalRowV2(int h, JournalEntry &e)
  {
   ResetJournalEntry(e);
   e.closeTime              = (datetime)StringToInteger(FileReadString(h));
   e.symbol                 = FileReadString(h);
   e.direction              = (int)StringToInteger(FileReadString(h));
   e.rMultiple              = StringToDouble(FileReadString(h));
   e.vwapAligned            = (StringToInteger(FileReadString(h)) != 0);
   e.vpMacdAligned          = (StringToInteger(FileReadString(h)) != 0);
   e.nearValidatedNewsEvent = (StringToInteger(FileReadString(h)) != 0);
   e.newsEventNameAtEntry   = FileReadString(h);
   e.positionId             = (ulong)StringToInteger(FileReadString(h));
   e.source                 = (ENUM_X15_TRADE_SOURCE)StringToInteger(FileReadString(h));
   e.valid                  = (StringToInteger(FileReadString(h)) != 0);
   e.invalidReason          = FileReadString(h);
   e.setupId                = FileReadString(h);
   e.setupType              = (ENUM_X15_SETUP_TYPE)StringToInteger(FileReadString(h));
   e.entryTime              = (datetime)StringToInteger(FileReadString(h));
   e.entryPrice             = StringToDouble(FileReadString(h));
   e.sl                     = StringToDouble(FileReadString(h));
   e.tp                     = StringToDouble(FileReadString(h));
   e.volume                 = StringToDouble(FileReadString(h));
   e.riskPct                = StringToDouble(FileReadString(h));
   e.riskMoney              = StringToDouble(FileReadString(h));
   e.exitTimeFirst          = (datetime)StringToInteger(FileReadString(h));
   e.exitPrice              = StringToDouble(FileReadString(h));
   e.grossProfit            = StringToDouble(FileReadString(h));
   e.commission             = StringToDouble(FileReadString(h));
   e.swap                   = StringToDouble(FileReadString(h));
   e.netProfit              = StringToDouble(FileReadString(h));
   e.spreadAtEntryPts       = StringToDouble(FileReadString(h));
   e.vwapState              = FileReadString(h);
   e.vpmacdState            = FileReadString(h);
   e.newsState              = FileReadString(h);
   e.compositeState         = FileReadString(h);
   e.regime                 = FileReadString(h);
   e.structureState         = FileReadString(h);
   e.liquidityState         = FileReadString(h);
   e.session                = FileReadString(h);
   e.entryReason            = FileReadString(h);
   e.exitReason             = (ENUM_X15_EXIT_REASON)StringToInteger(FileReadString(h));
   e.isFlip                 = (StringToInteger(FileReadString(h)) != 0);
   e.evidenceScore          = (int)StringToInteger(FileReadString(h));
   bool rowComplete = FileIsLineEnding(h) || FileIsEnding(h);
   if(!rowComplete) { e.slippagePts = StringToDouble(FileReadString(h)); rowComplete = true; } // optional trailing column (absent in older rows)
   SkipRestOfLine(h);
   // a short row (interrupted write, hand edit) is loaded as invalid: kept for audit, never learned from
   if(!rowComplete || e.closeTime <= 0)
     {
      e.valid = false;
      e.invalidReason = "malformed journal row";
     }
   return(true);
  }

// Legacy v1: closeTime, symbol, direction, rMultiple, vwapAligned,
// vpMacdAligned, nearValidatedNews, newsEvent -- written by any position on
// the symbol, so it comes in as LEGACY (not learned from by default).
int LoadJournalV1Rows(int h, string firstField)
  {
   int loaded = 0;
   string first = firstField;
   while(true)
     {
      if(first == "" && FileIsEnding(h)) break;
      JournalEntry e;
      ResetJournalEntry(e);
      e.closeTime              = (datetime)StringToInteger(first);
      e.symbol                 = FileReadString(h);
      e.direction              = (int)StringToInteger(FileReadString(h));
      e.rMultiple              = StringToDouble(FileReadString(h));
      e.vwapAligned            = (StringToInteger(FileReadString(h)) != 0);
      e.vpMacdAligned          = (StringToInteger(FileReadString(h)) != 0);
      e.nearValidatedNewsEvent = (StringToInteger(FileReadString(h)) != 0);
      e.newsEventNameAtEntry   = FileReadString(h);
      e.source = X15_SRC_LEGACY;
      e.entryReason = "imported from v1 journal";
      if(e.closeTime > 0)
        {
         int idx = ArraySize(g_journal);
         ArrayResize(g_journal, idx + 1);
         g_journal[idx] = e;
         loaded++;
        }
      if(FileIsEnding(h)) break;
      first = FileReadString(h);
     }
   return(loaded);
  }

int LoadJournalFile(string fname)
  {
   int handle = FileOpen(fname, FILE_READ|FILE_CSV|FILE_ANSI|FILE_SHARE_READ, ',');
   if(handle == INVALID_HANDLE)
     {
      X15Error("JOURNAL", StringFormat("found '%s' but could not open it (error %d) -- starting empty rather than guessing", fname, GetLastError()));
      return(-1);
     }
   int loaded = 0;
   string first = FileReadString(handle);
   if(first == X15_JOURNAL_MARKER)
     {
      SkipRestOfLine(handle);
      while(!FileIsEnding(handle))
        {
         string tag = FileReadString(handle);
         if(tag != "R") { SkipRestOfLine(handle); continue; }
         JournalEntry e;
         ReadJournalRowV2(handle, e);
         if(e.positionId != 0 && JournalHasPosition(e.positionId, e.source)) continue; // dedupe on load too
         int idx = ArraySize(g_journal);
         ArrayResize(g_journal, idx + 1);
         g_journal[idx] = e;
         loaded++;
        }
     }
   else loaded = LoadJournalV1Rows(handle, first);
   FileClose(handle);
   return(loaded);
  }

void LoadJournalFromFile(void)
  {
   ArrayResize(g_journal, 0);
   if(IsTester()) return;
   string fname = GetJournalFileName();
   if(FileIsExist(fname))
     {
      int n = LoadJournalFile(fname);
      if(n >= 0) X15Log("JOURNAL", StringFormat("loaded %d journal rows from '%s'", n, fname));
      return;
     }
   string legacy = GetLegacyJournalFileName();
   if(JournalFileNameOverride == "" && FileIsExist(legacy))
     {
      int n = LoadJournalFile(legacy);
      if(n > 0)
        {
         X15Log("JOURNAL", StringFormat("imported %d v1 rows from '%s' as LEGACY (excluded from learning unless InpLearningSource=ALL_OWN); the v1 file is left untouched", n, legacy));
         SaveJournalToFile();
        }
      return;
     }
   X15Log("JOURNAL", "no journal yet -- starting with an empty track record");
  }

void AppendJournal(JournalEntry &e)
  {
   if(e.positionId != 0 && JournalHasPosition(e.positionId, e.source)) return;
   int idx = ArraySize(g_journal);
   ArrayResize(g_journal, idx + 1);
   g_journal[idx] = e;
   g_perfDirty = true;
   SaveJournalToFile();
   X15Log("JOURNAL", StringFormat("%s %s %s closed: %.2fR, net %.2f, exit %s%s", SourceLabel(e.source), DirLabel(e.direction),
                                  e.setupId != "" ? e.setupId : IntegerToString((long)e.positionId), e.rMultiple, e.netProfit,
                                  ExitReasonLabel(e.exitReason), e.valid ? "" : " [INVALID: " + e.invalidReason + "]"));
  }

void FillJournalFromPosition(X15Position &p, JournalEntry &e)
  {
   ResetJournalEntry(e);
   e.symbol = _Symbol;
   e.direction = p.direction;
   e.vwapAligned = p.vwapAligned;
   e.vpMacdAligned = p.vpMacdAligned;
   e.nearValidatedNewsEvent = p.nearValidatedNewsEvent;
   e.newsEventNameAtEntry = p.newsEventNameAtEntry;
   e.positionId = p.positionId;
   e.source = !p.isOwn ? X15_SRC_EXTERNAL : (p.isPaper ? X15_SRC_PAPER : (IsTester() ? X15_SRC_TESTER : X15_SRC_LIVE));
   e.setupId = p.setupId;
   e.setupType = p.setupType;
   e.entryTime = p.entryTime;
   e.sl = p.originalSL;
   e.tp = p.originalTP;
   e.volume = p.peakVolume;
   e.riskPct = p.riskPct;
   e.riskMoney = p.riskMoney;
   e.spreadAtEntryPts = p.spreadAtEntryPts;
   e.vwapState = p.vwapState;
   e.vpmacdState = p.vpmacdState;
   e.newsState = p.newsState;
   e.compositeState = p.compositeState;
   e.regime = p.regime;
   e.structureState = p.structureState;
   e.liquidityState = p.liquidityState;
   e.session = p.session;
   e.entryReason = p.entryReason;
   e.isFlip = p.isFlip;
   e.evidenceScore = p.evidenceScore;
   e.slippagePts = (p.requestedPrice > 0.0 && p.entryPrice > 0.0 && g_spec.point > 0.0)
                   ? (p.entryPrice - p.requestedPrice) * p.direction / g_spec.point : 0.0;
   if(p.isPreExisting && p.isOwn)
     {
      e.valid = false;
      e.invalidReason = "pre-existing own position with no persisted entry context";
     }
   if(p.valuationFailed)
     {
      e.valid = false;
      e.invalidReason = "paper P&L could not be valued by the broker (OrderCalcProfit failed)";
     }
  }

// Own trades: R = net realized P&L / money at risk at entry, so partial
// closes, commission and swap are all inside one number. Without a money
// risk basis (external positions) R is price-based from the blended entry.
void ComputeJournalR(X15Position &p, JournalEntry &e)
  {
   if(p.isOwn && p.riskMoney > 0.0)
     {
      e.rMultiple = e.netProfit / p.riskMoney;
      return;
     }
   double riskDistance = (p.direction == 1) ? (e.entryPrice - p.originalSL) : (p.originalSL - e.entryPrice);
   if(p.originalSL <= 0.0 || riskDistance <= 0.0)
     {
      e.rMultiple = 0.0;
      e.valid = false;
      e.invalidReason = "no stop loss at entry: undefined risk basis";
      return;
     }
   e.rMultiple = (p.direction == 1) ? (e.exitPrice - e.entryPrice) / riskDistance : (e.entryPrice - e.exitPrice) / riskDistance;
  }

ENUM_X15_EXIT_REASON ClassifyBrokerExit(X15Position &p, long dealReason)
  {
   if(p.pendingExitReason != X15_EXIT_NONE) return(p.pendingExitReason);
   if(dealReason == DEAL_REASON_TP) return(X15_EXIT_TAKE_PROFIT);
   if(dealReason == DEAL_REASON_SO) return(X15_EXIT_STOP_OUT);
   if(dealReason == DEAL_REASON_CLIENT || dealReason == DEAL_REASON_MOBILE || dealReason == DEAL_REASON_WEB) return(X15_EXIT_MANUAL);
   if(dealReason == DEAL_REASON_SL)
     {
      double risk = MathAbs(p.entryPrice - p.originalSL);
      bool locked = (p.direction == 1) ? (p.currentSL >= p.avgEntryPrice) : (p.currentSL > 0.0 && p.currentSL <= p.avgEntryPrice);
      if(!locked) return(X15_EXIT_STOP_LOSS);
      if(risk > 0.0 && MathAbs(p.currentSL - p.avgEntryPrice) > (InpBreakEvenLockR + 0.05) * risk) return(X15_EXIT_TRAIL_STOP);
      return(X15_EXIT_BREAKEVEN_STOP);
     }
   return(X15_EXIT_UNKNOWN);
  }

// Idempotent: returns true once the position is journaled (or already
// was). Returns false while the closing deals are not in history yet -- the
// caller simply tries again on a later pass.
bool FinalizeLivePosition(X15Position &p)
  {
   ENUM_X15_TRADE_SOURCE src = !p.isOwn ? X15_SRC_EXTERNAL : (IsTester() ? X15_SRC_TESTER : X15_SRC_LIVE);
   if(JournalHasPosition(p.positionId, src)) return(true);
   if(!HistorySelectByPosition((long)p.positionId)) return(false);
   int total = HistoryDealsTotal();
   double inPV = 0.0, inVol = 0.0, outPV = 0.0, outVol = 0.0, gross = 0.0, comm = 0.0, swap = 0.0;
   datetime closeTime = 0, firstExit = 0;
   long lastReason = -1;
   for(int i = 0; i < total; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      long entry = HistoryDealGetInteger(d, DEAL_ENTRY);
      double vol = HistoryDealGetDouble(d, DEAL_VOLUME);
      double px = HistoryDealGetDouble(d, DEAL_PRICE);
      comm += HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_FEE);
      swap += HistoryDealGetDouble(d, DEAL_SWAP);
      gross += HistoryDealGetDouble(d, DEAL_PROFIT);
      if(entry == DEAL_ENTRY_IN) { inPV += px * vol; inVol += vol; }
      else if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY || entry == DEAL_ENTRY_INOUT)
        {
         outPV += px * vol; outVol += vol;
         datetime t = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
         if(firstExit == 0) firstExit = t;
         closeTime = t;
         lastReason = HistoryDealGetInteger(d, DEAL_REASON);
        }
     }
   if(outVol <= 0.0) return(false);

   JournalEntry e;
   FillJournalFromPosition(p, e);
   e.closeTime = closeTime;
   e.exitTimeFirst = firstExit;
   e.entryPrice = (inVol > 0.0) ? inPV / inVol : p.avgEntryPrice;
   e.exitPrice = outPV / outVol;
   e.grossProfit = gross;
   e.commission = comm;
   e.swap = swap;
   e.netProfit = gross + comm + swap;
   e.exitReason = ClassifyBrokerExit(p, lastReason);
   ComputeJournalR(p, e);
   AppendJournal(e);
   return(true);
  }

// Paper accounting: exits at the real bid/ask (or the TP level), P&L valued
// by the broker's own OrderCalcProfit. No commission is modelled -- stated,
// not hidden: paper R is optimistic by the commission a live fill pays.
void PaperClose(X15Position &p, double vol, double exitPrice)
  {
   if(vol <= 0.0 || p.closed) return;
   vol = MathMin(vol, p.volume);
   double profit = 0.0;
   if(!OrderCalcProfit(p.direction == 1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, vol, p.avgEntryPrice, exitPrice, profit))
     {
      bool losing = (p.direction * (exitPrice - p.avgEntryPrice) < 0.0);
      double tv = (losing && g_spec.tickValueLoss > 0.0) ? g_spec.tickValueLoss : g_spec.tickValue;
      profit =(g_spec.tickSize > 0.0) ? p.direction * (exitPrice - p.avgEntryPrice) / g_spec.tickSize * tv * vol : 0.0;
      p.valuationFailed = true;
      X15Error("POSITION", "[PAPER] OrderCalcProfit failed -- P&L estimated from tick value; this trade will be journaled as INVALID");
     }
   p.paperGross += profit;
   p.paperExitPriceVolume += exitPrice * vol;
   p.paperExitVolume += vol;
   if(p.firstExitTime == 0) p.firstExitTime = TimeCurrent();
   p.volume = NormalizeDouble(p.volume - vol, VolumeDigits());
   g_stateDirty = true;
   if(p.volume > 1e-9)
     {
      X15Log("POSITION", StringFormat("[PAPER] partial %.2f lots @ %s, %.2f", vol, DoubleToString(exitPrice, g_spec.digits), profit));
      return;
     }
   JournalEntry e;
   FillJournalFromPosition(p, e);
   e.closeTime = TimeCurrent();
   e.exitTimeFirst = p.firstExitTime;
   e.entryPrice = p.avgEntryPrice;
   e.exitPrice = (p.paperExitVolume > 0.0) ? p.paperExitPriceVolume / p.paperExitVolume : exitPrice;
   e.grossProfit = p.paperGross;
   e.netProfit = p.paperGross;
   e.exitReason = (p.pendingExitReason != X15_EXIT_NONE) ? p.pendingExitReason : X15_EXIT_UNKNOWN;
   ComputeJournalR(p, e);
   AppendJournal(e);
   p.closed = true;
  }

//====================================================================
// POSITION STATE PERSISTENCE  (spec 37)
//--------------------------------------------------------------------
// Own positions (live and paper) and pending entry contexts are saved with
// everything management needs (original SL, break-even/partial flags, the
// entry snapshot). After a restart they are reloaded and matched back to
// the broker's positions by POSITION_IDENTIFIER, so management continues
// and no alignment is fabricated for a position this EA really opened.
//====================================================================
string PositionStateFileName(void)
  {
   return(StringFormat("AutopsyX15_State_%s_%I64u%s.csv", _Symbol, InpMagicNumber, IsTester() ? "_TESTER" : ""));
  }

void WritePositionRow(int h, string kind, X15Position &p)
  {
   FileWrite(h, kind, (long)p.positionId, (long)p.ticket, p.isOwn ? 1 : 0, p.isPaper ? 1 : 0, p.isPreExisting ? 1 : 0,
             p.setupId, (int)p.setupType, p.direction, (long)p.entryTime, (long)p.entryBarTime, D8(p.entryPrice), D8(p.avgEntryPrice),
             D8(p.volume), D8(p.peakVolume), D8(p.originalSL), D8(p.originalTP), D8(p.currentSL), D8(p.currentTP), D8(p.riskPct),
             D8(p.riskMoney), D8(p.invalidation), D8(p.spreadAtEntryPts), p.beDone ? 1 : 0, p.partialDone ? 1 : 0, p.modifyFailCount,
             (long)p.lastModifyTime, (long)p.firstExitTime, (int)p.pendingExitReason, p.isFlip ? 1 : 0, p.evidenceScore,
             p.vwapAligned ? 1 : 0, p.vpMacdAligned ? 1 : 0, p.nearValidatedNewsEvent ? 1 : 0, SanitizeForCsv(p.newsEventNameAtEntry),
             SanitizeForCsv(p.vwapState), SanitizeForCsv(p.vpmacdState), SanitizeForCsv(p.newsState), SanitizeForCsv(p.compositeState),
             SanitizeForCsv(p.regime), SanitizeForCsv(p.structureState), SanitizeForCsv(p.liquidityState), SanitizeForCsv(p.session),
             SanitizeForCsv(p.entryReason), D8(p.paperExitPriceVolume), D8(p.paperExitVolume), D8(p.paperGross),
             p.isPendingOrder ? 1 : 0, D8(p.pendingPrice), (long)p.pendingExpiry, p.valuationFailed ? 1 : 0, D8(p.requestedPrice));
  }

void ReadPositionRow(int h, X15Position &p)
  {
   ResetPosition(p);
   p.positionId = (ulong)StringToInteger(FileReadString(h));
   p.ticket = (ulong)StringToInteger(FileReadString(h));
   p.isOwn = (StringToInteger(FileReadString(h)) != 0);
   p.isPaper = (StringToInteger(FileReadString(h)) != 0);
   p.isPreExisting = (StringToInteger(FileReadString(h)) != 0);
   p.setupId = FileReadString(h);
   p.setupType = (ENUM_X15_SETUP_TYPE)StringToInteger(FileReadString(h));
   p.direction = (int)StringToInteger(FileReadString(h));
   p.entryTime = (datetime)StringToInteger(FileReadString(h));
   p.entryBarTime = (datetime)StringToInteger(FileReadString(h));
   p.entryPrice = StringToDouble(FileReadString(h));
   p.avgEntryPrice = StringToDouble(FileReadString(h));
   p.volume = StringToDouble(FileReadString(h));
   p.peakVolume = StringToDouble(FileReadString(h));
   p.originalSL = StringToDouble(FileReadString(h));
   p.originalTP = StringToDouble(FileReadString(h));
   p.currentSL = StringToDouble(FileReadString(h));
   p.currentTP = StringToDouble(FileReadString(h));
   p.riskPct = StringToDouble(FileReadString(h));
   p.riskMoney = StringToDouble(FileReadString(h));
   p.invalidation = StringToDouble(FileReadString(h));
   p.spreadAtEntryPts = StringToDouble(FileReadString(h));
   p.beDone = (StringToInteger(FileReadString(h)) != 0);
   p.partialDone = (StringToInteger(FileReadString(h)) != 0);
   p.modifyFailCount = (int)StringToInteger(FileReadString(h));
   p.lastModifyTime = (datetime)StringToInteger(FileReadString(h));
   p.firstExitTime = (datetime)StringToInteger(FileReadString(h));
   p.pendingExitReason = (ENUM_X15_EXIT_REASON)StringToInteger(FileReadString(h));
   p.isFlip = (StringToInteger(FileReadString(h)) != 0);
   p.evidenceScore = (int)StringToInteger(FileReadString(h));
   p.vwapAligned = (StringToInteger(FileReadString(h)) != 0);
   p.vpMacdAligned = (StringToInteger(FileReadString(h)) != 0);
   p.nearValidatedNewsEvent = (StringToInteger(FileReadString(h)) != 0);
   p.newsEventNameAtEntry = FileReadString(h);
   p.vwapState = FileReadString(h);
   p.vpmacdState = FileReadString(h);
   p.newsState = FileReadString(h);
   p.compositeState = FileReadString(h);
   p.regime = FileReadString(h);
   p.structureState = FileReadString(h);
   p.liquidityState = FileReadString(h);
   p.session = FileReadString(h);
   p.entryReason = FileReadString(h);
   p.paperExitPriceVolume = StringToDouble(FileReadString(h));
   p.paperExitVolume = StringToDouble(FileReadString(h));
   p.paperGross = StringToDouble(FileReadString(h));
   p.isPendingOrder = (StringToInteger(FileReadString(h)) != 0);
   p.pendingPrice = StringToDouble(FileReadString(h));
   p.pendingExpiry = (datetime)StringToInteger(FileReadString(h));
   if(!FileIsLineEnding(h) && !FileIsEnding(h)) p.valuationFailed = (StringToInteger(FileReadString(h)) != 0); // absent in older state files
   if(!FileIsLineEnding(h) && !FileIsEnding(h)) p.requestedPrice = StringToDouble(FileReadString(h));
   SkipRestOfLine(h);
  }

void SavePositionState(void)
  {
   g_stateDirty = false;
   string fname = PositionStateFileName();
   string tmp = fname + ".tmp";
   int h = FileOpen(tmp, FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_SHARE_READ, ',');
   if(h == INVALID_HANDLE) { X15Error("JOURNAL", StringFormat("cannot write position state '%s' (error %d)", tmp, GetLastError())); return; }
   for(int i = 0; i < ArraySize(g_positions); i++)
      if(g_positions[i].isOwn && !g_positions[i].closed) WritePositionRow(h, "POS", g_positions[i]);
   for(int i = 0; i < ArraySize(g_dormantPaper); i++) WritePositionRow(h, "POS", g_dormantPaper[i]);
   for(int i = 0; i < ArraySize(g_entryContexts); i++) WritePositionRow(h, "CTX", g_entryContexts[i]);
   FileClose(h);
   if(!FileMove(tmp, 0, fname, FILE_REWRITE))
      X15Error("JOURNAL", StringFormat("cannot move position state into place (error %d)", GetLastError()));
  }

void LoadPositionState(void)
  {
   ArrayResize(g_positions, 0);
   ArrayResize(g_entryContexts, 0);
   ArrayResize(g_dormantPaper, 0);
   if(IsTester()) return;
   string fname = PositionStateFileName();
   if(!FileIsExist(fname)) return;
   int h = FileOpen(fname, FILE_READ|FILE_CSV|FILE_ANSI|FILE_SHARE_READ, ',');
   if(h == INVALID_HANDLE) { X15Error("JOURNAL", StringFormat("cannot read position state '%s' (error %d)", fname, GetLastError())); return; }
   int pos = 0, ctx = 0;
   while(!FileIsEnding(h))
     {
      string kind = FileReadString(h);
      if(kind != "POS" && kind != "CTX") { SkipRestOfLine(h); continue; }
      X15Position p;
      ReadPositionRow(h, p);
      if(kind == "POS")
        {
         // live rows always load (reconciliation decides whether the position still exists);
         // paper rows only run in PAPER mode and are otherwise carried through unchanged
         if(p.isPaper && InpExecutionMode != X15_PAPER_EXECUTION)
           {
            int d = ArraySize(g_dormantPaper);
            ArrayResize(g_dormantPaper, d + 1);
            g_dormantPaper[d] = p;
            continue;
           }
         AppendPosition(p); pos++;
        }
      else { AddEntryContext(p); ctx++; }
     }
   FileClose(h);
   if(pos + ctx > 0) X15Log("JOURNAL", StringFormat("restart: restored %d managed position(s) and %d pending entry context(s)", pos, ctx));
  }

//====================================================================
// RECONCILIATION  (spec 20, 37)
//--------------------------------------------------------------------
// Idempotent comparison of the registry against the broker. Runs on every
// OnTradeTransaction wake-up AND on every tick/timer as a backstop, so
// neither a missed transaction event nor a missed tick can lose a close.
//====================================================================
void RegisterLivePosition(ulong ticket, ulong positionId, bool own, bool initialPass)
  {
   if(!PositionSelectByTicket(ticket)) return;
   X15Position p;
   ResetPosition(p);
   p.positionId = positionId;
   p.ticket = ticket;
   p.isOwn = own;
   p.direction = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
   p.entryTime = (datetime)PositionGetInteger(POSITION_TIME);
   p.entryBarTime = p.entryTime;
   p.entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   p.avgEntryPrice = p.entryPrice;
   p.volume = PositionGetDouble(POSITION_VOLUME);
   p.peakVolume = p.volume;
   p.currentSL = PositionGetDouble(POSITION_SL);
   p.currentTP = PositionGetDouble(POSITION_TP);
   string posComment = PositionGetString(POSITION_COMMENT);

   // The broker's record of the OPENING order holds the SL/TP as originally
   // placed -- it survives restarts and any later break-even/trailing move.
   double orderSL = 0.0, orderTP = 0.0;
   string orderComment = "";
   bool hadExit = false;
   double inVolume = 0.0;
   if(HistorySelectByPosition((long)positionId))
     {
      // any OUT deal on a still-open position means a partial close already happened (possibly
      // before a crash): it must never be repeated. Peak volume = everything that ever entered.
      for(int d = HistoryDealsTotal() - 1; d >= 0; d--)
        {
         ulong dt = HistoryDealGetTicket(d);
         if(dt == 0) continue;
         long de = HistoryDealGetInteger(dt, DEAL_ENTRY);
         if(de == DEAL_ENTRY_IN) inVolume += HistoryDealGetDouble(dt, DEAL_VOLUME);
         else if(de == DEAL_ENTRY_OUT || de == DEAL_ENTRY_OUT_BY) hadExit = true;
        }
     }
   if(HistorySelectByPosition((long)positionId) && HistoryOrderSelect(positionId))
     {
      orderSL = HistoryOrderGetDouble(positionId, ORDER_SL);
      orderTP = HistoryOrderGetDouble(positionId, ORDER_TP);
      orderComment = HistoryOrderGetString(positionId, ORDER_COMMENT);
     }
   p.originalSL = (orderSL > 0.0) ? orderSL : p.currentSL;
   p.originalTP = (orderTP > 0.0) ? orderTP : p.currentTP;
   if(!PositionSelectByTicket(ticket)) return; // history calls do not deselect, but re-select to be certain

   if(own)
     {
      string sid = ExtractSetupIdFromComment(orderComment != "" ? orderComment : posComment);
      int ci = FindEntryContext(sid);
      if(ci >= 0)
        {
         X15Position ctx = g_entryContexts[ci];
         ctx.positionId = p.positionId; ctx.ticket = p.ticket; ctx.isPaper = false;
         ctx.entryTime = p.entryTime; ctx.entryPrice = p.entryPrice; ctx.avgEntryPrice = p.avgEntryPrice;
         ctx.volume = p.volume; ctx.peakVolume = p.volume;
         ctx.currentSL = p.currentSL; ctx.currentTP = p.currentTP;
         ctx.originalSL = p.originalSL; ctx.originalTP = p.originalTP;
         p = ctx;
         RemoveEntryContext(sid);
        }
      else
        {
         p.isPreExisting = true;
         p.setupId = sid;
         p.entryReason = "reconstructed: no persisted entry context";
         X15Log("POSITION", StringFormat("own position %I64u has no persisted context -- entry-time signals recorded as UNKNOWN, not re-read from current data", positionId));
        }
      // actual money at risk from the real fill to the original SL
      double pr = 0.0;
      if(p.originalSL > 0.0 && OrderCalcProfit(p.direction == 1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, p.volume, p.entryPrice, p.originalSL, pr) && pr < 0.0)
         p.riskMoney = -pr;
     }
   else
     {
      p.isPreExisting = initialPass;
      if(!initialPass)
        {
         // external position first seen now, i.e. at (or within a tick of) its entry: the
         // same entry-time reads the pre-robot journal used for every position
         string vwapClass = UseVWAPExit ? ClassifyVWAPTrend(_Symbol) : "NEUTRAL";
         p.vwapAligned = (p.direction == 1 && vwapClass == "BULLISH") || (p.direction == -1 && vwapClass == "BEARISH");
         string vpClass = UseVPMACDEntry ? ClassifyVPMACDSignal(_Symbol) : "NEUTRAL";
         p.vpMacdAligned = (p.direction == 1 && vpClass == "BULLISH") || (p.direction == -1 && vpClass == "BEARISH");
         if(!IsTester())
           {
            NewsDefenseState nd = CheckNewsDefense(_Symbol);
            p.nearValidatedNewsEvent = nd.isValidatedEvent;
            p.newsEventNameAtEntry = (nd.active && nd.isValidatedEvent) ? SanitizeForCsv(nd.reason) : "";
           }
        }
      p.entryReason = "external position";
     }
   if(hadExit) p.partialDone = true;
   p.peakVolume = MathMax(p.peakVolume, inVolume);
   AppendPosition(p);
   X15Log("POSITION", StringFormat("tracking %s position %I64u %s %.2f lots @ %s%s", own ? "own" : "external", positionId,
                                   DirLabel(p.direction), p.volume, DoubleToString(p.entryPrice, g_spec.digits),
                                   p.setupId != "" ? " setup " + p.setupId : ""));
  }

void ReconcilePositions(void)
  {
   bool initial = !g_firstSyncDone;
   g_reconcileRequested = false;
   int total = PositionsTotal();
   ulong seen[];
   ArrayResize(seen, total);
   int seenCount = 0;
   for(int i = 0; i < total; i++)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);
      bool own = (magic == InpMagicNumber);
      if(!own && InpMagicNumberFilter != 0 && magic != InpMagicNumberFilter) continue;
      ulong id = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      seen[seenCount] = id;
      seenCount++;
      int idx = FindPositionIndex(id, false);
      if(idx < 0) { RegisterLivePosition(t, id, own, initial); continue; }
      if(!PositionSelectByTicket(t)) continue;
      double vol = PositionGetDouble(POSITION_VOLUME);
      if(g_positions[idx].ticket != t || MathAbs(g_positions[idx].volume - vol) > 1e-9) g_stateDirty = true;
      if(vol < g_positions[idx].peakVolume - 1e-9) g_positions[idx].partialDone = true; // volume already reduced: never partial again
      g_positions[idx].ticket = t;
      g_positions[idx].volume = vol;
      g_positions[idx].peakVolume = MathMax(g_positions[idx].peakVolume, vol);
      g_positions[idx].avgEntryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      g_positions[idx].currentSL = PositionGetDouble(POSITION_SL);
      g_positions[idx].currentTP = PositionGetDouble(POSITION_TP);
     }

   for(int i = ArraySize(g_positions) - 1; i >= 0; i--)
     {
      if(g_positions[i].isPaper) continue;
      bool stillOpen = false;
      for(int j = 0; j < seenCount; j++) if(seen[j] == g_positions[i].positionId) { stillOpen = true; break; }
      if(stillOpen) continue;
      if(FinalizeLivePosition(g_positions[i])) { RemovePositionAt(i); continue; }
      g_positions[i].finalizeAttempts++;
      if(g_positions[i].finalizeAttempts >= 200)
        {
         // closing deals never appeared in history: record the gap honestly rather than drop it silently
         JournalEntry e;
         FillJournalFromPosition(g_positions[i], e);
         e.closeTime = TimeCurrent();
         e.valid = false;
         e.invalidReason = "position closed but its deal history was never available";
         AppendJournal(e);
         RemovePositionAt(i);
        }
     }

   ResolveUnconfirmedSetups(initial);
   g_firstSyncDone = true;
   if(g_stateDirty) SavePositionState();
  }

// Authoritative add count from the broker's deal history: every
// DEAL_ENTRY_IN on the position identifier is the original entry or an add.
int CountPositionEntryDeals(ulong positionIdentifier)
  {
   if(!HistorySelectByPosition((long)positionIdentifier)) return(0);
   int total = HistoryDealsTotal();
   int count = 0;
   for(int i = 0; i < total; i++)
     {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;
      if(HistoryDealGetInteger(dealTicket, DEAL_ENTRY) == DEAL_ENTRY_IN) count++;
     }
   return(count);
  }

struct AggregatePyramidRisk
  {
   double            totalLots;
   double            blendedEntryPrice;
   double            totalRiskAmount;          // money lost if the whole position hit its current SL
   double            totalRiskPercentOfEquity;
  };

// Expects the position already selected.
void ComputeAggregatePyramidRisk(AggregatePyramidRisk &agg)
  {
   agg.totalLots = PositionGetDouble(POSITION_VOLUME);
   agg.blendedEntryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   agg.totalRiskAmount = 0.0;
   agg.totalRiskPercentOfEquity = 0.0;
   double slPrice = PositionGetDouble(POSITION_SL);
   if(slPrice <= 0.0) return;
   int direction = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
   double pr = 0.0;
   if(OrderCalcProfit(direction == 1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, agg.totalLots, agg.blendedEntryPrice, slPrice, pr) && pr < 0.0)
      agg.totalRiskAmount = -pr;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > 0.0) agg.totalRiskPercentOfEquity = agg.totalRiskAmount / equity * 100.0;
  }

// Duplicate-protection key for one add; falls back to the position id so two
// reconstructed positions without a setup ID can never share a key.
string PyramidAddKey(int idx, int addNumber)
  {
   string base = (g_positions[idx].setupId != "") ? g_positions[idx].setupId : "POS" + IntegerToString((long)g_positions[idx].positionId);
   return(base + "+" + IntegerToString(addNumber));
  }

// Sized like a fresh trade: current equity, fresh ComputeFinalRiskPct(), and
// the add's OWN stop distance (current price to the existing SL). Then two
// caps shrink it: the position's aggregate risk <= InpMaxRiskPct, and this
// EA's total open risk <= InpMaxTotalOpenRiskPct.
double SizePyramidAdd(int idx, int direction, double &addRiskMoneyOut, string &why)
  {
   addRiskMoneyOut = 0.0; why = "";
   ulong ticket = 0;
   if(!SelectLivePositionById(g_positions[idx].positionId, ticket)) { why = "position not found"; return(0.0); }
   double slPrice = PositionGetDouble(POSITION_SL);
   double price = SymbolInfoDouble(_Symbol, direction == 1 ? SYMBOL_ASK : SYMBOL_BID);
   double stopDistance = (direction == 1) ? (price - slPrice) : (slPrice - price);
   if(slPrice <= 0.0 || price <= 0.0 || stopDistance <= 0.0) { why = "price is at or through the existing SL"; return(0.0); }
   AggregatePyramidRisk agg;
   ComputeAggregatePyramidRisk(agg);

   string trace;
   double riskPct = ComputeFinalRiskPct(direction, false, trace);
   double lots = 0.0, riskMoney = 0.0;
   if(!SizeForRisk(direction, price, slPrice, riskPct, lots, riskMoney, why)) return(0.0);

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double positionCap = equity * InpMaxRiskPct / 100.0 - agg.totalRiskAmount;
   X15Exposure ex;
   ComputeExposure(ex);
   double accountCap = equity * InpMaxTotalOpenRiskPct / 100.0 - ex.openRiskMoney;
   double allowed = MathMin(positionCap, accountCap);
   if(allowed <= 0.0) { why = "aggregate risk cap already saturated"; return(0.0); }
   if(riskMoney > allowed)
     {
      if(!SizeForRisk(direction, price, slPrice, allowed / equity * 100.0, lots, riskMoney, why))
        { why = "add shrunk below the broker minimum by the aggregate risk cap"; return(0.0); }
     }
   addRiskMoneyOut = riskMoney;
   return(lots);
  }

// Sends one add that CheckExecutionEligibility(addIdx) already authorized;
// `ed` carries its volume, money at risk and the position's own SL/TP.
void SendPyramidAdd(int idx, X15ExecDecision &ed)
  {
   int direction = ed.direction;
   int addNumber = MathMax(0, CountPositionEntryDeals(g_positions[idx].positionId) - 1) + 1;
   string addId = PyramidAddKey(idx, addNumber);
   string comment = BuildOrderComment("P" + IntegerToString(addNumber), g_positions[idx].setupId);

   if(InpExecutionMode != X15_LIVE_EXECUTION)
     {
      X15Log("EXECUTION", StringFormat("[%s] pyramid add %d would send %.2f lots %s (risk %.2f), SL %s TP %s unchanged -- nothing sent",
                                       InpExecutionMode == X15_PAPER_EXECUTION ? "PAPER" : "ANALYSIS", addNumber, ed.lots, DirLabel(direction),
                                       ed.riskMoney, DoubleToString(ed.sl, g_spec.digits), DoubleToString(ed.tp, g_spec.digits)));
      return;
     }

   RecordSetupStatus(addId, direction, "SENDING", 0);
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpMaxSlippagePoints);
   g_trade.SetTypeFilling(DetectFillingMode(_Symbol));
   // ed.sl / ed.tp are the position's existing SL/TP, passed through UNCHANGED --
   // CRITICAL: on a netting account the SL/TP of an order against an open
   // position becomes the position's SL/TP. Anything else here would silently
   // move the stop of the WHOLE blended position.
   bool ok = (direction == 1) ? g_trade.Buy(ed.lots, _Symbol, 0.0, ed.sl, ed.tp, comment)
                              : g_trade.Sell(ed.lots, _Symbol, 0.0, ed.sl, ed.tp, comment);
   ENUM_X15_SEND_OUTCOME outcome = ClassifySendResult(ok, g_trade.ResultRetcode(), false, g_trade.ResultOrder(), g_trade.ResultDeal());
   RecordSetupStatus(addId, direction, SendOutcomeLabel(outcome), g_trade.ResultOrder());
   if(outcome == X15_SEND_FILLED)
     {
      g_positions[idx].riskMoney += ed.riskMoney;
      g_stateDirty = true;
      g_reconcileRequested = true;
      g_lastTradeTime = TimeCurrent();
      X15Log("EXECUTION", StringFormat("[LIVE] pyramid add %d FILLED: %.2f lots %s @ ~%s, risk %.2f", addNumber, ed.lots, DirLabel(direction),
                                       DoubleToString(g_trade.ResultPrice(), g_spec.digits), ed.riskMoney));
      return;
     }
   if(SendOutcomeMayHaveExecuted(outcome)) g_reconcileRequested = true;
   // never retried: the add key is consumed whatever the outcome
   X15Error("EXECUTION", StringFormat("pyramid add %d %s: %u %s", addNumber, SendOutcomeLabel(outcome), g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
  }

void ProcessPyramidOpportunities(void)
  {
   if(!AllowPyramiding) return;
   for(int i = ArraySize(g_positions) - 1; i >= 0; i--)
     {
      if(!g_positions[i].isOwn || g_positions[i].isPaper || g_positions[i].closed) continue;
      X15ExecDecision ed = CheckExecutionEligibility(g_decision, i);
      if(ed.state != X15_ELIGIBLE_LONG && ed.state != X15_ELIGIBLE_SHORT)
        {
         X15Log("RISK", StringFormat("pyramid: position %I64u not eligible -- %s: %s", g_positions[i].positionId, ed.blockingGate, ed.reason), false, true);
         continue;
        }
      SendPyramidAdd(i, ed);
     }
  }

//====================================================================
// LAYER 10 -- PERFORMANCE, EVIDENCE TIERS, MONTE CARLO  (spec 18, 22-24)
//--------------------------------------------------------------------
// Everything here is REPORT-ONLY. Nothing in this section feeds position
// size: adaptive sizing reads the journal only through the existing gated
// bonus functions, and neither the Monte Carlo nor the regime breakdown
// nor the tiers are wired into any risk path.
//====================================================================
#define X15_PERF_LEARNABLE 0
#define X15_PERF_TRAINING  1
#define X15_PERF_OOS       2
#define X15_PERF_LIVE      3
#define X15_PERF_PAPER     4
#define X15_PERF_LEGACY    5

struct X15Performance
  {
   int               trades;
   double            winRate;
   double            expectancyR;
   double            profitFactor;   // gross R won / gross R lost; -1 when nothing was lost
   double            maxDrawdownR;
   double            netProfit;
  };

X15Performance g_perfLearn;
X15Performance g_perfTraining;
X15Performance g_perfOOS;
X15Performance g_perfLive;
X15Performance g_perfPaper;
X15Performance g_perfLegacy;
string g_regimeReport = "";

bool PerfFilter(JournalEntry &e, int filter)
  {
   if(filter == X15_PERF_LEARNABLE) return(IsLearnable(e));
   if(filter == X15_PERF_TRAINING)  return(IsLearnable(e) && e.closeTime < InpOutOfSampleStart);
   if(filter == X15_PERF_OOS)       return(IsLearnable(e) && e.closeTime >= InpOutOfSampleStart);
   if(filter == X15_PERF_LIVE)      return(e.valid && (e.source == X15_SRC_LIVE || e.source == X15_SRC_TESTER));
   if(filter == X15_PERF_PAPER)     return(e.valid && e.source == X15_SRC_PAPER);
   if(filter == X15_PERF_LEGACY)    return(e.valid && e.source == X15_SRC_LEGACY);
   return(false);
  }

void ComputePerformance(X15Performance &perf, int filter)
  {
   perf.trades = 0; perf.winRate = 0.0; perf.expectancyR = 0.0; perf.profitFactor = -1.0; perf.maxDrawdownR = 0.0; perf.netProfit = 0.0;
   double sumR = 0.0, wonR = 0.0, lostR = 0.0, cum = 0.0, peak = 0.0;
   int wins = 0;
   for(int i = 0; i < ArraySize(g_journal); i++)
     {
      if(!PerfFilter(g_journal[i], filter)) continue;
      double r = g_journal[i].rMultiple;
      perf.trades++;
      sumR += r;
      perf.netProfit += g_journal[i].netProfit;
      if(r > 0.0) { wins++; wonR += r; }
      else lostR += -r;
      cum += r;
      if(cum > peak) peak = cum;
      if(peak - cum > perf.maxDrawdownR) perf.maxDrawdownR = peak - cum;
     }
   if(perf.trades == 0) return;
   perf.winRate = (double)wins / perf.trades;
   perf.expectancyR = sumR / perf.trades;
   perf.profitFactor = (lostR > 0.0) ? wonR / lostR : -1.0;
  }

// Report-only regime-conditional expectancy: tells a human whether the
// regime labels mean anything for THIS system -- it never changes risk.
string BuildRegimeReport(void)
  {
   string labels[8];
   for(int k = 0; k < 8; k++) labels[k] = EnumLabel(EnumToString((ENUM_X15_REGIME)k), "X15_REGIME_");
   string out = "";
   for(int k = 0; k < 8; k++)
     {
      int n = 0;
      double sum = 0.0;
      for(int i = 0; i < ArraySize(g_journal); i++)
         if(IsLearnable(g_journal[i]) && g_journal[i].regime == labels[k]) { n++; sum += g_journal[i].rMultiple; }
      if(n == 0) continue;
      out += StringFormat("%s%s n=%d %.2fR", out == "" ? "" : ", ", labels[k], n, sum / n);
     }
   return(out == "" ? "no learnable trades yet" : out);
  }

struct X15MonteCarlo
  {
   bool              available;
   string            reason;
   int               sample;
   double            retP5;
   double            retP50;
   double            retP95;
   double            ddP50;
   double            ddP95;
   double            ddWorst;
   double            streakP50;
   double            streakP95;
   int               streakWorst;
   double            probDD1;
   double            probDD2;
   double            probDD3;
   string            worstSequence;
  };
X15MonteCarlo g_mc;

double PercentileSorted(double &v[], double q)
  {
   int n = ArraySize(v);
   if(n == 0) return(0.0);
   int idx = (int)MathFloor(q * (n - 1));
   return(v[MathMax(0, MathMin(n - 1, idx))]);
  }

// Bootstrap resampling of this system's own learnable R-multiples, with a
// fixed seed so the same journal always yields the same report.
void RunMonteCarlo(X15MonteCarlo &mc)
  {
   mc.available = false; mc.reason = ""; mc.sample = 0;
   mc.retP5 = 0.0; mc.retP50 = 0.0; mc.retP95 = 0.0; mc.ddP50 = 0.0; mc.ddP95 = 0.0; mc.ddWorst = 0.0;
   mc.streakP50 = 0.0; mc.streakP95 = 0.0; mc.streakWorst = 0; mc.probDD1 = 0.0; mc.probDD2 = 0.0; mc.probDD3 = 0.0;
   mc.worstSequence = "";
   if(!InpMonteCarloEnabled) { mc.reason = "disabled"; return; }
   double r[];
   int n = 0;
   ArrayResize(r, ArraySize(g_journal));
   for(int i = 0; i < ArraySize(g_journal); i++)
      if(IsLearnable(g_journal[i])) { r[n] = g_journal[i].rMultiple; n++; }
   ArrayResize(r, n);
   mc.sample = n;
   if(n < MinTradesForStats || n == 0) { mc.reason = StringFormat("n=%d, need %d learnable trades", n, MinTradesForStats); return; }
   int sims = MathMax(100, InpMonteCarloSims);
   int len  = MathMax(10, InpMonteCarloTradesPerSim);
   double rets[], dds[], streaks[];
   ArrayResize(rets, sims); ArrayResize(dds, sims); ArrayResize(streaks, sims);
   double worstSeq[];
   ArrayResize(worstSeq, len);
   double seq[];
   ArrayResize(seq, len);
   int hit1 = 0, hit2 = 0, hit3 = 0;
   MathSrand(InpMonteCarloSeed);
   for(int s = 0; s < sims; s++)
     {
      double cum = 0.0, peak = 0.0, maxdd = 0.0;
      int streak = 0, maxStreak = 0;
      for(int t = 0; t < len; t++)
        {
         int pick = (int)((double)MathRand() / 32768.0 * n);
         if(pick >= n) pick = n - 1;
         double x = r[pick];
         seq[t] = x;
         cum += x;
         if(cum > peak) peak = cum;
         if(peak - cum > maxdd) maxdd = peak - cum;
         if(x < 0.0) { streak++; if(streak > maxStreak) maxStreak = streak; }
         else streak = 0;
        }
      rets[s] = cum; dds[s] = maxdd; streaks[s] = maxStreak;
      if(maxdd >= InpMonteCarloDDThreshold1R) hit1++;
      if(maxdd >= InpMonteCarloDDThreshold2R) hit2++;
      if(maxdd >= InpMonteCarloDDThreshold3R) hit3++;
      if(maxdd > mc.ddWorst) { mc.ddWorst = maxdd; ArrayCopy(worstSeq, seq); }
      if(maxStreak > mc.streakWorst) mc.streakWorst = maxStreak;
     }
   ArraySort(rets); ArraySort(dds); ArraySort(streaks);
   mc.retP5 = PercentileSorted(rets, 0.05);
   mc.retP50 = PercentileSorted(rets, 0.50);
   mc.retP95 = PercentileSorted(rets, 0.95);
   mc.ddP50 = PercentileSorted(dds, 0.50);
   mc.ddP95 = PercentileSorted(dds, 0.95);
   mc.streakP50 = PercentileSorted(streaks, 0.50);
   mc.streakP95 = PercentileSorted(streaks, 0.95);
   mc.probDD1 = (double)hit1 / sims;
   mc.probDD2 = (double)hit2 / sims;
   mc.probDD3 = (double)hit3 / sims;
   for(int t = 0; t < MathMin(12, len); t++) mc.worstSequence += StringFormat("%s%.1f", t == 0 ? "" : " ", worstSeq[t]);
   mc.available = true;
  }

ENUM_X15_KELLY_STATUS KellyStatus(RuinBoundResult &rb, StatsResult &s)
  {
   if(RuinBoundAlpha <= 0.0 || RuinBoundAlpha >= 1.0 || RuinBoundBeta <= 0.0 || RuinBoundBeta >= 1.0) return(X15_KELLY_INVALID_INPUT);
   if(s.sampleSize < MinTradesForStats || !rb.available) return(X15_KELLY_INSUFFICIENT_SAMPLE);
   if(rb.ruinCertain) return(X15_KELLY_RUIN_CONDITION);
   return(rb.boundSatisfied ? X15_KELLY_VALID : X15_KELLY_BOUND_FAILED);
  }

string g_kellyLine = "";

void UpdatePerformance(void)
  {
   ComputePerformance(g_perfLearn, X15_PERF_LEARNABLE);
   ComputePerformance(g_perfTraining, X15_PERF_TRAINING);
   ComputePerformance(g_perfOOS, X15_PERF_OOS);
   ComputePerformance(g_perfLive, X15_PERF_LIVE);
   ComputePerformance(g_perfPaper, X15_PERF_PAPER);
   ComputePerformance(g_perfLegacy, X15_PERF_LEGACY);
   g_regimeReport = BuildRegimeReport();
   RunMonteCarlo(g_mc);
   StatsResult overall = ComputeStats();
   RuinBoundResult rb = ComputeKellyRuinBound(overall, InpBaseRiskPercent);
   ENUM_X15_KELLY_STATUS ks = KellyStatus(rb, overall);
   g_kellyLine = EnumLabel(EnumToString(ks), "X15_KELLY_") + (rb.available && !rb.ruinCertain ? StringFormat(" (avg %.3f at %.2f%%)", rb.averageTerm, InpBaseRiskPercent) : "");
   g_perfDirty = false;
   X15Log("JOURNAL", StringFormat("performance refreshed: learnable n=%d, exp %.2fR, PF %.2f, maxDD %.1fR; Kelly %s; MC %s",
                                  g_perfLearn.trades, g_perfLearn.expectancyR, g_perfLearn.profitFactor, g_perfLearn.maxDrawdownR,
                                  g_kellyLine, g_mc.available ? StringFormat("DD95 %.1fR", g_mc.ddP95) : g_mc.reason), false, true);
  }

//====================================================================
// DASHBOARD  (spec 31)
//--------------------------------------------------------------------
// One OBJ_LABEL per line, two columns. Lines are wrapped at 60 characters
// (chart label text is short-limited), so a long NO TRADE reason is shown
// in full across lines rather than cut off. A leading '#' marks a section
// header, '!' an alert, '+' a positive state.
//====================================================================
#define X15_DASH_PREFIX "AX15D_"
#define X15_DASH_WIDTH  60

string   g_dashLeft[];
string   g_dashRight[];
int      g_dashRendered[2];
datetime g_lastDashUpdate = 0;
datetime g_lastLossRefresh = 0;
double   g_adaptivePreviewPct = 0.0; // refreshed once per bar: ComputeAdaptiveRisk re-reads VWAP history

void DashAdd(string &lines[], string text)
  {
   int n = ArraySize(lines);
   ArrayResize(lines, n + 1);
   lines[n] = text;
  }

// Wraps on spaces at X15_DASH_WIDTH; continuation lines keep the marker and indent.
void DashWrap(string &lines[], string text)
  {
   string marker = "";
   if(StringLen(text) > 0)
     {
      ushort c = StringGetCharacter(text, 0);
      if(c == '!' || c == '+' || c == '#') marker = StringSubstr(text, 0, 1);
     }
   string rest = text;
   while(StringLen(rest) > X15_DASH_WIDTH)
     {
      int cut = X15_DASH_WIDTH;
      bool atSpace = false;
      for(int i = X15_DASH_WIDTH; i > 20; i--) if(StringGetCharacter(rest, i) == ' ') { cut = i; atSpace = true; break; }
      DashAdd(lines, StringSubstr(rest, 0, cut));
      rest = marker + "   " + StringSubstr(rest, atSpace ? cut + 1 : cut);
     }
   DashAdd(lines, rest);
  }

void RenderDashColumn(string &lines[], int column, int x)
  {
   color cText = C'210,214,222', cHead = C'232,190,90', cAlert = C'235,95,95', cGood = C'95,200,125';
   int n = ArraySize(lines);
   for(int i = 0; i < n; i++)
     {
      string name = StringFormat("%s%d_%d", X15_DASH_PREFIX, column, i);
      if(ObjectFind(0, name) < 0)
        {
         ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
         ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 26 + i * 13);
         ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
         ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
        }
      string t = lines[i];
      color c = cText;
      if(StringLen(t) > 0)
        {
         ushort m = StringGetCharacter(t, 0);
         if(m == '#') { c = cHead; t = StringSubstr(t, 1); }
         else if(m == '!') { c = cAlert; t = StringSubstr(t, 1); }
         else if(m == '+') { c = cGood; t = StringSubstr(t, 1); }
        }
      ObjectSetString(0, name, OBJPROP_TEXT, t == "" ? " " : t);
      ObjectSetInteger(0, name, OBJPROP_COLOR, c);
     }
   for(int i = n; i < g_dashRendered[column]; i++) ObjectDelete(0, StringFormat("%s%d_%d", X15_DASH_PREFIX, column, i));
   g_dashRendered[column] = n;
  }

void RenderDashBackground(int rows)
  {
   string name = X15_DASH_PREFIX + "bg";
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 4);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 20);
      ObjectSetInteger(0, name, OBJPROP_BGCOLOR, C'16,18,24');
      ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, name, OBJPROP_COLOR, C'60,64,72');
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
     }
   ObjectSetInteger(0, name, OBJPROP_XSIZE, 790);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, 14 + rows * 13);
  }

void DeleteDashboard(void)
  {
   ObjectsDeleteAll(0, X15_DASH_PREFIX);
   g_dashRendered[0] = 0;
   g_dashRendered[1] = 0;
  }

string Px(double v)
  {
   return(v > 0.0 ? DoubleToString(v, g_spec.digits) : "-");
  }

string ExecStateLabel(ENUM_X15_ELIGIBILITY s)
  {
   if(s == X15_ELIGIBLE_LONG)  return("ELIGIBLE LONG");
   if(s == X15_ELIGIBLE_SHORT) return("ELIGIBLE SHORT");
   if(s == X15_BLOCKED)        return("BLOCKED");
   if(s == X15_ELIG_DATA_UNAVAILABLE) return("DATA UNAVAILABLE");
   if(s == X15_ELIG_INSUFFICIENT_EVIDENCE) return("INSUFFICIENT EVIDENCE");
   return("NO TRADE");
  }

void BuildDashboard(void)
  {
   ArrayResize(g_dashLeft, 0);
   ArrayResize(g_dashRight, 0);
   string mode = EnumLabel(EnumToString(InpExecutionMode), "X15_");
   double equity = AccountInfoDouble(ACCOUNT_EQUITY), balance = AccountInfoDouble(ACCOUNT_BALANCE);
   X15Exposure ex;
   ComputeExposure(ex);

   // ---------------- left column ----------------
   DashAdd(g_dashLeft, "#AUTOPSY X FLIPDEMON X15  [" + mode + "]" + (InpEmergencyStop ? "  EMERGENCY STOP" : ""));
   DashAdd(g_dashLeft, "#ACCOUNT");
   DashAdd(g_dashLeft, StringFormat("Equity %.2f  Balance %.2f", equity, balance));
   if(g_loss.available)
     {
      DashAdd(g_dashLeft, StringFormat("%sDaily P/L %.2f (loss %.2f%% / %.2f%%)", g_loss.dailyLossPct >= InpMaxDailyLossPct ? "!" : "", g_loss.dailyPnL, g_loss.dailyLossPct, InpMaxDailyLossPct));
      DashAdd(g_dashLeft, StringFormat("%sWeekly P/L %.2f (loss %.2f%% / %.2f%%)", g_loss.weeklyLossPct >= InpMaxWeeklyLossPct ? "!" : "", g_loss.weeklyPnL, g_loss.weeklyLossPct, InpMaxWeeklyLossPct));
     }
   else DashAdd(g_dashLeft, "!Daily/Weekly P/L unavailable: " + g_loss.detail);
   DashAdd(g_dashLeft, StringFormat("Current risk %.2f%%  Open risk %.2f (%.2f%%)", g_exec.riskPct, ex.openRiskMoney, equity > 0.0 ? ex.openRiskMoney / equity * 100.0 : 0.0));

   DashAdd(g_dashLeft, "#MARKET");
   double sp = CurrentSpreadPoints(), avgSp = RecentAverageSpreadPoints();
   DashAdd(g_dashLeft, StringFormat("%s  exec %s  session %s", _Symbol, EnumLabel(EnumToString(InpExecTF), "PERIOD_"), EnumLabel(EnumToString(g_session), "X15_SESSION_")));
   DashAdd(g_dashLeft, "Regime " + EnumLabel(EnumToString(g_regime.regime), "X15_REGIME_"));
   DashWrap(g_dashLeft, "Volatility " + (g_regime.available ? g_regime.detail : "unavailable"));
   DashAdd(g_dashLeft, StringFormat("Spread %.0f pts (recent avg %s)", sp, avgSp > 0.0 ? DoubleToString(avgSp, 1) : "n/a"));

   DashAdd(g_dashLeft, "#BIAS");
   DashWrap(g_dashLeft, "HTF " + g_htfBias.state + " -- " + g_htfBias.detail);
   DashWrap(g_dashLeft, StringFormat("Exec %s, last %s @ %s", g_structExec.trendLabel, EnumLabel(EnumToString(g_structExec.lastEvent), "X15_EVT_"), Px(g_structExec.lastEventLevel)));
   DashAdd(g_dashLeft, StringFormat("Draw: up %s %s / down %s %s", g_liq.drawLongName, Px(g_liq.drawLongPrice), g_liq.drawShortName, Px(g_liq.drawShortPrice)));
   DashAdd(g_dashLeft, StringFormat("Dealing %s-%s  EQ %s", Px(g_liq.dealingLow), Px(g_liq.dealingHigh), Px(g_liq.equilibrium)));
   DashAdd(g_dashLeft, StringFormat("PDH %s PDL %s PWH %s PWL %s", Px(g_liq.pdh), Px(g_liq.pdl), Px(g_liq.pwh), Px(g_liq.pwl)));

   DashAdd(g_dashLeft, "#SIGNALS");
   DashAdd(g_dashLeft, "VWAP " + g_decision.vwapState + "  VP-MACD " + g_decision.vpmacdState);
   DashWrap(g_dashLeft, (g_newsGate.blocks ? "!" : "") + "News Defense " + g_newsGate.state + (g_newsGate.detail != "" ? ": " + g_newsGate.detail : ""));

   DashAdd(g_dashLeft, "#SETUP (pre-validation)");
   X15Setup s = g_decision.setup;
   if(s.type == X15_SETUP_NONE) DashAdd(g_dashLeft, "none on the last closed bar");
   else
     {
      DashAdd(g_dashLeft, StringFormat("%s %s  id %s", EnumLabel(EnumToString(s.type), "X15_SETUP_"), DirLabel(s.direction), s.setupId));
      DashAdd(g_dashLeft, StringFormat("Entry %s  SL %s  TP %s", Px(g_exec.entryPrice > 0.0 ? g_exec.entryPrice : s.entryRef), Px(s.sl), Px(s.tp)));
      DashAdd(g_dashLeft, StringFormat("R:R %.2f to %s  zone %s", s.rr, s.tpLevelName, s.zoneType));
      string ev = StringFormat("Evidence %d/%d:", g_decision.evidenceScore, g_decision.evidenceMax);
      for(int i = 0; i < g_decision.componentCount; i++)
        {
         if(g_decision.comps[i].hard) continue;
         string mark = (g_decision.comps[i].status == X15_PASS) ? "+" : ((g_decision.comps[i].status == X15_FAIL) ? "-" : "?");
         if(g_decision.comps[i].status == X15_NA) continue;
         ev += " " + g_decision.comps[i].name + mark;
        }
      DashWrap(g_dashLeft, ev);
     }

   // ---------------- right column ----------------
   // authoritative state first: the eligibility result, never the raw signal
   DashAdd(g_dashRight, "#DECISION" + (g_exec.barTime > 0 ? " (bar " + TimeToString(g_exec.barTime, TIME_MINUTES) + ")" : ""));
   bool eligible = (g_exec.state == X15_ELIGIBLE_LONG || g_exec.state == X15_ELIGIBLE_SHORT);
   string modeNote = (eligible && InpExecutionMode == X15_ANALYSIS_ONLY) ? "  [analysis only: not sent]" : "";
   DashAdd(g_dashRight, (eligible ? "+" : (g_exec.state == X15_BLOCKED ? "!" : "")) + ExecStateLabel(g_exec.state) + modeNote);
   if(!eligible && g_exec.computed) DashWrap(g_dashRight, (g_exec.state == X15_BLOCKED ? "!" : "") + "Why: " + g_exec.blockingGate + " -- " + g_exec.reason);
   // conditions that change mid-bar are shown live, so a stale ELIGIBLE can never mislead
   string lockNow = "";
   if(InpEmergencyStop) lockNow = "emergency stop";
   else if(g_loss.available && g_loss.dailyLossPct >= InpMaxDailyLossPct) lockNow = "daily loss limit";
   else if(g_loss.available && g_loss.weeklyLossPct >= InpMaxWeeklyLossPct) lockNow = "weekly loss limit";
   if(lockNow != "") DashAdd(g_dashRight, "!Entries locked NOW: " + lockNow);
   DashWrap(g_dashRight, "Signal before validation: " + EnumLabel(EnumToString(g_decision.state), "X15_DIR_") + " -- " + g_decision.stateReason);
   if(g_decision.state == X15_DIR_NEUTRAL)
     {
      DashWrap(g_dashRight, "long: " + g_decision.longReject);
      DashWrap(g_dashRight, "short: " + g_decision.shortReject);
     }
   if(g_exec.executionResult != "") DashWrap(g_dashRight, "Last action: " + g_exec.executionResult);

   DashAdd(g_dashRight, "#RISK");
   double adaptive = (InpBaseRiskPercent > 0.0) ? g_adaptivePreviewPct / InpBaseRiskPercent : 0.0;
   DashAdd(g_dashRight, StringFormat("Base %.2f%%  adaptive x%.2f  hard cap %.2f%%", InpBaseRiskPercent, adaptive, InpMaxRiskPct));
   if(eligible) DashWrap(g_dashRight, StringFormat("Final %.3f%%  %.2f lots  money at risk %.2f", g_exec.riskPct, g_exec.lots, g_exec.riskMoney));
   DashAdd(g_dashRight, StringFormat("Exposure %d/%d total, %d/%d symbol, open risk cap %.1f%%", ex.total, InpMaxPositionsTotal, ex.symbolTotal, InpMaxPositionsPerSymbol, InpMaxTotalOpenRiskPct));

   DashAdd(g_dashRight, "#POSITION");
   int own = 0;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID), ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   for(int i = 0; i < ArraySize(g_positions); i++)
     {
      if(!g_positions[i].isOwn || g_positions[i].closed) continue;
      own++;
      if(g_positions[i].isPendingOrder)
        {
         DashAdd(g_dashRight, StringFormat("%s stop-entry %s @ %s (paper)", DirLabel(g_positions[i].direction), g_positions[i].setupId, Px(g_positions[i].pendingPrice)));
         continue;
        }
      double risk = MathAbs(g_positions[i].entryPrice - g_positions[i].originalSL);
      double px = (g_positions[i].direction == 1) ? bid : ask;
      double rNow = (risk > 0.0) ? (px - g_positions[i].entryPrice) * g_positions[i].direction / risk : 0.0;
      string slState = g_positions[i].beDone ? "BE/locked" : "original";
      DashAdd(g_dashRight, StringFormat("%s%s %.2f lots  %+.2fR%s", rNow >= 0.0 ? "+" : "!", DirLabel(g_positions[i].direction), g_positions[i].volume, rNow, g_positions[i].isPaper ? " (paper)" : ""));
      DashAdd(g_dashRight, StringFormat("  SL %s (%s)  TP %s", Px(g_positions[i].currentSL), slState, Px(g_positions[i].currentTP)));
      DashAdd(g_dashRight, StringFormat("  trail %s, partial %s", EnumLabel(EnumToString(InpTrailMode), "X15_TRAIL_"), g_positions[i].partialDone ? "taken" : "pending"));
     }
   if(own == 0) DashAdd(g_dashRight, "no open positions");

   DashAdd(g_dashRight, "#JOURNAL");
   DashAdd(g_dashRight, StringFormat("Learnable n=%d  win %.1f%%  exp %.2fR", g_perfLearn.trades, g_perfLearn.winRate * 100.0, g_perfLearn.expectancyR));
   DashAdd(g_dashRight, StringFormat("PF %s  avg R %.2f  max DD %.1fR", g_perfLearn.profitFactor < 0.0 ? "n/a" : DoubleToString(g_perfLearn.profitFactor, 2), g_perfLearn.expectancyR, g_perfLearn.maxDrawdownR));
   DashAdd(g_dashRight, StringFormat("Tiers: train %d  OOS %d  live %d  paper %d  legacy %d", g_perfTraining.trades, g_perfOOS.trades, g_perfLive.trades, g_perfPaper.trades, g_perfLegacy.trades));
   DashWrap(g_dashRight, "Kelly bound: " + g_kellyLine);
   if(g_mc.available)
      DashWrap(g_dashRight, StringFormat("Monte Carlo: DD50 %.1fR DD95 %.1fR, P(DD>=%.0fR) %.0f%%, streak95 %.0f", g_mc.ddP50, g_mc.ddP95, InpMonteCarloDDThreshold2R, g_mc.probDD2 * 100.0, g_mc.streakP95));
   else DashWrap(g_dashRight, "Monte Carlo: " + g_mc.reason);

   DashAdd(g_dashRight, "#SYSTEM");
   DashAdd(g_dashRight, "State " + EnumLabel(EnumToString(g_state), "X15_ST_"));
   DashWrap(g_dashRight, (g_dq.ok ? "+Data OK" : "!Data: " + g_dq.reason));
   DashAdd(g_dashRight, "Last analysis " + (g_lastAnalysisTime > 0 ? TimeToString(g_lastAnalysisTime, TIME_DATE|TIME_MINUTES) : "-")
                      + "  last trade " + (g_lastTradeTime > 0 ? TimeToString(g_lastTradeTime, TIME_DATE|TIME_MINUTES) : "-"));
   if(g_lastError != "") DashWrap(g_dashRight, "!Last error " + TimeToString(g_lastErrorTime, TIME_MINUTES) + " " + g_lastError);
  }

void UpdateDashboard(bool force)
  {
   if(!InpShowDashboard) return;
   if(IsTester() && !MQLInfoInteger(MQL_VISUAL_MODE)) return;
   datetime now = TimeCurrent();
   if(!force && now - g_lastDashUpdate < 1) return;
   g_lastDashUpdate = now;
   if(now - g_lastLossRefresh >= 5) { ComputeLossMetrics(g_loss); g_lastLossRefresh = now; }
   if(force || g_adaptivePreviewPct <= 0.0)
      g_adaptivePreviewPct = ComputeAdaptiveRisk(_Symbol, g_decision.setup.direction != 0 ? g_decision.setup.direction : 1, false);
   BuildDashboard();
   RenderDashBackground(MathMax(ArraySize(g_dashLeft), ArraySize(g_dashRight)));
   RenderDashColumn(g_dashLeft, 0, 12);
   RenderDashColumn(g_dashRight, 1, 402);
   ChartRedraw(0);
  }

//====================================================================
// LIFECYCLE  (spec 28, 29, 37)
//--------------------------------------------------------------------
// OnTick: cheap execution-sensitive work every tick (reconcile, SL/TP and
// R-based management); the full market analysis, entry validation and
// pyramiding only once per new closed execution bar. OnTradeTransaction
// wakes reconciliation immediately; OnTimer keeps it running when no
// ticks arrive.
//====================================================================
datetime g_lastBarTime = 0;

bool IsNewBar(void)
  {
   datetime t = iTime(_Symbol, InpExecTF, 0); // execution TF, not the chart's: a chart TF change must not re-trigger or skip a decision
   if(t == 0) return(false);                  // history not loaded yet -- not a new bar
   if(t != g_lastBarTime)
     {
      g_lastBarTime = t;
      return(true);
     }
   return(false);
  }

// Same broker-capability probe as the sibling EA's ExecutionEngine.mqh:
// FOK preferred, IOC next, RETURN as the universal fallback.
ENUM_ORDER_TYPE_FILLING DetectFillingMode(const string symbol)
  {
   int filling = (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) != 0) return(ORDER_FILLING_FOK);
   if((filling & SYMBOL_FILLING_IOC) != 0) return(ORDER_FILLING_IOC);
   return(ORDER_FILLING_RETURN);
  }

bool ValidateInputs(string &why)
  {
   why = "";
   if(InpMagicNumber == 0) why = "InpMagicNumber must be non-zero (0 is what manual trades carry)";
   else if(InpExecTF == PERIOD_CURRENT) why = "InpExecTF must be an explicit timeframe, not PERIOD_CURRENT";
   else if(InpBaseRiskPercent <= 0.0 || InpMaxRiskPct <= 0.0) why = "risk percentages must be positive";
   else if(InpMinRR <= 0.0) why = "InpMinRR must be positive";
   else if(InpMaxDailyLossPct <= 0.0 || InpMaxWeeklyLossPct <= 0.0) why = "loss limits must be positive";
   else if(InpMaxPositionsTotal < 1 || InpMaxPositionsPerSymbol < 1 || InpMaxPositionsPerDirection < 1) why = "position limits must be at least 1";
   else if(InpPartialClosePercent <= 0.0 || InpPartialClosePercent >= 100.0) why = "InpPartialClosePercent must be between 0 and 100";
   else if(InpAsiaStartHour < 0 || InpAsiaStartHour > 23 || InpAsiaEndHour < 0 || InpAsiaEndHour > 23
           || InpLondonStartHour < 0 || InpLondonStartHour > 23 || InpLondonEndHour < 0 || InpLondonEndHour > 23
           || InpNewYorkStartHour < 0 || InpNewYorkStartHour > 23 || InpNewYorkEndHour < 0 || InpNewYorkEndHour > 23)
      why = "session hours must be 0-23";
   return(why == "");
  }

int OnInit(void)
  {
   g_state = X15_ST_INITIALIZING;
   g_runStartTime = TimeCurrent();
   string why;
   if(!ValidateInputs(why))
     {
      PrintFormat("[AX15][ERROR] invalid inputs: %s", why);
      return(INIT_PARAMETERS_INCORRECT);
     }
   g_atrExec = INVALID_HANDLE;
   for(int i = 0; i < 3; i++) g_atrHTF[i] = INVALID_HANDLE;
   if(!RefreshSymbolSpec(g_spec)) X15Log("DATA", "symbol properties not available yet: " + g_spec.reason);
   if(!CreateIndicatorHandles())
      X15Error("DATA", "could not create every ATR handle -- affected analysis will report DATA_UNAVAILABLE");
   ResetStructure(g_structExec, InpExecTF);
   ResetStructure(g_structHTF[0], InpHTF1);
   ResetStructure(g_structHTF[1], InpHTF2);
   ResetStructure(g_structHTF[2], InpHTF3);
   ResetStructure(g_structW1, PERIOD_W1);
   ResetDecision(g_decision);
   ResetExecDecision(g_exec);
   g_execGot = 0;
   g_lastBarTime = 0;
   g_lastError = "";
   g_dashRendered[0] = 0;
   g_dashRendered[1] = 0;

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpMaxSlippagePoints);
   g_trade.SetTypeFilling(DetectFillingMode(_Symbol));
   g_trade.SetAsyncMode(false); // always wait for the server's answer -- never fire-and-forget a real order

   // restart recovery (spec 37): journal -> setup store -> managed positions
   // -> setup IDs from the broker's own records -> reconcile against live positions
   LoadJournalFromFile();
   LoadSetupStore();
   LoadPositionState();
   RebuildSetupStoreFromBroker();
   g_firstSyncDone = false;
   ReconcilePositions();
   PruneEntryContexts();
   g_perfDirty = true;
   UpdatePerformance();
   ComputeLossMetrics(g_loss);
   EventSetTimer(1);

   string mode = EnumLabel(EnumToString(InpExecutionMode), "X15_");
   X15Log("INIT", StringFormat("%s on %s, exec %s, magic %I64u, journal %d rows, %d tracked position(s)",
                               mode, _Symbol, EnumLabel(EnumToString(InpExecTF), "PERIOD_"), InpMagicNumber, ArraySize(g_journal), ArraySize(g_positions)));
   if(InpExecutionMode == X15_LIVE_EXECUTION && !IsTester())
      X15Log("INIT", "LIVE EXECUTION IS ARMED -- this EA will send real orders when every gate passes. It has not been compiled or tested by its author.", true);
   g_state = X15_ST_WAIT;
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   SavePositionState();
   ReleaseIndicatorHandles();
   DeleteDashboard();
   Comment("");
  }

void OnTick(void)
  {
   SampleSpread();
   ReconcilePositions();
   bool newBar = IsNewBar();
   if(newBar) RunMarketAnalysis();
   ManagePositions(newBar);
   if(InpExecutionMode == X15_LIVE_EXECUTION) ManagePendingOrders(); // every tick: an invalidated stop-entry must die before it can trigger
   if(newBar)
     {
      ProcessEntryOpportunity();
      ProcessPyramidOpportunities();
      if(g_perfDirty)
        {
         ENUM_X15_STATE keep = g_state;
         g_state = X15_ST_LEARNING;
         UpdatePerformance();
         g_state = keep;
        }
      PruneEntryContexts();
     }
   if(g_stateDirty) SavePositionState();
   UpdateDashboard(newBar);
  }

void OnTimer(void)
  {
   SampleSpread();
   ReconcilePositions();
   if(g_perfDirty) UpdatePerformance();
   UpdateDashboard(false);
  }

// Lifecycle events arrive here first; the actual state change is always
// applied by the idempotent ReconcilePositions(), so a repeated or
// out-of-order transaction can never double-journal or double-register.
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.symbol != "" && trans.symbol != _Symbol) return;
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
     {
      g_reconcileRequested = true;
      if(HistoryDealSelect(trans.deal))
        {
         long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
         string kind = (entry == DEAL_ENTRY_IN) ? "IN (open/add)" : ((entry == DEAL_ENTRY_OUT) ? "OUT (close/partial)" : "OUT_BY/INOUT");
         X15Log("POSITION", StringFormat("deal #%I64u %s %.2f @ %s, position %I64u", trans.deal, kind, trans.volume,
                                         DoubleToString(trans.price, g_spec.digits), trans.position), false, true);
        }
     }
   else if(trans.type == TRADE_TRANSACTION_REQUEST)
     {
      if(request.magic == InpMagicNumber && !RetcodeSucceeded(result.retcode))
         X15Error("EXECUTION", StringFormat("server answered %u %s to '%s'", result.retcode, result.comment, request.comment));
     }
   else if(trans.type == TRADE_TRANSACTION_POSITION || trans.type == TRADE_TRANSACTION_ORDER_DELETE
           || trans.type == TRADE_TRANSACTION_HISTORY_ADD)
      g_reconcileRequested = true;
   if(g_reconcileRequested) ReconcilePositions();
  }
//+------------------------------------------------------------------+
