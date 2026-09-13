//+------------------------------------------------------------------+
//|                                    AutopsyX_HFT_Flip.mq5          |
//|                        AUTOPSY X HFT FLIP ENGINE                  |
//| Institutional-grade MT5 high-frequency flip trading system.       |
//| Detect -> Validate -> Enter -> Capture -> Exit -> Reassess.       |
//| Capital preservation > execution quality > signal quality > freq. |
//+------------------------------------------------------------------+
#property copyright "AUTOPSY X"
#property link      ""
#property version   "1.00"
#property description "Institutional-grade MT5 HFT flip trading engine. Attach, select symbol, set risk, enable trading."

#include <AutopsyX/Defines.mqh>
#include <AutopsyX/SymbolProfile.mqh>
#include <AutopsyX/MarketDataEngine.mqh>
#include <AutopsyX/MicrostructureEngine.mqh>
#include <AutopsyX/LiquidityEngine.mqh>
#include <AutopsyX/MomentumEngine.mqh>
#include <AutopsyX/RegimeEngine.mqh>
#include <AutopsyX/ConfidenceEngine.mqh>
#include <AutopsyX/RiskEngine.mqh>
#include <AutopsyX/EntryEngine.mqh>
#include <AutopsyX/ExecutionEngine.mqh>
#include <AutopsyX/ExitEngine.mqh>
#include <AutopsyX/AutopsyEngine.mqh>
#include <AutopsyX/AdaptiveEngine.mqh>
#include <AutopsyX/LiveCalibrationEngine.mqh>
#include <AutopsyX/Dashboard.mqh>

//======================= INPUTS =====================================
input group "=== General ==="
input long   InpMagicNumber            = 990011;      // Magic number
input ENUM_TIMEFRAMES InpStructureTimeframe = PERIOD_M1; // Bar timeframe for structure/regime
input bool   InpEnableTrading           = true;         // Enable trading (master switch)
input bool   InpShowDashboard           = true;         // Show on-chart dashboard
input int    InpDashboardRefreshMs      = 500;          // Dashboard refresh interval (ms)

input group "=== Signal / Confidence ==="
input double InpEntryThreshold          = 65.0;   // Minimum winning score to trade (55-90)
input double InpMinScoreGap             = 15.0;   // Minimum edge over the opposing side
input double InpMaxSpreadPoints         = 30.0;   // Max acceptable spread (points)
input double InpMaxSpreadExpansion      = 2.0;    // Max spread / average-spread ratio
input double InpMinAtrPoints            = 5.0;    // Min ATR (points) required in low-vol regime
input int    InpTickWindow              = 80;     // Rolling tick window (20-400)

input group "=== Liquidity / Momentum / Regime ==="
input int    InpLiquidityLookback       = 20;     // Bars used to define prior high/low
input int    InpLiquidityConfirmWindow  = 3;      // Bars allowed for displacement confirmation
input int    InpMomentumLookback        = 30;     // Bars for swing-structure detection
input int    InpRegimeLookback          = 30;     // Bars for ATR/trend/chaos classification

input group "=== Entry Timing Guards ==="
input int    InpMinDecisionIntervalSec  = 5;      // Minimum seconds between entry decisions
input double InpMinDisplacementPoints   = 4.0;    // Minimum price move (points) since last decision

input group "=== Risk Engine ==="
input double InpRiskPerTradePct         = 0.5;    // Risk per trade (% of equity)
input double InpMaxDailyLossPct         = 3.0;    // Max daily loss (% of day-start equity) -> kill switch
input int    InpMaxConsecutiveLosses    = 4;      // Consecutive losses before cooldown
input int    InpMaxOpenPositions        = 1;       // Max concurrent positions (engine manages one net position)
input int    InpMaxTradesPerMinute      = 6;      // Max trades per rolling minute
input int    InpMaxTradesPerSession     = 60;      // Max trades per session/day
input int    InpMaxFlipsPerMinute       = 4;       // Max directional flips per rolling minute
input double InpMaxDrawdownPct          = 8.0;    // Max drawdown from equity peak -> kill switch
input int    InpBaseCooldownSec         = 15;      // Base cooldown after a loss (scales with streak)

