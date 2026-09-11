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

input group "=== EXECUTION ===";
input ulong          InpMagicNumber             = 24091500; // Magic number
input int            InpDeviationPoints         = 20;       // Allowed price deviation, points
input int            InpMaxExecRetries          = 2;        // Max retries on transient broker errors

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
int                   g_consecutiveExecFailures = 0;

//--- pending entry intent: decision made on tick N, re-verified and executed on a later tick ---
bool                  g_pendingActive = false;
SAxScore              g_pendingScore;
datetime              g_pendingTime = 0;
#define AX_PENDING_MAX_AGE_SEC 2

//====================================================================
// HELPERS
//====================================================================
double AxRiskPercentForMode(void)
  {
   if(InpMode==AX_MODE_NORMAL)      return(0.5);
   if(InpMode==AX_MODE_AGGRESSIVE)  return(1.0);
   return(AxClampD(InpExtremeRiskPercent,0.05,2.0));
  }

bool AxFetchCloseFinancials(const ulong posTicket,double &closePrice,double &grossProfit,
                             double &commission,double &swap,datetime &closeTime)
  {
   closePrice=0; grossProfit=0; commission=0; swap=0; closeTime=0;
   if(!HistorySelectByPosition((long)posTicket)) return(false);
   int total = HistoryDealsTotal();
   bool found=false;
   for(int i=0;i<total;i++)
     {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket==0) continue;
      long entryType = HistoryDealGetInteger(dealTicket,DEAL_ENTRY);
      if(entryType!=DEAL_ENTRY_OUT && entryType!=DEAL_ENTRY_OUT_BY) continue;
      grossProfit += HistoryDealGetDouble(dealTicket,DEAL_PROFIT);
      commission  += HistoryDealGetDouble(dealTicket,DEAL_COMMISSION);
      swap        += HistoryDealGetDouble(dealTicket,DEAL_SWAP);
      closePrice   = HistoryDealGetDouble(dealTicket,DEAL_PRICE);
      closeTime    = (datetime)HistoryDealGetInteger(dealTicket,DEAL_TIME);
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

void AxFinalizeTrade(const double closePrice,const double grossProfit,const double commission,
                      const double swap,const datetime closeTime,const ENUM_AX_EXIT_REASON reason)
  {
   double netProfit = grossProfit+commission+swap;

   SAxTradeRecord rec;
   rec.ticket        = g_posState.ticket;
   rec.entryTime     = g_posState.entryTime;
   rec.exitTime      = (closeTime>0)? closeTime : TimeCurrent();
   rec.direction     = g_posState.dir;
   rec.entryPrice    = g_posState.entryPrice;
   rec.exitPrice     = closePrice;
   rec.lots          = g_posState.lots;
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
   rec.netProfit     = netProfit;
   rec.flipSeq       = g_posState.flipSeq;

   g_autopsy.RecordTrade(rec);
   if(rec.flipSeq>0) g_accuracy.RegisterFlipOutcome(netProfit>0);
   g_risk.RegisterTradeClosed(netProfit);
   if(reason==AX_EXIT_SL || reason==AX_EXIT_MOMENTUM_COLLAPSE || reason==AX_EXIT_MICROSTRUCTURE_REVERSAL)
      g_chop.RegisterStopOut();

   g_haveOpenPosition = false;
   g_posState.active  = false;
   g_posState.ticket  = 0;
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

   double closePrice=0,grossProfit=0,commission=0,swap=0; datetime closeTime=0;
   if(!AxFetchCloseFinancials(ticket,closePrice,grossProfit,commission,swap,closeTime))
     {
      closePrice = (g_posState.dir==AX_DIR_BUY)? g_md.CurrentBid() : g_md.CurrentAsk();
      closeTime  = TimeCurrent();
     }
   AxFinalizeTrade(closePrice,grossProfit,commission,swap,closeTime,reason);
   return(true);
  }

void AxRecordExternalClose(void)
  {
   double closePrice=0,grossProfit=0,commission=0,swap=0; datetime closeTime=0;
   ENUM_AX_EXIT_REASON reason = AX_EXIT_SL;
   if(AxFetchCloseFinancials(g_posState.ticket,closePrice,grossProfit,commission,swap,closeTime))
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
   g_haveOpenPosition  = true;
  }

bool AxAttemptEntry(const ENUM_AX_DIR dir,const SAxScore &score,const int flipSeq,const string tag)
  {
   double lots = g_risk.CalculateLotSize(g_md,InpEmergencySlPoints);
   if(lots<=0)
     {
      if(InpVerboseLogging) Print("AUTOPSY X: computed lot size is zero - entry skipped");
      return(false);
     }

   double intendedPrice = (dir==AX_DIR_BUY) ? g_md.CurrentAsk() : g_md.CurrentBid();
   double slPrice,tpPrice;
   g_exit.ComputeInitialStops(g_md,dir,intendedPrice,slPrice,tpPrice);

   string entryReason = AxBuildEntryReason(score,dir)+" "+tag;
   ulong newTicket; double fillPrice; string execErr;
   if(!g_exec.OpenMarket(_Symbol,dir,lots,slPrice,tpPrice,"AXFDX",newTicket,fillPrice,execErr))
     {
      g_consecutiveExecFailures++;
      if(InpVerboseLogging) PrintFormat("AUTOPSY X: entry failed (%s)",execErr);
      return(false);
     }
   g_consecutiveExecFailures = 0;

   AxInitPositionState(newTicket,dir,lots,fillPrice,slPrice,tpPrice,score,entryReason,flipSeq,intendedPrice);

   if(dir==AX_DIR_BUY && g_liq.BullishAttackReady(g_mom.DisplacementPts())) g_liq.ConsumeBullishAttack();
   if(dir==AX_DIR_SELL && g_liq.BearishAttackReady(g_mom.DisplacementPts())) g_liq.ConsumeBearishAttack();

   return(true);
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
   g_haveOpenPosition  = true;
  }

//====================================================================
// LIFECYCLE
//====================================================================
int OnInit(void)
  {
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
   g_liq.Init(_Symbol,InpRegimeTimeframe);
   g_liq.RefreshLevels();
   g_regime.Update();

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
                     InpSpreadAbnormalMultiplier,InpOpposingExitConfidence);

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
  }

