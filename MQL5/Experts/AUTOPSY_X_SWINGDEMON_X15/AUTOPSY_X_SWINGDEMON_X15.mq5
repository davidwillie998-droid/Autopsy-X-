//+------------------------------------------------------------------+
//|                                    AUTOPSY_X_SWINGDEMON_X15.mq5   |
//| Institutional Adaptive Swing Trading Intelligence Engine.         |
//|                                                                    |
//| Single-symbol-per-chart architecture: attach one instance per     |
//| instrument (XAUUSD first). Every instance sharing InpMagicNumber  |
//| is exposure-aware of every other instance's open positions, so    |
//| correlation/exposure limits hold across a multi-symbol deployment |
//| without one EA process having to juggle every symbol's ticks.     |
//+------------------------------------------------------------------+
#property strict
#property copyright "AUTOPSY X"
#property version   "1.00"

#include "core/Types.mqh"
#include "core/MarketState.mqh"
#include "core/StructureEngine.mqh"
#include "core/LiquidityEngine.mqh"
#include "core/IPDAEngine.mqh"
#include "core/RegimeEngine.mqh"
#include "core/BiasEngine.mqh"
#include "signals/SetupEngine.mqh"
#include "signals/ProbabilityEngine.mqh"
#include "signals/ExpectedValue.mqh"
#include "signals/SignalFusion.mqh"
#include "risk/RiskEngine.mqh"
#include "risk/ExposureEngine.mqh"
#include "risk/DrawdownEngine.mqh"
#include "execution/BrokerAdapter.mqh"
#include "execution/ExecutionEngine.mqh"
#include "execution/PositionManager.mqh"
#include "intelligence/CorrelationEngine.mqh"
#include "intelligence/NewsEngine.mqh"
#include "intelligence/SeasonalityEngine.mqh"
#include "intelligence/VolatilityEngine.mqh"
#include "autopsy/TradeJournal.mqh"
#include "autopsy/DiagnosticEngine.mqh"
#include "autopsy/DriftEngine.mqh"
#include "ui/Dashboard.mqh"

//==================== CORE ====================
input long   InpMagicNumber            = 150915;
input bool   InpEnableLiveTrading      = true;      // master switch; every other gate still applies
input bool   InpShowDashboard          = true;

//==================== RISK ====================
input double InpRiskPercentDefault        = 0.50;   // % equity risked on a full-quality A+ trade
input double InpMaxRiskPercentPerTrade    = 2.00;
input double InpMaxTotalOpenRiskPercent   = 6.00;
input double InpMaxCorrelatedRiskPercent  = 4.00;
input double InpCorrelationThreshold      = 0.60;
input int    InpMaxOpenPositions          = 3;
input double InpMaxDailyDrawdownPercent   = 3.00;
input double InpMaxWeeklyDrawdownPercent  = 6.00;
input double InpMaxMonthlyDrawdownPercent = 10.00;
input int    InpMaxConsecutiveLosses      = 5;

//==================== ENTRY ====================
input double InpMinConfidence   = 65.0;   // 0..100 fused confidence floor
input double InpMinRiskReward   = 1.30;   // TP1 distance / stop distance
input double InpMinExpectedR    = 0.15;   // EV floor, in R multiples
input bool   InpAllowGradeB     = false;  // A+/A only by default, per spec section 23

//==================== MANAGEMENT ====================
input double InpPartialClosePercent1 = 33.0;
input double InpPartialClosePercent2 = 33.0;

//==================== NEWS ====================
input bool InpNewsFilterEnabled        = true;
input int  InpPreEventBlackoutMinutes  = 30;
input int  InpPostEventConfirmMinutes  = 30;

//==================== EXECUTION ====================
input int InpMaxSpreadPoints  = 400;  // reject new entries above this spread; widen for exotic/metal quoting
input int InpDeviationPoints  = 30;
input int InpMaxRetries       = 3;

//==================== SAFETY ====================
input bool   InpEmergencyStop        = false;
input int    InpMaxTradesPerDay      = 6;
input int    InpMaxTradesPerWeek     = 20;
input double InpSlippageWarnPoints   = 15.0;

