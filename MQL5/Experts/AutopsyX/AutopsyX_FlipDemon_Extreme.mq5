//+------------------------------------------------------------------+
//|                                  FlipDemon_Extreme_HFT.mq5        |
//|                         FLIPDEMON EXTREME HFT                     |
//|        Ultra-aggressive MT5 HFT flipping & scalping engine        |
//|                                                                    |
//|  SCAN -> SCORE -> ATTACK -> MANAGE -> FLIP -> EXIT -> REASSESS     |
//|                                                                    |
//|  No martingale. No averaging down. No unlimited risk, ever.       |
//|  This EA does not promise profitability - see README.md for the   |
//|  required multi-phase validation workflow before risking capital. |
//+------------------------------------------------------------------+
#property copyright "FlipDemon Extreme HFT"
#property link      ""
#property version   "1.00"
#property strict

#include <AutopsyX/Defs.mqh>
#include <AutopsyX/MarketData.mqh>
#include <AutopsyX/Momentum.mqh>
#include <AutopsyX/Microstructure.mqh>
#include <AutopsyX/Liquidity.mqh>
#include <AutopsyX/Regime.mqh>
#include <AutopsyX/SignalScore.mqh>
#include <AutopsyX/FlipEngine.mqh>
#include <AutopsyX/AntiChop.mqh>
#include <AutopsyX/RiskEngine.mqh>
#include <AutopsyX/AccountCampaignCoordinator.mqh>
#include <AutopsyX/EntryEngine.mqh>
#include <AutopsyX/ExecutionEngine.mqh>
#include <AutopsyX/ExitEngine.mqh>
#include <AutopsyX/SniperEngine.mqh>
#include <AutopsyX/OrderFlow.mqh>
#include <AutopsyX/VolumeProfile.mqh>
#include <AutopsyX/Footprint.mqh>
#include <AutopsyX/Pulse.mqh>
#include <AutopsyX/Heatmap.mqh>
#include <AutopsyX/TradeAutopsy.mqh>
#include <AutopsyX/Statistics.mqh>
#include <AutopsyX/AdaptiveFlipEngine.mqh>
#include <AutopsyX/VWAPEngine.mqh>
#include <AutopsyX/EmergencyControls.mqh>
#include <AutopsyX/TradeReconciliation.mqh>
#include <AutopsyX/RestartRecovery.mqh>
#include <AutopsyX/Dashboard.mqh>

//====================================================================
// INPUTS
//====================================================================
input group "=== MODE ===";
input ENUM_AX_MODE   InpMode                    = AX_MODE_AGGRESSIVE; // Aggression mode
input double         InpExtremeRiskPercent      = 2.0;                // EXTREME mode risk % per trade (hard-capped at 2.0)

input group "=== SNIPER ENTRY (PRECISION TIMING) ===";
input bool            InpUseSniperEntry           = true; // Wait for a precise pullback-then-resume before entering, instead of firing immediately
input double          InpSniperPullbackPoints     = 15;   // Pullback required from the local extreme to arm the resume-watch, points
input double          InpSniperResumePoints       = 8;    // Resumption required from the pullback point to actually trigger entry, points
input int             InpSniperMaxWaitSeconds     = 8;     // Give up waiting for the retest after this long, seconds
input double          InpSniperMaxChasePoints     = 40;    // Abandon if price runs this far in our favor without ever pulling back
input bool            InpSniperUseStructureStop   = true;  // Prefer a stop just beyond the nearest liquidity level when it's tighter than ATR/fixed
input double          InpSniperStructureBufferPts = 10;    // Buffer placed beyond the structural level, points

input group "=== ORDER FLOW / VOLUME PROFILE / FOOTPRINT / HEATMAP / PULSE ===";
input bool            InpUseOrderFlow             = true;  // Blend order-flow/footprint/volume-profile into the score (advisory, not a hard gate)
input double          InpOrderFlowScoreWeight     = 15.0;  // Max points each of order flow / footprint / volume profile can add to a side's score
input int             InpVolumeProfileBars        = 120;   // Rolling lookback for the volume profile, bars
input double          InpVolumeProfileBinPoints   = 5.0;    // Volume profile bin width, points
input double          InpFootprintBinPoints       = 3.0;    // Footprint level width, points (finer than the volume profile)
input double          InpFootprintImbalanceRatio  = 0.70;   // Buy-or-sell share at a level that counts as "imbalanced"
input int             InpFootprintStackedLevels   = 3;      // Consecutive imbalanced levels required to call it "stacked"
input ENUM_TIMEFRAMES InpFootprintTimeframe       = PERIOD_M1; // Bar clock the footprint grid snapshots on
input bool            InpUseHeatmap               = true;   // Attempt to subscribe to broker market depth (silently unavailable if the broker doesn't provide it)
input double          InpHeatmapRangePoints       = 50.0;   // How far from the touch price DOM levels are considered, points
input bool            InpUseImpactCostSizing      = true;   // Cap position size to what the order book can actually absorb within budget (needs broker depth - no-op otherwise)
input double          InpMaxImpactCostPct         = 0.15;   // Max acceptable order-book impact cost for the full position size, %

input group "=== ADAPTIVE FLIP ENGINE (CAPITAL PROTECTION) ===";
input bool            InpUseAdaptiveFlipEngine    = true;   // Enable the AFE capital-protection layer (applies to fresh entries AND flips)
input double          InpAfeCautionDdPct          = 8.0;    // Peak-equity drawdown % that enters CAUTION (risk scaled down)
input double          InpAfeDefensiveDdPct        = 15.0;   // Peak-equity drawdown % that enters DEFENSIVE (risk scaled down further)
input double          InpAfeLockedDdPct           = 25.0;   // Peak-equity drawdown % that enters LOCKED (new entries hard-blocked)
input double          InpAfeCautionMultiplier     = 0.65;   // Risk multiplier applied in CAUTION
input double          InpAfeDefensiveMultiplier   = 0.30;   // Risk multiplier applied in DEFENSIVE
input double          InpAfeMaxRiskOfRuinPct      = 5.0;    // Block entries once estimated risk of ruin exceeds this, %
input double          InpAfeRuinThresholdPct      = 50.0;   // The peak-equity drawdown % that "ruin" means for that estimate
input double          InpAfeMinExpectedValueR     = 0.0;    // Block entries whose expected value, in R-multiples, is below this
input double          InpAfeMinAccountHealth      = 25.0;   // Block entries when the blended 0-100 account-health score is below this
input int             InpAfeMinTradesForStats     = 20;     // Trades required before trailing stats blend into the probability/EV estimate
input double          InpAfeAssumedRewardRisk     = 1.5;    // Cold-start reward:risk assumption before enough trade history exists
input double          InpCommissionPerLot         = 0.0;    // Broker's real commission per lot, round trip, account currency - get this from your broker, never guessed
input double          InpSlippageToleranceBufferPts = 0.0;  // Worst-case slippage buffer folded into the EV cost estimate, points
input double          InpImpactCoefficientK       = 1.0;    // Square-root price-impact model coefficient (Bouchaud et al.) - only used above InpImpactRelevanceThresholdLots
input double          InpImpactRelevanceThresholdLots = 50.0; // Institutional-scale size threshold before price impact is even computed - this EA's own sizing is never expected to reach it

input group "=== VWAP TREND ENGINE (Zarattini & Aziz, SSRN 4631351, 2023) ===";
input ENUM_AX_VWAP_MODE InpVWAPMode          = AX_VWAP_ROLLING; // Rolling trailing window, or anchored to the most recent FX session open
input int             InpVWAPRollingBars     = 240;    // Rolling VWAP window, bars (240 = 4 hours on M1 - adjust proportionally on other timeframes)
input int             InpVWAPSydneyHour      = 22;     // Sydney session open, broker SERVER time hour (0-23) - verify against your broker, not a universal clock
input int             InpVWAPTokyoHour       = 0;      // Tokyo session open, broker server time hour
input int             InpVWAPLondonHour      = 8;      // London session open, broker server time hour
input int             InpVWAPNewYorkHour     = 13;      // New York session open, broker server time hour
input double          InpVWAPDeadbandATRMult = 0.1;    // Deadband around VWAP, as a multiple of ATR, before a trend read is BULLISH/BEARISH rather than NEUTRAL
input bool            InpUseVWAPExit         = false;  // Opt-in mechanical exit: close if a bar closes on the wrong side of VWAP from the position's direction - see InpVWAPExitMode for exactly when it fires
input ENUM_AX_VWAP_EXIT_MODE InpVWAPExitMode  = AX_VWAP_EXIT_CONFIRMED_CROSS; // Only relevant when InpUseVWAPExit is on. CONFIRMED_CROSS is the original/default behavior (closed-bar confirmation) - see ExitEngine.mqh for all four modes
input double          InpVWAPAlignmentBonus  = 1.15;   // Sizing bonus applied ONLY when InpUseVWAPExit is on and this signal agrees with VWAP trend - see AdaptiveFlipEngine.mqh for how this is bounded

input group "=== RISK ENGINE ===";
input double         InpDailyLossLimitPercent   = 8.0;    // Daily loss limit (%) - stops session when hit
input int            InpMaxConsecutiveLosses    = 5;      // Max consecutive losses before pausing
input int            InpMaxOpenPositions        = 1;      // Max simultaneously open positions
input double         InpMaxExposureLots         = 1.0;    // Max total exposure, lots
input double         InpMaxCampaignRiskPercent  = 2.0;    // Campaign remaining stop-risk ceiling, % equity
input double         InpMaxAccountOpenRiskPercent= 4.0;    // All-account remaining stop-risk ceiling, % equity
input int            InpMaxFlipsPerDay          = 20;      // Max direction flips per day
input int            InpMaxTradesPerRollingPeriod = 10;    // Max trades within rolling window
input int            InpRollingPeriodSeconds    = 300;     // Rolling window length, seconds
input double         InpMaxSpreadPoints         = 250;     // Max acceptable spread, points
input double         InpMaxSlippagePoints       = 30;      // Max acceptable slippage, points
input double         InpMinFreeMarginPercent    = 150.0;   // Min margin level %, refuse new entries below this
input double         InpWeeklyLossLimitPercent  = 15.0;    // Weekly loss limit (%), Monday-anchored - stops the week when hit
input int            InpMaxPositionsPerSymbol   = 1;       // Max simultaneously open positions on this symbol specifically
input double         InpMaxDirectionalExposureLots = 1.0;  // Max exposure lots in one direction (BUY or SELL) at once
input double         InpMaxMarginUsagePercent   = 50.0;     // Max ACCOUNT_MARGIN / ACCOUNT_EQUITY, as a percent
input int            InpMaxExecutionFailures    = 5;        // Max consecutive order-send failures before blocking new entries

input group "=== EXECUTION MODE & EMERGENCY CONTROLS ===";
input ENUM_AX_EXECUTION_MODE InpExecutionMode = AX_EXEC_ANALYSIS_ONLY; // ANALYSIS_ONLY sends no orders at all - see EmergencyControls.mqh
input bool           InpEnableTrading           = true;    // Master trading switch - false blocks ALL new entries (existing positions still managed)
input bool           InpEnableLong              = true;    // false blocks new BUY entries specifically
input bool           InpEnableShort             = true;    // false blocks new SELL entries specifically

input group "=== SIGNAL SCORE ===";
input double         InpMinScoreToAct           = 60.0;    // Min BUY/SELL score required to act
input double         InpMinGapToAct             = 15.0;    // Min BUY-SELL gap required to act

input group "=== ENTRY ===";
input double         InpMinConfidenceToEnter    = 65.0;    // Min confidence % to open a new position

input group "=== FLIPDEMON REVERSAL ===";
input int            InpFlipRequiredConfirmations = 3;     // Consecutive confirming ticks required to flip
input double         InpFlipMinConfidence       = 70.0;    // Min confidence % required to confirm a flip

input group "=== ANTI-CHOP ===";
input int            InpAntiChopBaseCooldownSec = 20;      // Base cooldown after a chop-triggering event
input int            InpAntiChopMaxCooldownSec  = 1800;    // Max cooldown ceiling, seconds

input group "=== EXIT / PROFIT MANAGEMENT ===";
input double         InpEmergencySlPoints       = 300;     // Emergency stop-loss distance, points
input double         InpDynamicTpRR             = 1.6;     // Take-profit as multiple of SL distance
input double         InpBreakEvenTriggerPoints  = 150;     // Favorable move required to arm break-even
input double         InpBreakEvenLockPoints     = 20;      // Points locked in beyond entry at break-even
input double         InpTrailStartPoints        = 220;     // Favorable move required to start trailing
input double         InpTrailDistancePoints     = 120;     // Trailing distance, points
input int            InpMaxHoldSeconds          = 900;     // Max holding time, seconds
input double         InpMaxHoldExtensionMultiplier = 2.0;  // Let a still-profitable, still-trending position run up to this multiple of InpMaxHoldSeconds before the unconditional cutoff (1.0 = exact old behavior)
input double         InpSpreadAbnormalMultiplier= 2.2;     // Spread-abnormal exit multiplier vs average
input double         InpOpposingExitConfidence  = 55.0;    // Confidence required for a defensive opposite-signal exit
input bool           InpUseAtrStops             = true;    // Widen the emergency SL by ATR when volatility warrants it
input double          InpAtrStopMultiplier      = 1.8;     // ATR multiple compared against the fixed SL floor

input group "=== PARTIAL PROFIT (SCALE-OUT) ===";
input bool            InpEnablePartialTP        = false;   // Bank part of the position at a defined R-multiple
input double          InpPartialTriggerRR       = 1.0;     // Favorable move required, as a multiple of the SL distance
input double          InpPartialClosePercent    = 50.0;    // % of current position volume to close on trigger

input group "=== HIGHER-TIMEFRAME CONFLUENCE ===";
input ENUM_TIMEFRAMES InpHtfTimeframe           = PERIOD_H1; // Higher timeframe used for the confluence filter
input bool            InpRequireHtfConfluence   = true;      // Block entries that fight a clear HTF trend
input double          InpHtfMinR2ToBlock        = 0.35;      // HTF R^2 below this = no clear HTF opinion, don't block

