//+------------------------------------------------------------------+
//|                                    AUTOPSY_X_FLIPDEMON_X15.mq5      |
//|                                                                      |
//| Adaptive High-Conviction Account Growth & Capital Survival Engine.  |
//|                                                                       |
//| This file only ORCHESTRATES. Every actual decision rule lives in a  |
//| named engine under Core/, Intelligence/, Risk/, Execution/, Autopsy/ |
//| or UI/, so the decision hierarchy in Section 33 of the spec can be   |
//| read here top-to-bottom as a sequence of named calls rather than     |
//| buried inline logic.                                                 |
//|                                                                       |
//| LIVE TRADING FIRST: Inp_LiveTradingEnabled must be explicitly true   |
//| before any order is ever sent. Strategy Tester users should still    |
//| set it true to see real order flow; it exists to stop an accidental  |
//| drag-onto-chart from trading a live account unattended.               |
//+------------------------------------------------------------------+
#property copyright "AUTOPSY X FLIPDEMON X15"
#property version   "1.00"
#property strict

#include "Common/Defines.mqh"
#include "Common/Inputs.mqh"

#include "Core/MarketEngine.mqh"
#include "Core/VolatilityEngine.mqh"
#include "Core/RegimeEngine.mqh"
#include "Core/StructureEngine.mqh"
#include "Core/LiquidityEngine.mqh"

#include "Intelligence/BiasEngine.mqh"
#include "Intelligence/ProbabilityEngine.mqh"
#include "Intelligence/OpportunityEngine.mqh"
#include "Intelligence/ExpectedValue.mqh"
#include "Intelligence/CorrelationEngine.mqh"

#include "Risk/RiskEngine.mqh"
#include "Risk/CompoundingEngine.mqh"
#include "Risk/RuinEngine.mqh"
#include "Risk/DrawdownEngine.mqh"
#include "Risk/ExposureEngine.mqh"

#include "Execution/BrokerAdapter.mqh"
#include "Execution/ExecutionEngine.mqh"
#include "Execution/PositionManager.mqh"

#include "Autopsy/TradeJournal.mqh"
#include "Autopsy/DiagnosticEngine.mqh"
#include "Autopsy/DriftEngine.mqh"

#include "UI/Dashboard.mqh"

//+------------------------------------------------------------------+
//| per-symbol engine bundles (own indicator handles)                  |
//+------------------------------------------------------------------+
string                  g_symbols[];
CAxfMarketEngine        g_market[];
CAxfVolatilityEngine    g_volatility[];
CAxfRegimeEngine        g_regime[];

//--- account-wide / stateless-shared engines (single instances)
CAxfStructureEngine     g_structure;
CAxfLiquidityEngine     g_liquidity;
CAxfBiasEngine          g_bias;
CAxfProbabilityEngine   g_probability;
CAxfOpportunityEngine   g_opportunity;
CAxfExpectedValue       g_ev;
CAxfRiskEngine          g_riskEngine;
CAxfCompoundingEngine   g_compounding;
CAxfRuinEngine          g_ruinEngine;
CAxfDrawdownEngine      g_drawdown;
CAxfExposureEngine      g_exposure;
CAxfBrokerAdapter       g_broker;
CAxfExecutionEngine     g_execution;
CAxfPositionManager     g_posManager;
CAxfTradeJournal        g_journal;
CAxfDiagnosticEngine    g_diagnostic;
CAxfDecisionAudit       g_audit;
CAxfDriftEngine         g_drift;
CAxfDashboard           g_dashboard;

SAxfRuinEstimate        g_lastRuinAnalytical;
SAxfRuinEstimate        g_lastRuinMonteCarlo;
datetime                g_lastMonteCarloRun = 0;
ENUM_AXF_STATE          g_state = STATE_INITIALIZING;
string                  g_lastDecisionReason = "";

//--- lightweight open-position metadata, keyed by ticket, for MFE/MAE and
//--- journaling at close (Section 34). Sized generously; linear scan is fine
//--- at EA position-count scale.
struct SOpenMeta
  {
   ulong             ticket;
   string            symbol;
   ENUM_AXF_DIRECTION direction;
   ENUM_AXF_REGIME  regime;
   datetime          open_time;
   double            entry, stop, target1, target2, risk_pct;
   double            mfe_r, mae_r;
   ENUM_AXF_GROWTH_MODE mode;
   double            flip_score;
   string            entry_reason;
   int               adds;
  };
SOpenMeta               g_openMeta[];

bool                     g_bridgeUsable = true;
datetime                 g_lastBridgePost = 0;

//+------------------------------------------------------------------+
//| helpers                                                             |
//+------------------------------------------------------------------+
int FindMeta(const ulong ticket)
  {
   for(int i=0;i<ArraySize(g_openMeta);i++) if(g_openMeta[i].ticket==ticket) return i;
   return -1;
  }

void RemoveMeta(const int idx)
  {
   int n = ArraySize(g_openMeta);
   if(idx<0 || idx>=n) return;
   for(int i=idx;i<n-1;i++) g_openMeta[i]=g_openMeta[i+1];
   ArrayResize(g_openMeta,n-1);
  }

int SymbolIndex(const string symbol)
  {
   for(int i=0;i<ArraySize(g_symbols);i++) if(g_symbols[i]==symbol) return i;
   return -1;
  }

double AccountHealthScore(void)
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd = g_compounding.DrawdownFromHighPct(equity);
   double score = 100.0 - dd*4.0; // every 1% drawdown costs 4 health points
   if(g_drawdown.LossStreakForcesHalt(g_compounding.ConsecLosses())) score -= 40;
   return AxfClamp(score,0,100);
  }

