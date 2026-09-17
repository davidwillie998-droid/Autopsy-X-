//+------------------------------------------------------------------+
//|                                       AutopsyX_Example_EA.mq5    |
//|  AUTOPSY X — Example Integration                                 |
//|  Spec sections 2, 19, 22.                                        |
//|                                                                    |
//|  This is a WIRING EXAMPLE, not a trading strategy. It shows the  |
//|  hierarchy from spec section 19:                                  |
//|                                                                    |
//|      YOUR EA's SIGNAL LOGIC                                       |
//|             |                                                     |
//|             v                                                     |
//|      REQUEST TRADE  ->  AUTOPSY X REGIME ENGINE  ->  RISK GOVERNOR |
//|             |                                                     |
//|             v                                                     |
//|         PERMISSION                                                |
//|             |                                                     |
//|             v                                                     |
//|         EXECUTION  (your EA's own OrderSend/CTrade code)          |
//|                                                                    |
//|  MyExistingStrategySignal() below stands in for whatever an        |
//|  existing EA (Flipdemon or otherwise) already does to decide it   |
//|  wants to buy or sell. AutopsyX never overrides that signal — it  |
//|  only decides whether it's allowed to act on it right now, and    |
//|  how large. This example deliberately stops short of a real       |
//|  OrderSend so it can't be copy-pasted straight into live trading  |
//|  — the TODO block marks exactly where your EA's own execution     |
//|  code belongs, unchanged.                                          |
//+------------------------------------------------------------------+
#property copyright "AUTOPSY X"
#property version   "1.00"
#property strict

#include <AutopsyX/AutopsyX.mqh>

//--- Instrument / data-feed inputs -----------------------------------------
input string InpSymbolPrice  = "QQQ";   // drives direction/efficiency/liquidity — swap for your broker's US100/NAS100 CFD if QQQ isn't listed
input string InpSymbolVix    = "";      // leave blank if your broker doesn't list one
input string InpSymbolDxy    = "";
input string InpSymbolUs2y   = "";      // broker CFD proxy, if offered
input string InpSymbolUs10y  = "";

//--- Risk / correlation inputs ----------------------------------------------
input string InpBotId                    = "AX_EXAMPLE_EA";
input double InpBaseRiskPct              = 1.0;   // % of equity risked at RISK_MULTIPLIER = 1.0
input double InpCorrelationLimitPctEquity = 15.0; // aggregate Nasdaq-equivalent exposure ceiling, all EAs on this terminal
input int    InpAggressiveMinConfidence   = 60;
input bool   InpAllowRangeStrategy        = false; // set true only if YOUR EA has a dedicated chop/range strategy

//--- Manual event calendar (used whenever the broker's own calendar feed
//    isn't available — see AutopsyEventFilter.mqh) --------------------------
input bool     InpScheduleNextFOMC = false;
input datetime InpNextFOMCTime     = 0;

//--- Alpha Vantage bridge (optional — see mt5/README.md and server/README.md)
//    Feeds real Treasury yields, Fed funds momentum, actual CPI, and a
//    breadth proxy through server/alphaVantage.js. Leave InpAvBridgeUrl
//    blank to skip this entirely; everything still works off broker CFD
//    symbols alone, just with the gaps mt5/README.md already documents.
input string InpAvBridgeUrl        = ""; // e.g. "http://127.0.0.1:8787" — must be WebRequest-whitelisted, see OnInit()
input string InpAvBridgeKey        = "";
input int    InpAvRefreshEveryBars = 24; // H1 chart -> refresh roughly once a day; adjust to your chart's timeframe

datetime g_last_bar_time = 0;
int      g_bars_since_av_refresh = 0;

int OnInit()
  {
   AxConfig cfg;
   cfg.Defaults();
   cfg.symbol_price = InpSymbolPrice;
   cfg.symbol_vix   = InpSymbolVix;
   cfg.symbol_dxy   = InpSymbolDxy;
   cfg.symbol_us2y  = InpSymbolUs2y;
   cfg.symbol_us10y = InpSymbolUs10y;
   cfg.bot_id        = InpBotId;
   cfg.base_risk_pct = InpBaseRiskPct;
   cfg.correlation_limit_pct_equity = InpCorrelationLimitPctEquity;
   cfg.aggressive_min_confidence    = InpAggressiveMinConfidence;
   cfg.regime_th.allow_range_strategy = InpAllowRangeStrategy;
   cfg.log_filename = "AutopsyX_" + InpBotId + "_Log.csv";
   cfg.av_bridge_url = InpAvBridgeUrl;
   cfg.av_bridge_key = InpAvBridgeKey;

   if(!InitializeRegimeEngine(cfg))
     {
      Print("AutopsyX: InitializeRegimeEngine failed — check symbol_price is a real, selectable symbol.");
      return INIT_FAILED;
     }

   if(InpScheduleNextFOMC && InpNextFOMCTime > 0)
      AddManualEvent(InpNextFOMCTime, "FOMC");

   if(StringLen(InpAvBridgeUrl) > 0)
     {
      // Fetch once at startup so the first UpdateMarketState() already has
      // real macro data instead of waiting a full InpAvRefreshEveryBars.
      if(!RefreshFromAlphaVantageBridge())
         Print("AutopsyX: initial Alpha Vantage bridge fetch failed — see the WebRequest guidance above if this is error 4060. "
               "Continuing on broker CFD symbols / manual inputs alone.");
     }

   Print("AutopsyX initialized for ", InpSymbolPrice, ". This EA is a wiring example — it does not place real orders.");
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   DeinitializeRegimeEngine();
  }