input group "=== SESSION / ROLLOVER FILTER ===";
input int             InpSessionStartHour       = 0;   // Broker-time session start hour (0-23); equal to end = no restriction
input int             InpSessionEndHour         = 0;   // Broker-time session end hour (0-23)
input int             InpAvoidRolloverMinutes   = 5;   // Minutes around broker midnight to avoid (spread spikes)

input group "=== ADAPTIVE TUNING ===";
input bool            InpAdaptiveTuning         = true;   // Nudge the confidence bar from trailing live performance
input int             InpAdaptiveLookbackTrades = 20;     // Trades considered for the adaptive read
input double          InpAdaptiveMinMultiplier  = 0.85;   // Floor on the adaptive confidence multiplier
input double          InpAdaptiveMaxMultiplier  = 1.25;   // Ceiling on the adaptive confidence multiplier

input group "=== EXECUTION ===";
input ulong          InpMagicNumber             = 24091500; // Magic number
input int            InpDeviationPoints         = 20;       // Min allowed price deviation, points (floor)
input double          InpDeviationSpreadMultiplier = 1.5;   // Deviation also scales to spread*this, whichever is larger
input int            InpMaxExecRetries          = 2;        // Max retries on transient broker errors

input group "=== LIVE EXECUTION QUALITY ===";
input int             InpMaxFillLatencyMs        = 800;     // Fill considered "slow" past this, ms
input int             InpMaxConsecutivePoorFills = 4;       // Kill switch after this many consecutive slow/high-slippage fills
input int             InpMaxModifyFailures       = 3;       // Force-exit a position after this many failed SL/TP modifies

input group "=== STATISTICS / GATE ===";
input int            InpMinTradesForGateSignal  = 20;      // Min trades before the gate reports anything but INSUFFICIENT_DATA
input int            InpMinTradesForValidation  = 100;     // Min trades before VALIDATED is possible
input double         InpMaxAcceptableDrawdownPct= 15.0;    // Max drawdown % still compatible with VALIDATED

input group "=== MISC ===";
input ENUM_TIMEFRAMES InpRegimeTimeframe        = PERIOD_M1; // Timeframe used for regime/liquidity structure
input bool            InpShowDashboard          = true;      // Show on-chart dashboard
input bool            InpCloseAllOnKill         = true;      // Close open position when kill switch activates
input bool            InpVerboseLogging         = false;     // Verbose diagnostic logging (keep off live)
input int             InpMaxConsecutiveExecFailures = 3;     // Consecutive execution failures before auto-kill

//====================================================================
// GLOBAL ENGINE OBJECTS
//====================================================================
CMarketData          g_md;
CMomentumEngine       g_mom;
CMicrostructureEngine g_micro;
CLiquidityEngine      g_liq;
CRegimeEngine         g_regime;
CRegimeEngine         g_regimeHtf;
CSignalScorer         g_scorer;
CFlipEngine           g_flip;
CAntiChopEngine       g_chop;
CRiskEngine           g_risk;
CAccountCampaignCoordinator g_campaignRisk;
CEmergencyControls    g_emergency;
ENUM_AX_VWAP_EXIT_MODE g_effectiveVwapExitMode = AX_VWAP_EXIT_OFF; // set at OnInit, may be forced
                                                                     // down from InpVWAPExitMode - see
                                                                     // OnInit's validation for why
CEntryEngine          g_entryEngine;
CExecutionEngine      g_exec;
CExitEngine           g_exit;
CSniperEngine         g_sniper;
COrderFlowEngine      g_orderFlow;
CVolumeProfileEngine  g_volProfile;
CFootprintEngine      g_footprint;
CPulseEngine          g_pulse;
CHeatmapEngine        g_heatmap;
CAdaptiveFlipEngine   g_afe;
CVWAPEngine           g_vwap;
CTradeAutopsy         g_autopsy;
CStatistics           g_stats;
CAccuracyEngine       g_accuracy;
CDashboard            g_dash;
CTradeReconciler       g_tradeReconciler;
CRestartRecovery       g_restartRecovery;
bool                   g_recoveryInitialized = false;
bool                   g_recoveryReady = false; // false means new entries are blocked; existing positions remain managed

SAxPositionState      g_posState;
bool                  g_haveOpenPosition = false;
ulong                 g_positionIdentifier = 0; // POSITION_IDENTIFIER retained for history lookup
bool                  g_partialClosePending = false;
double                g_pendingPartialCloseVolume = 0.0;
ENUM_AX_ENGINE_STATE  g_engineState = AX_ENGINE_ACTIVE;
datetime              g_lastBarTime = 0;
datetime              g_lastHtfBarTime = 0;
int                   g_consecutiveExecFailures = 0;
double                g_adaptiveConfMultiplier = 1.0;
// the score actually acted on this tick, AFTER AxApplyOrderFlowBonus - CSignalScorer's own Last()
// only ever holds the PRE-bonus reading, so the dashboard reads this instead to show what really
// drove the decision rather than a stale, lower-confidence number that silently diverges from it
SAxScore              g_lastScore;

// VWAP Trend Engine readings, refreshed once per new bar (same cadence as regime/liquidity) -
// g_vwapValue is -1 when unavailable, g_vwapTrend is "NEUTRAL" in that case (never fabricated)
double                g_vwapValue = -1.0;
string                g_vwapTrend = "NEUTRAL";
double                g_lastClosedBarClose = 0.0;

//--- live execution-quality tracking: a demo feed rarely shows meaningful slippage or fill    ---
//--- latency, so these only really start to matter once running on a live account. Tracked    ---
//--- separately from g_consecutiveExecFailures (hard broker errors) because a "successful" but ---
//--- badly-slipped or slow fill is its own live-only warning sign that a fresh entry gets past. ---
int                   g_consecutivePoorFills = 0;
bool                  g_isLiveAccount = false;
double                g_sumSlippagePts = 0;
double                g_sumLatencyMs = 0;
int                   g_fillCount = 0;
int                   g_poorFillsToday = 0;
datetime              g_lastStatsDay = 0;

//--- pending entry intent: decision made on tick N, re-verified and executed on a later tick ---
bool                  g_pendingActive = false;
SAxScore              g_pendingScore;
datetime              g_pendingTime = 0;
#define AX_PENDING_MAX_AGE_SEC 2

//--- accuracy-engine registration throttle: sample at most once per direction-state or once ---
//--- per second, rather than every tick a decisive signal persists (avoids saturating the    ---
//--- accuracy ring buffer on fast-ticking symbols before longer horizons can resolve)         ---
ENUM_AX_DIR           g_lastAccSignalDir = AX_DIR_NONE;
datetime              g_lastAccSignalTime = 0;

//====================================================================
// HELPERS
//====================================================================
double AxRiskPercentForMode(void)
  {
   if(InpMode==AX_MODE_NORMAL)      return(0.5);
   if(InpMode==AX_MODE_AGGRESSIVE)  return(1.0);
   return(AxClampD(InpExtremeRiskPercent,0.05,2.0));
  }

//--- sums only OUT deals with a ticket strictly greater than sinceTicketExclusive - lets partial ---
//--- closes and the eventual final close each claim their own slice of a position's deal history ---
//--- with no double count. Filtering by ticket (not DEAL_TIME) matters: MT5 deal time only has    ---
//--- 1-second resolution, so a fast scalper's entry-to-exit could land in the same wall-clock      ---
//--- second - deal tickets are strictly increasing in chronological order regardless.              ---
bool AxFetchCloseFinancials(const ulong posTicket,const ulong sinceTicketExclusive,double &closePrice,
                             double &grossProfit,double &commission,double &swap,datetime &closeTime,
                             ulong &lastDealTicketOut)
  {
   closePrice=0; grossProfit=0; commission=0; swap=0; closeTime=0; lastDealTicketOut=sinceTicketExclusive;
   // HistorySelectByPosition requires POSITION_IDENTIFIER, not POSITION_TICKET.
   // Preserve the identifier captured while live because the position may be gone at close time.
   ulong positionId=(g_posState.ticket==posTicket)?g_positionIdentifier:0;
   if(positionId==0 && PositionSelect(_Symbol) &&
      (ulong)PositionGetInteger(POSITION_TICKET)==posTicket)
      positionId=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
   if(positionId==0 || !HistorySelectByPosition((long)positionId)) return(false);
   int total = HistoryDealsTotal();
   bool found=false;
   for(int i=0;i<total;i++)
     {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket==0 || dealTicket<=sinceTicketExclusive) continue;
      long entryType = HistoryDealGetInteger(dealTicket,DEAL_ENTRY);
      if(entryType!=DEAL_ENTRY_OUT && entryType!=DEAL_ENTRY_OUT_BY) continue;
      grossProfit += HistoryDealGetDouble(dealTicket,DEAL_PROFIT);
      commission  += HistoryDealGetDouble(dealTicket,DEAL_COMMISSION);
      swap        += HistoryDealGetDouble(dealTicket,DEAL_SWAP);
      closePrice   = HistoryDealGetDouble(dealTicket,DEAL_PRICE);
      closeTime    = (datetime)HistoryDealGetInteger(dealTicket,DEAL_TIME);
      if(dealTicket>lastDealTicketOut) lastDealTicketOut=dealTicket;
      found=true;
     }
   return(found);
  }

string AxBuildEntryReason(const SAxScore &score,const ENUM_AX_DIR dir)
  {
   string tags="";
   if(score.regime==AX_REGIME_BREAKOUT) tags+="BREAKOUT ";
   bool liqReady = (dir==AX_DIR_BUY) ? g_liq.BullishAttackReady(g_mom.DisplacementPts())
                                       : g_liq.BearishAttackReady(g_mom.DisplacementPts());
   if(liqReady) tags+="LIQUIDITY_SWEEP ";
   tags+="MOMENTUM";
   // VWAP trend read reported alongside the other engines here - advisory evidence only, never an
   // override of the regime/structure engines that already decided this trade (Task 2)
   return(StringFormat("%s | %s | VWAP=%s | B=%.0f S=%.0f C=%.0f",
          AxRegimeToString(score.regime),tags,g_vwapTrend,score.buyScore,score.sellScore,score.confidence));
  }

//--- builds a trade record from the current position state; does NOT touch g_posState or file it ---
SAxTradeRecord AxBuildTradeRecord(const double closePrice,const double grossProfit,const double commission,
                                   const double swap,const datetime closeTime,const ENUM_AX_EXIT_REASON reason,
                                   const double lotsForRecord,const bool isPartial)
  {
   SAxTradeRecord rec;
   rec.ticket        = g_posState.ticket;
   rec.positionIdentifier = g_positionIdentifier;
   rec.entryTime     = g_posState.entryTime;
   rec.exitTime      = (closeTime>0)? closeTime : TimeCurrent();
   rec.direction     = g_posState.dir;
   rec.entryPrice    = g_posState.entryPrice;
   rec.exitPrice     = closePrice;
   rec.lots          = lotsForRecord;
   rec.spreadAtEntry = g_posState.entrySpreadPts;
   rec.slippagePts   = g_posState.entrySlippagePts;
   rec.holdSeconds   = (int)(rec.exitTime-g_posState.entryTime);
   rec.buyScore      = g_posState.entryBuyScore;
   rec.sellScore     = g_posState.entrySellScore;
   rec.confidence    = g_posState.entryConfidence;
   rec.regime        = g_posState.entryRegime;
   rec.entryReason   = g_posState.entryReason;
   rec.exitReason    = reason;
   rec.mfe           = g_posState.mfeCurrency;
   rec.mae           = g_posState.maeCurrency;
   rec.grossProfit   = grossProfit;
   rec.commission    = commission;
   rec.swap          = swap;
   rec.netProfit     = grossProfit+commission+swap;
   // a partial is never itself the flip's outcome - only the leg's eventual full close is,
   // so tag it flipSeq=0 to keep it out of CORRECT_FLIP/FALSE_FLIP classification entirely
   rec.flipSeq       = isPartial ? 0 : g_posState.flipSeq;
   rec.isPartial     = isPartial;
   rec.afeCapitalState   = g_posState.afeCapitalState;
   rec.afeRiskOfRuinPct  = g_posState.afeRiskOfRuinPct;
   rec.afeExpectedValueR = g_posState.afeExpectedValueR;
   rec.afeWinProbability = g_posState.afeWinProbability;
   rec.afeRiskMultiplier = g_posState.afeRiskMultiplier;
   rec.impactCostPct     = g_posState.impactCostPct;

   //--- R-multiple (Journal v2, spec section 27) - only computed for a full close, never a partial  ---
   //--- slice (a partial's netProfit isn't the whole original risk's outcome, and GetDatasetRecords  ---
   //--- excludes isPartial records from Monte Carlo/Kelly input anyway, so 0 here is correct, not a   ---
   //--- placeholder). Uses g_posState.originalSlPrice - the AS-PLACED stop, never mutated by break-   ---
   //--- even/trailing - so this is always measured against the true original risk, same invariant    ---
   //--- the existing partial-take-profit R-multiple trigger already relies on. ---
   rec.rMultiple = 0.0;
   if(!isPartial && g_posState.originalSlPrice>0)
     {
      double riskPricePts = MathAbs(g_posState.entryPrice-g_posState.originalSlPrice);
      double tickSize = g_md.TickSize();
      double tickValue = g_md.TickValue();
      if(riskPricePts>0 && tickSize>0 && tickValue>0 && g_posState.lots>0)
        {
         double originalRiskCurrency = (riskPricePts/tickSize)*tickValue*g_posState.lots;
         if(originalRiskCurrency>0) rec.rMultiple = rec.netProfit/originalRiskCurrency;
        }
     }

   //--- KNOWN GAP, documented rather than silently left broken: vwapStateAtEntry, vpMacdStateAtEntry,
   //--- orderFlowStateAtEntry, structureStateAtEntry, liquidityStateAtEntry, newsStateAtEntry,
   //--- sessionAtEntry, setupId and dealIdIn remain unpopulated until their entry/event capture is wired.
   //--- dealIdOut and positionIdentifier are populated by the exit accounting path for restart recovery.
   return(rec);
  }

