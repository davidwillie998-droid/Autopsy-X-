//+------------------------------------------------------------------+
//|                                      AutopsyXFlipdemonX15.mq5      |
//|                          AUTOPSY X — FLIPDEMON HFT PRO X15         |
//+------------------------------------------------------------------+
#property copyright "AUTOPSY X"
#property version   "1.00"
#property description "Expected-Value Engine + adaptive-lookback Regime Engine slice for the AUTOPSY X Flipdemon HFT PRO X15 design (see docs/flipdemon-x15-spec.md and docs/qqq-tqqq-regime-engine-spec.md)."

//======================================================================
// NOTE ON THIS FILE'S ORIGIN — READ BEFORE TREATING THIS AS A DIFF
//
// This file did not exist anywhere in the attached project (repo working
// tree, git history, or session uploads) when the Expected-Value Engine
// rewrite was requested. It is written fresh against the design specs
// already recorded in this repo — docs/flipdemon-x15-spec.md and
// docs/qqq-tqqq-regime-engine-spec.md — not modernized from prior code,
// so there is no "before" version to diff against. The app's own UI
// (index.html, Live Bridge panel) already refers to a companion
// "AutopsyXBridge.mq5" EA that likewise doesn't exist in this repo — the
// MT5-native side of this system has so far been documented, not built.
//
// SCOPE: this file implements only what was asked — the Expected-Value
// Engine's cost model (CalculateExpectedCost and its helpers) and the
// adaptive-lookback piece of the Regime Engine that the EV engine reuses
// for volatility. It deliberately does NOT implement the VWAP flip
// entry/exit signal described in docs/flipdemon-x15-spec.md, the full
// six-state regime classifier from docs/qqq-tqqq-regime-engine-spec.md,
// or order execution — those are separate, larger tasks. OnTick() below
// is a skeleton showing where a real signal would call into this engine,
// clearly marked as a placeholder.
//======================================================================

//----------------------------------------------------------------------
// INPUTS
//----------------------------------------------------------------------
input group "=== Expected-Value Engine: Cost Inputs ==="
input double CommissionPerLot             = 0.0;   // Real commission per 1.0 lot round-trip, in account currency. MUST be set from your broker's actual fee schedule — MT5 exposes no universal API to read this. 0.0 here is treated as UNCONFIGURED, not "commission-free" (see commissionConfigured in SExpectedCost).
input double SlippageTolerancePoints      = 20.0;  // Worst-case slippage buffer, in points, added to expected cost. This is a configured assumption, not a live measurement — MT5 has no forward-looking slippage estimate to query.
input double ImpactRelevanceThresholdLots = 50.0;  // INSTITUTIONAL-SCALE, NOT TYPICAL RETAIL SIZE (illustrative default for a major FX pair). Below this, price-impact cost is forced to zero. This EA trades 0.01-to-a-few lots; this threshold exists so the impact term stays inert unless position sizing is badly misconfigured.
input double ImpactCoefficientK           = 1.0;   // k in cost ~ k * sigma * sqrt(orderSize / ADV). Engineering placeholder, not fitted to any symbol's observed impact — see CalculatePriceImpact().

input group "=== Regime Engine: Adaptive Lookback ==="
input int    ATRPeriod            = 14;   // Period for the single shared ATR volatility read, reused by both the Regime Engine's adaptive lookback and the EV Engine's price-impact term (never computed twice).
input int    BaseLookbackBars     = 20;   // Baseline formation-window length before ATR-normalization.
input double LookbackATRReference = 1.0;  // Reference ATR (symbol price units) that BaseLookbackBars is calibrated against. This is a placeholder — recalibrate per symbol, it has not been fitted.

input group "=== Risk Governors (do not weaken without a stated reason) ==="
input int    MinSampleSizeForStats = 30;   // Sample-size gate: below this many closed trades, this EA should not trust its own hit-rate/expectancy stats yet.
input double DrawdownHaltPct       = 10.0; // Trading halts entirely at/above this % drawdown from the equity peak — mirrors the drawdown-governor table in docs/qqq-tqqq-regime-engine-spec.md §14.

