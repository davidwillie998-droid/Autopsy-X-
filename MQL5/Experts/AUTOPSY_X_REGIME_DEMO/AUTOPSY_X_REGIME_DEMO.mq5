//+------------------------------------------------------------------+
//| AUTOPSY_X_REGIME_DEMO.mq5                                           |
//| Reference/demo integration: shows how an EXISTING trading bot     |
//| attaches the AUTOPSY X QQQ/TQQQ Regime Engine as a gatekeeper,     |
//| per the FLIPDEMON-compatibility hierarchy (spec section 19):       |
//|                                                                    |
//|   EXISTING STRATEGY -> REQUEST TRADE -> REGIME ENGINE ->            |
//|   RISK GOVERNOR -> PERMISSION -> EXECUTION                         |
//|                                                                    |
//| ComputeOwnStrategySignal() below is a deliberately trivial EMA-    |
//| cross placeholder standing in for "the existing bot" - swap it     |
//| for your real strategy's own entry logic. Everything else here    |
//| (the gating pattern, the permission check, the risk-scaled sizing) |
//| is the actual point of this file, and is what you port into your  |
//| real EA alongside its own signal generation.                      |
//|                                                                    |
//| InpEnableLiveTrading defaults to false: this file is a reference   |
//| implementation, not something to run live unmodified.             |
//+------------------------------------------------------------------+
#property strict
#property copyright "AUTOPSY X"
#property version   "1.00"

#include <Trade/Trade.mqh>
#include <AutopsyX/AutopsyRegimeEngine.mqh>

//==================== CORE ====================
input long   InpMagicNumber       = 150920;
input bool   InpEnableLiveTrading = false;   // off by default - this is a demo/reference implementation
input string InpReferenceSymbol   = "";      // "" = use the chart's own symbol as the Nasdaq reference

//==================== REGIME ENGINE - OPTIONAL PROXY SYMBOLS ====================
input string InpQQQSymbol       = "QQQ";
input string InpTQQQSymbol      = "TQQQ";
input string InpVIXSymbol       = "";   // e.g. "VIX" if your broker offers it - "" degrades cleanly
input string InpDXYSymbol       = "";   // e.g. "USDX" - "" degrades cleanly
input string InpUS2YSymbol      = "";
input string InpUS10YSymbol     = "";
input string InpRealYieldSymbol = "";
input string InpBreadthBasket   = "";   // e.g. "AAPL,MSFT,NVDA,GOOGL,AMZN,META,AVGO" - "" disables breadth
input string InpCorrelatedList  = "QQQ,TQQQ:3.0,US100:1.0,NAS100:1.0";

//==================== RISK ====================
input double InpBaseRiskPercent        = 1.00;
input double InpMaxRiskPercentPerTrade = 1.50;
input double InpMaxAggregateExposure   = 8.00;

//==================== EVENTS ====================
input int InpPreEventBlackoutMinutes = 30;
input int InpPostEventRepriceMinutes = 30;

//==================== engine ====================
CAutopsyRegimeEngine g_engine;
CTrade               g_trade;
string               g_referenceSymbol;

//+------------------------------------------------------------------+
int OnInit()
  {
   g_referenceSymbol = (InpReferenceSymbol=="") ? _Symbol : InpReferenceSymbol;

   AXRConfig cfg = AXRDefaultConfig(StringFormat("DEMO_%s_%I64d", g_referenceSymbol, InpMagicNumber), g_referenceSymbol);
   cfg.qqqSymbol = InpQQQSymbol; cfg.tqqqSymbol = InpTQQQSymbol;
   cfg.vixSymbol = InpVIXSymbol; cfg.dxySymbol = InpDXYSymbol;
   cfg.y2Symbol = InpUS2YSymbol; cfg.y10Symbol = InpUS10YSymbol; cfg.realYieldSymbol = InpRealYieldSymbol;
   cfg.breadthBasketCsv = InpBreadthBasket; cfg.correlatedListCsv = InpCorrelatedList;
   cfg.baseRiskPercent = InpBaseRiskPercent; cfg.maxRiskPercentPerTrade = InpMaxRiskPercentPerTrade;
   cfg.maxAggregateExposurePct = InpMaxAggregateExposure;
   cfg.preEventBlackoutMinutes = InpPreEventBlackoutMinutes; cfg.postEventRepriceMinutes = InpPostEventRepriceMinutes;

   g_engine.Init(cfg);
   g_trade.SetExpertMagicNumber((ulong)InpMagicNumber);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   g_engine.Deinit();
  }

