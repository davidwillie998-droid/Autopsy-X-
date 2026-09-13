//+------------------------------------------------------------------+
//|                                AutopsyX_FlipDemon_Extreme.mq5     |
//|                        AUTOPSY X FLIPDEMON EXTREME                |
//|        Ultra-aggressive MT5 HFT flipping & scalping engine        |
//|                                                                    |
//|  SCAN -> SCORE -> ATTACK -> MANAGE -> FLIP -> EXIT -> REASSESS     |
//|                                                                    |
//|  No martingale. No averaging down. No unlimited risk, ever.       |
//|  This EA does not promise profitability - see README.md for the   |
//|  required multi-phase validation workflow before risking capital. |
//+------------------------------------------------------------------+
#property copyright "AUTOPSY X"
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
#include <AutopsyX/EntryEngine.mqh>
#include <AutopsyX/ExecutionEngine.mqh>
#include <AutopsyX/ExitEngine.mqh>
#include <AutopsyX/TradeAutopsy.mqh>
#include <AutopsyX/Statistics.mqh>
#include <AutopsyX/Dashboard.mqh>

//====================================================================
// INPUTS
//====================================================================
input group "=== MODE ===";
input ENUM_AX_MODE   InpMode                    = AX_MODE_AGGRESSIVE; // Aggression mode
input double         InpExtremeRiskPercent      = 2.0;                // EXTREME mode risk % per trade (hard-capped at 2.0)

input group "=== RISK ENGINE ===";
input double         InpDailyLossLimitPercent   = 8.0;    // Daily loss limit (%) - stops session when hit
input int            InpMaxConsecutiveLosses    = 5;      // Max consecutive losses before pausing
input int            InpMaxOpenPositions        = 1;      // Max simultaneously open positions
input double         InpMaxExposureLots         = 1.0;    // Max total exposure, lots
input int            InpMaxFlipsPerDay          = 20;      // Max direction flips per day
input int            InpMaxTradesPerRollingPeriod = 10;    // Max trades within rolling window
input int            InpRollingPeriodSeconds    = 300;     // Rolling window length, seconds
input double         InpMaxSpreadPoints         = 250;     // Max acceptable spread, points
input double         InpMaxSlippagePoints       = 30;      // Max acceptable slippage, points
input double         InpMinFreeMarginPercent    = 150.0;   // Min margin level %, refuse new entries below this

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
CEntryEngine          g_entryEngine;
CExecutionEngine      g_exec;
CExitEngine           g_exit;
CTradeAutopsy         g_autopsy;
CStatistics           g_stats;
CAccuracyEngine       g_accuracy;
CDashboard            g_dash;

SAxPositionState      g_posState;
bool                  g_haveOpenPosition = false;
ENUM_AX_ENGINE_STATE  g_engineState = AX_ENGINE_ACTIVE;
datetime              g_lastBarTime = 0;
datetime              g_lastHtfBarTime = 0;
int                   g_consecutiveExecFailures = 0;
double                g_adaptiveConfMultiplier = 1.0;

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
   if(!HistorySelectByPosition((long)posTicket)) return(false);
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
   return(StringFormat("%s | %s | B=%.0f S=%.0f C=%.0f",
          AxRegimeToString(score.regime),tags,score.buyScore,score.sellScore,score.confidence));
  }

//--- builds a trade record from the current position state; does NOT touch g_posState or file it ---
SAxTradeRecord AxBuildTradeRecord(const double closePrice,const double grossProfit,const double commission,
                                   const double swap,const datetime closeTime,const ENUM_AX_EXIT_REASON reason,
                                   const double lotsForRecord,const bool isPartial)
  {
   SAxTradeRecord rec;
   rec.ticket        = g_posState.ticket;
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
   return(rec);
  }