void OnTick()
  {
   // Recompute once per new bar — AutopsyX is built on daily-bar structure
   // (EMA20/50/200, 20-day breakout, etc.), so there's nothing to gain from
   // recomputing it every tick, and it only costs CPU.
   const datetime bar_time = iTime(InpSymbolPrice, PERIOD_D1, 0);
   if(bar_time == g_last_bar_time) return;
   g_last_bar_time = bar_time;

   if(StringLen(InpAvBridgeUrl) > 0)
     {
      g_bars_since_av_refresh++;
      if(g_bars_since_av_refresh >= InpAvRefreshEveryBars)
        {
         g_bars_since_av_refresh = 0;
         if(!RefreshFromAlphaVantageBridge())
            Print("AutopsyX: Alpha Vantage bridge refresh failed this cycle — macro engine keeps using its last-known data.");
        }
     }

   if(!UpdateMarketState())
     {
      Print("AutopsyX: UpdateMarketState failed this bar — treating as BLOCK.");
      return;
     }

   PrintFormat("AutopsyX | regime=%s bias=%s confidence=%.1f trend_eff=%.2f vol=%s macro=%.1f breadth=%.1f "
               "risk_mult=%.3f allow_long=%s allow_short=%s aggressive=%s shock=%s decision=%s (%s)",
               AxRegimeToString(GetRegime()), AxBiasToString(GetDirection()), GetConfidence(),
               GetTrendEfficiency(), AxVolStateToString(GetVolatilityState()), GetMacroScore(), GetBreadthScore(),
               GetRiskMultiplier(), (AllowLong() ? "true" : "false"), (AllowShort() ? "true" : "false"),
               (IsAggressiveModePermitted() ? "true" : "false"), (IsVolatilityShock() ? "true" : "false"),
               AxDecisionToString(GetDecision()), GetDecisionNote());

   if(!AllowNewTrade())
      return; // gatekeeper says stand down — nothing below this line runs

   //+------------------------------------------------------------+
   //| REQUEST TRADE: this stands in for your EA's own strategy.   |
   //+------------------------------------------------------------+
   const int signal = MyExistingStrategySignal(); // -1 = short, 0 = no signal, +1 = long

   if(signal > 0 && AllowLong())
      OnApprovedSignal(ORDER_TYPE_BUY, GetRiskMultiplier());
   else if(signal < 0 && AllowShort())
      OnApprovedSignal(ORDER_TYPE_SELL, GetRiskMultiplier());

   // Keep the correlation engine honest: tell it how much Nasdaq-linked
   // exposure THIS bot is currently carrying so every other AutopsyX
   // instance on this terminal sees the true aggregate.
   ReportOwnExposure(InpSymbolPrice, CurrentPositionNotional());
  }

//+------------------------------------------------------------------+
//| Placeholder for your EA's actual entry logic. Replace this       |
//| function's body — do not replace anything else in this file's    |
//| control flow. AutopsyX has no opinion on how you generate a       |
//| signal, only on whether you're allowed to act on it.              |
//+------------------------------------------------------------------+
int MyExistingStrategySignal()
  {
   return 0; // example EA — no live signal logic on purpose
  }

//+------------------------------------------------------------------+
//| EXECUTION stub. In a real integration this is exactly where your |
//| existing EA's own OrderSend()/CTrade call already lives — you    |
//| are only adding the AllowLong()/AllowShort()/AllowNewTrade()      |
//| checks above it, and sizing off GetRiskMultiplier() instead of    |
//| a hard-coded lot size or a flat ×3.                                |
//+------------------------------------------------------------------+
void OnApprovedSignal(const ENUM_ORDER_TYPE order_type, const double risk_multiplier)
  {
   const double effective_risk_pct = InpBaseRiskPct * risk_multiplier;
   PrintFormat("AutopsyX APPROVED %s at %.3f%% effective risk (base %.2f%% x multiplier %.3f). "
               "TODO: replace this Print with your EA's existing OrderSend/CTrade call, sized off effective_risk_pct.",
               EnumToString(order_type), effective_risk_pct, InpBaseRiskPct, risk_multiplier);
  }

//+------------------------------------------------------------------+
//| Stand-in for "how much Nasdaq-linked notional am I holding right |
//| now". Wire this to your EA's real open-position accounting.       |
//+------------------------------------------------------------------+
double CurrentPositionNotional()
  {
   double total = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != InpSymbolPrice) continue;
      total += PositionGetDouble(POSITION_VOLUME) * PositionGetDouble(POSITION_PRICE_CURRENT) * SymbolInfoDouble(InpSymbolPrice, SYMBOL_TRADE_CONTRACT_SIZE);
     }
   return total;
  }