input group "=== Execution ==="
input int    InpDeviationPoints         = 20;      // Max allowed slippage (points)
input int    InpMaxRetries              = 2;       // Order retry attempts on requote/timeout
input int    InpRetryDelayMs            = 150;     // Delay between retries (ms)

input group "=== Stops / Targets ==="
input bool   InpUseAtrStops             = true;    // Size SL/TP from ATR instead of fixed points
input double InpStopLossPoints          = 60.0;    // Fixed SL distance (points) if ATR stops disabled
input double InpTakeProfitPoints        = 90.0;    // Fixed TP distance (points) if ATR stops disabled
input double InpSlAtrMultiplier         = 1.2;     // SL = ATR(points) * multiplier
input double InpTpAtrMultiplier         = 1.8;     // TP = ATR(points) * multiplier

input group "=== Exit Engine ==="
input int    InpMaxHoldingSec           = 300;     // Maximum holding time (sec)
input double InpTrailStartPoints        = 40.0;    // Profit (points) before trailing starts
input double InpTrailDistancePoints     = 25.0;    // Trailing stop distance (points)
input double InpBreakevenTriggerPoints  = 30.0;    // Profit (points) before breakeven applied
input double InpBreakevenLockPoints     = 5.0;     // Points locked in at breakeven
input double InpExitThreshold           = 50.0;    // Opposing score level that forces an exit
input double InpExitSpreadMultiplier    = 1.8;     // Spread multiplier (vs max) that forces an exit
input bool   InpMomentumExitEnabled     = true;    // Exit on momentum reversal/exhaustion
input bool   InpOppositeSignalExitEnabled = true;  // Exit when opposing score dominates

input group "=== Adaptive Parameters ==="
input bool   InpEnableAdaptive          = true;    // Allow bounded self-tuning
input int    InpAdaptiveUpdateEveryTrades = 10;    // Re-tune after this many closed trades

input group "=== Autopsy / Journal ==="
input double InpSlippageFailurePts      = 8.0;     // Slippage (points) tagged as a failure
input double InpSpreadFailurePts        = 35.0;    // Entry spread (points) tagged as a failure

input group "=== Live Calibration (demo != live: measure, don't guess) ==="
input bool   InpLiveCalibrationEnabled    = true;   // Measure real spread before trading anything
input int    InpCalibrationMinutes        = 20;     // Warm-up window (minutes), no trades placed
input int    InpMinCalibrationSamples     = 300;    // Minimum ticks required before trusting the measurement
input double InpSpreadToleranceMultiplier = 2.0;    // Spread gate = measured P90 spread * this
input double InpDisplacementCostMultiplier = 1.5;   // Min displacement = measured median spread * this
input double InpAtrCostMultiplier          = 3.0;   // Min ATR = measured median spread * this
input double InpDeviationToleranceMultiplier = 1.5; // Execution deviation = measured P90 spread * this

//======================= GLOBAL ENGINE INSTANCES =====================
CAXSymbolProfile   g_profile;
CAXMarketData      g_market;
CAXMicrostructure  g_micro;
CAXLiquidity       g_liquidity;
CAXMomentum        g_momentum;
CAXRegime          g_regime;
CAXConfidence      g_confidence;
CAXRisk            g_risk;
CAXEntry           g_entry;
CAXExecution       g_execution;
CAXExit            g_exit;
CAXAutopsy         g_autopsy;
CAXAdaptive        g_adaptive;
CAXCalibration     g_calibration;
CAXDashboard       g_dashboard;

AXPositionState    g_position;
ENUM_AX_STATUS     g_status = AX_STATUS_ACTIVE;
ENUM_AX_DIRECTION  g_lastTradeDirection = AX_DIR_NONE;

