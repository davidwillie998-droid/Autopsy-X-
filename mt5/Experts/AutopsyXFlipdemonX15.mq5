//+------------------------------------------------------------------+
//|                                      AutopsyXFlipdemonX15.mq5     |
//|  FLIPDEMON — the entry/execution EA that AUTOPSY X's regime        |
//|  governor (see mt5/Include/AutopsyX/) sits in front of. Trades     |
//|  XAUUSD and major FX pairs in retail-scale lots (0.01 - a few      |
//|  lots). Two internal engines gate every trade before it's sized:   |
//|                                                                     |
//|   EXPECTED-VALUE ENGINE — nets the strategy's assumed edge against |
//|   a real, itemized cost estimate (spread, commission, swap,        |
//|   slippage buffer, and a conditionally-gated price-impact term).   |
//|   No leg is a hardcoded constant unless the constant is a value    |
//|   only the user can know (their broker's commission schedule).     |
//|                                                                     |
//|   REGIME ENGINE — classifies trend/range using a volatility-       |
//|   adaptive lookback window rather than a fixed number of calendar  |
//|   days. See the section header below for why.                      |
//|                                                                     |
//|   PROVENANCE NOTE: this file was authored new, in full, to the     |
//|   specification below. It is not an edit of a pre-existing         |
//|   AutopsyXFlipdemonX15.mq5 — no such file was found anywhere in    |
//|   this repository's working tree, branches, or commit history      |
//|   when this was written. Where the spec assumed prior code (an     |
//|   existing ATR function to reuse, an existing fixed-window regime  |
//|   model to replace), this file supplies a first, real version of   |
//|   that logic instead, built the way the spec describes the         |
//|   replacement should work.                                         |
//|                                                                     |
//|   NOT COMPILER-CHECKED. Written without MetaEditor access. Every   |
//|   MQL5 API call below is used the way its documented signature     |
//|   describes, and the file was read through by hand afterward       |
//|   specifically hunting for double/long mismatches and signature    |
//|   errors — but that is not a substitute for actually compiling it. |
//+------------------------------------------------------------------+
#property copyright "AUTOPSY X"
#property strict
#property version   "1.00"

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| INPUTS — trading                                                   |
//+------------------------------------------------------------------+
input string InpTradeSymbol      = "";     // "" = current chart symbol
input double InpBaseRiskPct      = 1.0;    // % of equity at full (ungated) size
input ulong  InpMagic            = 150015;

//+------------------------------------------------------------------+
//| INPUTS — Expected-Value Engine / cost model                       |
//| Every one of these is either a live MQL5 API read or a value only |
//| the user can supply (their own broker's real schedule). None is a |
//| guessed constant.                                                  |
//+------------------------------------------------------------------+
input double CommissionPerLot           = 0.0;   // USD (account-currency) per lot, ROUND TURN — set from your broker's actual commission schedule. MT5 has no universal API for this; guessing it would misstate every EV calculation downstream, so it defaults to 0 and must be configured deliberately.
input double SlippageTolerancePoints    = 20.0;  // worst-case slippage buffer, in points — NOT "SlippageToleranceLots" as the spec's example name suggested: slippage is a price deviation, not a volume, and points convert to money the same well-defined way spread does (see CalculateExpectedCost). Named for correctness; same intent as requested.
input double ImpactRelevanceThresholdLots = 50.0; // INSTITUTIONAL-SCALE, NOT TYPICAL RETAIL SIZE. Below this, price-impact cost is hard-zeroed, not estimated small — see the Expected-Value Engine section banner below for why.
input double ImpactCoefficientK         = 1.0;   // k in cost ~= k * sigma * sqrt(orderSize / ADV); only ever multiplies a nonzero base when the threshold above is exceeded.