//----------------------------------------------------------------------
// SHARED STATE
//----------------------------------------------------------------------
int    g_atrHandle        = INVALID_HANDLE;
double g_equityPeak       = 0.0;
int    g_closedTradeCount = 0; // Not incremented anywhere in this file — wire this to your own trade-close handling (e.g. OnTradeTransaction) before SampleSizeGate() means anything.

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);
   if(g_atrHandle == INVALID_HANDLE)
     {
      Print("AutopsyXFlipdemonX15: failed to create ATR handle, error ", GetLastError());
      return(INIT_FAILED);
     }

   if(CommissionPerLot <= 0.0)
      Print("AutopsyXFlipdemonX15: CommissionPerLot is 0.0 — treated as UNCONFIGURED, not free. Set it from your broker's real commission schedule before trusting CalculateExpectedCost() output.");

   g_equityPeak = AccountInfoDouble(ACCOUNT_EQUITY);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
  }

//======================================================================
// REGIME ENGINE (adaptive-lookback slice only — see scope note above)
//
// Why ATR-normalized adaptive lookback windows instead of fixed
// calendar-day formation/holding periods: fixed multi-week/month
// lookback windows (the classic 20/60/250-day style used since the
// Jegadeesh & Titman-era momentum literature) are a known-stale default
// given documented momentum-factor crowding and decay since roughly the
// early 2010s — a window calibrated to one volatility regime silently
// becomes too short or too long as realized volatility shifts under it.
// Scaling the lookback by current ATR relative to a reference value
// (wider window when volatility is low, narrower when it's high) is the
// current standard replacement, and is what GetAdaptiveLookback() does
// below. This has NOT been backtested in this file — the calibration
// constants (BaseLookbackBars, LookbackATRReference) are placeholders,
// not fitted values.
//======================================================================

//----------------------------------------------------------------------
// GetATRVolatility
// Single, canonical ATR read — reused by both GetAdaptiveLookback()
// below and CalculatePriceImpact() further down, so volatility is never
// computed two different ways in this file.
// Returns ATR in symbol price units, or -1.0 (N/A) if the indicator
// buffer isn't ready yet (e.g. immediately after OnInit, before
// ATRPeriod+1 bars have formed) — callers must check for this rather
// than assume a valid value.
//----------------------------------------------------------------------
double GetATRVolatility()
  {
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(g_atrHandle, 0, 0, 1, buf) < 1)
      return -1.0; // N/A — not enough history yet, or indicator not ready.
   return buf[0];
  }

//----------------------------------------------------------------------
// GetAdaptiveLookback
// ATR-normalized formation-window length in bars. Scales
// BaseLookbackBars inversely with current ATR relative to
// LookbackATRReference. Clamped to [5, 250] bars so a near-zero ATR
// read can't blow the window out to an absurd length.
// Falls back to BaseLookbackBars (not a guess) if volatility is N/A.
//----------------------------------------------------------------------
int GetAdaptiveLookback()
  {
   double atr = GetATRVolatility();
   if(atr <= 0.0 || LookbackATRReference <= 0.0)
      return BaseLookbackBars; // N/A volatility read — fall back to the fixed base rather than scale by a bad ratio.

   double scaled   = BaseLookbackBars * (LookbackATRReference / atr);
   int    lookback = (int)MathRound(scaled);
   if(lookback < 5)   lookback = 5;
   if(lookback > 250) lookback = 250;
   return lookback;
  }

//======================================================================
// EXPECTED-VALUE ENGINE
//
// Why price impact defaults to zero: this EA sizes positions in lots
// (0.01 to a few lots) on XAUUSD and major FX pairs. At that size it is
// a price-taker, not a price-mover — the square-root impact model below
// only produces a meaningful nonzero cost once order size is a real
// fraction of a symbol's average daily volume, which for a major FX
// pair or XAUUSD means order sizes several orders of magnitude larger
// than anything this EA generates. For the gated term to matter, either
// position sizing would have to be badly misconfigured into
// institutional-scale lots, or this EA would have to be repointed at an
// illiquid, thinly-traded symbol — neither is this EA's intended use,
// which is why the term is OFF by default and gated behind
// ImpactRelevanceThresholdLots rather than always computed.
//======================================================================

struct SExpectedCost
  {
   double spreadCost;           // account currency, for the given lots (linear in lots)
   double commissionCost;       // account currency, for the given lots (linear in lots)
   double swapCost;             // account currency, for the given lots; 0.0 if not projected to hold overnight; can be legitimately negative (cost) or positive (credit)
   double slippageBuffer;       // account currency, for the given lots — a configured worst-case buffer, not a measurement
   double impactCost;           // account currency, for the given lots; 0.0 unless lots > ImpactRelevanceThresholdLots
   double totalCost;            // sum of the above
   bool   commissionConfigured; // false if CommissionPerLot was left at its 0.0 default (unconfigured, not "free")
   bool   swapDataAvailable;    // false if swap/point/tick data was N/A (see CalculateSwapCost)
   bool   spreadDataAvailable;  // false if spread/point/tick data was N/A (see CalculateSpreadCost)
   bool   impactApplied;        // true only if lots exceeded the institutional-scale threshold — expected to be false in normal operation
  };