void AxFinalizeTrade(const double closePrice,const double grossProfit,const double commission,
                      const double swap,const datetime closeTime,const ENUM_AX_EXIT_REASON reason)
  {
   SAxTradeRecord rec = AxBuildTradeRecord(closePrice,grossProfit,commission,swap,closeTime,reason,g_posState.lots,false);

   g_autopsy.RecordTrade(rec);
   if(rec.flipSeq>0) g_accuracy.RegisterFlipOutcome(rec.netProfit>0);
   g_risk.RegisterTradeClosed(rec.netProfit);
   if(reason==AX_EXIT_SL || reason==AX_EXIT_MOMENTUM_COLLAPSE || reason==AX_EXIT_MICROSTRUCTURE_REVERSAL)
      g_chop.RegisterStopOut();

   g_haveOpenPosition = false;
   g_posState.active  = false;
   g_posState.ticket  = 0;
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
      closePrice = (g_posState.dir==AX_DIR_BUY)? g_md.CurrentBid() : g_md.CurrentAsk();
      closeTime  = TimeCurrent();
     }
   AxFinalizeTrade(closePrice,grossProfit,commission,swap,closeTime,reason);
   return(true);
  }

void AxRecordExternalClose(void)
  {
   double closePrice=0,grossProfit=0,commission=0,swap=0; datetime closeTime=0; ulong lastTicket=0;
   ENUM_AX_EXIT_REASON reason = AX_EXIT_SL;
   if(AxFetchCloseFinancials(g_posState.ticket,g_posState.lastAccountedDealTicket,closePrice,grossProfit,commission,swap,closeTime,lastTicket))
     {
      double distToSl = MathAbs(closePrice-g_posState.initialSlPrice);
      double distToTp = MathAbs(closePrice-g_posState.initialTpPrice);
      reason = (distToTp<distToSl) ? AX_EXIT_TP : AX_EXIT_SL;
     }
   else
     {
      closeTime  = TimeCurrent();
      closePrice = (g_posState.dir==AX_DIR_BUY)? g_md.CurrentBid() : g_md.CurrentAsk();
     }
   AxFinalizeTrade(closePrice,grossProfit,commission,swap,closeTime,reason);
  }

//--- records the banked slice of a scale-out partial close without touching g_haveOpenPosition; ---
//--- the remainder keeps trading under the same ticket with g_posState.lots reduced accordingly ---
void AxRecordPartialClose(const double volumeClosed,const double closePrice,const double grossProfit,
                           const double commission,const double swap,const datetime closeTime,
                           const ulong lastDealTicket)
  {
   SAxTradeRecord rec = AxBuildTradeRecord(closePrice,grossProfit,commission,swap,closeTime,AX_EXIT_TP,volumeClosed,true);
   g_autopsy.RecordTrade(rec);
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
   string partErr;
   if(!g_exec.ClosePartial(_Symbol,volumeToClose,partErr))
     {
      if(InpVerboseLogging) PrintFormat("AUTOPSY X: partial close failed (%s)",partErr);
      return;
     }
   // the closing deal can occasionally be a beat behind ClosePartial()'s return in MT5's history
   // cache - retry briefly rather than leaving lastAccountedDealTicket stale, which would let the
   // eventual final close re-include (double count) this same partial's profit
   double pClosePrice=0,pGross=0,pComm=0,pSwap=0; datetime pTime=0; ulong pLastTicket=g_posState.lastAccountedDealTicket;
   bool gotDeal=false;
   for(int attempt=0; attempt<2 && !gotDeal; attempt++)
     {
      if(attempt>0) Sleep(40); // brief - this already runs on top of ClosePartial()'s own retry
                                // delays, and OnTick must not stall long during a volatile move
      gotDeal = AxFetchCloseFinancials(g_posState.ticket,g_posState.lastAccountedDealTicket,pClosePrice,pGross,pComm,pSwap,pTime,pLastTicket);
     }
   if(!gotDeal)
     {
      pClosePrice = (g_posState.dir==AX_DIR_BUY)? g_md.CurrentBid() : g_md.CurrentAsk();
      pTime = TimeCurrent();
      if(InpVerboseLogging) Print("AUTOPSY X: partial-close financials unavailable after retries - logged with zeroed P&L, deal boundary held");
     }
   AxRecordPartialClose(volumeToClose,pClosePrice,pGross,pComm,pSwap,pTime,pLastTicket);
  }