//====================================================================
// MAIN TICK LOOP: SCAN -> SCORE -> ATTACK -> MANAGE -> FLIP -> EXIT -> REASSESS
//====================================================================
void OnTick(void)
  {
   if(!g_md.OnTickUpdate()) return;
   g_risk.OnTickHousekeeping();

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
     }
   g_liq.UpdateTick(g_md.CurrentBid(),g_md.CurrentAsk(),g_mom.DisplacementPts(),g_md.Point());

   //--- SCORE ---
   SAxScore score = g_scorer.Evaluate(g_md,g_mom,g_micro,g_liq,g_regime);
   g_accuracy.OnTickUpdate(g_md.CurrentMid());
   if(score.action!=AX_DIR_NONE) g_accuracy.RegisterSignal(TimeCurrent(),g_md.CurrentMid(),score.action);

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
            g_chop.RegisterFlip();
            AxAttemptEntry(newDir,score,newFlipSeq,"FLIP");
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
                 }
               else if(InpVerboseLogging) PrintFormat("AUTOPSY X: stop modify failed (%s)",modErr);
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
         if(g_entryEngine.FinalConfirm(g_md,g_pendingScore,score,InpMaxSpreadPoints,finalReason))
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
         bool ok = g_entryEngine.PreFlightCheck(_Symbol,g_md,score,g_risk,g_chop,stopDistPts,0,0.0,reason);
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

   g_dash.Render(InpMode,g_regime.Regime(),g_scorer.Last(),g_mom.VelocityLabel(),
                 (g_mom.PersistentBull()?"BULLISH":g_mom.PersistentBear()?"BEARISH":"NEUTRAL"),
                 g_md.CurrentSpreadPts(),g_posState.dir,g_posState.entryPrice,curPrice,floatingPnl,
                 holdSeconds,g_risk.FlipsToday(),g_autopsy.Count(),snap,g_risk.DailyPnL(),
                 snap.maxDrawdownPercent,g_risk.RiskPercent(),displayState,gate);
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