//+------------------------------------------------------------------+
//| Section 28 — NEWS DEFENSE (best-effort; degrades to "not blocked"  |
//| if the terminal's economic calendar is unavailable, never fakes a  |
//| calendar read — see Section 44, No Fabricated Intelligence).       |
//+------------------------------------------------------------------+
bool IsNewsBlackout(const string symbol)
  {
   if(!Inp_NewsDefenseEnabled) return false;

   string base = SymbolInfoString(symbol,SYMBOL_CURRENCY_BASE);
   string profit = SymbolInfoString(symbol,SYMBOL_CURRENCY_PROFIT);

   datetime from = TimeCurrent() - Inp_NewsBlackoutMinsAfter*60;
   datetime to   = TimeCurrent() + Inp_NewsBlackoutMinsBefore*60;

   MqlCalendarValue values[];
   if(!CalendarValueHistory(values,from,to))
      return false; // calendar unavailable on this terminal/broker -> UNKNOWN, do not block

   for(int i=0;i<ArraySize(values);i++)
     {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id,ev)) continue;
      if(ev.importance != CALENDAR_IMPORTANCE_HIGH) continue;

      MqlCalendarCountry country;
      if(!CalendarCountryById(ev.country_id,country)) continue;
      if(country.currency==base || country.currency==profit)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Bridge telemetry (optional) — POSTs ticks/account to the AUTOPSY X  |
//| web dashboard bridge already in this repo's /server. Silently       |
//| disables itself after one failure (e.g. URL not allow-listed in     |
//| Tools->Options->Expert Advisors) rather than spamming errors.       |
//+------------------------------------------------------------------+
void PostBridgeTelemetry(void)
  {
   if(!Inp_BridgeEnabled || !g_bridgeUsable) return;
   if(TimeCurrent()-g_lastBridgePost < Inp_BridgePostSeconds) return;
   g_lastBridgePost = TimeCurrent();

   char post[]; char result[]; string headers;
   string account_json = StringFormat(
      "{\"balance\":%.2f,\"equity\":%.2f,\"margin\":%.2f,\"freeMargin\":%.2f,\"currency\":\"%s\",\"leverage\":%d,\"type\":\"live\"}",
      AccountInfoDouble(ACCOUNT_BALANCE),AccountInfoDouble(ACCOUNT_EQUITY),
      AccountInfoDouble(ACCOUNT_MARGIN),AccountInfoDouble(ACCOUNT_MARGIN_FREE),
      AccountInfoString(ACCOUNT_CURRENCY),(int)AccountInfoInteger(ACCOUNT_LEVERAGE));

   StringToCharArray(account_json,post,0,WHOLE_ARRAY,CP_UTF8);
   string url = Inp_BridgeURL+"/ingest/account";
   string hdr = "Content-Type: application/json\r\nx-bridge-key: "+Inp_BridgeKey+"\r\n";
   int rc = WebRequest("POST",url,hdr,3000,post,result,headers);
   if(rc==-1)
     {
      Print("AXF Bridge: WebRequest failed (",GetLastError(),
            "). Add ",Inp_BridgeURL," to Tools->Options->Expert Advisors->Allow WebRequest, or disable Inp_BridgeEnabled. Disabling bridge for this session.");
      g_bridgeUsable = false;
     }
  }

//+------------------------------------------------------------------+
//| per-symbol init/deinit                                             |
//+------------------------------------------------------------------+
bool InitSymbols(void)
  {
   string parts[];
   int n = StringSplit(Inp_TradedSymbols,',',parts);
   if(n<=0) return false;

   ArrayResize(g_symbols,0); ArrayResize(g_market,n); ArrayResize(g_volatility,n); ArrayResize(g_regime,n);
   int valid=0;
   for(int i=0;i<n;i++)
     {
      string s = parts[i];
      StringTrimLeft(s); StringTrimRight(s);
      if(StringLen(s)==0) continue;
      if(!SymbolSelect(s,true))
        {
         Print("AXF: symbol not available at this broker, skipping: ",s);
         continue;
        }

      ArrayResize(g_symbols,valid+1);
      g_symbols[valid]=s;

      if(!g_market[valid].Init(s)) { Print("AXF: MarketEngine init failed for ",s); }
      if(!g_volatility[valid].Init(s,Inp_ATR_Timeframe,Inp_ATR_Period,Inp_VolLookback))
         Print("AXF: VolatilityEngine init failed for ",s);
      if(!g_regime[valid].Init(s,Inp_HTF,Inp_ADX_Period,Inp_ADX_StrongTrend))
         Print("AXF: RegimeEngine init failed for ",s);

      valid++;
     }
   ArrayResize(g_market,valid); ArrayResize(g_volatility,valid); ArrayResize(g_regime,valid);
   return valid>0;
  }

