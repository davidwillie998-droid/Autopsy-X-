//+------------------------------------------------------------------+
//|                                    AutopsyRegimeEngineCore.mqh    |
//|  AUTOPSY X — top-level facade. Wires every sub-engine together     |
//|  behind the plain API described in spec sections 17 and 21, plus   |
//|  the section-23 decision log.                                      |
//|                                                                     |
//|  CRITICAL DESIGN RULE (spec section 22): this file never places,   |
//|  modifies, or closes a trade. It only answers three questions for  |
//|  whatever EA includes it — can I trade, which side, and at what    |
//|  size — and logs every answer for later audit. Execution stays     |
//|  entirely the existing EA's responsibility.                        |
//+------------------------------------------------------------------+
#property strict
#include "AutopsyXCommon.mqh"
#include "AutopsyVolatilityEngine.mqh"
#include "AutopsyMacroEngine.mqh"
#include "AutopsyRegimeEngine.mqh"
#include "AutopsyRiskGovernor.mqh"
#include "AutopsyCorrelationEngine.mqh"
#include "AutopsyEventFilter.mqh"

ENUM_AX_DATA_STATUS AxWorstStatus(ENUM_AX_DATA_STATUS a, ENUM_AX_DATA_STATUS b)
  {
   if(a == AX_DATA_UNAVAILABLE || b == AX_DATA_UNAVAILABLE) return AX_DATA_UNAVAILABLE;
   if(a == AX_DATA_DEGRADED    || b == AX_DATA_DEGRADED)    return AX_DATA_DEGRADED;
   return AX_DATA_OK;
  }

struct AxFullState
  {
   ENUM_AX_REGIME         regime;
   string                 nasdaqBias;         // "BULLISH" / "BEARISH" / "NEUTRAL"
   double                 confidence;         // 0..100
   AxDirectionState       direction;
   AxTrendEfficiencyState efficiency;
   AxVolatilityState      volatility;
   AxMacroState           macro;
   AxBreadthState         breadth;
   AxLiquidityState       liquidity;
   AxCorrelationState     correlation;
   AxEventState           event;
   double                 drawdownFactor;
   bool                   drawdownHalted;

   double                 regimeRiskMultiplier;  // section-17 "RISK_MULTIPLIER" — the regime x confidence band value
   bool                   tradeAllowedByRegime;
   bool                   aggressiveAllowed;
   bool                   allowLong;
   bool                   allowShort;
   bool                   allowNewTrade;
   ENUM_AX_DATA_STATUS    worstCriticalStatus;   // drives the section-20 fail-safe cap
  };