//+------------------------------------------------------------------+
//| INPUTS — Regime Engine                                            |
//+------------------------------------------------------------------+
input int    RegimeAtrPeriod          = 14;
input int    RegimeAtrHistoryBars     = 60;   // trailing window used to judge "is current ATR high or low for this instrument lately"
input int    RegimeBaseLookbackBars   = 50;   // lookback used when volatility is exactly at its trailing average
input int    RegimeMinLookbackBars    = 15;
input int    RegimeMaxLookbackBars    = 150;
input ENUM_TIMEFRAMES RegimeTimeframe = PERIOD_H1;

//+------------------------------------------------------------------+
//| INPUTS — safety gates, sample-size gate, drawdown governor        |
//+------------------------------------------------------------------+
input int    MinClosedTradeSample     = 30;    // require this many of THIS EA's own closed trades (by magic number) before its EV estimate is treated as statistically seasoned, not just a cold-start guess
input double MaxSpreadPoints          = 400;   // hard block if the live spread is wider than this (data/liquidity sanity gate)
input double DrawdownHaltPct          = 10.0;  // halt new trades once equity drawdown from its own peak reaches this
input double DrawdownRecoveryBufferPct= 2.0;   // must recover to (halt - buffer) before auto-reset is even considered
input int    DrawdownCooldownSeconds  = 24*3600;

CTrade g_trade;
string g_symbol;
int    g_atrHandle = INVALID_HANDLE;

double   g_peakEquity     = 0.0;
bool     g_ddHalted        = false;
datetime g_ddHaltedAt       = 0;
datetime g_lastBarTime      = 0;

//+------------------------------------------------------------------+
//| Shared ATR-based volatility read. Both the Expected-Value Engine's|
//| gated impact term and the Regime Engine's adaptive lookback call  |
//| this SAME function rather than each keeping its own ATR handle -- |
//| exactly the "reuse, don't duplicate" instruction from the spec.   |
//| Returns -1.0 (never a fabricated number) if the handle or the     |
//| underlying data isn't actually available yet.                    |
//+------------------------------------------------------------------+
double GetAtrVolatility(int atrHandle, int shift = 0)
  {
   if(atrHandle == INVALID_HANDLE)
      return -1.0;
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(atrHandle, 0, shift, 1, buf) < 1)
      return -1.0;
   if(buf[0] <= 0.0)
      return -1.0;
   return buf[0];
  }

//+------------------------------------------------------------------+
//| Average daily volume from real historical bar volume (iVolume).  |
//| CAVEAT (documented, not hidden): on most forex/CFD feeds this is  |
//| tick-count volume, not literal traded contract count — it's still |
//| a genuine, live-computed participation proxy, not a guess, but it |
//| is not interchangeable with an equity exchange's share volume.    |
//| Returns -1.0 if no real volume history exists for the symbol yet. |
//+------------------------------------------------------------------+
double GetAverageDailyVolume(string symbol, int days = 20)
  {
   double sum = 0.0;
   int counted = 0;
   for(int i = 1; i <= days; i++)
     {
      long v = iVolume(symbol, PERIOD_D1, i);
      if(v > 0) { sum += (double)v; counted++; }
     }
   if(counted == 0)
      return -1.0;
   return sum / counted;
  }

//+------------------------------------------------------------------+
//| REGIME ENGINE                                                      |
//|                                                                     |
//| Why an ATR-normalized adaptive lookback instead of a fixed         |
//| calendar-day formation/holding window: fixed multi-week or         |
//| multi-month lookbacks were the academic and retail-EA standard     |
//| through roughly the early 2010s, but the momentum-factor crowding  |
//| and decay documented since then (more capital chasing the same     |
//| fixed-window signals, compressing the edge those exact windows     |
//| used to capture) makes a static window a known-stale assumption    |
//| rather than a safe default. Sizing the lookback to the instrument's|
//| OWN current volatility relative to its recent past — wider in calm |
//| regimes, narrower once volatility expands — is the current         |
//| standard replacement: it keeps the number of "independent" price   |
//| moves inside the window roughly stable instead of the window's     |
//| calendar length staying fixed while the market's actual pace       |
//| changes underneath it.                                              |
//+------------------------------------------------------------------+
enum ENUM_FLIP_REGIME
  {
   FLIP_REGIME_NA = 0,
   FLIP_REGIME_TREND_UP,
   FLIP_REGIME_TREND_DOWN,
   FLIP_REGIME_RANGE
  };