datetime g_lastDecisionTime = 0;
double   g_lastDecisionPrice = 0.0;

// live-measured (or static-fallback) operating thresholds - see LiveCalibrationEngine.mqh
bool     g_calibrationDone = false;
double   g_effMaxSpreadPoints = 30.0;
double   g_effMinDisplacementPoints = 4.0;
double   g_effMinAtrPoints = 5.0;

bool g_recentResults[30];
int  g_recentResultsCount = 0;
int  g_recentResultsHead = 0;
int  g_tradesSinceAdaptiveUpdate = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   if(!g_profile.Init(_Symbol))
   {
      Print("AutopsyX: failed to read symbol profile for ", _Symbol);
      return INIT_FAILED;
   }
   if(!g_market.Init(_Symbol, InpStructureTimeframe, AX_TICK_BUFFER_CAPACITY))
   {
      Print("AutopsyX: failed to initialize market data (insufficient bar history?)");
      return INIT_FAILED;
   }

   g_micro.Init(g_profile, InpTickWindow);
   g_liquidity.Init(g_profile, InpLiquidityLookback, InpLiquidityConfirmWindow);
   g_momentum.Init(g_profile, InpMomentumLookback);

   if(!g_regime.Init(g_profile, _Symbol, InpStructureTimeframe, InpRegimeLookback))
   {
      Print("AutopsyX: failed to initialize ATR handle");
      return INIT_FAILED;
   }

   g_effMaxSpreadPoints        = InpMaxSpreadPoints;
   g_effMinDisplacementPoints  = InpMinDisplacementPoints;
   g_effMinAtrPoints           = InpMinAtrPoints;

   g_confidence.BindEngines(g_profile, g_micro, g_liquidity, g_momentum, g_regime);
   g_confidence.SetThresholds(InpEntryThreshold, InpMinScoreGap, g_effMaxSpreadPoints,
                               InpMaxSpreadExpansion, g_effMinAtrPoints);

   g_risk.Init(InpRiskPerTradePct, InpMaxDailyLossPct, InpMaxConsecutiveLosses, InpMaxOpenPositions,
               InpMaxTradesPerMinute, InpMaxTradesPerSession, InpMaxFlipsPerMinute,
               InpMaxDrawdownPct, InpBaseCooldownSec);

   g_execution.Init(InpMagicNumber, InpDeviationPoints, InpMaxRetries, InpRetryDelayMs);

   g_exit.Init(InpMaxHoldingSec, InpTrailStartPoints, InpTrailDistancePoints, InpBreakevenTriggerPoints,
               InpBreakevenLockPoints, InpExitThreshold, InpExitSpreadMultiplier,
               InpMomentumExitEnabled, InpOppositeSignalExitEnabled);

   g_adaptive.Init(InpEntryThreshold, InpExitThreshold, InpTickWindow, InpMaxHoldingSec,
                    InpTrailDistancePoints, InpBaseCooldownSec, InpMaxFlipsPerMinute);

   string journalPath = "AutopsyX\\" + _Symbol + "_journal.csv";
   g_autopsy.Init(journalPath, InpSlippageFailurePts, InpSpreadFailurePts);

   if(InpShowDashboard)
   {
      g_dashboard.Init("AXDash_" + _Symbol + "_", 20, 20);
      EventSetMillisecondTimer(MathMax(200, InpDashboardRefreshMs));
   }

   AXPositionState emptyPos;
   g_position = emptyPos;

   if(InpLiveCalibrationEnabled)
   {
      g_calibration.Init(InpCalibrationMinutes * 60, InpMinCalibrationSamples);
      g_calibration.Start(TimeTradeServer());
      g_calibrationDone = false;
      g_status = AX_STATUS_CALIBRATING;
      PrintFormat("AutopsyX: live calibration started - measuring real spread for %d minutes before any trade is considered",
                  InpCalibrationMinutes);
   }
   else
   {
      g_calibrationDone = true;
      g_status = InpEnableTrading ? AX_STATUS_ACTIVE : AX_STATUS_PAUSED;
   }

   PrintFormat("AutopsyX HFT Flip Engine initialized on %s (%s)", _Symbol, EnumToString(InpStructureTimeframe));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   g_regime.Deinit();
   if(InpShowDashboard) g_dashboard.Deinit();

   string report = g_autopsy.GenerateReport();
   Print(report);

   int fh = FileOpen("AutopsyX\\" + _Symbol + "_report.txt", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(fh != INVALID_HANDLE)
   {
      FileWriteString(fh, report);
      FileClose(fh);
   }
   g_autopsy.Deinit();
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(!g_market.OnTick()) return;

   g_risk.Heartbeat();
   g_micro.Update(g_market.ticks);

   if(!g_calibrationDone)
   {
      g_calibration.Feed(g_micro.SpreadCurrentPts());
      if(g_calibration.CheckComplete(TimeTradeServer()))
         FinishCalibration();
   }

   if(g_market.IsNewBar())
   {
      MqlRates rates[];
      int n = g_market.CopyRatesOut(rates);
      if(n > 0)
      {
         g_liquidity.OnNewBar(rates, n);
         g_momentum.OnNewBar(rates, n);
         g_regime.OnNewBar(rates, n);
      }
   }

   g_confidence.Update();

   ManageOpenPosition();

   if(g_risk.KillSwitchActive())
      g_status = AX_STATUS_LOCKED;
   else if(!g_calibrationDone)
      g_status = AX_STATUS_CALIBRATING;
   else if(!InpEnableTrading)
      g_status = AX_STATUS_PAUSED;
   else
      g_status = AX_STATUS_ACTIVE;

   if(g_status == AX_STATUS_ACTIVE)
      EvaluateEntry();
}