class CAutopsyRegimeEngineCore
  {
private:
   CAxVolatilityEngine     m_vol;
   CAxMacroEngine          m_macro;
   CAxRegimeEngine         m_regime;
   CAxRegimeDecisionMatrix m_matrix;
   CAxDrawdownGovernor     m_drawdown;
   CAxCorrelationEngine    m_correlation;
   CAxEventFilter          m_events;

   double m_baseRiskPct;
   bool   m_initialized;

   AxFullState m_last;
   AxLeverageBreakdown m_lastLeverage;
   double m_lastFinalRiskPctWithEvents;

   int    m_logHandle;
   string m_logFileName;
   string m_lastLogBlock;

   string DirectionLabel(double directionScore, double neutralBand = 40.0)
     {
      if(directionScore >= neutralBand)  return "BULLISH";
      if(directionScore <= -neutralBand) return "BEARISH";
      return "NEUTRAL";
     }

public:
   CAutopsyRegimeEngineCore()
     {
      m_baseRiskPct = 1.0;
      m_initialized = false;
      m_logHandle = INVALID_HANDLE;
      m_logFileName = "AutopsyX_Decisions.log";
      m_lastFinalRiskPctWithEvents = 0.0;
     }

   //--- Wire up every sub-engine. Call once from OnInit(). `qqqSymbol` is
   //    whatever this terminal/broker actually calls the Nasdaq-100 proxy
   //    you're trading (QQQ, US100, USTEC, ...) — everything downstream
   //    reads price/volume from that one symbol.
   bool Init(string qqqSymbol, ENUM_TIMEFRAMES tf, double baseRiskPct,
             string vixSymbol = "", string dxySymbol = "",
             bool hasRangeStrategy = false, string logFileName = "AutopsyX_Decisions.log")
     {
      m_baseRiskPct = MathMax(0.0, baseRiskPct);
      m_logFileName = logFileName;

      m_vol.SetInstrument(qqqSymbol, tf, vixSymbol);
      m_macro.SetInstrument(dxySymbol, tf);
      m_regime.SetInstrument(qqqSymbol, tf);
      m_matrix.SetHasRangeStrategy(hasRangeStrategy);
      m_correlation.LoadDefaultWatchlist();
      m_correlation.SetMaxAggregateExposure(2.0);
      m_drawdown.Init(AccountInfoDouble(ACCOUNT_EQUITY));

      bool ok = m_vol.Init() && m_regime.Init();
      m_initialized = ok;

      // Local to this terminal's MQL5\Files — each terminal/account keeps its
      // own audit trail. Switch in FILE_COMMON if you deliberately want one
      // shared log visible across every terminal on the machine instead.
      m_logHandle = FileOpen(m_logFileName, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI);
      if(m_logHandle != INVALID_HANDLE)
         FileSeek(m_logHandle, 0, SEEK_END);

      return ok;
     }

   void Shutdown()
     {
      if(m_logHandle != INVALID_HANDLE)
        {
         FileClose(m_logHandle);
         m_logHandle = INVALID_HANDLE;
        }
     }

   //--- Direct access to the sub-objects, for callers who want to override
   //    a default (e.g. m_matrix in EA.Matrix().Configure(...)) without this
   //    facade having to expose a setter for every single knob.
   CAxRegimeDecisionMatrix *Matrix()     { return GetPointer(m_matrix); }
   CAxVolatilityEngine     *Volatility() { return GetPointer(m_vol); }
   CAxMacroEngine          *Macro()      { return GetPointer(m_macro); }
   CAxRegimeEngine         *Regime()     { return GetPointer(m_regime); }
   CAxCorrelationEngine    *Correlation(){ return GetPointer(m_correlation); }
   CAxEventFilter          *Events()     { return GetPointer(m_events); }
   CAxDrawdownGovernor     *Drawdown()   { return GetPointer(m_drawdown); }

   //--- Recomputes every engine and the full permission set. Call once per
   //    bar (recommended) or per tick (more expensive, rarely necessary —
   //    nothing here reacts meaningfully faster than a few seconds anyway).
   void UpdateMarketState()
     {
      if(!m_initialized)
         return;

      m_last.volatility = m_vol.Update();
      m_last.macro      = m_macro.Update();
      m_last.direction  = m_regime.UpdateDirection();
      m_last.efficiency = m_regime.UpdateTrendEfficiency();
      m_last.breadth    = m_regime.UpdateBreadth();
      m_last.liquidity  = m_regime.UpdateLiquidity();
      m_last.correlation = m_correlation.Update();
      m_last.event        = m_events.Update();
      m_last.drawdownFactor = m_drawdown.Update(AccountInfoDouble(ACCOUNT_EQUITY));
      m_last.drawdownHalted = m_drawdown.IsHalted();

      m_last.regime = m_regime.ClassifyRegime(m_last.direction, m_last.efficiency, m_last.breadth,
                                               m_last.volatility.state, m_last.volatility.shockActive);
      m_last.nasdaqBias = DirectionLabel(m_last.direction.directionScore);
      m_last.confidence = m_regime.ComputeConfidence(m_last.direction, m_last.efficiency,
                                                      m_last.volatility.volatilityScore,
                                                      (m_last.volatility.dataStatus != AX_DATA_UNAVAILABLE),
                                                      m_last.macro.macroScore, m_last.macro.componentsAvailable,
                                                      m_last.breadth, m_last.liquidity);

      m_last.tradeAllowedByRegime = m_matrix.IsTradeAllowed(m_last.regime);
      m_last.aggressiveAllowed    = m_matrix.IsAggressiveAllowed(m_last.regime)
                                     && m_last.event.state == AX_EVENT_NONE
                                     && m_last.correlation.correlationMultiplier >= 0.99;
      m_last.regimeRiskMultiplier = m_matrix.GetRegimeMultiplier(m_last.regime, m_last.confidence);

      //--- Section 20 fail-safe: only the data sources the spec explicitly
      //    names (DXY/VIX/macro feed/QQQ price data) drive the hard cap.
      //    Breadth is optional-by-design (section 9 has no MT5-native
      //    source at all) and already degrades gracefully via renormalized
      //    weighting inside the confidence/regime math above — capping the
      //    whole engine to 0.25x every time nobody has wired a breadth feed
      //    would make the engine unusable out of the box, which isn't the
      //    spec's intent either.
      m_last.worstCriticalStatus = AxWorstStatus(
                                       AxWorstStatus(m_last.direction.dataStatus, m_last.efficiency.dataStatus),
                                       AxWorstStatus(m_last.volatility.dataStatus, m_last.macro.dataStatus));

      bool criticalPriceDataGone = (m_last.direction.dataStatus == AX_DATA_UNAVAILABLE)
                                    || (m_last.efficiency.dataStatus == AX_DATA_UNAVAILABLE)
                                    || (m_last.volatility.dataStatus == AX_DATA_UNAVAILABLE);

      m_last.allowNewTrade = m_last.tradeAllowedByRegime
                             && !m_last.drawdownHalted
                             && !m_last.correlation.limitBreached
                             && m_last.event.newTradesAllowed
                             && !criticalPriceDataGone;

      m_last.allowLong  = m_last.allowNewTrade && (m_last.direction.directionScore > 0.0);
      m_last.allowShort = m_last.allowNewTrade && (m_last.direction.directionScore < 0.0)
                          && (m_last.regime != AX_R4_BEAR_TRANSITION || m_last.direction.momentumPct < 0.0);
      // R4's extra momentum gate is the literal "wait for confirmation before
      // allowing aggressive short exposure" instruction from spec section 12 —
      // applied here as a gate on any new short at all in that specific
      // transitional regime, not only on aggressive sizing, since a
      // transition regime is exactly where a premature short is costliest.

      //--- Section 13 leverage model, then the section-16 event multiplier
      //    layered on top (event risk is a governor concern, not one of the
      //    five multipliers the spec's leverage formula itself names).
      m_lastLeverage = AxComputeLeverage(m_baseRiskPct, m_last.regimeRiskMultiplier, m_last.confidence,
                                          m_last.volatility.state, m_last.correlation.correlationMultiplier,
                                          m_last.drawdownFactor, m_last.worstCriticalStatus);
      m_lastFinalRiskPctWithEvents = m_lastLeverage.finalRiskPct * m_last.event.riskMultiplier;

      LogDecision();
     }

   //--- ===================== Section 21 / 17 public API ===================== ---
   ENUM_AX_REGIME GetRegime()          { return m_last.regime; }
   string         GetRegimeString()    { return AxRegimeToString(m_last.regime); }
   string         GetDirection()       { return m_last.nasdaqBias; }
   double         GetConfidence()      { return m_last.confidence; }
   double         GetRiskMultiplier()  { return m_last.regimeRiskMultiplier; }
   bool           AllowLong()          { return m_last.allowLong; }
   bool           AllowShort()         { return m_last.allowShort; }
   bool           AllowNewTrade()      { return m_last.allowNewTrade; }
   bool           IsVolatilityShock()  { return m_last.volatility.shockActive; }
   double         GetAggregateExposure() { return m_last.correlation.netExposureRatio; }

   void ResetRiskGovernor()
     {
      m_drawdown.ForceReset(AccountInfoDouble(ACCOUNT_EQUITY));
     }

   //--- Extra getters implied by the section-17 output list.
   ENUM_AX_VOL_STATE GetVolatilityState()   { return m_last.volatility.state; }
   double            GetTrendEfficiency()   { return m_last.efficiency.efficiencyScore; }
   double            GetMacroScore()        { return m_last.macro.macroScore; }
   double            GetBreadthScore()      { return m_last.breadth.breadthScore; }
   bool              IsAggressiveAllowed()  { return m_last.aggressiveAllowed; }
   bool              IsDrawdownHalted()     { return m_last.drawdownHalted; }
   ENUM_AX_EVENT_STATE GetEventState()      { return m_last.event.state; }
   ENUM_AX_DATA_STATUS GetDataStatus()      { return m_last.worstCriticalStatus; }

   //--- The fully compounded TQQQ position-sizing number (section 13, with
   //    the section-16 event multiplier layered on top). This is what an
   //    EA should actually size a trade with; GetRiskMultiplier() above is
   //    the simpler regime-band figure from the section-17 API contract.
   double GetFinalRiskPct()             { return m_lastFinalRiskPctWithEvents; }
   AxLeverageBreakdown GetLeverageBreakdown() { return m_lastLeverage; }

   AxFullState GetFullState()           { return m_last; }
   string GetLastDecisionLog()          { return m_lastLogBlock; }

   //--- ===================== Section 23 logging ===================== ---
private:
   void LogDecision()
     {
      string decision;
      if(!m_last.allowNewTrade)
         decision = "BLOCK";
      else if(m_last.regimeRiskMultiplier < 1.0 || m_last.event.state != AX_EVENT_NONE)
         decision = "REDUCE";
      else
         decision = "APPROVE";

      string block = "";
      block += TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES) + "\n";
      block += "REGIME = " + AxRegimeToString(m_last.regime) + "\n";
      block += "BIAS = " + m_last.nasdaqBias + "\n";
      block += "CONFIDENCE = " + DoubleToString(m_last.confidence, 1) + "\n";
      block += "TREND_EFFICIENCY = " + DoubleToString(m_last.efficiency.efficiencyScore, 2) + "\n";
      block += "VOL_STATE = " + AxVolStateToString(m_last.volatility.state) + "\n";
      block += "MACRO_SCORE = " + DoubleToString(m_last.macro.macroScore, 0) + "\n";
      block += "BREADTH_SCORE = " + (m_last.breadth.available ? DoubleToString(m_last.breadth.breadthScore, 0) : "N/A") + "\n";
      block += "REGIME_RISK_MULTIPLIER = " + DoubleToString(m_last.regimeRiskMultiplier, 2) + "\n";
      block += "FINAL_RISK_PCT = " + DoubleToString(m_lastFinalRiskPctWithEvents, 4) + "\n";
      block += "LONG_PERMISSION = " + (m_last.allowLong ? "TRUE" : "FALSE") + "\n";
      block += "SHORT_PERMISSION = " + (m_last.allowShort ? "TRUE" : "FALSE") + "\n";
      block += "SHOCK = " + (m_last.volatility.shockActive ? "TRUE (" + m_last.volatility.shockReasons + ")" : "FALSE") + "\n";
      block += "EVENT_STATE = " + EnumToString(m_last.event.state) +
               (StringLen(m_last.event.nearestEventName) > 0 ? (" [" + m_last.event.nearestEventName + "]") : "") + "\n";
      block += "DRAWDOWN_HALTED = " + (m_last.drawdownHalted ? "TRUE" : "FALSE") + "\n";
      block += "AGGREGATE_EXPOSURE = " + DoubleToString(m_last.correlation.netExposureRatio, 2) + "x equity\n";
      block += "DATA_STATUS = " + AxDataStatusToString(m_last.worstCriticalStatus) + "\n";
      block += "DECISION = " + decision + "\n";

      m_lastLogBlock = block;

      if(m_logHandle != INVALID_HANDLE)
        {
         FileWriteString(m_logHandle, block + "\n");
         FileFlush(m_logHandle);
        }
     }
  };