//+------------------------------------------------------------------+
//| Expert initialization                                               |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_state = STATE_INITIALIZING;

   if(!InitSymbols())
     {
      Print("AXF FATAL: no traded symbols could be initialised.");
      return INIT_FAILED;
     }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   g_structure.Init(Inp_SwingLookback,Inp_StructureBars,Inp_FVG_MinAtrFraction);
   g_bias.Init(Inp_DXY_Symbol);
   g_probability.Init(50);
   g_opportunity.Init(Inp_MinRR_Required);
   g_riskEngine.Init(Inp_BaseRiskPct,Inp_MaxRiskPct,Inp_FlipModeEnabled,Inp_FlipRiskMultiplier);
   g_compounding.Init(Inp_MagicNumber,equity);
   g_ruinEngine.Init(Inp_MonteCarloPaths,Inp_MonteCarloTrades,
                      Inp_RuinThreshold_Elevated,Inp_RuinThreshold_Defensive,Inp_RuinThreshold_Halt);
   g_drawdown.Init(Inp_MagicNumber,Inp_DailyMaxDrawdownPct,Inp_WeeklyMaxDrawdownPct,Inp_MaxAccountDrawdownPct,
                   Inp_LossStreak_Reduce1,Inp_LossStreak_Reduce2,Inp_LossStreak_Halt,Inp_LossStreak_CutFactor,
                   Inp_WinStreak_ReviewAt,Inp_WinStreak_CapFactor,equity);
   g_exposure.Init(Inp_MagicNumber,Inp_MaxPortfolioRiskPct);
   g_execution.Init(Inp_MagicNumber,Inp_MaxSlippagePoints,Inp_MaxOrderRetries);
   g_posManager.Init(Inp_MagicNumber,Inp_PyramidingEnabled,Inp_MaxAddsPerPosition);
   g_journal.Init(Inp_MagicNumber);
   g_diagnostic.Init(Inp_FlipScore_Elite,Inp_FlipScore_APlus,Inp_FlipScore_A,Inp_FlipScore_B);
   g_drift.Init(20,60);
   g_dashboard.Init("AXF15_"+IntegerToString((long)Inp_MagicNumber));
   CreateResetHaltButton();

   //--- Section 41 TERMINAL RECOVERY: reconstruct metadata for any EA
   //--- positions already open (survives a restart). Risk is reconstructed
   //--- from the live SL distance rather than assumed.
   ReconstructOpenMetaFromPositions();

   EventSetTimer(MathMax(1,Inp_TimerSeconds));
   g_state = STATE_COOLDOWN;
   Print("AXF FLIPDEMON X15 initialised. Live trading enabled: ",Inp_LiveTradingEnabled ? "YES" : "NO (analysis-only)");
   return INIT_SUCCEEDED;
  }

void ReconstructOpenMetaFromPositions(void)
  {
   ArrayResize(g_openMeta,0);
   for(int i=0;i<PositionsTotal();i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=Inp_MagicNumber) continue;

      SOpenMeta m;
      m.ticket = ticket;
      m.symbol = PositionGetString(POSITION_SYMBOL);
      long type = PositionGetInteger(POSITION_TYPE);
      m.direction = (type==POSITION_TYPE_BUY) ? DIR_LONG : DIR_SHORT;
      m.regime = REGIME_UNKNOWN; // unknown after restart; does not affect safety, only journal labelling
      m.open_time = (datetime)PositionGetInteger(POSITION_TIME);
      m.entry = PositionGetDouble(POSITION_PRICE_OPEN);
      m.stop  = PositionGetDouble(POSITION_SL);
      m.target1 = PositionGetDouble(POSITION_TP);
      m.target2 = m.target1;
      double dist = MathAbs(m.entry-m.stop);
      double tick_value = SymbolInfoDouble(m.symbol,SYMBOL_TRADE_TICK_VALUE);
      double tick_size  = SymbolInfoDouble(m.symbol,SYMBOL_TRADE_TICK_SIZE);
      double vol = PositionGetDouble(POSITION_VOLUME);
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      m.risk_pct = (dist>0 && tick_size>0 && equity>0) ? (dist/tick_size)*tick_value*vol/equity*100.0 : 0.0;
      m.mfe_r=0; m.mae_r=0;
      m.mode = MODE_NORMAL;
      m.flip_score = 0;
      m.entry_reason = "RECOVERED_ON_RESTART";
      m.adds = 0;

      int n=ArraySize(g_openMeta);
      ArrayResize(g_openMeta,n+1);
      g_openMeta[n]=m;
     }
   if(ArraySize(g_openMeta)>0)
      Print("AXF: recovered ",ArraySize(g_openMeta)," open EA position(s) after (re)start.");
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   g_dashboard.Remove();
   ObjectDelete(0,ResetHaltButtonName());
  }

//+------------------------------------------------------------------+
//| manual reset control for the account-max-drawdown HALT latch       |
//| (Section 5/40: this halt requires a human, never auto-clears).     |
//+------------------------------------------------------------------+
string ResetHaltButtonName(void) { return "AXF15_"+IntegerToString((long)Inp_MagicNumber)+"_ResetHalt"; }

void CreateResetHaltButton(void)
  {
   string name = ResetHaltButtonName();
   if(ObjectFind(0,name)>=0) return;
   ObjectCreate(0,name,OBJ_BUTTON,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,10);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,320);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,220);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,22);
   ObjectSetString(0,name,OBJPROP_TEXT,"RESET ACCOUNT HALT (manual)");
   ObjectSetInteger(0,name,OBJPROP_COLOR,clrWhite);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,clrFireBrick);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
  }

void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
  {
   if(id==CHARTEVENT_OBJECT_CLICK && sparam==ResetHaltButtonName())
     {
      g_drawdown.ClearManualHalt();
      ObjectSetInteger(0,ResetHaltButtonName(),OBJPROP_STATE,false);
      Print("AXF: account max-drawdown HALT manually cleared by operator at the chart.");
     }
  }