//==================== CORRELATION / MACRO ====================
input string InpCorrelationWatchList = "USDJPY,XAGUSD,USOIL,US500,BTCUSD";

//==================== WEEKEND ====================
enum ENUM_AX_WEEKEND_MODE { WEEKEND_HOLD, WEEKEND_REDUCE, WEEKEND_CLOSE };
input ENUM_AX_WEEKEND_MODE InpWeekendMode  = WEEKEND_HOLD;
input int InpWeekendActionHourServer       = 20; // server-time hour on Friday to apply the weekend action

//==================== engines (stable addresses: taken by pointer everywhere) ====================
CBrokerAdapter     g_broker;
CMarketState       g_market;
CStructureEngine   g_structure;
CLiquidityEngine   g_liquidity;
CIPDAEngine        g_ipda;
CRegimeEngine      g_regimeEngine;
CBiasEngine        g_biasEngine;
CVolatilityEngine  g_vol;
CNewsEngine        g_news;
CCorrelationEngine g_corr;
CSeasonalityEngine g_season;
CTradeJournal      g_journal;
CDiagnosticEngine  g_diag;
CDriftEngine       g_drift;
CRiskEngine        g_risk;
CExposureEngine    g_exposure;
CDrawdownEngine    g_drawdown;
CExecutionEngine   g_exec;
CPositionManager   g_posMgr;
CSetupEngine       g_setupEngine;
CProbabilityEngine g_prob;
CExpectedValue     g_ev;
CSignalFusion      g_fusion;
CDashboard         g_dash;

ulong  g_knownTickets[];
bool   g_tradingSuspended = false;
string g_suspendReason = "";
bool   g_weekendActionDoneToday = false;
int    g_tradesToday = 0, g_tradesThisWeek = 0;
int    g_lastCountedDay = -1, g_lastCountedWeek = -1;

//+------------------------------------------------------------------+
int OnInit()
  {
   g_broker.Init(_Symbol);
   g_market.Init(_Symbol);
   g_structure.Init(&g_market, 3, 3);
   g_liquidity.Init(&g_market, &g_structure, _Symbol);
   g_ipda.Init(&g_market);
   g_regimeEngine.Init(&g_market, &g_structure, &g_vol);
   g_biasEngine.Init(&g_market, &g_structure);
   g_vol.Init(&g_market);
   g_news.Init(_Symbol);

   g_corr.Init();
   string parts[];
   int n = StringSplit(InpCorrelationWatchList, ',', parts);
   for(int i=0;i<n;i++)
     {
      string s = parts[i];
      StringTrimLeft(s); StringTrimRight(s);
      if(s!="") g_corr.AddWatchSymbol(s);
     }

   g_season.Init();
   g_journal.Init(_Symbol, InpMagicNumber);
   for(int i=0;i<g_journal.Count();i++)
     {
      AXAutopsy r = g_journal.GetRecord(i);
      g_season.Record(r.openTime, r.rMultiple);
     }

   g_diag.Init(InpMaxTradesPerDay, InpMaxTradesPerWeek, InpSlippageWarnPoints);
   g_risk.Init(InpRiskPercentDefault, InpMaxRiskPercentPerTrade, InpMaxTotalOpenRiskPercent, InpMaxOpenPositions);
   g_exposure.Init(&g_corr, InpMaxCorrelatedRiskPercent, InpCorrelationThreshold);
   g_drawdown.Init(_Symbol, InpMagicNumber);
   g_exec.Init(&g_broker, _Symbol, InpMagicNumber, InpDeviationPoints, InpMaxRetries);
   g_posMgr.Init(&g_market, &g_structure, &g_exec, &g_broker, _Symbol, InpMagicNumber,
                 InpPartialClosePercent1, InpPartialClosePercent2);
   g_setupEngine.Init(&g_market, &g_structure, &g_liquidity, &g_ipda, &g_biasEngine, &g_vol, &g_news);
   g_prob.Init(&g_journal);
   g_ev.Init();
   g_fusion.Init(InpMinConfidence, InpMinRiskReward, InpMinExpectedR, InpAllowGradeB);
   if(InpShowDashboard) g_dash.Init("AXSD15_", 12, 20);

   RecoverExistingPositions();

   EventSetTimer(30);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   g_market.Deinit();
   g_regimeEngine.Deinit();
   g_biasEngine.Deinit();
   if(InpShowDashboard) g_dash.Deinit();
  }