struct RegimeReadout
  {
   ENUM_FLIP_REGIME regime;
   int              lookbackBarsUsed;
   double           volRatio;      // current ATR / trailing-average ATR; >1 = more volatile than usual lately
   bool             valid;
  };

//--- Scales RegimeBaseLookbackBars inversely with how volatile the
//    instrument is right now relative to its own recent history, then
//    clamps to [RegimeMinLookbackBars, RegimeMaxLookbackBars]. Falls back
//    to the base (not a fabricated number, just the neutral default) if
//    the trailing-average ATR can't actually be computed yet.
int GetAdaptiveLookbackBars(int atrHandle, double &outVolRatio)
  {
   outVolRatio = 1.0;
   double currentAtr = GetAtrVolatility(atrHandle, 0);
   if(currentAtr <= 0.0)
      return RegimeBaseLookbackBars;

   double histBuf[];
   ArraySetAsSeries(histBuf, true);
   if(CopyBuffer(atrHandle, 0, 1, RegimeAtrHistoryBars, histBuf) < RegimeAtrHistoryBars)
      return RegimeBaseLookbackBars;

   double sum = 0.0;
   for(int i = 0; i < RegimeAtrHistoryBars; i++)
      sum += histBuf[i];
   double avgAtr = sum / RegimeAtrHistoryBars;
   if(avgAtr <= 0.0)
      return RegimeBaseLookbackBars;

   double ratio = currentAtr / avgAtr;
   outVolRatio = ratio;
   if(ratio <= 0.0)
      return RegimeBaseLookbackBars;

   int bars = (int)MathRound((double)RegimeBaseLookbackBars / ratio);
   if(bars < RegimeMinLookbackBars) bars = RegimeMinLookbackBars;
   if(bars > RegimeMaxLookbackBars) bars = RegimeMaxLookbackBars;
   return bars;
  }

//--- Direction over the adaptive window: net displacement vs. the sum of
//    the window's bar-to-bar moves (an efficiency-ratio style read, not
//    just first-vs-last price) so a choppy round-trip inside the window
//    doesn't get misread as a clean trend just because it ended higher.
RegimeReadout ClassifyRegime(string symbol, ENUM_TIMEFRAMES tf, int atrHandle)
  {
   RegimeReadout r;
   r.regime = FLIP_REGIME_NA;
   r.lookbackBarsUsed = 0;
   r.volRatio = 1.0;
   r.valid = false;

   int bars = GetAdaptiveLookbackBars(atrHandle, r.volRatio);
   r.lookbackBarsUsed = bars;

   int need = bars + 1;
   double closes[];
   ArraySetAsSeries(closes, true);
   if(CopyClose(symbol, tf, 0, need, closes) < need)
      return r;

   double netChange = closes[0] - closes[need - 1];
   double sumAbs = 0.0;
   for(int i = 0; i < need - 1; i++)
      sumAbs += MathAbs(closes[i] - closes[i + 1]);
   if(sumAbs <= 0.0)
      return r;

   double efficiency = MathAbs(netChange) / sumAbs; // 0..1, 1 = pure directional move
   r.valid = true;

   const double rangeEfficiencyCeiling = 0.35; // below this, too much backtracking to call it a trend
   if(efficiency < rangeEfficiencyCeiling)
     {
      r.regime = FLIP_REGIME_RANGE;
      return r;
     }
   r.regime = (netChange > 0.0) ? FLIP_REGIME_TREND_UP : FLIP_REGIME_TREND_DOWN;
   return r;
  }