//+------------------------------------------------------------------+
//| Section 33 DECISION ENGINE — the full hierarchy for one symbol.    |
//| Returns true only if a new trade should be opened; 'lots_out' and   |
//| 'opp_out' carry the sized, approved trade.                          |
//+------------------------------------------------------------------+
bool EvaluateSymbol(const int idx,SAxfOpportunity &opp_out,double &lots_out,
                    ENUM_AXF_GROWTH_MODE &mode_out,double &flip_score_out,double &risk_pct_out,
                    ENUM_AXF_REGIME &regime_out)
  {
   string symbol = g_symbols[idx];

   //--- defensive defaults: every out-param is sane even on the earliest
   //--- rejection, so a caller never reads an uninitialised local.
   lots_out = 0.0; mode_out = MODE_NORMAL; flip_score_out = 0.0; risk_pct_out = 0.0;
   regime_out = REGIME_UNKNOWN;

   //--- rung 1: ACCOUNT SURVIVAL
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_compounding.UpdateEquityWatermark(equity);
   if(g_drawdown.CheckAccountMaxDrawdown(g_compounding.EquityHigh(),equity))
     { g_audit.Reject(DECISION_REJECT_ACCOUNT_SURVIVAL,"max account drawdown breached — manual reset required"); return false; }
   if(g_drawdown.DailyLimitBreached(equity))
     { g_audit.Reject(DECISION_REJECT_ACCOUNT_SURVIVAL,"daily drawdown limit reached"); return false; }
   if(g_drawdown.WeeklyLimitBreached(equity))
     { g_audit.Reject(DECISION_REJECT_ACCOUNT_SURVIVAL,"weekly drawdown limit reached"); return false; }
   if(g_drawdown.LossStreakForcesHalt(g_compounding.ConsecLosses()))
     { g_audit.Reject(DECISION_REJECT_ACCOUNT_SURVIVAL,"consecutive loss halt — awaiting manual review"); return false; }

   //--- rung 2: BROKER / EXECUTION SAFETY (spread/stops checked properly once
   //--- we know the stop distance, further down; a coarse check here first)
   string broker_reason = g_broker.PreTradeCheck(symbol,Inp_MaxSpreadPoints,0);
   if(broker_reason!="")
     { g_audit.Reject(DECISION_REJECT_BROKER_SAFETY,broker_reason); return false; }

   //--- rung 3: DATA QUALITY
   if(!g_market[idx].IsDataFresh())
     { g_audit.Reject(DECISION_REJECT_DATA_QUALITY,"stale or invalid tick data"); return false; }

   //--- rung 4: MARKET REGIME
   SAxfVolatility vol = g_volatility[idx].Compute(symbol);
   if(!vol.valid)
     { g_audit.Reject(DECISION_REJECT_DATA_QUALITY,"insufficient volatility history"); return false; }
   SAxfRegime regime = g_regime[idx].Compute(symbol,vol);
   if(!regime.valid)
     { g_audit.Reject(DECISION_REJECT_DATA_QUALITY,"insufficient regime history"); return false; }
   regime_out = regime.regime;
   if(CAxfRegimeEngine::ForcesCapitalPreservation(regime.regime))
     { g_audit.Reject(DECISION_REJECT_REGIME,"regime forces capital preservation: "+AxfRegimeToString(regime.regime)); return false; }

   //--- rung 5: HTF BIAS
   SAxfStructure htf_structure = g_structure.Compute(symbol,Inp_HTF,vol.atr);
   ENUM_AXF_DIRECTION htf_bias = g_bias.HtfBias(htf_structure);
   if(htf_bias==DIR_NONE)
     { g_audit.Reject(DECISION_REJECT_HTF_BIAS,"no clear HTF bias"); return false; }

   bool macro_checked=false, macro_aligned=false;
   macro_checked = g_bias.MacroAlignment(symbol,htf_bias,macro_aligned);
   if(macro_checked && !macro_aligned)
     { g_audit.Reject(DECISION_REJECT_HTF_BIAS,"macro (DXY-correlation) read opposes HTF bias"); return false; }

   //--- rung 6/7: LIQUIDITY + STRUCTURE (execution timeframe)
   SAxfLiquidityMap liq = g_liquidity.Compute(symbol,Inp_LTF,vol.atr);
   if(!liq.valid)
     { g_audit.Reject(DECISION_REJECT_LIQUIDITY,"liquidity map unavailable"); return false; }
   SAxfStructure ltf_structure = g_structure.Compute(symbol,Inp_LTF,vol.atr);
   if(!ltf_structure.valid || ltf_structure.bias==DIR_NONE)
     { g_audit.Reject(DECISION_REJECT_STRUCTURE,"no confirmed LTF structure"); return false; }
   if(ltf_structure.bias != htf_bias)
     { g_audit.Reject(DECISION_REJECT_STRUCTURE,"LTF structure disagrees with HTF bias"); return false; }

   //--- rung 8: VOLATILITY suitability
   if(vol.classification==VOL_VERY_LOW)
     { g_audit.Reject(DECISION_REJECT_VOLATILITY,"volatility too low to justify costs"); return false; }

   //--- rung 9: OPPORTUNITY MAGNITUDE + rung 13 ASYMMETRY (structural stop only)
   SAxfOpportunity opp = g_opportunity.Build(symbol,ltf_structure,liq,regime,vol,
                                              g_market[idx].Point(),g_market[idx].StopsLevelPoints());
   if(!opp.valid)
     { g_audit.Reject(DECISION_REJECT_MAGNITUDE,"opportunity magnitude/asymmetry insufficient"); return false; }

   //--- rung 10: PROBABILITY (from this EA's own journal, sample-size aware)
   SAxfTradeRecord history[];
   g_journal.GetRecords(history,200,true,regime.regime,opp.direction);
   SAxfProbability prob = g_probability.Compute(history);

   //--- rung 11: EXPECTED VALUE
   double reward_r_tp2 = (opp.reward_price_distance>0) ? MathAbs(opp.target2-opp.entry)/opp.risk_price_distance : opp.r_multiple_potential;
   SAxfExpectedValue ev = g_ev.Compute(prob,opp.r_multiple_potential,reward_r_tp2,
                                        opp.risk_price_distance,
                                        g_market[idx].SpreadPoints()*g_market[idx].Point(),
                                        Inp_CommissionPerLot,1.0,
                                        g_market[idx].ContractSize(),g_market[idx].TickValue(),g_market[idx].TickSize(),
                                        Inp_AssumedSlippagePoints,g_market[idx].Point());
   if(!ev.valid || !ev.positive)
     { g_audit.Reject(DECISION_REJECT_EXPECTED_VALUE,"expected value non-positive or unproven (sample confidence too low)"); return false; }

   //--- rung 12: RISK OF RUIN
   RefreshRuinEstimates();
   ENUM_AXF_RUIN_STATE ruin_state = g_ruinEngine.ClassifyState(g_lastRuinAnalytical,g_lastRuinMonteCarlo);
   if(ruin_state==RUIN_HALT)
     { g_audit.Reject(DECISION_REJECT_RISK_OF_RUIN,"probability of ruin at HALT threshold"); return false; }

   //--- FLIP SCORE (Section 32) — computed here so the mode/risk decision below
   //--- can use it, and so it is displayed even for rejected setups upstream.
   //--- take the more conservative (higher P(50%DD)) of the two ruin readings.
   SAxfRuinEstimate worse_ruin;
   if(g_lastRuinAnalytical.p_dd50 > g_lastRuinMonteCarlo.p_dd50) worse_ruin = g_lastRuinAnalytical;
   else worse_ruin = g_lastRuinMonteCarlo;
   SAxfFlipScore flip = g_diagnostic.Compute(regime,ltf_structure,liq,vol,opp,ev,
                                              g_execution.CurrentScore(),AccountHealthScore(),
                                              worse_ruin);
   flip_score_out = flip.total;
   if(flip.grade=="NO TRADE")
     { g_audit.Reject(DECISION_REJECT_PROBABILITY,"flip score below trading floor ("+DoubleToString(flip.total,1)+")"); return false; }

   //--- rung 14: PORTFOLIO / CORRELATED EXPOSURE + POSITION SIZE
   ENUM_AXF_GROWTH_MODE mode = g_riskEngine.DetermineMode(flip.total,ruin_state,regime.regime,
                                                           g_compounding.DrawdownFromHighPct(equity),
                                                           Inp_FlipScore_APlus);
   mode_out = mode;
   if(mode==MODE_SURVIVAL)
     { g_audit.Reject(DECISION_REJECT_ACCOUNT_SURVIVAL,"mode forced to SURVIVAL — no new risk"); return false; }

   double loss_factor = g_drawdown.LossStreakFactor(g_compounding.ConsecLosses());
   double win_ceiling  = g_drawdown.WinStreakCeiling(g_compounding.ConsecWins());

   double risk_pct = g_riskEngine.ComputeFinalRiskPct(mode,opp.quality_score,regime.regime,ev,
                                                       g_execution.CurrentScore(),ruin_state,
                                                       g_compounding.DrawdownFromHighPct(equity),
                                                       loss_factor,win_ceiling);
   if(risk_pct<=0)
     { g_audit.Reject(DECISION_REJECT_POSITION_SIZE,"computed risk collapsed to zero (a hard gate tripped)"); return false; }

   double effective_portfolio_risk;
   if(!g_exposure.CanAcceptNewRisk(symbol,risk_pct,opp.direction,effective_portfolio_risk))
     { g_audit.Reject(DECISION_REJECT_RISK_OF_RUIN,StringFormat("effective portfolio risk would reach %.2f%% (correlated exposure)",effective_portfolio_risk)); return false; }

   double lots;
   if(!g_riskEngine.ComputeLots(equity,risk_pct,opp.risk_price_distance,
                                 g_market[idx].TickValue(),g_market[idx].TickSize(),
                                 g_market[idx].VolumeMin(),g_market[idx].VolumeMax(),g_market[idx].VolumeStep(),lots))
     { g_audit.Reject(DECISION_REJECT_POSITION_SIZE,"sized lot below broker minimum for this risk%"); return false; }

   //--- rung 15: EXECUTION SAFETY, now that we know the real stop distance
   string broker_reason2 = g_broker.PreTradeCheck(symbol,Inp_MaxSpreadPoints,opp.risk_price_distance);
   if(broker_reason2!="")
     { g_audit.Reject(DECISION_REJECT_EXECUTION,broker_reason2); return false; }
   if(g_execution.CurrentScore() < Inp_ExecutionScoreFloor)
     { g_audit.Reject(DECISION_REJECT_EXECUTION,"execution score below floor — throttling new entries"); return false; }

   if(IsNewsBlackout(symbol))
     { g_audit.Reject(DECISION_REJECT_EXECUTION,"news blackout window active"); return false; }

   opp_out = opp;
   lots_out = lots;
   risk_pct_out = risk_pct;
   g_audit.Approve();
   return true;
  }