//+------------------------------------------------------------------+
void OnTimer()
{
   if(!InpShowDashboard) return;

   AXDashboardData d;
   d.status          = g_status;
   d.regime          = g_regime.CurrentRegime();
   d.direction       = g_confidence.Direction();
   d.buyScore        = g_confidence.BuyScore();
   d.sellScore       = g_confidence.SellScore();
   d.confidence      = g_confidence.Confidence();
   d.spreadPts       = g_micro.SpreadCurrentPts();
   d.tickVelocity    = g_micro.TickVelocity();
   d.momentumBias    = g_momentum.MomentumBias();
   d.tradesToday     = g_risk.TradesToday();
   d.winRatePct      = g_autopsy.WinRatePct();
   d.dailyPL         = g_risk.DailyPL();
   d.drawdownPct     = g_risk.EquityDrawdownPct();
   d.currentPosition = g_position.active ? g_position.direction : AX_DIR_NONE;
   d.holdTimeSec     = g_position.active ? (int)(TimeTradeServer() - g_position.open_time) : 0;
   if(g_position.active)
      d.exitMode = CurrentExitModeLabel();
   else if(!g_calibrationDone)
      d.exitMode = StringFormat("CALIBRATING (%d sec left, %d samples)",
                                 g_calibration.RemainingSeconds(TimeTradeServer()), g_calibration.SampleCount());
   else
      d.exitMode = "--";

   d.statusNote      = g_risk.KillSwitchActive() ? g_risk.KillReason() : "";

   g_dashboard.Update(d);
}

//+------------------------------------------------------------------+
double OnTester()
{
   Print(g_autopsy.GenerateReport());
   return TesterStatistics(STAT_PROFIT);
}