void AxFinalizeTrade(const double closePrice,const double grossProfit,const double commission,
                      const double swap,const datetime closeTime,const ENUM_AX_EXIT_REASON reason,const ulong lastDealTicket)
  {
   SAxTradeRecord rec = AxBuildTradeRecord(closePrice,grossProfit,commission,swap,closeTime,reason,g_posState.lots,false);

   g_autopsy.RecordTrade(rec);
   // Persist the exit-side registry update before clearing in-memory campaign state. A failed
   // removal does not undo the broker close, but it blocks future entries until recovery is sound.
   bool recoveryRemovalOk = true;
   if(g_recoveryInitialized)
      recoveryRemovalOk = g_restartRecovery.RemoveOpenSetup(g_posState.ticket);
   if(!recoveryRemovalOk || (g_recoveryInitialized && !g_restartRecovery.IsPersisting()))
     {
      g_recoveryReady = false;
      Print("FLIPDEMON RECOVERY ERROR: close completed but registry removal was not persisted; new entries remain blocked.");
     }
   // Do not re-enable entries from an exit callback. Recovery may have been blocked because
   // startup reconciliation found an untracked/mismatched live position, not merely a failed write.
   // A fresh successful reconciliation is required to clear that safety latch.
   if(rec.flipSeq>0) g_accuracy.RegisterFlipOutcome(rec.netProfit>0);
   g_risk.RegisterTradeClosed(rec.netProfit);
   if(reason==AX_EXIT_SL || reason==AX_EXIT_MOMENTUM_COLLAPSE || reason==AX_EXIT_MICROSTRUCTURE_REVERSAL)
      g_chop.RegisterStopOut();

   g_haveOpenPosition = false;
   g_posState.active  = false;
   g_posState.ticket  = 0;

   g_positionIdentifier = 0;

   g_partialClosePending = false;

   g_pendingPartialCloseVolume = 0.0;
   g_posState.dir     = AX_DIR_NONE;
   g_posState.entryReason = "";
  }

bool AxCloseAndRecord(const ENUM_AX_EXIT_REASON reason)
  {
   ulong ticket = g_posState.ticket;
   string errReason;
   if(!g_exec.ClosePosition(_Symbol,errReason))
     {
      g_consecutiveExecFailures++;
      if(InpVerboseLogging) PrintFormat("AUTOPSY X: close failed (%s)",errReason);
      return(false);
     }
   g_consecutiveExecFailures = 0;

   double closePrice=0,grossProfit=0,commission=0,swap=0; datetime closeTime=0; ulong lastTicket=0;
   if(!AxFetchCloseFinancials(ticket,g_posState.lastAccountedDealTicket,closePrice,grossProfit,commission,swap,closeTime,lastTicket))
     {
      // Broker close succeeded, but history may lag. Preserve campaign state and defer
      // finalization; returning false prevents immediate flip-entry on incomplete evidence.
      Print("FLIPDEMON: close confirmed but deal history is not ready; finalization deferred.");
      return(false);
     }
   AxFinalizeTrade(closePrice,grossProfit,commission,swap,closeTime,reason,lastTicket);
   return(true);
  }

void AxRecordExternalClose(void)
  {
   double closePrice=0,grossProfit=0,commission=0,swap=0; datetime closeTime=0; ulong lastTicket=0;
   ENUM_AX_EXIT_REASON reason = AX_EXIT_SL;
   if(!AxFetchCloseFinancials(g_posState.ticket,g_posState.lastAccountedDealTicket,closePrice,grossProfit,commission,swap,closeTime,lastTicket))
     {
      // Never fabricate a zero-PnL outcome when the broker history cache lags.
      // Keep campaign state active so OnTick can retry this reconciliation.
      if(InpVerboseLogging) Print("FLIPDEMON: external close detected but deal history is not ready; finalization deferred.");
      return;
     }
   double distToSl = MathAbs(closePrice-g_posState.initialSlPrice);
   double distToTp = MathAbs(closePrice-g_posState.initialTpPrice);
   reason = (distToTp<distToSl) ? AX_EXIT_TP : AX_EXIT_SL;
   AxFinalizeTrade(closePrice,grossProfit,commission,swap,closeTime,reason);
  }

//--- records the banked slice of a scale-out partial close without touching g_haveOpenPosition; ---
//--- the remainder keeps trading under the same ticket with g_posState.lots reduced accordingly ---
void AxRecordPartialClose(const double volumeClosed,const double closePrice,const double grossProfit,
                           const double commission,const double swap,const datetime closeTime,
                           const ulong lastDealTicket)
  {
   SAxTradeRecord rec = AxBuildTradeRecord(closePrice,grossProfit,commission,swap,closeTime,AX_EXIT_TP,volumeClosed,true);
   rec.dealIdOut=lastDealTicket;
   rec.positionIdentifier=g_positionIdentifier;
   g_autopsy.RecordTrade(rec);
   if(lastDealTicket>0 && g_autopsy.LastAccountedDealTicket(g_positionIdentifier)<lastDealTicket)
     {
      g_recoveryReady=false;
      Print("FLIPDEMON JOURNAL ERROR: partial exit record was not confirmed in the durable journal; new entries blocked.");
     }
   // deliberately NOT calling g_risk.RegisterTradeClosed / g_chop.RegisterStopOut here - a partial
   // is a banked partial win, not the thesis's final outcome; consecutive-loss and chop tracking
   // are driven by the remainder's eventual close, which reflects how the full trade actually ended
   g_posState.lots -= volumeClosed;
   g_posState.partialTaken = true;
   g_posState.lastAccountedDealTicket = lastDealTicket;
   // MFE/MAE currency tracking is lot-size-dependent (UpdateExcursion multiplies by st.lots) -
   // a pre-partial peak measured at the old, larger lot size is no longer comparable to the
   // remainder's excursion. Reset so exitEfficiencyPct/classification reflect only how the
   // remaining, reduced position performed from here.
   g_posState.mfeCurrency = 0;
   g_posState.maeCurrency = 0;
   g_posState.bestFavorablePrice = 0; // 0 signals UpdateExcursion to reinitialize on the next tick
  }

void AxExecutePartialClose(const double volumeToClose)
  {
   if(g_partialClosePending)
     {
      if(InpVerboseLogging) Print("FLIPDEMON: partial close reconciliation pending; refusing another scale-out.");
      return;
     }
   string partErr;
   if(!g_exec.ClosePartial(_Symbol,volumeToClose,partErr))
     {
      if(InpVerboseLogging) PrintFormat("AUTOPSY X: partial close failed (%s)",partErr);
      return;
     }

   // Do not fabricate a partial-close result if the broker history cache lags.
   double pClosePrice=0,pGross=0,pComm=0,pSwap=0;
   datetime pTime=0;
   ulong pLastTicket=g_posState.lastAccountedDealTicket;
   if(!AxFetchCloseFinancials(g_posState.ticket,g_posState.lastAccountedDealTicket,
                              pClosePrice,pGross,pComm,pSwap,pTime,pLastTicket))
     {
      g_partialClosePending=true;
      g_pendingPartialCloseVolume=volumeToClose;
      Print("FLIPDEMON: partial close confirmed but deal history is not ready; accounting deferred.");
      return;
     }

   if(!PositionSelect(_Symbol))
     {
      g_partialClosePending=true;
      g_pendingPartialCloseVolume=volumeToClose;
      Print("FLIPDEMON: partial-close position snapshot unavailable; accounting deferred.");
      return;
     }
   double actualClosed=g_posState.lots-PositionGetDouble(POSITION_VOLUME);
   if(actualClosed<=0.0)
     {
      g_partialClosePending=true;
      g_pendingPartialCloseVolume=volumeToClose;
      Print("FLIPDEMON: partial close deal found but broker volume has not reconciled; accounting deferred.");
      return;
     }
   AxRecordPartialClose(actualClosed,pClosePrice,pGross,pComm,pSwap,pTime,pLastTicket);
  }

// Retry accounting only. Never submit a second close order while reconciliation is pending.
void AxRetryPendingPartialClose(void)
  {
   if(!g_partialClosePending || !g_posState.active) return;
   if(!g_exec.HasOpenPosition(_Symbol))
     {
      // The final-close history query will consume all unaccounted exit deals.
      g_partialClosePending=false;
      g_pendingPartialCloseVolume=0.0;
      return;
     }

   double pClosePrice=0,pGross=0,pComm=0,pSwap=0;
   datetime pTime=0;
   ulong pLastTicket=g_posState.lastAccountedDealTicket;
   if(!AxFetchCloseFinancials(g_posState.ticket,g_posState.lastAccountedDealTicket,
                              pClosePrice,pGross,pComm,pSwap,pTime,pLastTicket))
      return;
   if(!PositionSelect(_Symbol)) return;
   double actualClosed=g_posState.lots-PositionGetDouble(POSITION_VOLUME);
   if(actualClosed<=0.0) return;

   AxRecordPartialClose(actualClosed,pClosePrice,pGross,pComm,pSwap,pTime,pLastTicket);
   g_partialClosePending=false;
   g_pendingPartialCloseVolume=0.0;
  }

void AxInitPositionState(const ulong ticket,const ENUM_AX_DIR dir,const double lots,const double fillPrice,
                          const double slPrice,const double tpPrice,const SAxScore &score,
                          const string entryReason,const int flipSeq,const double intendedPrice)
  {
   g_posState.ticket             = ticket;
   g_positionIdentifier=0;
   if(PositionSelect(_Symbol) && (ulong)PositionGetInteger(POSITION_TICKET)==ticket)
      g_positionIdentifier=(ulong)PositionGetInteger(POSITION_IDENTIFIER);

   g_positionIdentifier          = 0;

   if(PositionSelect(_Symbol) && (ulong)PositionGetInteger(POSITION_TICKET)==ticket &&

      (ulong)PositionGetInteger(POSITION_MAGIC)==InpMagicNumber)

      g_positionIdentifier=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
   g_posState.entryTime          = TimeCurrent();
   g_posState.entryPrice         = fillPrice;
   g_posState.dir                = dir;
   g_posState.lots               = lots;
   g_posState.initialSlPrice     = slPrice;
   g_posState.initialTpPrice     = tpPrice;
   g_posState.originalSlPrice    = slPrice;
   g_posState.breakEvenDone      = false;
   g_posState.bestFavorablePrice = fillPrice;
   g_posState.mfeCurrency        = 0;
   g_posState.maeCurrency        = 0;
   g_posState.entryBuyScore      = score.buyScore;
   g_posState.entrySellScore     = score.sellScore;
   g_posState.entryConfidence    = score.confidence;
   g_posState.entryRegime        = score.regime;
   g_posState.entryReason        = entryReason;
   g_posState.entrySpreadPts     = g_md.CurrentSpreadPts();
   double point = g_md.Point();
   g_posState.entrySlippagePts = (point>0) ? MathAbs(fillPrice-intendedPrice)/point : 0.0;
   g_posState.flipSeq = flipSeq;
   g_posState.active  = true;
   g_posState.modifyFailCount = 0;
   g_posState.partialTaken = false;
   g_posState.lastAccountedDealTicket = 0; // a freshly opened position has no OUT deals yet
   g_haveOpenPosition  = true;
  }

//--- higher-timeframe confluence: block entries that fight a clear HTF trend. A HTF with no ---
//--- clear direction (low R^2) never blocks - this is a filter against fighting HTF trend,  ---
//--- not a requirement that HTF agree outright. ---
bool AxHtfConfluenceOk(const ENUM_AX_DIR dir)
  {
   if(!InpRequireHtfConfluence) return(true);
   if(g_regimeHtf.R2() < InpHtfMinR2ToBlock) return(true);
   double slope = g_regimeHtf.Slope();
   if(dir==AX_DIR_BUY)  return(slope>=0);
   if(dir==AX_DIR_SELL) return(slope<=0);
   return(true);
  }

//--- blends order flow / footprint / volume profile / heatmap into an already-computed score as a ---
//--- bounded advisory bonus (never a hard gate) - each of the (up to) four contributes at most     ---
//--- InpOrderFlowScoreWeight points to a side's raw score (heatmap only when available - see       ---
//--- below), same additive-component pattern the scorer already uses internally for micro/         ---
//--- liquidity/momentum. Confidence and action are then                                            ---
//--- RE-derived from the blended scores using the EA's own configured thresholds, so a strong      ---
//--- order-flow read can genuinely turn a sub-threshold score into an actionable one (and vice     ---
//--- versa a contradicting order-flow read can silently keep a borderline score from firing)       ---
//--- exactly as if it had been part of the score from the start. ---
void AxApplyOrderFlowBonus(SAxScore &score)
  {
   if(!InpUseOrderFlow) return;
   // mirror CSignalScorer::Evaluate's own regime gate - an unsafe/untradeable regime already forces
   // an all-zero score with action=NONE, and a bonus must never be the thing that overrides that
   if(!g_regime.TradingAllowed()) return;

   double w = InpOrderFlowScoreWeight;
   double refPrice = g_md.CurrentMid();

   double buyBonus  = (g_orderFlow.BullishScoreComponent()/100.0)*w
                     + (g_footprint.BullishScoreComponent()/100.0)*w
                     + (g_volProfile.BullishScoreComponent(refPrice)/100.0)*w;
   double sellBonus = (g_orderFlow.BearishScoreComponent()/100.0)*w
                     + (g_footprint.BearishScoreComponent()/100.0)*w
                     + (g_volProfile.BearishScoreComponent(refPrice)/100.0)*w;

   if(InpUseHeatmap && g_heatmap.IsAvailable())
     {
      buyBonus  += (g_heatmap.BullishScoreComponent()/100.0)*w;
      sellBonus += (g_heatmap.BearishScoreComponent()/100.0)*w;
     }

   score.buyScore  = AxClampD(score.buyScore+buyBonus,0,100);
   score.sellScore = AxClampD(score.sellScore+sellBonus,0,100);

   double gap = MathAbs(score.buyScore-score.sellScore);
   score.confidence = AxClampD(gap*1.15,0,100);

   score.action = AX_DIR_NONE;
   if(gap>=InpMinGapToAct)
     {
      if(score.buyScore>score.sellScore && score.buyScore>=InpMinScoreToAct)       score.action = AX_DIR_BUY;
      else if(score.sellScore>score.buyScore && score.sellScore>=InpMinScoreToAct) score.action = AX_DIR_SELL;
     }
  }