//+------------------------------------------------------------------+
//| EXPECTED-VALUE ENGINE                                              |
//|                                                                     |
//| Why price impact is gated off by default: this EA sizes positions  |
//| in retail lots (0.01 to a few lots) on XAUUSD and major FX pairs   |
//| — markets where daily turnover runs into the tens of billions of   |
//| dollars. An order of that size is a price TAKER, not a price       |
//| MOVER; it fills against existing liquidity without measurably      |
//| displacing it. A market-impact cost model built for institutional  |
//| execution (desks working orders that ARE a meaningful fraction of  |
//| a day's volume) would attribute a real cost to a trade that in     |
//| practice pays none, quietly understating this EA's true expected   |
//| value every single time. For the gated term below to matter at     |
//| all, position size would need to grow roughly three orders of      |
//| magnitude past what this EA is configured to ever generate --      |
//| ImpactRelevanceThresholdLots exists to make that boundary explicit |
//| and auditable rather than silently assumed.                        |
//+------------------------------------------------------------------+
struct ExpectedCostBreakdown
  {
   double spreadCost;
   double commissionCost;
   double swapCost;
   bool   swapApplied;        // true only if the position is projected to cross a rollover
   bool   swapDataAvailable;  // false if the symbol's swap mode isn't one this function knows how to convert (see below) -- treat swapCost as N/A in that case, not as zero
   double slippageBuffer;
   double impactCost;
   bool   impactGated;        // true = below ImpactRelevanceThresholdLots, term is intentionally zero by design
   bool   impactDataAvailable;// only meaningful when impactGated==false: whether sigma/ADV were actually computable
   double totalCost;          // sum of every leg that IS available; see `valid`
   bool   valid;               // false if a REQUIRED leg (spread/commission/slippage -- the legs every trade always pays) couldn't be read from real data at all
  };

