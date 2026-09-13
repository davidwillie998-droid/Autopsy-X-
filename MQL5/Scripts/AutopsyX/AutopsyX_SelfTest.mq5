//+------------------------------------------------------------------+
//|                                   AutopsyX_SelfTest.mq5           |
//| Exercises each major AUTOPSY X engine independently against       |
//| synthetic data. Places NO orders. Run from the Navigator on any   |
//| chart to sanity-check the build after changes.                    |
//+------------------------------------------------------------------+
#property copyright "AUTOPSY X"
#property version   "1.00"
#property script_show_inputs

#include <AutopsyX/Defines.mqh>
#include <AutopsyX/SymbolProfile.mqh>
#include <AutopsyX/TickBuffer.mqh>
#include <AutopsyX/MicrostructureEngine.mqh>
#include <AutopsyX/LiquidityEngine.mqh>
#include <AutopsyX/MomentumEngine.mqh>
#include <AutopsyX/RiskEngine.mqh>
#include <AutopsyX/EntryEngine.mqh>
#include <AutopsyX/ExitEngine.mqh>
#include <AutopsyX/AdaptiveEngine.mqh>
#include <AutopsyX/AutopsyEngine.mqh>
#include <AutopsyX/LiveCalibrationEngine.mqh>

int g_pass = 0, g_fail = 0;

void Check(const bool cond, const string testName)
{
   if(cond) { g_pass++; PrintFormat("[PASS] %s", testName); }
   else     { g_fail++; PrintFormat("[FAIL] %s", testName); }
}

//--- builds a synthetic descending-then-recovering rates series (series order, idx0=newest forming)
void BuildSweepRecoverySeries(MqlRates &r[], const double basePrice, const double point)
{
   ArrayResize(r, 40);
   datetime t = TimeCurrent();
   for(int i = 0; i < 40; i++)
   {
      double drift = (39 - i) * 2 * point;   // gentle downward slope further back in time
      r[i].time  = t - i * 60;
      r[i].open  = basePrice + drift;
      r[i].close = basePrice + drift;
      r[i].high  = basePrice + drift + 3 * point;
      r[i].low   = basePrice + drift - 3 * point;
   }
   // establish a clean prior low around index 5..24 (used as lookback window by LiquidityEngine)
   for(int i = 5; i < 25; i++)
   {
      r[i].low = basePrice - 20 * point;
      r[i].high = basePrice - 10 * point;
      r[i].open = basePrice - 15 * point;
      r[i].close = basePrice - 14 * point;
   }
   // idx1 = the bar that just closed: sweeps below prior low, rejects, closes back above it
   r[1].low   = basePrice - 30 * point;   // wicks well below prior low
   r[1].open  = basePrice - 14 * point;
   r[1].close = basePrice - 5 * point;    // closes back above prior low with a bullish body
   r[1].high  = basePrice - 4 * point;

   // idx0 = forming bar, irrelevant to the closed-bar logic
   r[0].open = r[0].close = r[0].high = r[0].low = basePrice - 5 * point;
}

void BuildBullishStructureSeries(MqlRates &r[], const double basePrice, const double point)
{
   ArrayResize(r, 40);
   datetime t = TimeCurrent();
   for(int i = 0; i < 40; i++)
   {
      double level = basePrice - (39 - i) * 6 * point; // rising into the present
      r[i].time  = t - i * 60;
      r[i].open  = level - 2 * point;
      r[i].close = level + 2 * point;
      r[i].high  = level + 5 * point;
      r[i].low   = level - 5 * point;
   }
}

void TestSymbolProfile(void)
{
   CAXSymbolProfile p;
   bool ok = p.Init(_Symbol);
   Check(ok, "SymbolProfile.Init succeeds on current chart symbol");
   Check(p.point > 0.0, "SymbolProfile.point > 0");
   Check(p.tick_size > 0.0, "SymbolProfile.tick_size > 0");
   Check(p.contract_size > 0.0, "SymbolProfile.contract_size > 0");
   Check(MathAbs(p.PriceToPoints(p.PointsToPrice(10.0)) - 10.0) < 0.0001, "Points <-> price round-trip");
   double vol = p.NormalizeVolume(p.volume_min / 2.0);
   Check(vol >= p.volume_min, "NormalizeVolume clamps below minimum up to volume_min");
}

void TestTickBuffer(void)
{
   CAXTickBuffer buf;
   buf.Init(16);
   for(int i = 0; i < 20; i++)
      buf.Push(TimeCurrent(), (ulong)(GetTickCount()) + i, 1.1000 + i * 0.0001, 1.1002 + i * 0.0001);

   Check(buf.Count() == 16, "TickBuffer caps at capacity");
   AXTickSample latest;
   buf.Get(0, latest);
   Check(MathAbs(latest.bid - (1.1000 + 19 * 0.0001)) < 0.00001, "TickBuffer.Get(0) returns most recent sample");
}