//--- tracks live execution quality (slippage + fill latency) across fills. A demo feed rarely
//--- exercises this path meaningfully; on a live account, repeated poor fills are a real signal
//--- that current broker/network conditions aren't fit for this strategy right now, and the EA
//--- protects capital by killing itself rather than continuing to trade through it.
void AxRegisterFillQuality(const double slippagePts,const int latencyMs)
  {
   g_sumSlippagePts += slippagePts;
   g_sumLatencyMs   += latencyMs;
   g_fillCount++;

   bool poor = !g_risk.SlippageAcceptable(slippagePts) || (latencyMs>InpMaxFillLatencyMs);
   if(poor)
     {
      g_consecutivePoorFills++;
      g_poorFillsToday++;
      if(InpVerboseLogging)
         PrintFormat("AUTOPSY X: poor fill quality (slippage=%.1fpts latency=%dms) - streak=%d",
                     slippagePts,latencyMs,g_consecutivePoorFills);
      if(g_consecutivePoorFills>=InpMaxConsecutivePoorFills && !g_risk.IsKilled())
         g_risk.ActivateKillSwitch("Repeated poor live execution quality (slippage/latency)");
     }
   else
      g_consecutivePoorFills = 0;
  }

//--- real, broker-backed position/exposure counts for THIS symbol+magic, scanned by index (never   ---
//--- PositionSelect(symbol) alone - see DuplicateGuard.mqh's own comment on why that alone misses    ---
//--- positions on a hedging account). Used to feed CRiskEngine::PreTradeAllowed()'s per-symbol/     ---
//--- directional-exposure circuit breakers with real numbers instead of the hardcoded 0/0.0 that     ---
//--- call site used before Phase 8 (code-review finding: those two new breakers were otherwise       ---
//--- silently unreachable, always seeing 0 regardless of real exposure). ---
void AxCountRealPositions(int &positionsForSymbolOut,double &directionalExposureLotsOut,const ENUM_AX_DIR dir)
  {
   positionsForSymbolOut=0; directionalExposureLotsOut=0.0;
   int total = PositionsTotal();
   for(int i=0;i<total;i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
      positionsForSymbolOut++;
      long type = PositionGetInteger(POSITION_TYPE);
      ENUM_AX_DIR posDir = (type==POSITION_TYPE_BUY) ? AX_DIR_BUY : AX_DIR_SELL;
      if(posDir==dir) directionalExposureLotsOut += PositionGetDouble(POSITION_VOLUME);
     }
  }

//--- every entry (fresh or flip re-entry) funnels through here, so risk/chop/HTF gates apply ---
//--- unconditionally - a confirmed flip is always allowed to CLOSE the losing side, but the   ---
//--- re-open into the new direction is still just another entry subject to every hard limit.  ---
//--- A netting account has only one position per symbol. If another EA or a manual trade owns
//--- that position, sending an opposite deal can reduce, close, or reverse somebody else's exposure.
//--- Fail closed instead of treating the symbol as flat just because this EA's magic differs.
bool AxHasForeignPositionOnSymbol(string &reasonOut)
  {
   int total=PositionsTotal();
   for(int i=0;i<total;i++)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      ulong positionMagic=(ulong)PositionGetInteger(POSITION_MAGIC);
      if(positionMagic!=InpMagicNumber)
        {
         reasonOut=StringFormat("Foreign position on %s (ticket %I64u, magic %I64u); refusing to trade a shared netting position",
                                _Symbol,ticket,positionMagic);
         return(true);
        }
     }
   reasonOut="";
   return(false);
  }

//--- account-wide position count and gross lots. These feed the account-level hard caps in
//--- CRiskEngine; passing literal zeroes here would silently disable both max-open-position and
//--- total-exposure checks whenever other charts/EAs already had risk on the account.
void AxCountAccountExposure(int &positionsOut,double &grossLotsOut)
  {
   positionsOut=0;
   grossLotsOut=0.0;
   int total=PositionsTotal();
   for(int i=0;i<total;i++)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      double volume=PositionGetDouble(POSITION_VOLUME);
      if(volume<=0.0) continue;
      positionsOut++;
      grossLotsOut+=volume;
     }
  }