//+------------------------------------------------------------------+
//| Stand-in for "the existing bot's own entry logic" - a plain H1    |
//| EMA20/EMA50 cross. Replace this one function with your real       |
//| strategy's signal; nothing downstream of it needs to change.      |
//+------------------------------------------------------------------+
int ComputeOwnStrategySignal()
  {
   int fastHandle = iMA(g_referenceSymbol, PERIOD_H1, 20, 0, MODE_EMA, PRICE_CLOSE);
   int slowHandle = iMA(g_referenceSymbol, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE);
   if(fastHandle==INVALID_HANDLE || slowHandle==INVALID_HANDLE) return 0;

   int signal = 0;
   double fastBuf[], slowBuf[];
   if(CopyBuffer(fastHandle,0,0,1,fastBuf)>0 && CopyBuffer(slowHandle,0,0,1,slowBuf)>0)
      signal = (fastBuf[0]>slowBuf[0]) ? 1 : -1;

   IndicatorRelease(fastHandle);
   IndicatorRelease(slowHandle);
   return signal;
  }

bool HasOpenPosition()
  {
   for(int i=0;i<PositionsTotal();i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)==InpMagicNumber) return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   g_engine.UpdateMarketState();

   // SAFETY > REGIME > RISK > STRATEGY > ENTRY > EXECUTION (section 19): the existing strategy's own
   // signal is only a REQUEST - the regime engine and its risk governor decide whether it fires at all,
   // and how large, before anything reaches the broker.
   int ownSignal = ComputeOwnStrategySignal();
   if(ownSignal==0 || HasOpenPosition())
     {
      g_engine.LogDecision(ownSignal==0 ? "NO_REQUEST" : "POSITION_OPEN");
      return;
     }

   AXRPermission p = g_engine.GetPermission();
   bool approved = (ownSignal>0 && p.allowLong) || (ownSignal<0 && p.allowShort);
   g_engine.LogDecision(approved ? "APPROVE" : "REJECT");

   if(!approved || !InpEnableLiveTrading) return;

   // position sizing off the engine's own risk-governed percentage, not the strategy's own guess -
   // this is the whole point: the strategy proposes a direction, AUTOPSY X decides how much
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * (p.finalRiskPercent/100.0);
   if(riskMoney<=0.0) return;

   int atrHandle = iATR(_Symbol, PERIOD_H1, 14);
   if(atrHandle==INVALID_HANDLE) return;
   double atrBuf[];
   if(CopyBuffer(atrHandle,0,0,1,atrBuf)<=0) { IndicatorRelease(atrHandle); return; }
   double stopDistPrice = atrBuf[0]*1.5;
   IndicatorRelease(atrHandle);
   if(stopDistPrice<=0.0) return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(point<=0.0 || tickSize<=0.0 || tickValue<=0.0) return;

   double pointValue = tickValue*(point/tickSize);
   double stopPoints = stopDistPrice/point;
   if(stopPoints<=0.0 || pointValue<=0.0) return;

   double volume = riskMoney/(stopPoints*pointValue);
   double volMin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double volMax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(volStep>0.0) volume = MathFloor(volume/volStep)*volStep;
   volume = MathMax(volMin, MathMin(volMax, volume));
   if(volume<volMin) return;

   double price = ownSignal>0 ? SymbolInfoDouble(_Symbol,SYMBOL_ASK) : SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double sl = ownSignal>0 ? price-stopDistPrice : price+stopDistPrice;

   if(ownSignal>0) g_trade.Buy(volume, _Symbol, 0.0, sl, 0.0, "AXR-DEMO");
   else            g_trade.Sell(volume, _Symbol, 0.0, sl, 0.0, "AXR-DEMO");
  }