//+------------------------------------------------------------------+
//| Scan open positions on OnInit and rebuild what we can - never    |
//| duplicate a position just because the terminal/EA restarted.     |
//+------------------------------------------------------------------+
void RecoverExistingPositions()
  {
   ArrayResize(g_knownTickets, 0);
   int total = PositionsTotal();
   for(int i=0;i<total;i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;

      int n=ArraySize(g_knownTickets); ArrayResize(g_knownTickets,n+1); g_knownTickets[n]=ticket;
      if(!g_posMgr.HasThesis(ticket))
         g_posMgr.AddThesis(g_posMgr.ReconstructThesis(ticket));
     }
  }

//+------------------------------------------------------------------+
bool IsOurPosition(ulong ticket)
  {
   if(!PositionSelectByTicket(ticket)) return false;
   return PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)==InpMagicNumber;
  }

bool TicketKnown(ulong ticket)
  {
   for(int i=0;i<ArraySize(g_knownTickets);i++) if(g_knownTickets[i]==ticket) return true;
   return false;
  }

//+------------------------------------------------------------------+
//| Detect positions that vanished since last tick -> journal them.  |
//| Detect new positions opened outside this loop (manual/other EA)  |
//| are ignored: only tickets we ever tracked get autopsied.         |
//+------------------------------------------------------------------+
void ReconcilePositions()
  {
   ulong stillOpen[];
   int total = PositionsTotal();
   for(int i=0;i<total;i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0 || !IsOurPosition(ticket)) continue;
      int n=ArraySize(stillOpen); ArrayResize(stillOpen,n+1); stillOpen[n]=ticket;
      if(!TicketKnown(ticket))
        {
         int k=ArraySize(g_knownTickets); ArrayResize(g_knownTickets,k+1); g_knownTickets[k]=ticket;
        }
     }

   for(int i=ArraySize(g_knownTickets)-1;i>=0;i--)
     {
      ulong ticket = g_knownTickets[i];
      bool stillHere=false;
      for(int j=0;j<ArraySize(stillOpen);j++) if(stillOpen[j]==ticket) { stillHere=true; break; }
      if(stillHere) continue;

      ENUM_AX_EXIT_REASON reason = InferExitReason(ticket);
      AXAutopsy rec = g_posMgr.BuildAutopsy(ticket, reason);
      g_journal.Append(rec);
      g_season.Record(rec.openTime, rec.rMultiple);
      g_drawdown.RecordTradeResult(rec.netProfit>0.0);
      g_posMgr.RemoveThesis(ticket);

      ArrayRemove(g_knownTickets, i, 1);
     }
  }

ENUM_AX_EXIT_REASON InferExitReason(ulong ticket)
  {
   if(!HistorySelectByPosition((long)ticket)) return EXIT_MANUAL;
   int deals = HistoryDealsTotal();
   for(int i=deals-1;i>=0;i--)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d==0) continue;
      if(HistoryDealGetInteger(d, DEAL_ENTRY)!=DEAL_ENTRY_OUT) continue;
      ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(d, DEAL_REASON);
      if(reason==DEAL_REASON_SL) return EXIT_SL;
      if(reason==DEAL_REASON_TP) return EXIT_TP_FINAL;
      return EXIT_MANUAL;
     }
   return EXIT_MANUAL;
  }