bool AxAttemptEntry(const ENUM_AX_DIR dir,const SAxScore &score,const int flipSeq,const string tag)
  {
   // Restart recovery is a hard entry prerequisite. Never add exposure when the persisted
   // ticket-to-setup registry is unreadable, stale, or failed to save. Existing positions
   // continue through the normal management loop.
   if(!g_recoveryReady)
     {
      if(InpVerboseLogging) Print("FLIPDEMON RECOVERY: new entry blocked; registry is not verified and persisted.");
      return(false);
     }
   string gateReason;
   //--- emergency controls checked FIRST, ahead of every other gate - an operator-triggered stop or
   //--- a disabled direction is a deliberate override and should never be shadowed by a message that
   //--- makes it look like an ordinary risk/session gate declined the trade (spec section 38). ---
   if(!g_emergency.CanEnterDirection(dir,gateReason))
     {
      if(InpVerboseLogging) PrintFormat("AUTOPSY X: entry blocked (%s)",gateReason);
      return(false);
     }
   if(AxHasForeignPositionOnSymbol(gateReason))
     {
      if(InpVerboseLogging) PrintFormat("AUTOPSY X: entry blocked (%s)",gateReason);
      return(false);
     }
   int realPositionsForSymbol; double realDirectionalExposure;
   AxCountRealPositions(realPositionsForSymbol,realDirectionalExposure,dir);
   int accountOpenPositions; double accountExposureLots;
   AxCountAccountExposure(accountOpenPositions,accountExposureLots);
   if(!g_risk.PreTradeAllowed(accountOpenPositions,accountExposureLots,g_md.CurrentSpreadPts(),gateReason,
                               realPositionsForSymbol,realDirectionalExposure))
     {
      if(InpVerboseLogging) PrintFormat("AUTOPSY X: entry blocked (%s)",gateReason);
      return(false);
     }
   if(!g_entryEngine.SessionAllowed(InpSessionStartHour,InpSessionEndHour,InpAvoidRolloverMinutes,gateReason))
     {
      if(InpVerboseLogging) PrintFormat("AUTOPSY X: entry blocked (%s)",gateReason);
      return(false);
     }
   if(g_chop.IsInCooldown())
     {
      if(InpVerboseLogging) Print("AUTOPSY X: entry blocked (anti-chop cooldown)");
      return(false);
     }
   if(!AxHtfConfluenceOk(dir))
     {
      if(InpVerboseLogging) Print("AUTOPSY X: entry blocked (HTF confluence)");
      return(false);
     }

   double intendedPrice = (dir==AX_DIR_BUY) ? g_md.CurrentAsk() : g_md.CurrentBid();
   double point = g_md.Point();
   double slPrice,tpPrice;
   double atrForStops = InpUseAtrStops ? g_regime.CurrentAtr() : 0.0;
   g_exit.ComputeInitialStops(g_md,dir,intendedPrice,atrForStops,slPrice,tpPrice);

   // sniper precision extends to risk placement: prefer a stop just beyond the nearest tracked
   // liquidity level over the generic ATR/fixed one, but only when it's actually TIGHTER and
   // still respects the broker's minimum stop distance - never widen risk, only sharpen it.
   // Gated on InpUseSniperEntry too so turning sniper entries off is a true A/B baseline, per README.
   // Flip re-entries ("FLIP" tag) are excluded on purpose: they're a defensive, time-critical
   // reaction to a reversal already in progress and must stay on the plain ATR/fixed stop untouched
   // by sniper precision, exactly as README section 13's "Scope" documents.
   if(InpUseSniperEntry && InpSniperUseStructureStop && point>0 && tag!="FLIP")
     {
      bool wantHighLevel = (dir==AX_DIR_SELL); // SELL stops sit above a recent high, BUY below a recent low
      double levelPrice = g_liq.GetNearestLevel(wantHighLevel,intendedPrice);
      // NearestLevel only picks the geometrically closest level of the requested side - it does NOT
      // guarantee that level is on the correct side of price, e.g. a stale/lagging "low" fractal that
      // now sits above the current ask after a fast reversal. A stop must sit strictly on the loss
      // side of entry (below for BUY, above for SELL); reject anything else outright rather than let
      // an absolute-distance "tighter" comparison mask a stop on the wrong side of the market.
      bool correctSide = (dir==AX_DIR_BUY) ? (levelPrice<intendedPrice) : (levelPrice>intendedPrice);
      if(levelPrice>0 && correctSide)
        {
         double buffer = InpSniperStructureBufferPts*point;
         double structureSl = (dir==AX_DIR_BUY) ? levelPrice-buffer : levelPrice+buffer;
         bool tighter = (dir==AX_DIR_BUY) ? (structureSl>slPrice) : (structureSl<slPrice);
         int minStopPts = g_md.MinStopDistancePts();
         double distFromEntryPts = MathAbs(intendedPrice-structureSl)/point;
         if(tighter && distFromEntryPts>=minStopPts)
            slPrice = g_md.NormalizePrice(structureSl);
        }
     }

   // size off the ACTUAL resulting stop distance (which the above may have widened for the
   // broker's stops/freeze level, widened for ATR, or tightened to structure) so the dollar
   // risk stays pinned to the configured risk percent regardless of how far away the stop sits
   double actualSlDistPts = (point>0) ? MathAbs(intendedPrice-slPrice)/point : InpEmergencySlPoints;

   SAxRiskSizingDecision sizingDecision;
   double lots = g_risk.CalculateLotSize(g_md,intendedPrice,slPrice,dir,sizingDecision);
   if(InpVerboseLogging) PrintFormat("FLIPDEMON SIZING | equity=%.2f budget=%.2f raw=%.5f lots=%.5f risk=%.2f%% reason=%s",sizingDecision.equity,sizingDecision.riskBudgetMoney,sizingDecision.rawLots,sizingDecision.normalizedLots,sizingDecision.projectedRiskPercent,sizingDecision.rejectionReason);

   // Enforce the remaining account-wide gross-lot budget, not just the per-order ceiling.
   // NormalizeVolume may clamp upward to the broker minimum, so reject a remainder too small
   // to represent safely rather than letting normalization exceed the account cap.
   double remainingExposureLots = InpMaxExposureLots-accountExposureLots;
   if(remainingExposureLots<=0.0)
      lots=0.0;
   else if(lots>remainingExposureLots)
     {
      if(remainingExposureLots<g_md.VolumeMin())
         lots=0.0;
      else
        {
         lots=g_md.NormalizeVolume(MathMin(lots,remainingExposureLots));
         if(lots>remainingExposureLots+0.0000001)
            lots=0.0;
        }
     }

   // A broker minimum lot can otherwise force a position larger than the configured
   // account-risk budget. Fail closed instead of allowing the minimum volume to
   // override the risk ceiling.
   if(lots>0.0 && AccountInfoDouble(ACCOUNT_EQUITY)>0.0)
     {
      double projectedProfit = 0.0;
      ENUM_ORDER_TYPE riskOrderType = (dir==AX_DIR_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      if(!OrderCalcProfit(riskOrderType,_Symbol,lots,intendedPrice,slPrice,projectedProfit) ||
         !MathIsValidNumber(projectedProfit) || projectedProfit>=0.0)
         lots=0.0;
      else
        {
         double projectedRiskPct = MathAbs(projectedProfit)/
                                   AccountInfoDouble(ACCOUNT_EQUITY)*100.0;
         if(projectedRiskPct > g_risk.RiskPercent()+0.0001)
            lots = 0.0;
        }
     }

   // Adaptive Flip Engine: capital-protection gate + position-size scaler, applied unconditionally
   // like every other gate above - a flip re-entry gets no exemption from risk-of-ruin/drawdown
   // protection just because it's defensive in nature. Runs here (AFTER stops/base lot size are
   // known) rather than before, because CalculateExpectedCost() needs a real lot size to convert
   // spread/commission/swap/slippage into a real currency figure - it can't run against nothing.
   // Computing the stats snapshot here (rather than reusing OnTimer's cached one) keeps this
   // function a pure read of current state; it's only ever called at an actual entry attempt, far
   // rarer than the tick loop, so this cost is fine.
   double afeRiskMultiplier = 1.0;
   // this signal's own direction vs the current VWAP trend read - feeds both AFE's VWAP alignment
   // bonus (Task 4) below AND g_posState.vwapAlignedAtEntry further down, so it's computed once
   // here, outside the AFE toggle, rather than being unreachable when InpUseAdaptiveFlipEngine is
   // off. Deliberately does NOT check g_posState: this is evaluated before any position exists for
   // this specific attempt, at the moment of a fresh entry/flip decision.
   bool vwapAlignedForThisEntry = (dir==AX_DIR_BUY && g_vwapTrend=="BULLISH") ||
                                   (dir==AX_DIR_SELL && g_vwapTrend=="BEARISH");
   if(InpUseAdaptiveFlipEngine)
     {
      SAxStatsSnapshot afeStats = g_stats.Compute(g_autopsy,g_risk.DayStartEquity()>0?g_risk.DayStartEquity():AccountInfoDouble(ACCOUNT_EQUITY));
      // volatility reused from CRegimeEngine's own ATR (never duplicated here), converted to points
      // to match CalculateExpectedCost's point-based cost math. Session volume is a real MT5 API
      // field, often 0/unavailable on OTC forex-CFD symbols with no consolidated tape - the impact
      // term inside CalculateExpectedCost treats that honestly as "cannot compute", not zero cost.
      double afeVolatilityPts = (point>0) ? g_regime.CurrentAtr()/point : 0.0;
      double afeSessionVolumeLots = SymbolInfoDouble(_Symbol,SYMBOL_SESSION_VOLUME);
      string afeReason;
      if(!g_afe.Evaluate(score,afeStats,g_consecutivePoorFills,
                          _Symbol,dir,lots,point,g_md.TickSize(),g_md.TickValue(),
                          afeVolatilityPts,InpMaxHoldSeconds,afeSessionVolumeLots,
                          InpUseVWAPExit,vwapAlignedForThisEntry,
                          afeRiskMultiplier,afeReason))
        {
         if(InpVerboseLogging) PrintFormat("AUTOPSY X: entry blocked by Adaptive Flip Engine (%s)",afeReason);
         return(false);
        }
     }

   // AFE only ever SCALES DOWN from RiskEngine's already-configured, already-capped risk percent -
   // afeRiskMultiplier is clamped to [0,1] inside CAdaptiveFlipEngine, so this can never push size
   // past what RiskEngine itself already decided was the maximum acceptable for this stop distance.
   // NormalizeVolume() clamps UP to the broker's minimum rather than down to zero, so a scaled size
   // that falls below half a volume step must be treated as "AFE wants this skipped", not silently
   // promoted back up to the broker minimum - that would defeat DEFENSIVE/CAUTION sizing outright
   // on small accounts where the base lot size already sits near the minimum.
   if(afeRiskMultiplier<1.0)
     {
      double scaledLots = lots*afeRiskMultiplier;
      // the real trigger for the up-clamp defeat is scaledLots < VolumeMin() - anything below that
      // floors to (or below) the broker minimum inside NormalizeVolume and gets forced back up to
      // volMin by its own clamp, regardless of how close it is to volMin. A base lot size that's
      // already at the broker minimum (the small-account case this fix targets) times any scaling
      // multiplier below 1.0 will always land under volMin, so it must be zeroed here, not normalized.
      double volMin = g_md.VolumeMin();
      lots = (scaledLots < volMin) ? 0.0 : g_md.NormalizeVolume(scaledLots);
     }

   // order-book impact-cost sizing (Patnaik & Thomas 2004): cap size to what the book can actually
   // absorb within budget, rather than trusting a spread-based tolerance to say anything about a
   // size-dependent cost. A no-op when the broker provides no real depth - EstimateExecution()
   // returns false and lots is left exactly as AFE/RiskEngine already decided it.
   double impactCostPct = 0.0;
   if(InpUseImpactCostSizing && InpUseHeatmap && lots>0)
     {
      double maxAffordableLots = 0.0;
      if(g_heatmap.EstimateExecution(dir,lots,InpMaxImpactCostPct,impactCostPct,maxAffordableLots))
        {
         if(maxAffordableLots<lots)
           {
            double volMin = g_md.VolumeMin();
            lots = (maxAffordableLots < volMin) ? 0.0 : g_md.NormalizeVolume(maxAffordableLots);
           }
        }
     }
   if(lots<=0)
     {
      if(InpVerboseLogging) Print("AUTOPSY X: computed lot size is zero - entry skipped");
      return(false);
     }

   // Recalculate live stop-risk after all sizing scalers. Every account position is
   // included; a missing/invalid stop or failed broker profit calculation blocks new risk.
   double proposedStopPnl=0.0;
   ENUM_ORDER_TYPE campaignOrderType=(dir==AX_DIR_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcProfit(campaignOrderType,_Symbol,lots,intendedPrice,slPrice,proposedStopPnl) ||
      !MathIsValidNumber(proposedStopPnl) || proposedStopPnl>=0.0)
     {
      Print("FLIPDEMON CAMPAIGN RISK BLOCK: proposed stop risk could not be verified.");
      return(false);
     }
   string campaignRiskReason;
   if(!g_campaignRisk.CanAdmitEntry(_Symbol,InpMagicNumber,MathAbs(proposedStopPnl),
                                    MathMin(2.0,InpMaxCampaignRiskPercent),
                                    MathMax(0.01,InpMaxAccountOpenRiskPercent),campaignRiskReason))
     {
      PrintFormat("FLIPDEMON CAMPAIGN RISK BLOCK: %s",campaignRiskReason);
      return(false);
     }
   if(InpVerboseLogging) PrintFormat("FLIPDEMON CAMPAIGN RISK: %s",campaignRiskReason);

   // Final broker-side margin preflight must use the actual post-risk, post-AFE,
   // post-impact lot size and a fresh executable-side quote. Account leverage alone
   // is not proof that this order is affordable; OrderCalcMargin is broker-specific.
   MqlTick marginTick;
   if(!SymbolInfoTick(_Symbol,marginTick) ||
      marginTick.bid<=0.0 || marginTick.ask<=0.0 || marginTick.ask<marginTick.bid)
     {
      PrintFormat("FLIPDEMON MARGIN ERROR: no valid fresh quote for '%s'; entry blocked.",_Symbol);
      return(false);
     }
   ENUM_ORDER_TYPE marginOrderType=(dir==AX_DIR_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double marginPrice=(dir==AX_DIR_BUY) ? marginTick.ask : marginTick.bid;
   double requiredMargin=0.0;
   if(!OrderCalcMargin(marginOrderType,_Symbol,lots,marginPrice,requiredMargin) ||
      !MathIsValidNumber(requiredMargin) || requiredMargin<=0.0)
     {
      PrintFormat("FLIPDEMON MARGIN ERROR: OrderCalcMargin failed or returned invalid margin for %s lots=%.8f price=%.10g; entry blocked. error=%d",
                  _Symbol,lots,marginPrice,GetLastError());
      return(false);
     }
   double freeMargin=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(!MathIsValidNumber(freeMargin) || freeMargin<=0.0 || requiredMargin>freeMargin)
     {
      PrintFormat("FLIPDEMON MARGIN BLOCK: symbol=%s lots=%.8f estimated_required=%.2f free_margin=%.2f currency=%s",
                  _Symbol,lots,requiredMargin,freeMargin,AccountInfoString(ACCOUNT_CURRENCY));
      return(false);
     }
   if(InpVerboseLogging)
      PrintFormat("FLIPDEMON MARGIN OK: symbol=%s lots=%.8f estimated_required=%.2f free_margin=%.2f currency=%s",
                  _Symbol,lots,requiredMargin,freeMargin,AccountInfoString(ACCOUNT_CURRENCY));

   // live spread can widen well past anything a demo feed shows - scale the allowed deviation to
   // it (floored at the configured minimum) so normal spread widening doesn't spuriously reject
   // an otherwise-fine fill, while still capping how far price can move against us
   int deviationPts = (int)MathMax(InpDeviationPoints,MathRound(g_md.CurrentSpreadPts()*InpDeviationSpreadMultiplier));
   g_exec.SetDeviationPoints(deviationPts);

   string entryReason = AxBuildEntryReason(score,dir)+" "+tag;
   ulong newTicket; double fillPrice; double actualLots; string execErr; int fillLatencyMs;
   if(!g_exec.OpenMarket(_Symbol,dir,lots,slPrice,tpPrice,"AXFDX",newTicket,fillPrice,execErr,fillLatencyMs,actualLots))
     {
      g_consecutiveExecFailures++;
      g_risk.RegisterExecutionFailure(); // feeds CRiskEngine's own MaxExecutionFailures circuit breaker
                                          // (spec section 18) - a distinct counter/threshold from
                                          // g_consecutiveExecFailures above, which existed before this
                                          // phase for its own purposes; both now track every failure
      if(InpVerboseLogging) PrintFormat("AUTOPSY X: entry failed (%s)",execErr);
      return(false);
     }
   g_consecutiveExecFailures = 0;
   g_risk.RegisterExecutionSuccess();

   // Use the confirmed filled volume, not the requested volume. A legitimate partial
   // fill is a real position and must be managed at its actual exposure.
   lots = actualLots;
   AxInitPositionState(newTicket,dir,lots,fillPrice,slPrice,tpPrice,score,entryReason,flipSeq,intendedPrice);
   // The broker has already confirmed this fill. Persist its real ticket and a unique setup ID
   // immediately; if persistence fails, keep managing the open position but block every new entry.
   string recoverySetupId = AxGenerateSetupId(_Symbol,dir);
   bool recoverySaved = g_recoveryInitialized &&
                        g_restartRecovery.RecordOpenSetup(newTicket,g_positionIdentifier,recoverySetupId,_Symbol,dir,TimeCurrent());
   if(!recoverySaved || !g_restartRecovery.IsPersisting())
     {
      g_recoveryReady = false;
      PrintFormat("FLIPDEMON RECOVERY ERROR: live position ticket %I64u is open but its setup registry could not be verified; managing existing position and blocking new entries.",newTicket);
     }
   // AFE's readings at the moment of this entry, carried through to the closed-trade autopsy record
   g_posState.afeCapitalState   = g_afe.State();
   g_posState.afeRiskOfRuinPct  = g_afe.RiskOfRuinPct();
   g_posState.afeExpectedValueR = g_afe.ExpectedValueR();
   g_posState.afeWinProbability = g_afe.WinProbability();
   g_posState.afeRiskMultiplier = afeRiskMultiplier;
   g_posState.impactCostPct     = impactCostPct;
   // arms CExitEngine's mechanical VWAP exit for THIS position only - reuses vwapAlignedForThisEntry
   // (already computed above, same dir/g_vwapTrend comparison) rather than re-deriving it
   g_posState.vwapAlignedAtEntry = InpUseVWAPExit && vwapAlignedForThisEntry;
   AxRegisterFillQuality(g_posState.entrySlippagePts,fillLatencyMs);

   if(dir==AX_DIR_BUY && g_liq.BullishAttackReady(g_mom.DisplacementPts())) g_liq.ConsumeBullishAttack();
   if(dir==AX_DIR_SELL && g_liq.BearishAttackReady(g_mom.DisplacementPts())) g_liq.ConsumeBearishAttack();

   return(true);
  }

//--- self-tuning: nudges the entry confidence bar from trailing live performance, bounded so ---
//--- it can never widen or narrow the gate beyond the configured min/max multiplier. This is  ---
//--- the only thing adaptive tuning touches - never position size, never risk limits. ---
double AxAdaptiveConfidenceMultiplier(void)
  {
   if(!InpAdaptiveTuning) return(1.0);
   int n = g_autopsy.Count();
   if(n<=0) return(1.0);

   // walk backward from the most recent record, skipping scale-out partials - a partial is a
   // banked slice of a still-open thesis, not a standalone outcome, and would otherwise pad
   // the win rate with guaranteed wins (it only ever fires in profit) and mislead this reading
   int wins=0,counted=0; double netSum=0;
   for(int i=n-1;i>=0 && counted<InpAdaptiveLookbackTrades;i--)
     {
      SAxTradeRecord r;
      if(!g_autopsy.GetRecord(i,r)) continue;
      if(r.isPartial) continue;
      if(r.netProfit>0) wins++;
      netSum += r.netProfit;
      counted++;
     }
   if(counted<10) return(1.0);
   double winRate = 100.0*wins/counted;

   double mult = 1.0;
   if(winRate>=55.0 && netSum>0)      mult = 0.90; // performing well - allow slightly more entries
   else if(winRate<40.0 || netSum<0)  mult = 1.15; // performing poorly - be pickier until it improves

   return(AxClampD(mult,InpAdaptiveMinMultiplier,InpAdaptiveMaxMultiplier));
  }

void AxReconcileExistingPosition(void)
  {
   if(!PositionSelect(_Symbol)) return;
   if((ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) return;

   long type = PositionGetInteger(POSITION_TYPE);
   g_posState.ticket            = (ulong)PositionGetInteger(POSITION_TICKET);

   g_positionIdentifier          = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
   g_posState.entryTime          = (datetime)PositionGetInteger(POSITION_TIME);
   g_posState.entryPrice          = PositionGetDouble(POSITION_PRICE_OPEN);
   g_posState.dir                  = (type==POSITION_TYPE_BUY)? AX_DIR_BUY : AX_DIR_SELL;
   g_posState.lots                  = PositionGetDouble(POSITION_VOLUME);
   g_posState.initialSlPrice         = PositionGetDouble(POSITION_SL);
   g_posState.initialTpPrice          = PositionGetDouble(POSITION_TP);
   // true original (pre-break-even) SL isn't recoverable from position state alone after a
   // restart - approximate with the current SL; only affects the partial-TP R-multiple trigger
   g_posState.originalSlPrice          = g_posState.initialSlPrice;
   g_posState.breakEvenDone            = false;
   g_posState.bestFavorablePrice        = g_posState.entryPrice;
   g_posState.mfeCurrency                = 0;
   g_posState.maeCurrency                 = 0;
   g_posState.entryBuyScore                = 0;
   g_posState.entrySellScore                = 0;
   g_posState.entryConfidence                = 0;
   g_posState.entryRegime                     = AX_REGIME_UNSAFE;
   g_posState.entryReason                      = "RECONCILED_ON_INIT";
   g_posState.entrySpreadPts                    = 0;
   g_posState.entrySlippagePts                   = 0;
   g_posState.flipSeq = 0;
   g_posState.active  = true;
   g_posState.modifyFailCount = 0;
   // no live AFE reading exists for a position the EA is re-attaching to after a restart -
   // neutral defaults rather than a fabricated one; the autopsy record for this trade will show them
   g_posState.afeCapitalState   = AX_CAPITAL_NORMAL;
   g_posState.afeRiskOfRuinPct  = 0.0;
   g_posState.afeExpectedValueR = 0.0;
   g_posState.afeWinProbability = 0.5;
   g_posState.afeRiskMultiplier = 1.0;
   g_posState.impactCostPct     = 0.0;
   // no real "VWAP trend at entry" reading exists for a position from before this EA session
   // started - never arm the mechanical exit off a fabricated alignment, default to unarmed
   g_posState.vwapAlignedAtEntry = false;

   // baseline to any OUT deals that already happened on this position before this EA session
   // started (e.g. a partial close from before a restart), so they are never re-reported -
   // and if any such deal exists, a partial must already have fired (the position is still
   // open, so a full close would have left PositionSelect() false above) - never re-arm it
   double rClosePrice=0,rGross=0,rComm=0,rSwap=0; datetime rTime=0; ulong rLastTicket=0;
   bool priorDealFound = AxFetchCloseFinancials(g_posState.ticket,0,rClosePrice,rGross,rComm,rSwap,rTime,rLastTicket);
   // A history high-water mark is NOT proof that earlier exit deals were durably journaled.
   // This build has no persistent deal-by-deal accounting ledger, so silently baselining those
   // deals can hide partial-close PnL after a restart. Keep the known boundary to avoid double
   // counting already-journaled deals, but fail closed and report the unresolved history explicitly.
   g_posState.lastAccountedDealTicket = rLastTicket;
   g_posState.partialTaken = priorDealFound;
   ulong journalBoundary=g_autopsy.LastAccountedDealTicket(g_positionIdentifier);
   if(priorDealFound && rLastTicket>journalBoundary)
     {
      g_recoveryReady = false;
      PrintFormat("FLIPDEMON RECOVERY ERROR: position %I64u has exit history through deal %I64u but the durable journal only confirms through deal %I64u. Existing position will remain managed; NEW ENTRIES BLOCKED pending accounting reconciliation.",g_posState.ticket,rLastTicket,journalBoundary);
     }
   else if(priorDealFound)
      PrintFormat("FLIPDEMON RECOVERY: historical exit deals through %I64u are covered by journal boundary %I64u.",rLastTicket,journalBoundary);

   g_haveOpenPosition  = true;
  }

//====================================================================
// BROKER / SYMBOL CAPABILITY DIAGNOSTICS
// Runtime metadata is authoritative; broker names are never used as an allowlist.
// Unsupported or invalid symbol properties must be visible before trading is considered.
//====================================================================
bool AxLogBrokerCompatibility(void)
  {
   string company=AccountInfoString(ACCOUNT_COMPANY);
   string server=AccountInfoString(ACCOUNT_SERVER);
   string currency=AccountInfoString(ACCOUNT_CURRENCY);
   long leverage=AccountInfoInteger(ACCOUNT_LEVERAGE);
   long marginMode=AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   long accountTradeMode=AccountInfoInteger(ACCOUNT_TRADE_MODE);

   if(!SymbolSelect(_Symbol,true))
     {
      PrintFormat("FLIPDEMON BROKER ERROR: unable to select symbol '%s' in Market Watch; entries must remain blocked.",_Symbol);
      return(false);
     }

   long digits=SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   long tradeMode=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_MODE);
   long executionMode=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_EXEMODE);
   long fillingMode=SymbolInfoInteger(_Symbol,SYMBOL_FILLING_MODE);
   long orderMode=SymbolInfoInteger(_Symbol,SYMBOL_ORDER_MODE);
   long stopsLevel=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevel=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL);
   long swapMode=SymbolInfoInteger(_Symbol,SYMBOL_SWAP_MODE);
   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double tickValue=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tickValueProfit=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE_PROFIT);
   double tickValueLoss=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE_LOSS);
   double contractSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_CONTRACT_SIZE);
   double volumeMin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double volumeMax=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double volumeStep=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double volumeLimit=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_LIMIT);
   double swapLong=SymbolInfoDouble(_Symbol,SYMBOL_SWAP_LONG);
   double swapShort=SymbolInfoDouble(_Symbol,SYMBOL_SWAP_SHORT);
   double bid=0.0,ask=0.0,spreadPoints=0.0;
   MqlTick quote;
   if(SymbolInfoTick(_Symbol,quote))
     {
      bid=quote.bid;
      ask=quote.ask;
      if(point>0.0 && ask>=bid && bid>0.0) spreadPoints=(ask-bid)/point;
     }

   PrintFormat("FLIPDEMON BROKER: company='%s' server='%s' terminal_build=%d account_currency='%s' leverage=1:%I64d margin_mode=%I64d account_trade_mode=%I64d",
               company,server,(int)TerminalInfoInteger(TERMINAL_BUILD),currency,leverage,marginMode,accountTradeMode);
   PrintFormat("FLIPDEMON SYMBOL: name='%s' digits=%I64d point=%.10g tick_size=%.10g tick_value=%.10g tick_value_profit=%.10g tick_value_loss=%.10g contract_size=%.10g",
               _Symbol,digits,point,tickSize,tickValue,tickValueProfit,tickValueLoss,contractSize);
   PrintFormat("FLIPDEMON SYMBOL RULES: trade_mode=%I64d execution_mode=%I64d filling_flags=%I64d order_flags=%I64d stops_level_points=%I64d freeze_level_points=%I64d volume_min=%.8g volume_max=%.8g volume_step=%.8g volume_limit=%.8g swap_mode=%I64d swap_long=%.8g swap_short=%.8g",
               tradeMode,executionMode,fillingMode,orderMode,stopsLevel,freezeLevel,volumeMin,volumeMax,volumeStep,volumeLimit,swapMode,swapLong,swapShort);
   PrintFormat("FLIPDEMON QUOTE: symbol='%s' bid=%.10g ask=%.10g spread_points=%.2f",
               _Symbol,bid,ask,spreadPoints);

   if(!MathIsValidNumber(point) || point<=0.0 ||
      !MathIsValidNumber(tickSize) || tickSize<=0.0 ||
      !MathIsValidNumber(volumeMin) || volumeMin<=0.0 ||
      !MathIsValidNumber(volumeStep) || volumeStep<=0.0 ||
      !MathIsValidNumber(volumeMax) || volumeMax<volumeMin ||
      !MathIsValidNumber(contractSize) || contractSize<=0.0)
     {
      PrintFormat("FLIPDEMON BROKER ERROR: critical symbol metadata is invalid for '%s'; refusing initialization rather than guessing broker specifications.",_Symbol);
      return(false);
     }

   if(tradeMode==SYMBOL_TRADE_MODE_DISABLED)
     {
      PrintFormat("FLIPDEMON BROKER ERROR: symbol '%s' is trade-disabled by the broker. This symbol cannot be traded until broker metadata changes.",_Symbol);
      return(false);
     }

   return(true);
  }