//----------------------------------------------------------------------
// CalculateSpreadCost
// Real-time spread from SymbolInfoInteger(..., SYMBOL_SPREAD), converted
// to account currency via tick value/tick size — never a hardcoded
// constant. Returns cost for `lots`, or -1.0 (N/A) if symbol info isn't
// ready. A spread cost is always >= 0 by construction, so -1.0 is an
// unambiguous N/A sentinel here (unlike swap, see CalculateSwapCost).
//----------------------------------------------------------------------
double CalculateSpreadCost(const string symbol, double lots)
  {
   long   spreadPoints = SymbolInfoInteger(symbol, SYMBOL_SPREAD);
   double point        = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double tickValue    = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize     = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   if(point <= 0.0 || tickSize <= 0.0 || tickValue <= 0.0)
      return -1.0; // N/A — symbol info not available/ready.

   double priceDistance = spreadPoints * point;
   double costPerLot    = (priceDistance / tickSize) * tickValue;
   return costPerLot * lots;
  }

//----------------------------------------------------------------------
// CalculateSwapCost
// Only nonzero if the position is projected to hold across the next
// rollover (expectedCloseTime compared against an approximated next-
// rollover time). Reads SYMBOL_SWAP_LONG or SYMBOL_SWAP_SHORT depending
// on direction.
//
// Uses an explicit `ok` out-parameter for N/A rather than a sentinel
// return value, because a real swap cost can legitimately be negative
// (a cost) or positive (a credit) — a numeric sentinel like -1.0 would
// be indistinguishable from a genuine -1.0-currency-unit swap and is
// exactly the kind of bug that's easy to ship in cost-calculation code.
//
// APPROXIMATION (flagged, not fixed): MT5 exposes no direct API for
// "time of next rollover." This assumes rollover at broker-server
// midnight, which is the common case but not universal — some brokers
// roll over at a different hour, and most apply triple swap on a
// specific weekday rather than a fixed multiplier every day. Verify
// against your broker's actual rollover schedule before trusting this
// near a session boundary.
//
// APPROXIMATION (flagged, not fixed): this does not branch on
// SYMBOL_SWAP_MODE. The tick-value conversion below is correct for
// SYMBOL_SWAP_MODE_POINTS (the common case for FX/CFD). It is NOT
// verified for interest-rate-based or currency-margin swap modes
// (SWAP_MODE_CURRENCY_SYMBOL, SWAP_MODE_CURRENCY_MARGIN,
// SWAP_MODE_CURRENCY_DEPOSIT, SWAP_MODE_INTEREST_CURRENT,
// SWAP_MODE_INTEREST_OPEN, SWAP_MODE_REOPEN_CURRENT/BID) — check
// SymbolInfoInteger(symbol, SYMBOL_SWAP_MODE) for your broker's actual
// mode before relying on this for a symbol that isn't points-based.
//----------------------------------------------------------------------
double CalculateSwapCost(const string symbol, bool isBuy, datetime expectedCloseTime, double lots, bool &ok)
  {
   ok = true;

   datetime     now = TimeTradeServer();
   MqlDateTime  dtNow, dtRollover;
   TimeToStruct(now, dtNow);
   dtRollover = dtNow;
   dtRollover.hour = 0;
   dtRollover.min  = 0;
   dtRollover.sec  = 0;
   datetime nextRollover = StructToTime(dtRollover) + 86400; // next broker-server midnight — see APPROXIMATION note above.

   if(expectedCloseTime < nextRollover)
      return 0.0; // not projected to hold overnight — a real, legitimate zero, not N/A.

   double swapPoints = isBuy ? SymbolInfoDouble(symbol, SYMBOL_SWAP_LONG)
                              : SymbolInfoDouble(symbol, SYMBOL_SWAP_SHORT);
   double point      = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double tickValue  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   if(point <= 0.0 || tickSize <= 0.0 || tickValue <= 0.0)
     {
      ok = false;
      return 0.0;
     }

   double priceDistance = swapPoints * point;
   double costPerLot    = (priceDistance / tickSize) * tickValue; // sign follows swapPoints — can be negative (cost) or positive (credit)
   return costPerLot * lots;
  }