void AxInitPositionState(const ulong ticket,const ENUM_AX_DIR dir,const double lots,const double fillPrice,
                          const double slPrice,const double tpPrice,const SAxScore &score,
                          const string entryReason,const int flipSeq,const double intendedPrice)
  {
   g_posState.ticket             = ticket;
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

//--- every entry (fresh or flip re-entry) funnels through here, so risk/chop/HTF gates apply ---
//--- unconditionally - a confirmed flip is always allowed to CLOSE the losing side, but the   ---
//--- re-open into the new direction is still just another entry subject to every hard limit.  ---
bool AxAttemptEntry(const ENUM_AX_DIR dir,const SAxScore &score,const int flipSeq,const string tag)
  {
   string gateReason;
   if(!g_risk.PreTradeAllowed(0,0.0,g_md.CurrentSpreadPts(),gateReason))
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
   double slPrice,tpPrice;
   double atrForStops = InpUseAtrStops ? g_regime.CurrentAtr() : 0.0;
   g_exit.ComputeInitialStops(g_md,dir,intendedPrice,atrForStops,slPrice,tpPrice);

   // size off the ACTUAL resulting stop distance (which ComputeInitialStops may have widened
   // for the broker's stops/freeze level or for ATR) so the dollar risk stays pinned to the
   // configured risk percent regardless of how far away the stop ends up sitting
   double point = g_md.Point();
   double actualSlDistPts = (point>0) ? MathAbs(intendedPrice-slPrice)/point : InpEmergencySlPoints;

   double lots = g_risk.CalculateLotSize(g_md,actualSlDistPts);
   if(lots<=0)
     {
      if(InpVerboseLogging) Print("AUTOPSY X: computed lot size is zero - entry skipped");
      return(false);
     }

   // live spread can widen well past anything a demo feed shows - scale the allowed deviation to
   // it (floored at the configured minimum) so normal spread widening doesn't spuriously reject
   // an otherwise-fine fill, while still capping how far price can move against us
   int deviationPts = (int)MathMax(InpDeviationPoints,MathRound(g_md.CurrentSpreadPts()*InpDeviationSpreadMultiplier));
   g_exec.SetDeviationPoints(deviationPts);

   string entryReason = AxBuildEntryReason(score,dir)+" "+tag;
   ulong newTicket; double fillPrice; string execErr; int fillLatencyMs;
   if(!g_exec.OpenMarket(_Symbol,dir,lots,slPrice,tpPrice,"AXFDX",newTicket,fillPrice,execErr,fillLatencyMs))
     {
      g_consecutiveExecFailures++;
      if(InpVerboseLogging) PrintFormat("AUTOPSY X: entry failed (%s)",execErr);
      return(false);
     }
   g_consecutiveExecFailures = 0;

   AxInitPositionState(newTicket,dir,lots,fillPrice,slPrice,tpPrice,score,entryReason,flipSeq,intendedPrice);
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

   // baseline to any OUT deals that already happened on this position before this EA session
   // started (e.g. a partial close from before a restart), so they are never re-reported -
   // and if any such deal exists, a partial must already have fired (the position is still
   // open, so a full close would have left PositionSelect() false above) - never re-arm it
   double rClosePrice=0,rGross=0,rComm=0,rSwap=0; datetime rTime=0; ulong rLastTicket=0;
   bool priorDealFound = AxFetchCloseFinancials(g_posState.ticket,0,rClosePrice,rGross,rComm,rSwap,rTime,rLastTicket);
   g_posState.lastAccountedDealTicket = rLastTicket;
   g_posState.partialTaken = priorDealFound;

   g_haveOpenPosition  = true;
  }

//====================================================================
// LIFECYCLE
//====================================================================
int OnInit(void)
  {
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

   g_scorer.Configure(InpMinScoreToAct,InpMinGapToAct);
   g_flip.Configure(InpFlipRequiredConfirmations,InpFlipMinConfidence);
   g_chop.Configure(InpAntiChopBaseCooldownSec,InpAntiChopMaxCooldownSec);
   g_risk.Configure(AxRiskPercentForMode(),InpDailyLossLimitPercent,InpMaxConsecutiveLosses,
                     InpMaxOpenPositions,InpMaxExposureLots,InpMaxFlipsPerDay,
                     InpMaxTradesPerRollingPeriod,InpRollingPeriodSeconds,
                     InpMaxSpreadPoints,InpMaxSlippagePoints,InpMinFreeMarginPercent);
   g_entryEngine.Configure(InpMinConfidenceToEnter);
   g_exec.Init(_Symbol,InpMagicNumber,InpDeviationPoints,InpMaxExecRetries);
   g_exit.Configure(InpEmergencySlPoints,InpDynamicTpRR,InpBreakEvenTriggerPoints,InpBreakEvenLockPoints,
                     InpTrailStartPoints,InpTrailDistancePoints,InpMaxHoldSeconds,
                     InpSpreadAbnormalMultiplier,InpOpposingExitConfidence,InpUseAtrStops,
                     InpAtrStopMultiplier);

   if(!g_autopsy.Init("AutopsyX_FlipDemon_Extreme",_Symbol))
      Print("AUTOPSY X: warning - could not open trade autopsy CSV log");

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
  }

//====================================================================
// MAIN TICK LOOP: SCAN -> SCORE -> ATTACK -> MANAGE -> FLIP -> EXIT -> REASSESS
//====================================================================
void OnTick(void)
  {
   if(!g_md.OnTickUpdate()) return;
   g_risk.OnTickHousekeeping();

   //--- roll the "poor fills today" counter at broker midnight, same day boundary RiskEngine uses ---
   MqlDateTime dtNow; TimeToStruct(TimeCurrent(),dtNow);
   datetime today = TimeCurrent()-(dtNow.hour*3600+dtNow.min*60+dtNow.sec);
   if(today!=g_lastStatsDay) { g_lastStatsDay=today; g_poorFillsToday=0; }

   //--- position may have closed externally (SL/TP hit, manual intervention) ---
   if(g_haveOpenPosition && !g_exec.HasOpenPosition(_Symbol))
      AxRecordExternalClose();

   //--- SCAN: cheap per-tick microstructure/momentum update ---
   g_mom.Update(g_md);
   g_micro.Update(g_md,g_mom);

   //--- refresh structural regime/liquidity levels only on a new bar - not every tick ---
   datetime barTime = iTime(_Symbol,InpRegimeTimeframe,0);
   if(barTime!=g_lastBarTime && barTime>0)
     {
      g_lastBarTime = barTime;
      g_regime.Update();
      g_liq.RefreshLevels();
      g_adaptiveConfMultiplier = AxAdaptiveConfidenceMultiplier();
      g_entryEngine.Configure(InpMinConfidenceToEnter*g_adaptiveConfMultiplier);
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
         SAxExitDecision dec = g_exit.Evaluate(g_posState,g_md,g_mom,g_micro,score,InpMaxSpreadPoints);
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
      //--- ATTACK: evaluate a fresh entry, using a one-tick confirmation delay so ---
      //--- conditions are re-verified immediately before committing capital ---
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

//====================================================================
// TIMER: dashboard redraw only - never in the hot tick path
//====================================================================
void OnTimer(void)
  {
   if(!InpShowDashboard) return;

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

   g_dash.Render(InpMode,g_regime.Regime(),g_scorer.Last(),g_mom.VelocityLabel(),
                 (g_mom.PersistentBull()?"BULLISH":g_mom.PersistentBear()?"BEARISH":"NEUTRAL"),
                 g_md.CurrentSpreadPts(),g_posState.dir,g_posState.entryPrice,curPrice,floatingPnl,
                 holdSeconds,g_risk.FlipsToday(),g_autopsy.Count(),snap,g_risk.DailyPnL(),
                 snap.maxDrawdownPercent,g_risk.RiskPercent(),displayState,gate,extras);
  }

//====================================================================
// CHART EVENTS: KILL ENGINE button
//====================================================================
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