//+------------------------------------------------------------------+
//| Real, live checks - never assume infrastructure is healthy.      |
//+------------------------------------------------------------------+
bool CheckFailsafes(string &reason)
  {
   if(InpEmergencyStop) { reason="Emergency stop engaged by input"; return false; }
   if(!TerminalInfoInteger(TERMINAL_CONNECTED)) { reason="Terminal not connected to trade server"; return false; }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) { reason="Terminal trading disabled (AutoTrading off)"; return false; }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) { reason="EA trading permission not granted"; return false; }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)) { reason="Account trading disabled"; return false; }
   if(!SymbolInfoInteger(_Symbol, SYMBOL_SELECT)) { reason="Symbol not selected/available"; return false; }
   if(g_broker.SpreadPoints() > InpMaxSpreadPoints) { reason=StringFormat("Spread %.0f pts exceeds max %d", g_broker.SpreadPoints(), InpMaxSpreadPoints); return false; }
   double marginLevel = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   if(AccountInfoDouble(ACCOUNT_MARGIN)>0.0 && marginLevel>0.0 && marginLevel<150.0)
      { reason=StringFormat("Margin level %.0f%% unsafe", marginLevel); return false; }
   long lastTick = (long)SymbolInfoInteger(_Symbol, SYMBOL_TIME);
   if(TimeCurrent()-lastTick > 300) { reason="Market data stale (>5min since last tick)"; return false; }
   reason="";
   return true;
  }

//+------------------------------------------------------------------+
void RefreshTradeCounters()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.day!=g_lastCountedDay) { g_tradesToday=0; g_lastCountedDay=dt.day; }
   int week = g_drawdown.ISOWeekNumber(TimeCurrent());
   if(week!=g_lastCountedWeek) { g_tradesThisWeek=0; g_lastCountedWeek=week; }
  }

//+------------------------------------------------------------------+
void HandleWeekendRisk()
  {
   if(InpWeekendMode==WEEKEND_HOLD) return;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week!=5 || dt.hour<InpWeekendActionHourServer) { g_weekendActionDoneToday=false; return; }
   if(g_weekendActionDoneToday) return;

   int total = PositionsTotal();
   for(int i=0;i<total;i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0 || !IsOurPosition(ticket)) continue;
      if(InpWeekendMode==WEEKEND_CLOSE)
         g_exec.CloseFull(ticket);
      else if(InpWeekendMode==WEEKEND_REDUCE)
        {
         double vol = PositionGetDouble(POSITION_VOLUME);
         g_exec.ClosePartial(ticket, g_broker.NormalizeVolume(vol*0.5));
        }
     }
   g_weekendActionDoneToday = true;
  }

//+------------------------------------------------------------------+
//| Best-effort macro proxy: DXY-style relationship inferred purely  |
//| from the traded symbol's own currency legs against a correlated  |
//| watch-symbol's trend. Degrades to zero reliability (no opinion)  |
//| when nothing usable is configured - never invents a macro view.  |
//+------------------------------------------------------------------+
void GetMacroContext(ENUM_AX_BIAS &macroBias, double &macroReliability, string &macroNote)
  {
   macroBias = BIAS_NEUTRAL; macroReliability = 0.0; macroNote = "No reliable macro proxy configured";
   string profitCcy = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
   string baseCcy   = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   bool inverseToUsd = (profitCcy=="USD" && baseCcy!="USD");
   bool directToUsd  = (baseCcy=="USD");
   if(!inverseToUsd && !directToUsd) return;

   for(int i=0;i<g_corr.WatchCount();i++)
     {
      string ws = g_corr.WatchSymbol(i);
      if(StringFind(ws,"USD")<0 && StringFind(ws,"DXY")<0) continue;
      double closeNow = iClose(ws, PERIOD_D1, 0);
      double closePast = iClose(ws, PERIOD_D1, 10);
      if(closeNow<=0.0 || closePast<=0.0) continue;
      bool usdProxyRising = closeNow>closePast;
      ENUM_AX_BIAS proxyBias = usdProxyRising ? BIAS_BULLISH : BIAS_BEARISH;
      macroBias = (inverseToUsd) ? (proxyBias==BIAS_BULLISH?BIAS_BEARISH:BIAS_BULLISH) : proxyBias;
      macroReliability = 0.5; // proxy-derived, not a real macro dataset - moderate weight only
      macroNote = StringFormat("Proxy via %s trend (%s to USD)", ws, inverseToUsd?"inverse":"direct");
      return;
     }
  }