void RefreshRuinEstimates(void)
  {
   double wr = g_compounding.WinRate();
   double aw = g_compounding.AvgWinR();
   double al = MathAbs(g_compounding.AvgLossR());
   int n = g_compounding.ClosedTrades();

   g_lastRuinAnalytical = g_ruinEngine.AnalyticalEstimate(wr,aw,al,Inp_BaseRiskPct,n);

   // Monte Carlo is heavier — run at most once per configured Inp_TimerSeconds*20
   // (roughly every 20 cycles) rather than on every evaluation.
   if(TimeCurrent()-g_lastMonteCarloRun >= MathMax(30,Inp_TimerSeconds*20))
     {
      g_lastRuinMonteCarlo = g_ruinEngine.MonteCarloEstimate(wr,aw,al,Inp_BaseRiskPct);
      g_lastMonteCarloRun = TimeCurrent();
     }
   if(!g_lastRuinMonteCarlo.valid) g_lastRuinMonteCarlo = g_lastRuinAnalytical;
  }

//+------------------------------------------------------------------+
//| open a new position from an approved opportunity                   |
//+------------------------------------------------------------------+
void ExecuteApprovedTrade(const string symbol,const SAxfOpportunity &opp,const double lots,
                          const ENUM_AXF_GROWTH_MODE mode,const double flip_score,const double risk_pct,
                          const ENUM_AXF_REGIME regime)
  {
   if(!Inp_LiveTradingEnabled)
     {
      if(Inp_VerboseLogging)
         Print("AXF [ANALYSIS-ONLY] would open ",symbol," ",(opp.direction==DIR_LONG?"LONG":"SHORT"),
               " lots=",lots," risk%=",risk_pct," mode=",AxfModeToString(mode)," flip=",flip_score);
      return;
     }

   double sl = g_market[SymbolIndex(symbol)].NormalizePrice(opp.stop);
   double tp = g_market[SymbolIndex(symbol)].NormalizePrice(opp.target_final);

   string reason;
   ulong ticket = g_execution.OpenMarket(symbol,opp.direction,lots,sl,tp,
                                          "AXF15|"+AxfModeToString(mode),reason);
   if(ticket==0)
     {
      Print("AXF: order failed for ",symbol,": ",reason);
      return;
     }

   SOpenMeta m;
   m.ticket=ticket; m.symbol=symbol; m.direction=opp.direction; m.regime=regime;
   m.open_time=TimeCurrent(); m.entry=opp.entry; m.stop=opp.stop;
   m.target1=opp.target1; m.target2=opp.target2; m.risk_pct=risk_pct;
   m.mfe_r=0; m.mae_r=0; m.mode=mode; m.flip_score=flip_score;
   m.entry_reason = StringFormat("regime=%s structQ=%.0f RR=%.2f",AxfRegimeToString(regime),opp.quality_score,opp.r_multiple_potential);
   m.adds=0;

   int n=ArraySize(g_openMeta);
   ArrayResize(g_openMeta,n+1);
   g_openMeta[n]=m;

   Print("AXF: opened ",symbol," ",(opp.direction==DIR_LONG?"LONG":"SHORT")," lots=",lots,
         " risk%=",DoubleToString(risk_pct,2)," mode=",AxfModeToString(mode)," flip=",DoubleToString(flip_score,1));
  }

