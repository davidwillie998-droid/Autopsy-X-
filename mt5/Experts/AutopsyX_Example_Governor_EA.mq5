//+------------------------------------------------------------------+
//|                          AutopsyX_Example_Governor_EA.mq5         |
//|  Reference wiring example for AUTOPSY X (spec section 22).         |
//|                                                                     |
//|  This is NOT meant to be your trading strategy. The entry logic    |
//|  below (a plain fast/slow EMA cross) is a deliberately generic     |
//|  stand-in for "your existing EA's signal" — swap that one block    |
//|  out for your real bot's own entry logic and keep everything else.|
//|                                                                     |
//|  What actually matters, and what you should copy into your real   |
//|  EA's OnInit/OnDeinit/OnTick, is the AUTOPSY X call sequence:      |
//|    InitializeRegimeEngine(...) once in OnInit()                    |
//|    UpdateMarketState() once per bar in OnTick()                    |
//|    AllowNewTrade() / AllowLong() / AllowShort() gating your signal |
//|    GetFinalRiskPct() sizing whatever you were about to send        |
//|    ShutdownRegimeEngine() in OnDeinit()                            |
//|                                                                     |
//|  Hierarchy (spec section 19): SAFETY > REGIME > RISK > STRATEGY >  |
//|  ENTRY > EXECUTION. Your strategy proposes; this engine disposes.  |
//+------------------------------------------------------------------+
#property copyright "AUTOPSY X"
#property strict
#property version   "1.00"

#include <Trade/Trade.mqh>
#include "../Include/AutopsyX/AutopsyRegimeEngineCore.mqh"

//--- Instrument / timeframe this governor watches. Point it at whatever
//    your broker actually calls the Nasdaq-100 proxy you trade.
input string           InpQqqSymbol        = "QQQ";
input ENUM_TIMEFRAMES  InpTimeframe        = PERIOD_D1;
input string           InpVixSymbol        = "";        // leave blank if your broker doesn't offer one
input string           InpDxySymbol        = "";        // leave blank if your broker doesn't offer one
input bool             InpHasRangeStrategy = false;      // set true only if you actually have a dedicated chop/range playbook

//--- Position sizing
input double           InpBaseRiskPct      = 1.0;        // percent of equity at full (unthrottled) risk
input double           InpAtrStopMultiple  = 2.0;         // this example EA's own stop distance, ATR-based
input ulong            InpMagic            = 990001;

//--- This example's own generic stand-in signal (replace with your real EA)
input int              InpFastEmaPeriod    = 10;
input int              InpSlowEmaPeriod    = 30;

CTrade   trade;
int      g_fastEmaHandle, g_slowEmaHandle, g_atrHandle;
datetime g_lastBarTime;

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber((long)InpMagic);

   bool ok = InitializeRegimeEngine(InpQqqSymbol, InpTimeframe, InpBaseRiskPct,
                                     InpVixSymbol, InpDxySymbol, InpHasRangeStrategy,
                                     "AutopsyX_Decisions.log");
   if(!ok)
     {
      Print("AUTOPSY X: engine failed to initialize — check InpQqqSymbol is a valid, selectable symbol.");
      return(INIT_FAILED);
     }

   g_fastEmaHandle = iMA(InpQqqSymbol, InpTimeframe, InpFastEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_slowEmaHandle = iMA(InpQqqSymbol, InpTimeframe, InpSlowEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_atrHandle     = iATR(InpQqqSymbol, InpTimeframe, 14);
   if(g_fastEmaHandle == INVALID_HANDLE || g_slowEmaHandle == INVALID_HANDLE || g_atrHandle == INVALID_HANDLE)
     {
      Print("AUTOPSY X example EA: indicator handle creation failed.");
      return(INIT_FAILED);
     }

   g_lastBarTime = 0;
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   ShutdownRegimeEngine();
   IndicatorRelease(g_fastEmaHandle);
   IndicatorRelease(g_slowEmaHandle);
   IndicatorRelease(g_atrHandle);
  }

bool IsNewBar()
  {
   datetime t = iTime(InpQqqSymbol, InpTimeframe, 0);
   if(t != g_lastBarTime) { g_lastBarTime = t; return true; }
   return false;
  }

double HandleLast(int handle)
  {
   double buf[];
   if(CopyBuffer(handle, 0, 0, 1, buf) < 1) return 0.0;
   return buf[0];
  }

//--- A plain risk% + ATR-stop position-sizing helper. Your real EA almost
//    certainly already has one of these — this exists only so the example
//    is runnable end to end.
double CalculateLots(string symbol, double riskPct, double stopDistancePrice)
  {
   if(riskPct <= 0.0 || stopDistancePrice <= 0.0) return 0.0;
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * riskPct / 100.0;

   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0) return 0.0;

   double moneyPerLotAtStop = (stopDistancePrice / tickSize) * tickValue;
   if(moneyPerLotAtStop <= 0.0) return 0.0;

   double lots = riskMoney / moneyPerLotAtStop;

   double stepLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   if(stepLot > 0.0) lots = MathFloor(lots / stepLot) * stepLot;
   lots = AxClamp(lots, minLot, maxLot);
   return lots;
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(!IsNewBar())
      return;

   //--- 1. Refresh every AUTOPSY X read for this bar.
   UpdateMarketState();
   Comment(GetLastDecisionLog());

   //--- 2. Your (stand-in) strategy proposes a side. Replace this block with
   //       your real EA's own signal — everything below this point is the
   //       part that actually needs to stay.
   double emaFast = HandleLast(g_fastEmaHandle);
   double emaSlow = HandleLast(g_slowEmaHandle);
   bool wantLong  = (emaFast > emaSlow);
   bool wantShort = (emaFast < emaSlow);

   //--- 3. AUTOPSY X gates it. This is the whole point of the module.
   if(!AllowNewTrade())
      return; // capital-preservation mode, a halt, an event blackout, or missing critical data

   bool haveOpenPosition = PositionSelect(InpQqqSymbol);
   if(haveOpenPosition)
      return; // this example only ever holds one position at a time; your real EA manages its own book

   double atr = HandleLast(g_atrHandle);
   if(atr <= 0.0)
      return;
   double stopDistance = atr * InpAtrStopMultiple;

   double riskPct = GetFinalRiskPct(); // already regime x confidence x volatility x correlation x drawdown x event
   double lots = CalculateLots(InpQqqSymbol, riskPct, stopDistance);
   if(lots <= 0.0)
      return;

   double ask = SymbolInfoDouble(InpQqqSymbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(InpQqqSymbol, SYMBOL_BID);

   if(wantLong && AllowLong())
     {
      double sl = ask - stopDistance;
      trade.Buy(lots, InpQqqSymbol, ask, sl, 0.0, "AutopsyX gated long, regime=" + GetRegime());
     }
   else if(wantShort && AllowShort())
     {
      double sl = bid + stopDistance;
      trade.Sell(lots, InpQqqSymbol, bid, sl, 0.0, "AutopsyX gated short, regime=" + GetRegime());
     }
  }