//====================== POSITION MANAGEMENT ===========================
void ManageOpenPosition(void)
{
   if(!g_position.active) return;

   if(!PositionSelectByTicket(g_position.ticket))
   {
      // position vanished (SL/TP hit, manual close, etc.) - reconcile from history
      FinalizeClosedPosition(AX_EXIT_NONE);
      return;
   }

   double currentPrice = (g_position.direction == AX_DIR_BUY) ? g_market.Bid() : g_market.Ask();

   ENUM_AX_EXIT_REASON reason;
   if(g_risk.KillSwitchActive())
      reason = AX_EXIT_RISK_SHUTDOWN;
   else
      reason = g_exit.Evaluate(g_position, g_micro.SpreadCurrentPts(), g_effMaxSpreadPoints,
                                g_confidence.BuyScore(), g_confidence.SellScore(),
                                g_momentum.MomentumBias(), g_micro.MomentumExhausted());

   if(reason != AX_EXIT_NONE)
   {
      ClosePositionNow(reason);
      return;
   }

   double newSL;
   if(g_exit.CheckBreakeven(g_profile, g_position, currentPrice, newSL))
   {
      if(g_execution.ModifyPosition(g_profile, g_position.ticket, newSL, g_position.tp))
      {
         g_position.sl = newSL;
         g_position.breakeven_done = true;
      }
   }
   else if(g_exit.CheckTrailing(g_profile, g_position, currentPrice, newSL))
   {
      if(g_execution.ModifyPosition(g_profile, g_position.ticket, newSL, g_position.tp))
         g_position.sl = newSL;
   }
}

void ClosePositionNow(const ENUM_AX_EXIT_REASON reason)
{
   string err;
   g_execution.ClosePosition(g_profile, g_position.ticket, err);
   if(err != "") PrintFormat("AutopsyX: close issue - %s", err);
   FinalizeClosedPosition(reason);
}

void FinalizeClosedPosition(const ENUM_AX_EXIT_REASON fallbackReason)
{
   AXTradeRecord rec;
   rec.ticket               = g_position.ticket;
   rec.open_time            = g_position.open_time;
   rec.direction            = g_position.direction;
   rec.requested_price      = g_position.requested_price;
   rec.filled_price         = g_position.entry_price;
   rec.lots                 = g_position.lots;
   rec.spread_at_entry      = g_position.spread_at_entry;
   rec.buy_score_at_entry   = g_position.entry_snapshot.buy_score;
   rec.sell_score_at_entry  = g_position.entry_snapshot.sell_score;
   rec.regime_at_entry      = g_position.entry_snapshot.regime;
   rec.signal_to_order_ms   = g_position.order_submit_msc - g_position.signal_time_msc;
   rec.order_to_fill_ms     = g_position.order_fill_msc - g_position.order_submit_msc;

   double entrySlipPts = (g_position.direction == AX_DIR_BUY)
      ? g_profile.PriceToPoints(g_position.entry_price - g_position.requested_price)
      : g_profile.PriceToPoints(g_position.requested_price - g_position.entry_price);
   rec.slippage_points = MathAbs(entrySlipPts);

   double profit = 0.0;
   datetime closeTime = TimeTradeServer();
   double closePrice = (g_position.direction == AX_DIR_BUY) ? g_market.Bid() : g_market.Ask();
   ENUM_AX_EXIT_REASON reason = fallbackReason;

   if(HistorySelectByPosition(g_position.ticket))
   {
      int deals = HistoryDealsTotal();
      for(int i = deals - 1; i >= 0; i--)
      {
         ulong dealTicket = HistoryDealGetTicket(i);
         if(dealTicket == 0) continue;
         long entryType = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
         if(entryType == DEAL_ENTRY_OUT || entryType == DEAL_ENTRY_INOUT)
         {
            profit += HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                    + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                    + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
            closePrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
            closeTime  = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
            long dealReason = HistoryDealGetInteger(dealTicket, DEAL_REASON);
            if(fallbackReason == AX_EXIT_NONE)
            {
               if(dealReason == DEAL_REASON_SL) reason = AX_EXIT_STOP_LOSS;
               else if(dealReason == DEAL_REASON_TP) reason = AX_EXIT_TAKE_PROFIT;
               else reason = AX_EXIT_MANUAL;
            }
            break;
         }
      }
   }

   rec.exit_price      = closePrice;
   rec.close_time      = closeTime;
   rec.profit          = profit;
   rec.holding_seconds = (int)(closeTime - g_position.open_time);
   rec.exit_reason     = reason;

   g_autopsy.OnTradeClosed(rec);
   g_risk.RegisterTradeClosed(profit);
   RegisterAdaptiveSample(profit >= 0.0);

   AXPositionState emptyPos;
   g_position = emptyPos;
}