//+------------------------------------------------------------------+
//| manage every currently open EA position                            |
//+------------------------------------------------------------------+
void ManageOpenPositions(void)
  {
   for(int i=ArraySize(g_openMeta)-1;i>=0;i--)
     {
      ulong ticket = g_openMeta[i].ticket;
      if(!PositionSelectByTicket(ticket))
        continue; // closed since last cycle; OnTradeTransaction handles journaling

      string symbol = g_openMeta[i].symbol;
      int sidx = SymbolIndex(symbol);
      if(sidx<0) continue;

      SAxfVolatility vol = g_volatility[sidx].Compute(symbol);
      SAxfStructure  ltf = g_structure.Compute(symbol,Inp_LTF,vol.valid?vol.atr:0);

      //--- update MFE/MAE in R
      double op = g_openMeta[i].entry, sl = g_openMeta[i].stop;
      double risk_dist = MathAbs(op-sl);
      if(risk_dist>0)
        {
         double price = (g_openMeta[i].direction==DIR_LONG) ? SymbolInfoDouble(symbol,SYMBOL_BID)
                                                             : SymbolInfoDouble(symbol,SYMBOL_ASK);
         double r_now = (g_openMeta[i].direction==DIR_LONG) ? (price-op)/risk_dist : (op-price)/risk_dist;
         if(r_now > g_openMeta[i].mfe_r) g_openMeta[i].mfe_r = r_now;
         if(r_now < g_openMeta[i].mae_r) g_openMeta[i].mae_r = r_now;
        }

      //--- thesis invalidation exit overrides everything else this cycle
      if(ltf.valid && g_posManager.ThesisInvalidated(g_openMeta[i].direction,ltf))
        {
         string reason;
         if(g_execution.ClosePosition(ticket,reason))
            Print("AXF: closed ",symbol," on thesis invalidation (CHOCH against position).");
         continue;
        }

      g_posManager.TakePartialAtTarget1(g_execution,ticket,g_openMeta[i].target1);
      g_posManager.ManagePosition(g_execution,ticket,ltf.last_swing_high,ltf.last_swing_low,vol.valid?vol.atr:0);

      //--- pyramiding: only ever adds to an already-profitable position, only
      //--- with a fresh A+ confirmation in the same direction (Section 21).
      SAxfLiquidityMap liq = g_liquidity.Compute(symbol,Inp_LTF,vol.valid?vol.atr:0);
      SAxfRegime regime = g_regime[sidx].Compute(symbol,vol);
      SAxfOpportunity fresh = g_opportunity.Build(symbol,ltf,liq,regime,vol,g_market[sidx].Point(),g_market[sidx].StopsLevelPoints());
      if(g_posManager.CanPyramid(ticket,g_openMeta[i].adds,fresh))
        {
         double add_risk_pct;
         double effective;
         if(g_exposure.CanAcceptNewRisk(symbol,Inp_BaseRiskPct,fresh.direction,effective))
           {
            double add_lots;
            if(g_riskEngine.ComputeLots(AccountInfoDouble(ACCOUNT_EQUITY),Inp_BaseRiskPct,fresh.risk_price_distance,
                                        g_market[sidx].TickValue(),g_market[sidx].TickSize(),
                                        g_market[sidx].VolumeMin(),g_market[sidx].VolumeMax(),g_market[sidx].VolumeStep(),add_lots))
              {
               if(Inp_LiveTradingEnabled)
                 {
                  string reason;
                  ulong add_ticket = g_execution.OpenMarket(symbol,fresh.direction,add_lots,
                                        g_market[sidx].NormalizePrice(fresh.stop),
                                        g_market[sidx].NormalizePrice(fresh.target_final),
                                        "AXF15|ADD",reason);
                  if(add_ticket>0) g_openMeta[i].adds++;
                 }
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| trade transaction hook — journals a trade the moment it closes     |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   ulong deal_ticket = trans.deal;
   if(!HistoryDealSelect(deal_ticket)) return;
   if((ulong)HistoryDealGetInteger(deal_ticket,DEAL_MAGIC) != Inp_MagicNumber) return;
   if(HistoryDealGetInteger(deal_ticket,DEAL_ENTRY) != DEAL_ENTRY_OUT) return;

   ulong position_id = (ulong)HistoryDealGetInteger(deal_ticket,DEAL_POSITION_ID);
   int idx = FindMeta(position_id);
   if(idx<0) return; // not one of ours (or already flushed)

   double exit_price = HistoryDealGetDouble(deal_ticket,DEAL_PRICE);
   double profit = HistoryDealGetDouble(deal_ticket,DEAL_PROFIT);
   double commission = HistoryDealGetDouble(deal_ticket,DEAL_COMMISSION);
   double swap = HistoryDealGetDouble(deal_ticket,DEAL_SWAP);

   SOpenMeta m = g_openMeta[idx];
   double risk_dist = MathAbs(m.entry-m.stop);
   double r_multiple = 0;
   if(risk_dist>0)
      r_multiple = (m.direction==DIR_LONG) ? (exit_price-m.entry)/risk_dist : (m.entry-exit_price)/risk_dist;

   SAxfTradeRecord rec; ZeroMemory(rec);
   rec.ticket=position_id; rec.symbol=m.symbol; rec.direction=m.direction; rec.regime=m.regime;
   rec.open_time=m.open_time; rec.close_time=TimeCurrent();
   rec.entry=m.entry; rec.stop=m.stop; rec.target=m.target1; rec.exit_price=exit_price;
   rec.risk_pct=m.risk_pct; rec.r_multiple=r_multiple; rec.mfe_r=m.mfe_r; rec.mae_r=m.mae_r;
   rec.spread_cost=0; rec.commission_cost=MathAbs(commission); rec.swap_cost=swap; rec.slippage_cost=0;
   rec.mode=m.mode; rec.flip_score=m.flip_score;
   rec.entry_reason=m.entry_reason;
   rec.exit_reason = (r_multiple>=0) ? "TARGET_OR_TRAIL" : "STOP_OR_THESIS";

   g_journal.Record(rec);
   g_compounding.RecordClosedTrade(r_multiple);

   Print("AXF AUTOPSY: ",m.symbol," closed R=",DoubleToString(r_multiple,2),
         " profit=",DoubleToString(profit,2)," tag recorded.");

   RemoveMeta(idx);
  }

//+------------------------------------------------------------------+
//| OnTick — cheap, safe-to-run-every-tick bookkeeping only             |
//+------------------------------------------------------------------+
void OnTick()
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_compounding.UpdateEquityWatermark(equity);
  }

//+------------------------------------------------------------------+
//| OnTimer — the real cycle: scan, decide, execute, manage, report    |
//+------------------------------------------------------------------+
void OnTimer()
  {
   g_state = STATE_DATA_VALIDATION;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_drawdown.RollDailyWeeklyAnchors(equity);
   g_compounding.UpdateEquityWatermark(equity);

   //--- drift check (Section 36): recommend-only, logged, does not itself alter risk
   SAxfTradeRecord all_recent[];
   g_journal.GetRecords(all_recent,300);
   double recent_exp, baseline_exp;
   ENUM_AXF_DRIFT_SIGNAL drift = g_drift.Evaluate(all_recent,recent_exp,baseline_exp);
   if(drift==DRIFT_HALT_RECOMMENDED && Inp_VerboseLogging)
      Print("AXF DRIFT: recent expectancy ",DoubleToString(recent_exp,2)," vs baseline ",
            DoubleToString(baseline_exp,2)," — recommend manual review / halt.");

   ManageOpenPositions();

   ENUM_AXF_GROWTH_MODE last_mode = MODE_NORMAL;
   double last_flip = 0; double last_risk_pct=0;

   if(Inp_AllowNewTrades)
     {
      g_state = STATE_OPPORTUNITY_SCAN;
      for(int i=0;i<ArraySize(g_symbols);i++)
        {
         // one EA position per symbol at a time from fresh entries (pyramiding
         // handles adds separately); skip scanning a symbol we're already in.
         bool already_in=false;
         for(int j=0;j<ArraySize(g_openMeta);j++) if(g_openMeta[j].symbol==g_symbols[i]) { already_in=true; break; }
         if(already_in) continue;

         SAxfOpportunity opp; double lots; ENUM_AXF_GROWTH_MODE mode; double flip_score; double risk_pct; ENUM_AXF_REGIME regime_out;
         g_state = STATE_RISK_APPROVAL;
         if(EvaluateSymbol(i,opp,lots,mode,flip_score,risk_pct,regime_out))
           {
            g_state = STATE_ORDER_PREPARATION;
            g_state = STATE_EXECUTION;
            ExecuteApprovedTrade(g_symbols[i],opp,lots,mode,flip_score,risk_pct,regime_out);
            g_state = STATE_POSITION_VERIFICATION;
           }
         g_lastDecisionReason = g_symbols[i]+": "+g_audit.LastReason();
         last_mode=mode; last_flip=flip_score; last_risk_pct=risk_pct;
        }
     }

   g_state = STATE_COOLDOWN;
   PostBridgeTelemetry();
   UpdateDashboard(last_mode,last_flip,last_risk_pct);
  }

//+------------------------------------------------------------------+
//| dashboard refresh (chart symbol, or first configured symbol)       |
//+------------------------------------------------------------------+
void UpdateDashboard(const ENUM_AXF_GROWTH_MODE mode,const double flip_score,const double current_risk_pct)
  {
   int idx = SymbolIndex(_Symbol);
   if(idx<0) idx=0;
   if(idx>=ArraySize(g_symbols)) return;
   string symbol = g_symbols[idx];

   SAxfVolatility vol = g_volatility[idx].Compute(symbol);
   SAxfRegime regime = g_regime[idx].Compute(symbol,vol);
   SAxfStructure structure = g_structure.Compute(symbol,Inp_LTF,vol.valid?vol.atr:0);
   SAxfLiquidityMap liq = g_liquidity.Compute(symbol,Inp_LTF,vol.valid?vol.atr:0);

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   SAxfDashboardData d; ZeroMemory(d);
   d.symbol=symbol; d.price=SymbolInfoDouble(symbol,SYMBOL_BID);
   d.spread_points=g_market[idx].SpreadPoints();
   d.vol_class = vol.valid?vol.classification:VOL_UNKNOWN;
   d.regime = regime.valid?regime.regime:REGIME_UNKNOWN;
   d.htf_bias = structure.valid?structure.bias:DIR_NONE;
   d.structure_desc = structure.valid ? StringFormat("BOS:%s CHOCH:%s Q:%.0f",
                        structure.bos_confirmed?"Y":"n",structure.choch_confirmed?"Y":"n",structure.quality) : "n/a";
   d.liquidity_target_desc = liq.valid ? StringFormat("above:%.5f below:%.5f",liq.nearest_liquidity_above,liq.nearest_liquidity_below) : "n/a";
   d.setup_desc = g_lastDecisionReason;

   d.flip_score = flip_score; d.flip_grade = (flip_score>=Inp_FlipScore_Elite)?"ELITE":(flip_score>=Inp_FlipScore_APlus)?"A+":(flip_score>=Inp_FlipScore_A)?"A":(flip_score>=Inp_FlipScore_B)?"B":"NO TRADE";
   d.opportunity_magnitude_r = 0; d.expected_r=0; d.expected_net_value_r=0;

   d.equity=equity; d.drawdown_pct=g_compounding.DrawdownFromHighPct(equity);
   d.base_risk_pct=Inp_BaseRiskPct; d.current_risk_pct=current_risk_pct;
   d.portfolio_risk_pct=g_exposure.CurrentEffectiveRisk();
   if(g_lastRuinMonteCarlo.valid) d.ruin = g_lastRuinMonteCarlo;
   else d.ruin = g_lastRuinAnalytical;
   d.mode = mode;
   d.execution_score = g_execution.CurrentScore();

   int mi = -1;
   for(int j=0;j<ArraySize(g_openMeta);j++) if(g_openMeta[j].symbol==symbol) { mi=j; break; }
   d.has_position = (mi>=0);
   if(mi>=0)
     {
      d.pos_entry=g_openMeta[mi].entry; d.pos_sl=g_openMeta[mi].stop;
      d.pos_tp1=g_openMeta[mi].target1; d.pos_tp2=g_openMeta[mi].target2; d.pos_final=g_openMeta[mi].target2;
      double risk_dist=MathAbs(d.pos_entry-d.pos_sl);
      double price = (g_openMeta[mi].direction==DIR_LONG)?SymbolInfoDouble(symbol,SYMBOL_BID):SymbolInfoDouble(symbol,SYMBOL_ASK);
      d.pos_r = (risk_dist>0)?((g_openMeta[mi].direction==DIR_LONG)?(price-d.pos_entry)/risk_dist:(d.pos_entry-price)/risk_dist):0;
      d.pos_mfe_r=g_openMeta[mi].mfe_r; d.pos_mae_r=g_openMeta[mi].mae_r;
      d.pos_holding_seconds = TimeCurrent()-g_openMeta[mi].open_time;
     }

   d.journal_count = g_compounding.ClosedTrades();
   d.expectancy_r = g_compounding.ExpectancyR();
   d.win_rate = g_compounding.WinRate();
   d.avg_r = d.expectancy_r;
   d.consec_streak = (g_compounding.ConsecWins()>0) ? g_compounding.ConsecWins() : -g_compounding.ConsecLosses();

   d.state_name = EnumToString(g_state);
   d.last_decision_reason = g_lastDecisionReason;

   g_dashboard.Update(d);
  }
//+------------------------------------------------------------------+