//====================================================================
// LIFECYCLE
//====================================================================
int OnInit(void)
  {
   // Inspect the connected broker and actual symbol before configuring strategy/risk modules.
   // This is metadata-driven portability, not a hard-coded broker-name allowlist.
   if(!AxLogBrokerCompatibility())
      return(INIT_FAILED);

   // this EA assumes one net position per symbol throughout (PositionSelect-based state
   // tracking, single-ticket close/flip/partial logic). That assumption only holds on a
   // netting account. US NFA-regulated accounts are netting/FIFO by law (no hedging); on a
   // hedging-mode account, multiple simultaneous tickets per symbol are possible and this
   // EA's position tracking is not designed to reconcile against that - refuse to run rather
   // than risk silently mismanaging exposure it can't see.
   long marginMode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(marginMode==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      Print("AUTOPSY X: account is in hedging mode. This EA requires a netting account ",
            "(one net position per symbol) and will not run on hedging-mode accounts. ",
            "Use a netting account, or a broker/account type that supports it.");
      return(INIT_FAILED);
     }

   // demo execution is typically near-instant with near-zero slippage - it will not surface the
   // live-only problems this EA specifically defends against (spread spikes, slow fills, real
   // slippage). Detected once here purely to label the dashboard/log honestly; behavior itself
   // doesn't branch on it - the execution-quality circuit breaker runs unconditionally and simply
   // won't have much to react to on a demo feed.
   long tradeMode = AccountInfoInteger(ACCOUNT_TRADE_MODE);
   g_isLiveAccount = (tradeMode==ACCOUNT_TRADE_MODE_REAL);
   PrintFormat("AUTOPSY X: account mode = %s",g_isLiveAccount?"LIVE":(tradeMode==ACCOUNT_TRADE_MODE_CONTEST?"CONTEST":"DEMO"));

   if(!g_md.Init(_Symbol))
     {
      Print("AUTOPSY X: failed to initialize market data for ",_Symbol);
      return(INIT_FAILED);
     }
   if(!g_regime.Init(_Symbol,InpRegimeTimeframe))
     {
      Print("AUTOPSY X: failed to initialize regime engine (ATR handle)");
      return(INIT_FAILED);
     }
   if(!g_regimeHtf.Init(_Symbol,InpHtfTimeframe))
     {
      Print("AUTOPSY X: failed to initialize HTF regime engine (ATR handle)");
      return(INIT_FAILED);
     }
   g_liq.Init(_Symbol,InpRegimeTimeframe);
   g_liq.RefreshLevels();
   g_regime.Update();
   g_regimeHtf.Update();

   g_volProfile.Init(_Symbol,InpVolumeProfileBars,InpVolumeProfileBinPoints,g_md.Point(),InpRegimeTimeframe);
   g_volProfile.Refresh();
   g_footprint.Configure(InpFootprintBinPoints,InpFootprintImbalanceRatio,InpFootprintStackedLevels,g_md.Point());
   // market depth is unavailable on most retail forex/CFD symbols via MT5 - this is expected, not
   // an error, and the dashboard/score both degrade to "N/A"/no contribution when it's not there
   if(InpUseHeatmap) g_heatmap.Init(_Symbol);

   g_scorer.Configure(InpMinScoreToAct,InpMinGapToAct);
   g_flip.Configure(InpFlipRequiredConfirmations,InpFlipMinConfidence);
   g_chop.Configure(InpAntiChopBaseCooldownSec,InpAntiChopMaxCooldownSec);
   g_campaignRisk.Configure(2.0); // absolute per-entry ceiling; inputs/progression cannot raise it
   g_risk.Configure(AxRiskPercentForMode(),InpDailyLossLimitPercent,InpMaxConsecutiveLosses,
                     InpMaxOpenPositions,InpMaxExposureLots,InpMaxFlipsPerDay,
                     InpMaxTradesPerRollingPeriod,InpRollingPeriodSeconds,
                     InpMaxSpreadPoints,InpMaxSlippagePoints,InpMinFreeMarginPercent,
                     InpWeeklyLossLimitPercent,InpMaxPositionsPerSymbol,
                     InpMaxDirectionalExposureLots,InpMaxMarginUsagePercent,InpMaxExecutionFailures);
   g_emergency.Configure(InpExecutionMode,InpEnableTrading,InpEnableLong,InpEnableShort);

   //--- IMMEDIATE and CONFIRMED_CROSS_PLUS_STRUCTURE VWAP exit modes need live-price and structure-
   //--- engine wiring that does not exist in this EA yet (see the g_exit.Evaluate() call site) - an
   //--- operator selecting either would otherwise believe a mechanical exit is armed when it can
   //--- never actually fire. Warned loudly and forced to the one mode that IS fully wired, rather
   //--- than silently doing nothing (code-review finding). ---
   if(InpUseVWAPExit && InpVWAPExitMode!=AX_VWAP_EXIT_CONFIRMED_CROSS)
     {
      PrintFormat("AUTOPSY X WARNING: InpVWAPExitMode=%s is not yet wired to live data in this build "
                  "(needs live-tick-price and/or structure-engine integration) - it will NEVER trigger. "
                  "Forcing CONFIRMED_CROSS, the only fully-wired mode, for this session.",
                  AxVwapExitModeToString(InpVWAPExitMode));
      g_effectiveVwapExitMode = AX_VWAP_EXIT_CONFIRMED_CROSS;
     }
   else
      g_effectiveVwapExitMode = InpVWAPExitMode;

   g_entryEngine.Configure(InpMinConfidenceToEnter);
   g_exec.Init(_Symbol,InpMagicNumber,InpDeviationPoints,InpMaxExecRetries);
   g_exit.Configure(InpEmergencySlPoints,InpDynamicTpRR,InpBreakEvenTriggerPoints,InpBreakEvenLockPoints,
                     InpTrailStartPoints,InpTrailDistancePoints,InpMaxHoldSeconds,
                     InpSpreadAbnormalMultiplier,InpOpposingExitConfidence,InpUseAtrStops,
                     InpAtrStopMultiplier,InpMaxHoldExtensionMultiplier);
   // sniper thresholds are configured in points but tracked internally in raw price units
   g_sniper.Configure(InpSniperPullbackPoints*g_md.Point(),InpSniperResumePoints*g_md.Point(),
                       InpSniperMaxWaitSeconds,InpSniperMaxChasePoints*g_md.Point());

   g_afe.Configure(InpUseAdaptiveFlipEngine,InpAfeCautionDdPct,InpAfeDefensiveDdPct,InpAfeLockedDdPct,
                    InpAfeCautionMultiplier,InpAfeDefensiveMultiplier,InpAfeMaxRiskOfRuinPct,
                    InpAfeRuinThresholdPct,InpAfeMinExpectedValueR,InpAfeMinAccountHealth,
                    InpAfeMinTradesForStats,InpAfeAssumedRewardRisk,g_risk.RiskPercent(),
                    InpCommissionPerLot,InpSlippageToleranceBufferPts,
                    InpImpactCoefficientK,InpImpactRelevanceThresholdLots,
                    InpVWAPAlignmentBonus);
   g_afe.Init(_Symbol,InpMagicNumber);

   g_vwap.Configure(InpVWAPMode,InpVWAPRollingBars,InpVWAPSydneyHour,InpVWAPTokyoHour,
                     InpVWAPLondonHour,InpVWAPNewYorkHour,InpVWAPDeadbandATRMult);

   if(!g_autopsy.Init("AutopsyX_FlipDemon_Extreme",_Symbol))
      Print("AUTOPSY X: warning - could not open trade autopsy CSV log");

   // Load and reconcile restart state before allowing any new entry. A corrupt/unreadable
   // registry does not stop management of a broker position already open, but it does keep
   // new entries disabled. An untracked live position is managed defensively, never assigned
   // a fabricated historical setup thesis.
   int recoveryMatched=0, recoveryUntracked=0, recoveryStale=0;
   g_recoveryInitialized = g_restartRecovery.Init("FlipDemon_Extreme_HFT",_Symbol,InpMagicNumber);
   if(g_recoveryInitialized)
     {
      g_restartRecovery.Reconcile(_Symbol,InpMagicNumber,recoveryMatched,recoveryUntracked,recoveryStale);
      g_recoveryReady = g_restartRecovery.IsPersisting() && recoveryUntracked==0;
      PrintFormat("FLIPDEMON RECOVERY: matched=%d untracked=%d stale_removed=%d persistence=%s entries=%s",
                  recoveryMatched,recoveryUntracked,recoveryStale,
                  g_restartRecovery.IsPersisting()?"OK":"FAILED",
                  g_recoveryReady?"ENABLED":"BLOCKED");
     }
   else
     {
      g_recoveryReady = false;
      Print("FLIPDEMON RECOVERY ERROR: registry initialization failed. Existing positions will still be managed; new entries are blocked.");
     }

   g_risk.OnTickHousekeeping();
   AxReconcileExistingPosition();

   if(InpShowDashboard)
     {
      g_dash.Init(_Symbol);
      EventSetTimer(1);
     }

   g_engineState = AX_ENGINE_ACTIVE;
   PrintFormat("AUTOPSY X FLIPDEMON EXTREME initialized on %s | mode=%d | risk=%.2f%%",
               _Symbol,(int)InpMode,g_risk.RiskPercent());
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   if(InpShowDashboard)
     {
      EventKillTimer();
      g_dash.RemoveAll();
     }
   g_autopsy.Deinit();
   g_regime.Deinit();
   g_regimeHtf.Deinit();
   g_heatmap.Deinit();
  }