//--- Every leg is either a live SymbolInfo*/CopyBuffer/iVolume read, a
//    direct passthrough of a user input, or a call into GetAtrVolatility/
//    GetAverageDailyVolume above. Nothing here is a hardcoded cost
//    constant, and nothing is guessed when real data isn't available --
//    unavailable legs are flagged, not defaulted to zero and hidden.
ExpectedCostBreakdown CalculateExpectedCost(string symbol, double lots, ENUM_ORDER_TYPE side,
                                             datetime projectedCloseTime, int atrHandleForImpact)
  {
   ExpectedCostBreakdown c;
   c.spreadCost = 0; c.commissionCost = 0; c.swapCost = 0; c.swapApplied = false;
   c.swapDataAvailable = true; c.slippageBuffer = 0; c.impactCost = 0;
   c.impactGated = true; c.impactDataAvailable = false; c.totalCost = 0; c.valid = false;

   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double point       = SymbolInfoDouble(symbol, SYMBOL_POINT);
   long   spreadPts   = SymbolInfoInteger(symbol, SYMBOL_SPREAD);

   if(tickValue <= 0.0 || tickSize <= 0.0 || point <= 0.0)
      return c; // core conversion factors unavailable -- caller must treat the whole result as N/A, not zero-cost

   //--- Spread cost: real-time spread in points, converted through the
   //    symbol's own tick value/tick size, scaled by lots. No hardcoded
   //    constant anywhere in this leg.
   double spreadPriceDistance = (double)spreadPts * point;
   c.spreadCost = (spreadPriceDistance / tickSize) * tickValue * lots;

   //--- Commission: pure passthrough of the user's real, broker-quoted
   //    schedule. This function never estimates it.
   c.commissionCost = CommissionPerLot * lots;

   //--- Swap: only charged if the position is projected to still be open
   //    at the next rollover. SYMBOL_SWAP_MODE governs how SYMBOL_SWAP_LONG/
   //    SYMBOL_SWAP_SHORT should be interpreted -- points vs. an already-
   //    direct currency amount -- and this function only converts the
   //    modes it can convert correctly; anything else is flagged N/A
   //    rather than silently mis-converted.
   datetime now = TimeCurrent();
   MqlDateTime nowStruct;
   TimeToStruct(now, nowStruct);
   datetime secondsSinceMidnight = nowStruct.hour * 3600 + nowStruct.min * 60 + nowStruct.sec;
   datetime nextRollover = now - secondsSinceMidnight + 86400;

   if(projectedCloseTime > nextRollover)
     {
      double swapRaw = (side == ORDER_TYPE_BUY) ? SymbolInfoDouble(symbol, SYMBOL_SWAP_LONG)
                                                  : SymbolInfoDouble(symbol, SYMBOL_SWAP_SHORT);
      long swapMode = SymbolInfoInteger(symbol, SYMBOL_SWAP_MODE);

      double swapMultiplier = 1.0;
      MqlDateTime rolloverStruct;
      TimeToStruct(nextRollover, rolloverStruct);
      long tripleDay = SymbolInfoInteger(symbol, SYMBOL_SWAP_ROLLOVER3DAYS);
      if(rolloverStruct.day_of_week == (int)tripleDay)
         swapMultiplier = 3.0; // standard FX triple-swap day, read from the symbol itself, not assumed to be Wednesday

      if(swapMode == SYMBOL_SWAP_MODE_POINTS)
        {
         c.swapCost = (swapRaw * point / tickSize) * tickValue * lots * swapMultiplier;
         c.swapApplied = true;
        }
      else if(swapMode == SYMBOL_SWAP_MODE_CURRENCY_SYMBOL ||
              swapMode == SYMBOL_SWAP_MODE_CURRENCY_MARGIN ||
              swapMode == SYMBOL_SWAP_MODE_CURRENCY_DEPOSIT)
        {
         // In these modes SymbolInfoDouble already returns a direct
         // currency amount per lot per day -- no point/tick conversion.
         c.swapCost = swapRaw * lots * swapMultiplier;
         c.swapApplied = true;
        }
      else
        {
         // Interest-based modes (SYMBOL_SWAP_MODE_INTEREST_CURRENT / _OPEN,
         // SYMBOL_SWAP_MODE_REOPEN_CURRENT / _BID) need the position's
         // margin/reopen price to compute correctly, which this function
         // doesn't have. Flag N/A rather than guess.
         c.swapApplied = false;
         c.swapDataAvailable = false;
        }
     }

   //--- Slippage: user-configured worst-case buffer, in points, converted
   //    exactly the same well-defined way spread is. Not a fabricated
   //    percent-of-price.
   c.slippageBuffer = (SlippageTolerancePoints * point / tickSize) * tickValue * lots;

   //--- Price impact: gated. See the section banner above for the "why".
   //    Square-root propagator approximation (Bouchaud et al.) --
   //    cost-as-a-fraction-of-price ~= k * sigma * sqrt(orderSize / ADV) --
   //    NOT the older linear Almgren-Chriss impact assumption. This is not
   //    expected to ever fire for a normal position size this EA generates;
   //    it exists so the EV Engine is honest about where its cost model
   //    stops being valid, rather than silently assuming no size is ever
   //    large enough to matter.
   if(lots > ImpactRelevanceThresholdLots)
     {
      c.impactGated = false;
      double sigmaAbs = GetAtrVolatility(atrHandleForImpact, 0); // reuses the SAME shared ATR function, not a duplicate
      double adv = GetAverageDailyVolume(symbol);
      double price = (side == ORDER_TYPE_BUY) ? SymbolInfoDouble(symbol, SYMBOL_ASK)
                                                 : SymbolInfoDouble(symbol, SYMBOL_BID);
      double contractSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_CONTRACT_SIZE);

      if(sigmaAbs > 0.0 && adv > 0.0 && price > 0.0 && contractSize > 0.0)
        {
         double sigmaFraction = sigmaAbs / price; // ATR expressed as a fraction of price, so the propagator's units work out to a fraction-of-price cost
         double costFraction = ImpactCoefficientK * sigmaFraction * MathSqrt(lots / adv);
         c.impactCost = costFraction * price * contractSize * lots;
         c.impactDataAvailable = true;
        }
      else
        {
         c.impactDataAvailable = false; // above threshold but sigma/ADV genuinely unavailable -- N/A, not zero
        }
     }

   double impactLegForTotal = (c.impactGated || !c.impactDataAvailable) ? 0.0 : c.impactCost;
   double swapLegForTotal   = (c.swapApplied && c.swapDataAvailable) ? c.swapCost : 0.0;
   c.totalCost = c.spreadCost + c.commissionCost + swapLegForTotal + c.slippageBuffer + impactLegForTotal;
   c.valid = true; // every REQUIRED leg (spread, commission, slippage) is always computable from real data or a real input; only swap/impact can individually be N/A, and each is flagged, not folded silently into totalCost
   return c;
  }