//====================== LIVE CALIBRATION ===============================
// Demo and live execution are not the same thing - most brokers simulate
// friendlier fills on a demo server. Rather than trade on guessed static
// thresholds, the EA measures this account's real spread for a warm-up
// window (no trades placed) and derives its gates from that measurement.
void FinishCalibration(void)
{
   g_effMaxSpreadPoints       = g_calibration.EffectiveMaxSpreadPts(InpSpreadToleranceMultiplier, InpMaxSpreadPoints);
   g_effMinDisplacementPoints = g_calibration.EffectiveMinDisplacementPts(InpDisplacementCostMultiplier, InpMinDisplacementPoints);
   g_effMinAtrPoints          = g_calibration.EffectiveMinAtrPts(InpAtrCostMultiplier, InpMinAtrPoints);
   int effDeviation           = g_calibration.EffectiveDeviationPoints(InpDeviationToleranceMultiplier, InpDeviationPoints);

   g_confidence.SetThresholds(InpEntryThreshold, InpMinScoreGap, g_effMaxSpreadPoints,
                               InpMaxSpreadExpansion, g_effMinAtrPoints);
   g_execution.SetDeviationPoints(effDeviation);

   g_calibrationDone = true;

   if(g_calibration.HasEnoughData())
   {
      PrintFormat("AutopsyX: live calibration complete on %s - median spread %.1f pts, P90 %.1f pts (%d samples). "
                  "Gates set to: max spread %.1f pts, min displacement %.1f pts, min ATR %.1f pts, deviation %d pts.",
                  _Symbol, g_calibration.MedianSpreadPts(), g_calibration.P90SpreadPts(), g_calibration.SampleCount(),
                  g_effMaxSpreadPoints, g_effMinDisplacementPoints, g_effMinAtrPoints, effDeviation);
   }
   else
   {
      PrintFormat("AutopsyX: calibration window elapsed with too few samples (%d) on %s - falling back to static inputs. "
                  "This symbol may be too illiquid for this engine, or the chart isn't receiving ticks.",
                  g_calibration.SampleCount(), _Symbol);
   }
}