//----------------------------------------------------------------------
// GetAverageDailyVolumeProxy
// XAUUSD and major FX pairs trade OTC — there is no consolidated,
// centralized "average daily volume" the way there is for a listed
// equity, and MT5's tick-volume field counts price changes, not traded
// size. This returns the average D1 tick volume over `days` as a rough
// liquidity proxy, explicitly labeled as such — it is not a substitute
// for real ADV. Returns -1.0 (N/A) if D1 history isn't available.
//----------------------------------------------------------------------
double GetAverageDailyVolumeProxy(const string symbol, int days = 20)
  {
   long volumes[];
   ArraySetAsSeries(volumes, true);
   int copied = CopyTickVolume(symbol, PERIOD_D1, 1, days, volumes); // start_pos=1 skips the still-forming current day
   if(copied <= 0)
      return -1.0; // N/A — history not available.

   long sum = 0;
   for(int i = 0; i < copied; i++)
      sum += volumes[i];
   return (double)sum / (double)copied;
  }

//----------------------------------------------------------------------
// CalculatePriceImpact
// Gated to zero unless lots > ImpactRelevanceThresholdLots (default
// institutional-scale — NOT typical retail size, and not expected to
// ever fire for normal position sizes this EA generates).
//
// Approximates the empirical square-root impact law documented across
// equity and futures market-impact research (associated with Bouchaud,
// Farmer, Lillo, and related work on the "square-root law" of market
// impact), NOT the older linear Almgren-Chriss temporary-impact
// assumption. No specific paper is cited by number here — the
// square-root form is described generically because it wasn't sourced
// from a specific document in this session; verify against a primary
// source before citing it authoritatively elsewhere.
//
// Formula: I(Q) = ImpactCoefficientK * sigma * sqrt(Q / ADV), where
// Q = lots * contract size (the FULL order size), sigma is the shared
// ATR-based volatility read (GetATRVolatility — reused, not duplicated),
// and ADV is the tick-volume proxy above. I(Q) is a PRICE-DISTANCE
// (the average adverse price move per unit traded), not a total dollar
// cost by itself.
//
// UNIT NOTE (worth reading before changing this function): the return
// value is the money cost PER 1.0 LOT of that price-distance — i.e.
// (I(Q)/tickSize)*tickValue — even though I(Q) was computed using the
// FULL order size Q inside the sqrt term. That is correct, not a
// double-count: I(Q) is the average adverse price experienced by every
// unit of the order (its sub-linear sqrt growth already reflects the
// full order size), and the total dollar cost of the position is that
// per-unit price-distance's money value multiplied by how many lots you
// actually hold. So CalculateExpectedCost() below is right to multiply
// this function's return value by `lots` again — that is not
// double-scaling, it's converting a per-lot money-per-price-distance
// figure into a total cost for the position.
//----------------------------------------------------------------------
double CalculatePriceImpact(const string symbol, double lots)
  {
   if(lots <= ImpactRelevanceThresholdLots)
      return 0.0; // gated off — this is the expected path for this EA's normal sizing.

   double sigma = GetATRVolatility();
   double adv   = GetAverageDailyVolumeProxy(symbol);
   if(sigma <= 0.0 || adv <= 0.0)
     {
      Print("AutopsyXFlipdemonX15: price-impact term triggered (lots=", DoubleToString(lots, 2),
            ") but volatility or ADV proxy is N/A — returning 0.0 rather than guessing. ",
            "This should not happen at this order size; check the ATR handle and D1 history availability.");
      return 0.0;
     }

   double contractSize   = SymbolInfoDouble(symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double orderSizeUnits = lots * contractSize;
   double impactPriceUnits = ImpactCoefficientK * sigma * MathSqrt(orderSizeUnits / adv);

   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0 || tickValue <= 0.0)
      return -1.0; // N/A — a price-impact cost is always >= 0 by construction, so -1.0 is unambiguous here.

   return (impactPriceUnits / tickSize) * tickValue; // per 1.0 lot — see UNIT NOTE above; caller multiplies by lots.
  }