//====================================================================
// MAIN TICK LOOP: SCAN -> SCORE -> ATTACK -> MANAGE -> FLIP -> EXIT -> REASSESS
//====================================================================
void OnTick(void)
  {
   if(!g_md.OnTickUpdate()) return;
   g_risk.OnTickHousekeeping();
   g_afe.OnTickHousekeeping();

   //--- roll the "poor fills today" counter at broker midnight, same day boundary RiskEngine uses ---
   MqlDateTime dtNow; TimeToStruct(TimeCurrent(),dtNow);
   datetime today = TimeCurrent()-(dtNow.hour*3600+dtNow.min*60+dtNow.sec);
   if(today!=g_lastStatsDay) { g_lastStatsDay=today; g_poorFillsToday=0; }

   //--- position may have closed externally (SL/TP hit, manual intervention) ---
    // Resolve delayed scale-out accounting before processing the next signal.
    AxRetryPendingPartialClose();

   if(g_haveOpenPosition && !g_exec.HasOpenPosition(_Symbol))
      AxRecordExternalClose();

   //--- SCAN: cheap per-tick microstructure/momentum update ---
   g_mom.Update(g_md);
   g_micro.Update(g_md,g_mom);

   //--- order flow: session CVD + rolling imbalance/absorption, every tick (O(window) scan, same ---
   //--- performance category as Microstructure's own per-tick loop above) ---
   g_orderFlow.Update(g_md);
   if(InpUseOrderFlow)
     {
      // guard barTime>0 the same way the regime/HTF bar-tracking blocks below do - a transient 0
      // from iTime (history-cache eviction/feed hiccup) must never be treated as a new bar boundary,
      // or Footprint would snapshot a partially-filled bar early and then double-count the real
      // boundary once iTime recovers, splitting one bar's grid across two history entries
      datetime fpBarTime = iTime(_Symbol,InpFootprintTimeframe,0);
      if(fpBarTime>0)
         g_footprint.OnTick(fpBarTime,g_md.CurrentMid(),g_orderFlow.LastTickBuyVol(),g_orderFlow.LastTickSellVol());
     }
   g_pulse.Update(g_mom,g_micro,g_regime,g_orderFlow);

   //--- refresh structural regime/liquidity/volume-profile levels only on a new bar - not every tick ---
   bool isNewBarThisTick = false;
   datetime barTime = iTime(_Symbol,InpRegimeTimeframe,0);
   if(barTime!=g_lastBarTime && barTime>0)
     {
      isNewBarThisTick = true;
      g_lastBarTime = barTime;
      g_regime.Update();
      g_liq.RefreshLevels();
      g_volProfile.Refresh();
      g_adaptiveConfMultiplier = AxAdaptiveConfidenceMultiplier();
      g_entryEngine.Configure(InpMinConfidenceToEnter*g_adaptiveConfMultiplier);

      // VWAP Trend Engine (Zarattini & Aziz 2023) - refreshed at the same once-per-bar cadence as
      // regime/liquidity above, reusing the ATR CRegimeEngine just updated rather than computing a
      // second volatility read. g_vwapValue stays -1 (unavailable) rather than 0 when the engine
      // can't compute a real reading - AxBuildEntryReason/the dashboard/g_vwapTrend all treat that
      // as "no read", never as a price of zero.
      double closedBarCloseCandidate = iClose(_Symbol,InpRegimeTimeframe,1);
      if(closedBarCloseCandidate>0)
        {
         g_lastClosedBarClose = closedBarCloseCandidate;
         g_vwapValue = g_vwap.GetVWAP(_Symbol,InpRegimeTimeframe);
         g_vwapTrend = g_vwap.ClassifyVWAPTrend(g_lastClosedBarClose,g_vwapValue,g_regime.CurrentAtr());
        }
      else
        {
         // iClose() returning 0 means the closed bar's price genuinely isn't available yet (a
         // fresh history cache right after EA start, a brief feed/history gap) - MQL5 documents
         // this as a real, non-error return value, not an exception. A zero price is never a real
         // market price, so it must never be trusted as one: force everything downstream that
         // depends on it back to "unavailable" rather than let a spurious 0 corrupt the trend
         // classification or arm/fire the mechanical VWAP exit off bad data.
         g_vwapValue = -1.0;
         g_vwapTrend = "NEUTRAL";
        }
     }
   //--- HTF confluence structure refreshes on its own, slower bar clock ---
   datetime htfBarTime = iTime(_Symbol,InpHtfTimeframe,0);
   if(htfBarTime!=g_lastHtfBarTime && htfBarTime>0)
     {
      g_lastHtfBarTime = htfBarTime;
      g_regimeHtf.Update();
     }
   g_liq.UpdateTick(g_md.CurrentBid(),g_md.CurrentAsk(),g_mom.DisplacementPts(),g_md.Point());

   //--- SCORE ---
   SAxScore score = g_scorer.Evaluate(g_md,g_mom,g_micro,g_liq,g_regime);
   AxApplyOrderFlowBonus(score);
   g_lastScore = score; // dashboard reads this, not g_scorer.Last(), so it shows the blended score
   g_accuracy.OnTickUpdate(g_md.CurrentMid());
   //--- sample into the accuracy engine on signal-direction change or at most once/second -   ---
   //--- registering every tick of a sustained signal would saturate the ring buffer on fast-  ---
   //--- ticking symbols before the longer horizons (10s/30s) get a chance to resolve          ---
   if(score.action!=AX_DIR_NONE)
     {
      bool changed = (score.action!=g_lastAccSignalDir);
      bool throttleElapsed = (TimeCurrent()-g_lastAccSignalTime)>=1;
      if(changed || throttleElapsed)
        {
         g_accuracy.RegisterSignal(TimeCurrent(),g_md.CurrentMid(),score.action);
         g_lastAccSignalDir  = score.action;
         g_lastAccSignalTime = TimeCurrent();
        }
     }
   else
      g_lastAccSignalDir = AX_DIR_NONE;

   //--- KILL SWITCH / catastrophic execution guard ---
   if(g_consecutiveExecFailures>=InpMaxConsecutiveExecFailures && !g_risk.IsKilled())
      g_risk.ActivateKillSwitch("Catastrophic execution failures");

   if(g_risk.IsKilled())
     {
      g_engineState = AX_ENGINE_KILLED;
      if(g_haveOpenPosition && InpCloseAllOnKill)
         AxCloseAndRecord(AX_EXIT_MANUAL_KILL);
      return;
     }

   //--- RISK SHUTDOWN: daily loss limit ---
   if(g_risk.DailyLossLimitBreached())
     {
      g_engineState = AX_ENGINE_PAUSED;
      if(g_haveOpenPosition)
         AxCloseAndRecord(AX_EXIT_RISK_SHUTDOWN);
      return;
     }

   //--- MANAGE / FLIP / EXIT ---
   if(g_haveOpenPosition)
     {
      g_engineState = AX_ENGINE_MANAGING;
      bool spreadOk = g_micro.SpreadAcceptable(InpMaxSpreadPoints);

      bool flipTriggered = g_flip.Evaluate(g_posState.dir,score,g_mom,g_micro,spreadOk);
      if(flipTriggered)
        {
         ENUM_AX_DIR newDir  = (g_posState.dir==AX_DIR_BUY) ? AX_DIR_SELL : AX_DIR_BUY;
         int newFlipSeq = g_flip.FlipGeneration();
         if(AxCloseAndRecord(AX_EXIT_FLIP))
           {
            g_risk.RegisterFlip();
            // attempt the reversal BEFORE arming this flip's own anti-chop cooldown - RegisterFlip()
            // always pushes m_cooldownUntil forward, so registering first would make AxAttemptEntry's
            // IsInCooldown() check block the very re-entry this flip is trying to make, 100% of the
            // time under default settings. The reentry is still gated by whatever cooldown PRIOR
            // events already armed; only after attempting it do we arm/extend the cooldown for the
            // NEXT flip, which is what actually throttles rapid repeated flipping.
            AxAttemptEntry(newDir,score,newFlipSeq,"FLIP");
            g_chop.RegisterFlip();
           }
        }
      else
        {
         g_exit.UpdateExcursion(g_posState,g_md.CurrentBid(),g_md.CurrentAsk(),g_md.TickValue(),g_md.TickSize());
         //--- InpUseVWAPExit is the master on/off switch (unchanged); InpVWAPExitMode governs exactly
         //--- when it fires once armed. IMMEDIATE-mode live-price and PLUS_STRUCTURE-mode structure
         //--- confirmation aren't wired to real inputs yet (StructureEngine isn't integrated into the
         //--- live tick loop) - passing 0.0/false is correct-by-construction for CONFIRMED_CROSS (the
         //--- default), which never reads either parameter; selecting IMMEDIATE or PLUS_STRUCTURE
         //--- before that wiring exists would silently never fire, which is documented here rather
         //--- than left to be discovered.
         ENUM_AX_VWAP_EXIT_MODE effectiveVwapExitMode = InpUseVWAPExit ? g_effectiveVwapExitMode : AX_VWAP_EXIT_OFF;
         SAxExitDecision dec = g_exit.Evaluate(g_posState,g_md,g_mom,g_micro,score,InpMaxSpreadPoints,
                                                effectiveVwapExitMode,isNewBarThisTick,g_vwapValue,
                                                g_lastClosedBarClose,0.0,false);
         if(dec.shouldExit)
           {
            AxCloseAndRecord(dec.reason);
           }
         else
           {
            double curPrice = (g_posState.dir==AX_DIR_BUY) ? g_md.CurrentBid() : g_md.CurrentAsk();

            if(InpEnablePartialTP && !g_posState.partialTaken)
              {
               double volToClose;
               if(g_exit.CheckPartialTakeProfit(g_posState,g_md,curPrice,InpPartialTriggerRR,
                                                 InpPartialClosePercent,volToClose))
                  AxExecutePartialClose(volToClose);
              }

            double newSl;
            bool wantModify=false;
            bool isBreakEvenMove=false;
            if(g_exit.CheckBreakEven(g_posState,g_md,curPrice,newSl))
              {
               wantModify=true;
               isBreakEvenMove=true;
              }
            else if(g_exit.CheckTrailing(g_posState,g_md,curPrice,g_posState.initialSlPrice,g_mom,newSl))
              {
               wantModify=true;
              }
            if(wantModify)
              {
               string modErr;
               if(g_exec.ModifyStops(_Symbol,newSl,g_posState.initialTpPrice,modErr))
                 {
                  g_posState.initialSlPrice = newSl;
                  if(isBreakEvenMove) g_posState.breakEvenDone = true;
                  g_posState.modifyFailCount = 0;
                 }
               else
                 {
                  g_posState.modifyFailCount++;
                  if(InpVerboseLogging) PrintFormat("AUTOPSY X: stop modify failed (%s) - streak=%d",modErr,g_posState.modifyFailCount);
                  // stops that can't be reliably managed are unsafe to hold - cut rather than run naked
                  if(g_posState.modifyFailCount>=InpMaxModifyFailures)
                     AxCloseAndRecord(AX_EXIT_EXECUTION_QUALITY);
                 }
              }
           }
        }
     }
   else
     {
      //--- ATTACK: evaluate a fresh entry. Two modes:
      //--- sniper mode arms on a confirmed signal and waits for a genuine pullback-then-resume
      //--- before committing capital (better price, no chasing); legacy mode uses a plain
      //--- one-tick confirmation delay. Either way, conditions are re-verified immediately
      //--- before committing capital.
      if(InpUseSniperEntry)
        {
         if(g_sniper.IsArmed())
           {
            bool expired;
            bool triggered = g_sniper.OnTick(g_md.CurrentMid(),expired);
            if(triggered)
              {
               string finalReason;
               if(g_entryEngine.FinalConfirm(g_md,g_pendingScore,score,InpMaxSpreadPoints,finalReason) &&
                  AxHtfConfluenceOk(g_pendingScore.action))
                 {
                  g_engineState = AX_ENGINE_ATTACKING;
                  AxAttemptEntry(g_pendingScore.action,score,0,"SNIPER");
                 }
               else if(InpVerboseLogging) PrintFormat("AUTOPSY X: sniper trigger cancelled (%s)",finalReason);
              }
            else if(expired)
              {
               if(InpVerboseLogging) Print("AUTOPSY X: sniper entry expired - no valid retest, standing down");
              }
            else
              {
               g_engineState = AX_ENGINE_ACTIVE; // waiting for the precise retest
              }
           }
         else
           {
            string reason;
            double stopDistPts = InpEmergencySlPoints;
            bool ok = g_entryEngine.PreFlightCheck(_Symbol,g_md,score,g_risk,g_chop,stopDistPts,0,0.0,
                                                    InpSessionStartHour,InpSessionEndHour,
                                                    InpAvoidRolloverMinutes,reason)
                      && AxHtfConfluenceOk(score.action);
            if(ok)
              {
               g_sniper.Arm(score.action,g_md.CurrentMid());
               g_pendingScore = score; // remember direction/score for FinalConfirm's "original" baseline
               g_engineState  = AX_ENGINE_ACTIVE;
              }
            else
              {
               g_engineState = g_chop.IsInCooldown() ? AX_ENGINE_COOLDOWN : AX_ENGINE_ACTIVE;
              }
           }
        }
      else
        {
         if(g_pendingActive && (TimeCurrent()-g_pendingTime)>AX_PENDING_MAX_AGE_SEC)
            g_pendingActive = false; // missed move - never chase

         if(g_pendingActive)
           {
            string finalReason;
            if(g_entryEngine.FinalConfirm(g_md,g_pendingScore,score,InpMaxSpreadPoints,finalReason) &&
               AxHtfConfluenceOk(score.action))
              {
               g_engineState = AX_ENGINE_ATTACKING;
               AxAttemptEntry(score.action,score,0,"ENTRY");
              }
            else if(InpVerboseLogging) PrintFormat("AUTOPSY X: entry cancelled (%s)",finalReason);
            g_pendingActive = false;
           }
         else
           {
            string reason;
            double stopDistPts = InpEmergencySlPoints;
            bool ok = g_entryEngine.PreFlightCheck(_Symbol,g_md,score,g_risk,g_chop,stopDistPts,0,0.0,
                                                    InpSessionStartHour,InpSessionEndHour,
                                                    InpAvoidRolloverMinutes,reason)
                      && AxHtfConfluenceOk(score.action);
            if(ok)
              {
               g_pendingActive = true;
               g_pendingScore  = score;
               g_pendingTime   = TimeCurrent();
               g_engineState   = AX_ENGINE_ACTIVE;
              }
            else
              {
               g_engineState = g_chop.IsInCooldown() ? AX_ENGINE_COOLDOWN : AX_ENGINE_ACTIVE;
              }
           }
        }
     }
  }