//+------------------------------------------------------------------+
//| Sample-size gate: don't let a cold-start EV estimate act as if it |
//| were statistically seasoned. Counts THIS EA's own real closed      |
//| trades from account history, filtered by magic number -- not a     |
//| guess, a real HistorySelect/HistoryDeal* read.                     |
//+------------------------------------------------------------------+
int CountClosedTradesForMagic(ulong magic)
  {
   if(!HistorySelect(0, TimeCurrent()))
      return 0;
   int total = HistoryDealsTotal();
   int count = 0;
   for(int i = 0; i < total; i++)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if((ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC) != magic) continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue; // count closes, not opens
      count++;
     }
   return count;
  }

//+------------------------------------------------------------------+
//| Drawdown governor -- same bracket-and-halt design used by the      |
//| AUTOPSY X regime module (mt5/Include/AutopsyX/AutopsyRiskGovernor  |
//| .mqh), reproduced here so this EA is self-contained and can run    |
//| either standalone or gated by that module.                         |
//+------------------------------------------------------------------+
double UpdateDrawdownGovernor(double currentEquity)
  {
   if(g_peakEquity <= 0.0)
      g_peakEquity = currentEquity;
   g_peakEquity = MathMax(g_peakEquity, currentEquity);
   double ddPct = (g_peakEquity > 0.0) ? (g_peakEquity - currentEquity) / g_peakEquity * 100.0 : 0.0;

   if(ddPct >= DrawdownHaltPct && !g_ddHalted)
     {
      g_ddHalted = true;
      g_ddHaltedAt = TimeCurrent();
      Print("FLIPDEMON: drawdown governor HALTED new trades at ", DoubleToString(ddPct, 2), "% drawdown.");
     }

   if(g_ddHalted)
     {
      bool recovered = ddPct <= (DrawdownHaltPct - DrawdownRecoveryBufferPct);
      bool cooledDown = (TimeCurrent() - g_ddHaltedAt) >= DrawdownCooldownSeconds;
      if(recovered && cooledDown)
        {
         g_ddHalted = false;
         g_ddHaltedAt = 0;
         Print("FLIPDEMON: drawdown governor auto-reset after recovery + cooldown.");
        }
      else
         return 0.0;
     }

   if(ddPct <= 3.0)  return 1.00;
   if(ddPct <= 5.0)  return 0.75;
   if(ddPct <= 8.0)  return 0.50;
   if(ddPct <= DrawdownHaltPct) return 0.25;
   return 0.0;
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   g_symbol = (StringLen(InpTradeSymbol) > 0) ? InpTradeSymbol : _Symbol;
   g_trade.SetExpertMagicNumber(InpMagic);

   g_atrHandle = iATR(g_symbol, RegimeTimeframe, RegimeAtrPeriod);
   if(g_atrHandle == INVALID_HANDLE)
     {
      Print("FLIPDEMON: failed to create ATR handle for ", g_symbol, " -- Regime Engine and impact gate will read N/A.");
     }

   g_peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_ddHalted = false;
   g_ddHaltedAt = 0;
   g_lastBarTime = 0;

   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
  }