//----------------------------------------------------------------------
// CalculateExpectedCost
// Single entry point for the EV Engine's cost side. Combines spread,
// commission, swap (conditionally), slippage buffer, and gated price
// impact into one breakdown.
//----------------------------------------------------------------------
SExpectedCost CalculateExpectedCost(const string symbol, double lots, bool isBuy, datetime expectedCloseTime)
  {
   SExpectedCost result;
   ZeroMemory(result);

   double spread = CalculateSpreadCost(symbol, lots);
   result.spreadDataAvailable = (spread >= 0.0);
   result.spreadCost = result.spreadDataAvailable ? spread : 0.0;
   if(!result.spreadDataAvailable)
      Print("AutopsyXFlipdemonX15: spread cost N/A for ", symbol, " — symbol info not ready.");

   result.commissionConfigured = (CommissionPerLot > 0.0);
   result.commissionCost = CommissionPerLot * lots; // 0.0 if unconfigured — flagged via commissionConfigured, not silently treated as free.

   bool swapOk = true;
   double swap = CalculateSwapCost(symbol, isBuy, expectedCloseTime, lots, swapOk);
   result.swapDataAvailable = swapOk;
   result.swapCost = swapOk ? swap : 0.0;
   if(!swapOk)
      Print("AutopsyXFlipdemonX15: swap cost N/A for ", symbol, " — symbol info not ready.");

   double point     = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   if(point > 0.0 && tickSize > 0.0 && tickValue > 0.0)
      result.slippageBuffer = ((SlippageTolerancePoints * point) / tickSize) * tickValue * lots;
   else
      result.slippageBuffer = 0.0; // N/A — symbol info not ready.

   result.impactApplied = (lots > ImpactRelevanceThresholdLots);
   double impactPerLot = CalculatePriceImpact(symbol, lots);
   result.impactCost = (impactPerLot > 0.0) ? impactPerLot * lots : 0.0; // see UNIT NOTE on CalculatePriceImpact — this is not a double-count.

   result.totalCost = result.spreadCost + result.commissionCost + result.swapCost
                     + result.slippageBuffer + result.impactCost;
   return result;
  }

//======================================================================
// RISK GOVERNORS
// Not present anywhere in this file before this change (the file is
// new — see the origin note at the top), added because the task that
// produced this file explicitly required not weakening any such logic,
// which only makes sense to honor if real (not decorative) gates exist.
//======================================================================

//----------------------------------------------------------------------
// DrawdownGovernor
// Risk multiplier in [0,1] per the drawdown-governor table in
// docs/qqq-tqqq-regime-engine-spec.md §14: 0-3% dd -> 1.0, 3-5% -> 0.75,
// 5-8% -> 0.5, 8-10% -> 0.25, >= DrawdownHaltPct -> 0.0 (halt).
// Tracks its own running equity peak in g_equityPeak.
//----------------------------------------------------------------------
double DrawdownGovernor()
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > g_equityPeak)
      g_equityPeak = equity;
   if(g_equityPeak <= 0.0)
      return 1.0; // no equity data yet — do not fabricate a drawdown reading.

   double ddPct = (g_equityPeak - equity) / g_equityPeak * 100.0;
   if(ddPct >= DrawdownHaltPct) return 0.0;
   if(ddPct >= 8.0)             return 0.25;
   if(ddPct >= 5.0)             return 0.50;
   if(ddPct >= 3.0)             return 0.75;
   return 1.0;
  }

//----------------------------------------------------------------------
// SampleSizeGate
// True once enough closed trades exist to trust this EA's own hit-rate
// / expectancy statistics; false (be conservative) before that.
// g_closedTradeCount must be incremented by your own trade-close
// handling (e.g. OnTradeTransaction) — it is declared but not populated
// in this file, which does not implement trade management.
//----------------------------------------------------------------------
bool SampleSizeGate()
  {
   return g_closedTradeCount >= MinSampleSizeForStats;
  }

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
  {
   double riskMultiplier = DrawdownGovernor();
   if(riskMultiplier <= 0.0)
     {
      Comment("AutopsyXFlipdemonX15: HALTED — drawdown governor at 0 risk multiplier.");
      return;
     }

   // ---- Entry/exit signal logic is OUT OF SCOPE for this file ----
   // Wire your own VWAP/regime signal here (see docs/flipdemon-x15-spec.md
   // and the browser Flipdemon HFT Pro panel in index.html for the
   // reference rule set). Before sending any order, call
   // CalculateExpectedCost() with the position size and direction your
   // signal proposes, and reject or resize the trade if totalCost makes
   // its expected edge non-positive — that comparison needs a real
   // expected-edge estimate, which this file does not produce.

   Comment(StringFormat(
      "AutopsyXFlipdemonX15 | riskMultiplier=%.2f | adaptiveLookback=%d bars | sampleSizeGate=%s | commissionConfigured=%s",
      riskMultiplier,
      GetAdaptiveLookback(),
      SampleSizeGate() ? "PASS" : "WAIT",
      (CommissionPerLot > 0.0) ? "true" : "false"));
  }