//+------------------------------------------------------------------+
void TryEnterTrade()
  {
   if(g_risk.WouldExceedMaxPositions(InpMagicNumber)) return;

   AXBiasStack biasStack = g_biasEngine.GetBiasStack();
   ENUM_AX_REGIME regime = g_regimeEngine.Classify(PERIOD_H1);
   AXDealingRange dr = g_ipda.GetDealingRange(PERIOD_H4, 40);

   AXLiquidityLevel levels[];
   g_liquidity.GetLevels(levels);

   string preEvent="", postEvent="";
   if(InpNewsFilterEnabled)
     {
      if(g_news.InPreEventWindow(InpPreEventBlackoutMinutes, preEvent)) return; // no new exposure into a scheduled release
      g_news.InPostEventWindow(InpPostEventConfirmMinutes, postEvent);
     }

   AXSignal candidates[];
   g_setupEngine.EvaluateAll(biasStack, regime, dr, levels, preEvent, postEvent, candidates);
   if(ArraySize(candidates)==0) return; // NO TRADE is a valid, and the default, outcome

   AXFusedSignal best; bool haveBest=false;

   for(int i=0;i<ArraySize(candidates);i++)
     {
      AXSignal sig = candidates[i];
      bool wellLocated = g_ipda.IsWellLocated(sig.direction, dr);

      AXOrderBlock obs[];
      g_structure.GetOrderBlocks(PERIOD_H4, obs, 40);
      double structQuality = 55.0;
      for(int k=0;k<ArraySize(obs);k++)
         if(obs[k].bullish==(sig.direction>0)) { structQuality=MathMax(structQuality,obs[k].qualityScore); }

      ENUM_AX_VOL_REGIME volRegime = g_vol.Classify(PERIOD_H1);

      ENUM_AX_BIAS structuralBias = sig.direction>0?BIAS_BULLISH:BIAS_BEARISH;
      ENUM_AX_BIAS macroBias; double macroReliability; string macroNote;
      GetMacroContext(macroBias, macroReliability, macroNote);
      double corrConfirm = 0.0;
      if(macroReliability>0.0) corrConfirm = (macroBias==structuralBias) ? 1.0 : -1.0;

      double probCont = g_prob.ProbContinuation(sig.setup);
      double riskDist = MathAbs(sig.entryPrice-sig.stopLoss);
      double r1 = riskDist>0.0 ? MathAbs(sig.tp1-sig.entryPrice)/riskDist : 0.0;
      double r2 = riskDist>0.0 ? MathAbs(sig.tp2-sig.entryPrice)/riskDist : 0.0;
      double rF = riskDist>0.0 ? MathAbs(sig.tpFinal-sig.entryPrice)/riskDist : 0.0;
      double p1 = g_prob.ProbTp1(sig.setup, r1);
      double p2 = g_prob.ProbTp2(sig.setup, r2);
      double pF = g_prob.ProbFinal(sig.setup, rF);

      double provisionalVolume = g_risk.ComputeVolume(g_broker, InpRiskPercentDefault, riskDist);
      double costR = g_ev.CostInR(g_broker, g_broker.SpreadPoints(), 0.0, InpDeviationPoints*0.3, MathMax(provisionalVolume,g_broker.volumeMin), riskDist);
      double expectedR = g_ev.ComputeExpectedR(r1, r2, rF, p1, p2, pF, costR);

      AXFusedSignal fused = g_fusion.Fuse(sig, biasStack, wellLocated, structQuality, volRegime,
                                          corrConfirm, macroReliability, probCont, p1, p2, pF, expectedR);
      // macro context can only ever adjust confidence, never invert the structurally-derived direction
      fused.confidence = g_biasEngine.ApplyMacroModifier(fused.confidence, structuralBias, macroBias, macroReliability);
      fused.confidence += g_season.ConfidenceModifierNow();
      fused.confidence = MathMax(0.0, MathMin(100.0, fused.confidence));
      fused.quality = g_fusion.QualityFromConfidence(fused.confidence);

      if(!fused.passesFilters) continue;
      if(!haveBest || fused.confidence>best.confidence) { best=fused; haveBest=true; }
     }

   if(!haveBest) return;

   AXDriftReport drift = g_drift.Evaluate(g_journal);
   double volMult = g_vol.SizeMultiplierFor(g_vol.Classify(PERIOD_H1)) * g_drift.RiskMultiplierFor(drift);
   double riskPct = g_risk.RiskPercentForTrade(best.quality, volMult, g_drawdown.ConsecutiveLosses());
   if(riskPct<=0.0) return;

   if(g_risk.WouldExceedOpenRiskCap(InpMagicNumber, riskPct)) return;
   string exReason;
   if(!g_exposure.AllowsNewExposure(_Symbol, InpMagicNumber, riskPct, exReason)) return;
   if(g_exposure.HasOpposingPosition(_Symbol, InpMagicNumber, best.signal.direction)) return;

   double riskDist = MathAbs(best.signal.entryPrice-best.signal.stopLoss);
   double volume = g_risk.ComputeVolume(g_broker, riskPct, riskDist);
   if(volume < g_broker.volumeMin) return;

   AXExecutionResult res = g_exec.OpenMarket(best.signal.direction, volume, best.signal.stopLoss, best.signal.tpFinal,
                                              StringFormat("AXSD15-%s", AXSetupToString(best.signal.setup)));
   if(!res.success) return;

   AXTradeThesis thesis;
   thesis.ticket=res.ticket; thesis.direction=best.signal.direction;
   thesis.whyNow=best.signal.rationaleWhyNow; thesis.whyHere=best.signal.rationaleWhyHere;
   thesis.liquidityTarget=best.signal.liquidityTarget; thesis.structuralInvalidation=best.signal.stopLoss;
   thesis.expectedHoldingBars=24; thesis.expectedR=best.expectedValueR;
   thesis.macroContext = StringFormat("bias=%s conf=%.0f", AXBiasToString(biasStack.composite), biasStack.alignmentScore);
   thesis.regime=regime; thesis.confidence=best.confidence; thesis.setup=best.signal.setup; thesis.quality=best.quality;
   thesis.openTime=TimeCurrent(); thesis.entryPrice=res.executedPrice; thesis.stopLoss=best.signal.stopLoss;
   thesis.tp1=best.signal.tp1; thesis.tp2=best.signal.tp2; thesis.tpFinal=best.signal.tpFinal;
   thesis.initialStopDistance=MathAbs(res.executedPrice-best.signal.stopLoss);
   thesis.initialRiskMoney = g_broker.RiskMoneyForStop(thesis.initialStopDistance, volume);
   thesis.equityAtEntry = AccountInfoDouble(ACCOUNT_EQUITY);
   thesis.volumeOriginal=volume; thesis.volumeRemaining=volume;
   thesis.phase=PHASE_1_INITIAL; thesis.partial1Done=false; thesis.partial2Done=false; thesis.movedToBreakeven=false;
   thesis.mfe=0.0; thesis.mae=0.0; thesis.highestPrice=res.executedPrice; thesis.lowestPrice=res.executedPrice;
   g_posMgr.AddThesis(thesis);

   int kt=ArraySize(g_knownTickets); ArrayResize(g_knownTickets,kt+1); g_knownTickets[kt]=res.ticket;
   g_tradesToday++; g_tradesThisWeek++;

   PrintFormat("AXSD15 ENTER #%I64u %s dir=%d setup=%s quality=%s conf=%.1f R=%.2f vol=%.2f",
               res.ticket, _Symbol, best.signal.direction, AXSetupToString(best.signal.setup),
               AXQualityToString(best.quality), best.confidence, best.expectedValueR, volume);
  }