//+------------------------------------------------------------------+
//| Section 21 free-function API — an existing EA includes this file  |
//| and calls these directly. It never needs to know a class exists.  |
//+------------------------------------------------------------------+
CAutopsyRegimeEngineCore g_AxEngine;

bool InitializeRegimeEngine(string qqqSymbol, ENUM_TIMEFRAMES tf, double baseRiskPct,
                             string vixSymbol = "", string dxySymbol = "",
                             bool hasRangeStrategy = false, string logFileName = "AutopsyX_Decisions.log")
  {
   return g_AxEngine.Init(qqqSymbol, tf, baseRiskPct, vixSymbol, dxySymbol, hasRangeStrategy, logFileName);
  }

void   UpdateMarketState()        { g_AxEngine.UpdateMarketState(); }
string GetRegime()                { return g_AxEngine.GetRegimeString(); }
string GetDirection()             { return g_AxEngine.GetDirection(); }
double GetConfidence()            { return g_AxEngine.GetConfidence(); }
double GetRiskMultiplier()        { return g_AxEngine.GetRiskMultiplier(); }
double GetFinalRiskPct()          { return g_AxEngine.GetFinalRiskPct(); }
bool   AllowLong()                { return g_AxEngine.AllowLong(); }
bool   AllowShort()                { return g_AxEngine.AllowShort(); }
bool   AllowNewTrade()            { return g_AxEngine.AllowNewTrade(); }
bool   IsVolatilityShock()        { return g_AxEngine.IsVolatilityShock(); }
double GetAggregateExposure()     { return g_AxEngine.GetAggregateExposure(); }
void   ResetRiskGovernor()        { g_AxEngine.ResetRiskGovernor(); }
string GetLastDecisionLog()       { return g_AxEngine.GetLastDecisionLog(); }
void   ShutdownRegimeEngine()     { g_AxEngine.Shutdown(); }