void TestMicrostructure(void)
{
   CAXSymbolProfile p;
   p.Init(_Symbol);
   CAXTickBuffer buf;
   buf.Init(64);
   double price = 1.1000;
   for(int i = 0; i < 30; i++)
   {
      price += p.point * 2; // strictly increasing -> bullish tick stream
      buf.Push(TimeCurrent() + i, (ulong)(1000 + i * 50), price, price + p.point * 2);
   }
   CAXMicrostructure micro;
   micro.Init(p, 30);
   micro.Update(buf);

   Check(micro.TickDirection() == 1, "Microstructure detects bullish last-tick direction");
   Check(micro.ConsecutiveDirectionalTicks() > 0, "Microstructure counts consecutive bullish ticks");
   Check(micro.TickImbalance() > 0.5, "Microstructure tick imbalance skews bullish on a monotonic run");
   Check(micro.PriceDisplacementPts() > 0.0, "Microstructure displacement is positive on an uptrend");
}

void TestLiquidityEngine(void)
{
   CAXSymbolProfile p;
   p.Init(_Symbol);
   MqlRates rates[];
   BuildSweepRecoverySeries(rates, 1.1000, p.point);

   CAXLiquidity liq;
   liq.Init(p, 20, 3);
   liq.OnNewBar(rates, ArraySize(rates));
   Check(liq.HasPendingSweep() || liq.LiquidityFlipSignal() != AX_DIR_NONE,
         "Liquidity engine arms or fires after a sweep+rejection bar");

   // feed a follow-through bullish displacement bar to confirm the sequence
   MqlRates rates2[];
   ArrayCopy(rates2, rates);
   for(int i = ArraySize(rates2) - 1; i > 0; i--) rates2[i] = rates2[i - 1];
   rates2[1].open = 1.1000 - 5 * p.point;
   rates2[1].close = 1.1000 + 15 * p.point;
   rates2[1].high = 1.1000 + 16 * p.point;
   rates2[1].low = 1.1000 - 6 * p.point;
   liq.OnNewBar(rates2, ArraySize(rates2));
   Check(liq.LiquidityFlipSignal() == AX_DIR_BUY || liq.HasPendingSweep(),
         "Liquidity flip confirms bullish or is still legitimately waiting within its window");
}

void TestMomentumEngine(void)
{
   CAXSymbolProfile p;
   p.Init(_Symbol);
   MqlRates rates[];
   BuildBullishStructureSeries(rates, 1.1000, p.point);

   CAXMomentum mom;
   mom.Init(p, 30);
   mom.OnNewBar(rates, ArraySize(rates));
   Check(mom.StructureBias() >= 0, "Momentum structure bias is non-bearish on a rising series");
}

void TestRiskEngine(void)
{
   CAXRisk risk;
   risk.Init(0.5, 3.0, 3, 1, 6, 60, 4, 8.0, 10);
   string reason;
   Check(risk.CanOpenNewTrade(0, reason), "Risk engine allows a fresh trade with no state");

   risk.RegisterTradeClosed(-10.0);
   risk.RegisterTradeClosed(-10.0);
   risk.RegisterTradeClosed(-10.0);
   Check(risk.ConsecutiveLosses() == 3, "Risk engine tracks consecutive losses");
   Check(!risk.CanOpenNewTrade(0, reason), "Risk engine blocks trading after consecutive-loss limit");

   risk.RegisterTradeClosed(50.0);
   Check(risk.ConsecutiveLosses() == 0, "A winning trade resets the consecutive-loss counter");

   risk.TriggerKillSwitch("unit test");
   Check(risk.KillSwitchActive(), "Manual kill switch trigger engages");
   Check(!risk.CanOpenNewTrade(0, reason), "Kill switch blocks new trades");
   risk.ManualReset();
   Check(!risk.KillSwitchActive(), "Manual reset clears the kill switch");
}

void TestAdaptiveEngine(void)
{
   CAXAdaptive adaptive;
   adaptive.Init(65.0, 50.0, 80, 300, 25.0, 15, 4);

   for(int i = 0; i < 50; i++)
      adaptive.Update(20.0, 20, AX_REGIME_CHAOTIC); // hammer it with the worst-case inputs repeatedly

   Check(adaptive.EntryThreshold() <= AX_ADAPT_ENTRY_THRESH_MAX, "Adaptive entry threshold respects hard max");
   Check(adaptive.EntryThreshold() >= AX_ADAPT_ENTRY_THRESH_MIN, "Adaptive entry threshold respects hard min");
   Check(adaptive.CooldownSec() <= AX_ADAPT_COOLDOWN_MAX_SEC, "Adaptive cooldown respects hard max");
   Check(adaptive.TickWindow() <= AX_ADAPT_TICKWINDOW_MAX, "Adaptive tick window respects hard max");
}