//+------------------------------------------------------------------+
void RenderDashboard()
  {
   if(!InpShowDashboard) return;
   AXDashboardData d;
   d.symbol=_Symbol; d.price=g_market.Mid(); d.spreadPoints=g_broker.SpreadPoints();
   ENUM_AX_REGIME regime = g_regimeEngine.Classify(PERIOD_H1);
   d.regime = AXRegimeToString(regime);
   d.volState = EnumToString(g_vol.Classify(PERIOD_H1));

   AXBiasStack bs = g_biasEngine.GetBiasStack();
   d.macroBias=AXBiasToString(bs.monthly); d.weeklyBias=AXBiasToString(bs.weekly);
   d.dailyBias=AXBiasToString(bs.daily); d.h4Bias=AXBiasToString(bs.h4); d.h1Bias=AXBiasToString(bs.h1);

   AXLiquidityLevel levels[]; g_liquidity.GetLevels(levels);
   d.nearestLiquidity = ArraySize(levels)>0 ? levels[0].label : "n/a";
   d.majorLiquidity = ArraySize(levels)>1 ? levels[1].label : "n/a";
   AXLiquidityLevel draw;
   d.currentDraw = g_liquidity.GetProbableDraw(bs.composite==BIAS_BEARISH?-1:1, levels, draw) ? draw.label : "n/a";

   d.setupType = g_posMgr.Count()>0 ? AXSetupToString(g_posMgr.GetThesis(0).setup) : "none open";
   d.confidence = g_posMgr.Count()>0 ? g_posMgr.GetThesis(0).confidence : 0.0;
   d.score = d.confidence;
   if(g_posMgr.Count()>0)
     {
      AXTradeThesis t = g_posMgr.GetThesis(0);
      d.entry=t.entryPrice; d.sl=t.stopLoss; d.tp1=t.tp1; d.tp2=t.tp2; d.tpFinal=t.tpFinal; d.expectedR=t.expectedR;
     }
   else { d.entry=0;d.sl=0;d.tp1=0;d.tp2=0;d.tpFinal=0;d.expectedR=0; }

   d.equity=AccountInfoDouble(ACCOUNT_EQUITY);
   d.currentRiskPct=InpRiskPercentDefault;
   d.openExposurePct=g_risk.CurrentOpenRiskPercent(InpMagicNumber);
   d.drawdownPct=g_drawdown.DailyDrawdownPercent();
   d.dailyStatus = g_tradingSuspended ? ("SUSPENDED: "+g_suspendReason) : "Normal";

   AXExecutionQualityStats q = g_exec.QualityStats();
   d.execSpread=g_broker.SpreadPoints(); d.execSlippage=q.avgSlippagePoints;
   d.brokerStatus = g_broker.tradeAllowed ? "OK" : "RESTRICTED";

   d.recentTrades=g_journal.Count(); d.expectancy=g_journal.Expectancy(20);
   d.aPlusPerformance = StringFormat("%.2fR avg", g_journal.SetupExpectancy(SETUP_A_SWEEP_MSS,20));
   d.regimePerformance = StringFormat("%s: %.2fR", d.regime, g_journal.RegimeExpectancy(regime,20));
   d.tradingState = g_tradingSuspended ? "SUSPENDED" : "ACTIVE";

   g_dash.Render(d);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   g_broker.Refresh();
   g_market.Update();
   RefreshTradeCounters();

   string failReason;
   bool healthy = CheckFailsafes(failReason);
   string ddText;
   g_drawdown.Update();
   bool hardStop = g_drawdown.CheckHardStops(InpMaxDailyDrawdownPercent, InpMaxWeeklyDrawdownPercent,
                                              InpMaxMonthlyDrawdownPercent, InpMaxConsecutiveLosses, ddText);

   g_tradingSuspended = (!healthy) || hardStop || (!InpEnableLiveTrading);
   g_suspendReason = !healthy ? failReason : (hardStop ? ddText : (!InpEnableLiveTrading ? "Live trading disabled by input" : ""));

   ReconcilePositions();

   int total = PositionsTotal();
   for(int i=0;i<total;i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0 || !IsOurPosition(ticket)) continue;
      g_posMgr.Update(ticket);
     }

   HandleWeekendRisk();

   if(!g_tradingSuspended && g_market.IsNewBar(PERIOD_H1))
     {
      string diagReason;
      AXExecutionQualityStats q = g_exec.QualityStats();
      bool suspendForDiag = g_diag.ShouldSuspend(g_journal, g_tradesToday, g_tradesThisWeek, q.avgSlippagePoints, diagReason);
      if(!suspendForDiag)
         TryEnterTrade();
     }

   static datetime lastDashRender=0;
   if(TimeCurrent()-lastDashRender>=1)
     {
      RenderDashboard();
      lastDashRender=TimeCurrent();
     }
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   HandleWeekendRisk();
  }

//+------------------------------------------------------------------+
void OnTrade()
  {
   ReconcilePositions();
  }