//====================================================================
// TIMER: dashboard redraw only - never in the hot tick path
//====================================================================
void OnTimer(void)
  {
   if(!InpShowDashboard) return;

   // DOM refresh is heavier than a tick read and doesn't need tick-rate freshness to stay useful -
   // the dashboard/timer's 1s cadence (the only periodic clock this EA runs) is the natural home for it
   if(InpUseHeatmap)
      g_heatmap.Update(g_md.CurrentBid(),g_md.CurrentAsk(),InpHeatmapRangePoints,g_md.Point());

   double floatingPnl = 0;
   double curPrice = g_md.CurrentMid();
   int holdSeconds = 0;
   if(g_haveOpenPosition && PositionSelect(_Symbol))
     {
      floatingPnl = PositionGetDouble(POSITION_PROFIT);
      curPrice    = PositionGetDouble(POSITION_PRICE_CURRENT);
      holdSeconds = (int)(TimeCurrent()-g_posState.entryTime);
     }

   SAxStatsSnapshot snap = g_stats.Compute(g_autopsy,g_risk.DayStartEquity()>0?g_risk.DayStartEquity():AccountInfoDouble(ACCOUNT_EQUITY));
   ENUM_AX_GATE gate = g_stats.EvaluateGate(snap,InpMinTradesForGateSignal,InpMinTradesForValidation,InpMaxAcceptableDrawdownPct);

   ENUM_AX_ENGINE_STATE displayState = g_engineState;
   if(g_risk.IsKilled()) displayState = AX_ENGINE_KILLED;
   else if(g_risk.DailyLockout()) displayState = AX_ENGINE_PAUSED;
   else if(g_chop.IsInCooldown()) displayState = AX_ENGINE_COOLDOWN;

   SAxDashboardExtras extras;
   extras.htfRegime             = g_regimeHtf.Regime();
   extras.htfSlope              = g_regimeHtf.Slope();
   extras.accuracy5s            = g_accuracy.Accuracy(2); // AxAccHorizonsSec index 2 == 5 seconds
   extras.accuracy30s           = g_accuracy.Accuracy(4); // index 4 == 30 seconds
   extras.flipAccuracy          = g_accuracy.FlipAccuracy();
   extras.grossProfitFactor     = snap.grossProfitFactor;
   extras.adaptiveMultiplier    = g_adaptiveConfMultiplier;
   extras.partialTaken          = g_posState.partialTaken;
   extras.htfConfluenceEnabled  = InpRequireHtfConfluence;
   extras.isLiveAccount         = g_isLiveAccount;
   extras.avgSlippagePts        = (g_fillCount>0)? g_sumSlippagePts/g_fillCount : 0.0;
   extras.avgLatencyMs          = (g_fillCount>0)? g_sumLatencyMs/g_fillCount : 0.0;
   extras.poorFillsToday        = g_poorFillsToday;
   extras.consecutivePoorFills  = g_consecutivePoorFills;
   extras.sniperEnabled         = InpUseSniperEntry;
   extras.sniperArmed           = g_sniper.IsArmed();
   extras.sniperPullbackSeen    = g_sniper.PullbackSeen();
   extras.sniperSecondsWaiting  = g_sniper.SecondsWaiting();

   extras.orderFlowEnabled      = InpUseOrderFlow;
   extras.sessionCvd            = g_orderFlow.SessionCvd();
   extras.orderFlowImbalance    = g_orderFlow.ImbalanceRatio();
   extras.bullAbsorption        = g_orderFlow.BullishAbsorption();
   extras.bearAbsorption        = g_orderFlow.BearishAbsorption();
   extras.volProfileValid       = g_volProfile.IsValid();
   extras.volProfilePosition    = g_volProfile.Position(g_md.CurrentMid());
   extras.footprintStackedDir   = g_footprint.LastBarStackedDir();
   extras.pulseValue            = g_pulse.Value();
   extras.pulseDirection        = g_pulse.Direction();
   extras.pulseLabel            = g_pulse.Label();
   extras.heatmapEnabled        = InpUseHeatmap;
   extras.heatmapAvailable      = g_heatmap.IsAvailable();
   extras.heatmapBuyPressure    = g_heatmap.BuyWallPressure();
   extras.heatmapSellPressure   = g_heatmap.SellWallPressure();

   extras.afeEnabled             = InpUseAdaptiveFlipEngine;
   extras.afeState                = g_afe.State();
   extras.afeDrawdownFromPeakPct  = g_afe.DrawdownFromPeakPct();
   extras.afeRiskOfRuinPct        = g_afe.RiskOfRuinPct();
   extras.afeExpectedValueR       = g_afe.ExpectedValueR();
   extras.afeCostR                 = g_afe.CostR();
   extras.afeWinProbability       = g_afe.WinProbability();
   extras.afeAccountHealth        = g_afe.AccountHealth();
   extras.afeRiskMultiplier       = g_afe.LastRiskMultiplier();

   extras.impactCostEnabled       = InpUseImpactCostSizing;
   extras.impactCostPct           = g_posState.impactCostPct;

   extras.vwapTrend               = g_vwapTrend;
   extras.vwapValue               = g_vwapValue;
   extras.vwapExitEnabled         = InpUseVWAPExit;
   //--- reflects THIS position's own armed state, not just the global toggle - the exact flag        ---
   //--- CExitEngine gates its VWAP exit branch on (code-review finding: the dashboard previously      ---
   //--- showed [EXIT ARMED] off the toggle alone, even when this position's own vwapAlignedAtEntry      ---
   //--- was false and the exit could never fire for it) ---
   extras.vwapExitArmedForPosition = g_posState.active && g_posState.vwapAlignedAtEntry;

   extras.executionMode           = g_emergency.ExecutionMode();
   extras.enableTrading           = g_emergency.EnableTrading();
   extras.enableLong              = g_emergency.EnableLong();
   extras.enableShort             = g_emergency.EnableShort();
   extras.emergencyStopActive     = g_emergency.IsEmergencyStopActive();
   extras.emergencyStopReason     = g_emergency.EmergencyStopReason();

   extras.weeklyPnl               = g_risk.WeeklyPnL();
   extras.weeklyPnlPercent        = g_risk.WeeklyPnLPercent();
   extras.weeklyLockout           = g_risk.WeeklyLockout();
   extras.marginUsagePercent      = g_risk.MarginUsagePercent();

   // composite direction / structure / eligibility / lifecycle engines exist (Phases 2-6) but are
   // not yet wired into this OnTick loop - honestly reported as pending rather than fabricated
   extras.extendedEnginesIntegrated = false;

   g_dash.Render(InpMode,g_regime.Regime(),g_lastScore,g_mom.VelocityLabel(),
                 (g_mom.PersistentBull()?"BULLISH":g_mom.PersistentBear()?"BEARISH":"NEUTRAL"),
                 g_md.CurrentSpreadPts(),g_posState.dir,g_posState.entryPrice,curPrice,floatingPnl,
                 holdSeconds,g_risk.FlipsToday(),g_autopsy.Count(),snap,g_risk.DailyPnL(),
                 snap.maxDrawdownPercent,g_risk.RiskPercent(),displayState,gate,extras);
  }

//====================================================================
// CHART EVENTS: KILL ENGINE button
//====================================================================
// Broker-confirmed transaction observer. This deliberately logs only this EA's
// symbol+magic so unrelated manual trades and other EAs do not pollute its journal.
// It is an audit hook, not a substitute for campaign-level reconciliation/state recovery.
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   string symbol=trans.symbol;
   ulong magic=0;
   bool relevant=false;

   if(trans.type==TRADE_TRANSACTION_REQUEST)
     {
      symbol=request.symbol;
      magic=request.magic;
      relevant=(symbol==_Symbol && magic==InpMagicNumber);
     }
   else if(trans.type==TRADE_TRANSACTION_DEAL_ADD && trans.deal>0 && HistoryDealSelect(trans.deal))
     {
      symbol=HistoryDealGetString(trans.deal,DEAL_SYMBOL);
      magic=(ulong)HistoryDealGetInteger(trans.deal,DEAL_MAGIC);
      relevant=(symbol==_Symbol && magic==InpMagicNumber);

      // A DEAL_ADD is a broker-confirmed fill, but MT5 may deliver several deal/order
      // transactions for one request and their order is not guaranteed. Only finalize
      // when the deal is an exit, our tracked campaign is active, and the symbol no
      // longer has a live position. Partial closes leave a live position and are left
      // to the existing volume/history accounting path; entry deals never finalize.
      if(relevant && g_haveOpenPosition && g_posState.active)
        {
         long dealEntry=HistoryDealGetInteger(trans.deal,DEAL_ENTRY);
         bool isExit=(dealEntry==DEAL_ENTRY_OUT || dealEntry==DEAL_ENTRY_OUT_BY);
         if(isExit && !g_exec.HasOpenPosition(_Symbol))
           {
            double closePrice=0,grossProfit=0,commission=0,swap=0;
            datetime closeTime=0;
            ulong lastDealTicket=0;
            // Do not finalize on a transient history-cache miss: that would record a
            // zero-PnL fallback as a real result. Let OnTick retry the established
            // external-close path when complete close-deal history is available.
            if(AxFetchCloseFinancials(g_posState.ticket,g_posState.lastAccountedDealTicket,
                                      closePrice,grossProfit,commission,swap,closeTime,lastDealTicket))
              {
               double distToSl=MathAbs(closePrice-g_posState.initialSlPrice);
               double distToTp=MathAbs(closePrice-g_posState.initialTpPrice);
               ENUM_AX_EXIT_REASON exitReason=(distToTp<distToSl)?AX_EXIT_TP:AX_EXIT_SL;
               PrintFormat("FLIPDEMON TRANSACTION: final exit deal=%I64u; financial history confirmed.",
                           trans.deal);
               AxFinalizeTrade(closePrice,grossProfit,commission,swap,closeTime,exitReason,lastDealTicket);
              }
            else
               PrintFormat("FLIPDEMON TRANSACTION: final exit deal=%I64u; history not ready, deferring reconciliation.",
                           trans.deal);
           }
        }
     }
   else if(trans.order>0 && HistoryOrderSelect(trans.order))
     {
      symbol=HistoryOrderGetString(trans.order,ORDER_SYMBOL);
      magic=(ulong)HistoryOrderGetInteger(trans.order,ORDER_MAGIC);
      relevant=(symbol==_Symbol && magic==InpMagicNumber);
     }

   if(!relevant) return;
   PrintFormat("FLIPDEMON EXTREME HFT | %s",
               g_tradeReconciler.Classify(trans,request,result));
  }

void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
  {
   if(id!=CHARTEVENT_OBJECT_CLICK) return;
   if(!g_dash.IsKillButtonClick(sparam)) return;

   g_risk.ActivateKillSwitch("Manual KILL ENGINE button");
   g_engineState = AX_ENGINE_KILLED;
   if(g_haveOpenPosition && InpCloseAllOnKill)
      AxCloseAndRecord(AX_EXIT_MANUAL_KILL);
   g_dash.ResetKillButtonState();
   Print("AUTOPSY X: KILL ENGINE activated - all new entries disabled");
  }
//+------------------------------------------------------------------+