void TestAutopsyEngine(void)
{
   CAXAutopsy autopsy;
   AXTradeRecord rec;
   rec.slippage_points = 1.0;
   rec.spread_at_entry = 5.0;
   rec.profit = 20.0;
   rec.exit_reason = AX_EXIT_TAKE_PROFIT;
   Check(autopsy.Classify(rec) == AX_TAG_TAKE_PROFIT, "Autopsy tags a profitable TP exit correctly");

   rec.exit_reason = AX_EXIT_STOP_LOSS;
   rec.profit = -15.0;
   Check(autopsy.Classify(rec) == AX_TAG_STOP_LOSS, "Autopsy tags a stop-loss exit correctly");

   rec.exit_reason = AX_EXIT_RISK_SHUTDOWN;
   Check(autopsy.Classify(rec) == AX_TAG_RISK_SHUTDOWN, "Autopsy tags a risk shutdown correctly regardless of P/L");

   rec.exit_reason = AX_EXIT_MOMENTUM;
   rec.slippage_points = 20.0; // exceeds default failure threshold
   Check(autopsy.Classify(rec) == AX_TAG_SLIPPAGE_FAILURE, "Autopsy flags excessive slippage ahead of exit-reason logic");
}

void TestEntryEngineRejectsNoDirection(void)
{
   CAXSymbolProfile p;
   p.Init(_Symbol);
   CAXEntry entry;
   double lots = 0.01;
   string reason;
   bool ok = entry.Validate(p, AX_DIR_NONE, lots, 1.0, 1.0, 30.0, 2.0, AX_DIR_NONE, reason);
   Check(!ok && reason != "", "Entry engine rejects a no-direction request with a reason");
}

void TestExitEngineStops(void)
{
   CAXSymbolProfile p;
   p.Init(_Symbol);
   CAXExit exitEngine;
   exitEngine.Init(300, 40, 25, 30, 5, 50, 1.8, true, true);

   double sl, tp;
   double entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(entryPrice <= 0.0) entryPrice = 1.1000;
   exitEngine.InitialStops(p, AX_DIR_BUY, entryPrice, 60, 90, sl, tp);
   Check(sl < entryPrice, "Buy stop-loss is placed below entry");
   Check(tp > entryPrice, "Buy take-profit is placed above entry");

   exitEngine.InitialStops(p, AX_DIR_SELL, entryPrice, 60, 90, sl, tp);
   Check(sl > entryPrice, "Sell stop-loss is placed above entry");
   Check(tp < entryPrice, "Sell take-profit is placed below entry");
}

void TestCalibrationEngine(void)
{
   CAXCalibration calib;
   calib.Init(60, 20); // 60s window, 20 samples minimum

   Check(!calib.CheckComplete(TimeCurrent()), "Calibration is not complete before it has started");
   calib.Start(TimeCurrent());
   Check(!calib.HasEnoughData(), "Calibration has no data immediately after starting");

   for(int i = 0; i < 100; i++)
   {
      double spread = 10.0 + (i % 5); // synthetic spread samples clustered 10-14 pts
      calib.Feed(spread);
   }
   Check(calib.HasEnoughData(), "Calibration accumulates enough samples from fed spreads");
   Check(calib.MedianSpreadPts() >= 10.0 && calib.MedianSpreadPts() <= 14.0, "Median spread falls within the fed sample range");
   Check(calib.P90SpreadPts() >= calib.MedianSpreadPts(), "P90 spread is never below the median");

   double eff = calib.EffectiveMaxSpreadPts(2.0, 999.0);
   Check(eff < 999.0 && eff > 0.0, "Effective max spread is derived from measurement, not the fallback");

   double fallback = calib.EffectiveMaxSpreadPts(2.0, 999.0);
   Check(fallback != 999.0, "Fallback value is only used when data is insufficient");

   CAXCalibration emptyCalib;
   emptyCalib.Init(60, 500); // demand more samples than we will feed
   emptyCalib.Start(TimeCurrent());
   emptyCalib.Feed(15.0);
   Check(emptyCalib.EffectiveMaxSpreadPts(2.0, 42.0) == 42.0, "Falls back to the static value when data is insufficient");
}

void OnStart()
{
   Print("===== AUTOPSY X SELF-TEST =====");
   TestSymbolProfile();
   TestTickBuffer();
   TestMicrostructure();
   TestLiquidityEngine();
   TestMomentumEngine();
   TestRiskEngine();
   TestAdaptiveEngine();
   TestAutopsyEngine();
   TestCalibrationEngine();
   TestEntryEngineRejectsNoDirection();
   TestExitEngineStops();

   PrintFormat("===== RESULT: %d passed, %d failed =====", g_pass, g_fail);
   if(g_fail == 0)
      Print("ALL COMPONENT TESTS PASSED");
   else
      Print("SOME TESTS FAILED - review log above");
}