//====================== ENTRY EVALUATION ==============================
void EvaluateEntry(void)
{
   if(g_position.active) return;
   if(!g_calibrationDone) return; // never trade on unmeasured live conditions

   ENUM_AX_DIRECTION dir = g_confidence.Direction();
   if(dir == AX_DIR_NONE) return;

   string riskReason;
   int ownOpen = CountOwnPositions();
   if(!g_risk.CanOpenNewTrade(ownOpen, riskReason))
      return;

   datetime now = TimeTradeServer();
   double mid = g_market.Mid();
   if(g_lastDecisionTime != 0)
   {
      int elapsed = (int)(now - g_lastDecisionTime);
      if(elapsed < InpMinDecisionIntervalSec) return;
      double movedPts = g_profile.PriceToPoints(MathAbs(mid - g_lastDecisionPrice));
      if(movedPts < g_effMinDisplacementPoints) return;
   }

   double slPoints = InpStopLossPoints;
   double tpPoints = InpTakeProfitPoints;
   if(InpUseAtrStops && g_regime.AtrPts() > 0.0)
   {
      slPoints = g_regime.AtrPts() * InpSlAtrMultiplier;
      tpPoints = g_regime.AtrPts() * InpTpAtrMultiplier;
   }

   double lots = g_risk.LotsForRisk(g_profile, slPoints);

   string entryReason;
   if(!g_entry.Validate(g_profile, dir, lots, g_micro.SpreadCurrentPts(), g_micro.SpreadExpansionRatio(),
                         g_effMaxSpreadPoints, InpMaxSpreadExpansion, g_confidence.Direction(), entryReason))
      return; // conditions deteriorated between signal and execution - never chase

   AXSignalSnapshot snap = g_confidence.Snapshot();
   ulong signalMsc = GetMicrosecondCount() / 1000;

   double refPrice = (dir == AX_DIR_BUY) ? g_market.Ask() : g_market.Bid();
   double sl, tp;
   g_exit.InitialStops(g_profile, dir, refPrice, slPoints, tpPoints, sl, tp);

   AXExecResult res = g_execution.OpenMarketOrder(g_profile, dir, lots, sl, tp, "AutopsyX HFT");
   if(!res.success)
   {
      PrintFormat("AutopsyX: entry not filled - %s", res.comment);
      return;
   }

   ulong posTicket = ResolvePositionTicket(res.order_ticket);

   g_position.active          = true;
   g_position.ticket          = posTicket;
   g_position.direction       = dir;
   g_position.entry_price     = res.filled_price;
   g_position.lots            = lots;
   g_position.sl              = sl;
   g_position.tp              = tp;
   g_position.requested_price = res.requested_price;
   g_position.spread_at_entry = g_micro.SpreadCurrentPts();
   g_position.open_time       = now;
   g_position.breakeven_done  = false;
   g_position.trail_level     = 0.0;
   g_position.entry_snapshot  = snap;
   g_position.signal_time_msc  = signalMsc;
   g_position.order_submit_msc = res.submit_msc;
   g_position.order_fill_msc   = res.fill_msc;

   g_risk.RegisterTradeOpened();
   if(g_lastTradeDirection != AX_DIR_NONE && g_lastTradeDirection != dir)
      g_risk.RegisterFlip();
   g_lastTradeDirection = dir;

   g_lastDecisionTime = now;
   g_lastDecisionPrice = mid;
}

//====================== HELPERS ========================================
ulong ResolvePositionTicket(const ulong fallback)
{
   if(PositionSelect(_Symbol) && (long)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      return (ulong)PositionGetInteger(POSITION_TICKET);
   return fallback;
}

int CountOwnPositions(void)
{
   int c = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      c++;
   }
   return c;
}

string CurrentExitModeLabel(void)
{
   ENUM_AX_EXIT_REASON r = g_exit.Evaluate(g_position, g_micro.SpreadCurrentPts(), g_effMaxSpreadPoints,
                                            g_confidence.BuyScore(), g_confidence.SellScore(),
                                            g_momentum.MomentumBias(), g_micro.MomentumExhausted());
   if(r != AX_EXIT_NONE) return AXExitReasonToString(r);
   if(g_position.breakeven_done) return "TRAIL/BE";
   return "MOMENTUM/TIME";
}

void RegisterAdaptiveSample(const bool win)
{
   int cap = ArraySize(g_recentResults);
   g_recentResults[g_recentResultsHead] = win;
   g_recentResultsHead = (g_recentResultsHead + 1) % cap;
   if(g_recentResultsCount < cap) g_recentResultsCount++;

   g_tradesSinceAdaptiveUpdate++;
   if(!InpEnableAdaptive) return;
   if(g_tradesSinceAdaptiveUpdate < InpAdaptiveUpdateEveryTrades) return;

   int wins = 0;
   for(int i = 0; i < g_recentResultsCount; i++)
      if(g_recentResults[i]) wins++;
   double winRate = (g_recentResultsCount > 0) ? (100.0 * wins / g_recentResultsCount) : 0.0;

   g_adaptive.Update(winRate, g_recentResultsCount, g_regime.CurrentRegime());
   g_confidence.SetEntryThreshold(g_adaptive.EntryThreshold());
   g_exit.SetExitThreshold(g_adaptive.ExitThreshold());
   g_micro.SetWindow(g_adaptive.TickWindow());

   g_tradesSinceAdaptiveUpdate = 0;
}