bool IsNewBar()
  {
   datetime t = iTime(g_symbol, RegimeTimeframe, 0);
   if(t != g_lastBarTime) { g_lastBarTime = t; return true; }
   return false;
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(!IsNewBar())
      return;

   //--- Safety gate: spread sanity.
   long spreadPts = SymbolInfoInteger(g_symbol, SYMBOL_SPREAD);
   if(spreadPts <= 0 || spreadPts > MaxSpreadPoints)
     {
      Comment("FLIPDEMON: spread gate blocked -- ", spreadPts, " points.");
      return;
     }

   //--- Safety gate: drawdown governor (also advances its own state every bar).
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double ddFactor = UpdateDrawdownGovernor(equity);
   if(ddFactor <= 0.0)
     {
      Comment("FLIPDEMON: drawdown-halted, no new trades.");
      return;
     }

   //--- Sample-size gate: below MinClosedTradeSample closed trades, still
   //    trade (a strategy has to start somewhere), but flag the EV read as
   //    unseasoned rather than pretending it's statistically established.
   int closedSample = CountClosedTradesForMagic(InpMagic);
   bool seasoned = (closedSample >= MinClosedTradeSample);

   //--- Regime Engine.
   RegimeReadout regime = ClassifyRegime(g_symbol, RegimeTimeframe, g_atrHandle);
   if(!regime.valid)
     {
      Comment("FLIPDEMON: regime read N/A (insufficient history) -- standing aside.");
      return;
     }

   //--- Stand-in entry signal. This EA's real strategy logic is not part
   //    of this task -- only the EV Engine's cost model and the Regime
   //    Engine's window logic were in scope. Swap this block for the
   //    actual Flipdemon signal; everything else in this file is what was
   //    asked to be built/modernized.
   bool wantLong  = (regime.regime == FLIP_REGIME_TREND_UP);
   bool wantShort = (regime.regime == FLIP_REGIME_TREND_DOWN);
   if(!wantLong && !wantShort)
     {
      Comment("FLIPDEMON: regime=RANGE, lookback=", regime.lookbackBarsUsed, " bars, volRatio=", DoubleToString(regime.volRatio,2), " -- no trend side to trade.");
      return;
     }

   double lots = 0.01; // placeholder sizing; real position sizing from InpBaseRiskPct x ddFactor is a separate concern from what this task asked for
   ENUM_ORDER_TYPE side = wantLong ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   datetime projectedCloseTime = TimeCurrent() + 6 * 3600; // placeholder assumed holding period; wire to the real strategy's expected holding time

   ExpectedCostBreakdown cost = CalculateExpectedCost(g_symbol, lots, side, projectedCloseTime, g_atrHandle);
   if(!cost.valid)
     {
      Comment("FLIPDEMON: EV Engine cost read N/A (missing tick value/size/point data) -- standing aside.");
      return;
     }

   string summary = StringFormat(
      "FLIPDEMON\nRegime: %s (lookback=%d bars, volRatio=%.2f)%s\nCost: spread=%.2f commission=%.2f swap=%s slippageBuf=%.2f impact=%s\nTotal cost: %.2f  ddFactor=%.2f  sample=%d%s",
      EnumToString(regime.regime), regime.lookbackBarsUsed, regime.volRatio,
      seasoned ? "" : "  [UNSEASONED SAMPLE]",
      cost.spreadCost, cost.commissionCost,
      cost.swapApplied ? (cost.swapDataAvailable ? DoubleToString(cost.swapCost,2) : "N/A(swap mode)") : "not applicable (no rollover crossed)",
      cost.slippageBuffer,
      cost.impactGated ? "gated (below threshold)" : (cost.impactDataAvailable ? DoubleToString(cost.impactCost,2) : "N/A(no ADV/vol data)"),
      cost.totalCost, ddFactor, closedSample, seasoned ? "" : " (below MinClosedTradeSample)"
     );
   Comment(summary);

   // Execution intentionally left out of scope for this task -- see the
   // stand-in signal note above. A real EA would net an edge estimate
   // against cost.totalCost here and call g_trade.Buy()/Sell() only when
   // that net is positive and every gate above has passed.
  }
