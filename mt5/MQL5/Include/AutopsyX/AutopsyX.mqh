//+------------------------------------------------------------------+
//|                                                    AutopsyX.mqh  |
//|  AUTOPSY X — QQQ/TQQQ Regime Engine — top-level facade           |
//|  Spec sections 2, 17, 19, 21, 22.                                |
//|                                                                    |
//|  This is the only file an existing EA needs to #include. It      |
//|  wires the six engines together and exposes the exact global     |
//|  function names from spec section 21 so the EA never needs to    |
//|  know how any score underneath is calculated — it only ever      |
//|  asks: can I trade, which direction, and how much.                |
//|                                                                    |
//|  CRITICAL DESIGN RULE (section 22): this module never touches    |
//|  the host EA's own entry, exit, or trade-management logic. It    |
//|  only answers permission questions. The host EA still decides    |
//|  what to do with that answer.                                     |
//+------------------------------------------------------------------+
#property strict
#include "AutopsyTypes.mqh"
#include "AutopsyVolatilityEngine.mqh"
#include "AutopsyMacroEngine.mqh"
#include "AutopsyRegimeEngine.mqh"
#include "AutopsyRiskGovernor.mqh"
#include "AutopsyCorrelationEngine.mqh"
#include "AutopsyEventFilter.mqh"
#include "AutopsyLogger.mqh"

//+------------------------------------------------------------------+
//| Everything InitializeRegimeEngine() needs. Every field has a     |
//| sane default via Defaults() — set only what your broker/account  |
//| actually needs to differ.                                         |
//+------------------------------------------------------------------+
struct AxConfig
  {
   string symbol_price;   // the instrument driving direction/efficiency/liquidity — QQQ, or your broker's US100/NAS100 CFD
   string symbol_vix;     // optional — leave "" if your broker doesn't list a VIX instrument
   string symbol_dxy;     // optional
   string symbol_us2y;    // optional — broker CFD proxy for the 2Y yield, if it lists one
   string symbol_us10y;   // optional — broker CFD proxy for the 10Y yield, if it lists one

   string bot_id;                       // unique per EA/chart instance, used by the correlation engine
   double base_risk_pct;                // spec section 13's BASE_RISK, e.g. 1.0 = 1% of equity
   double correlation_limit_pct_equity; // spec section 15's aggregate-exposure ceiling

   int    aggressive_min_confidence;    // composite confidence floor before AGGRESSIVE_MODE is permitted

   string log_filename;

   AxWeights          weights;
   AxRegimeThresholds regime_th;
   AxVolThresholds    vol_th;
   AxMacroThresholds  macro_th;

   int    pre_event_minutes;
   int    blackout_minutes;
   int    post_event_cooldown_minutes;

   void Defaults()
     {
      symbol_price = "QQQ";
      symbol_vix   = "";
      symbol_dxy   = "";
      symbol_us2y  = "";
      symbol_us10y = "";

      bot_id = "AX_DEFAULT";
      base_risk_pct = 1.0;
      correlation_limit_pct_equity = 15.0;
      aggressive_min_confidence = 60;
      log_filename = "AutopsyX_Log.csv";

      weights.Defaults();
      regime_th.Defaults();
      vol_th.Defaults();
      macro_th.Defaults();

      pre_event_minutes = 60;
      blackout_minutes = 15;
      post_event_cooldown_minutes = 30;
     }
  };

//+------------------------------------------------------------------+
//| CAutopsyX — the orchestrator. Used as a singleton via the global |
//| wrapper functions at the bottom of this file; nothing stops a    |
//| host EA from instantiating its own instance directly instead if  |
//| it prefers an object over free functions.                         |
//+------------------------------------------------------------------+
class CAutopsyX
  {
private:
   AxConfig             m_cfg;
   CAxVolatilityEngine  m_vol;
   CAxMacroEngine       m_macro;
   CAxRegimeEngine      m_regime;
   CAxRiskGovernor      m_risk;
   CAxCorrelationEngine m_corr;
   CAxEventFilter       m_event;
   CAxLogger            m_logger;

   AxSnapshot           m_last;
   bool                 m_initialized;

public:
   CAutopsyX() { m_initialized = false; m_last.Clear(); }

   bool Init(const AxConfig &cfg)
     {
      m_cfg = cfg;
      m_vol.Init(m_cfg.symbol_price, m_cfg.symbol_vix, m_cfg.vol_th);
      m_macro.Init(m_cfg.symbol_dxy, m_cfg.symbol_us2y, m_cfg.symbol_us10y, m_cfg.macro_th);
      m_regime.Init(m_cfg.symbol_price, m_cfg.regime_th);
      m_risk.Init(m_cfg.base_risk_pct);
      m_corr.Init(m_cfg.bot_id, m_cfg.correlation_limit_pct_equity);
      m_event.Init(m_cfg.pre_event_minutes, m_cfg.blackout_minutes, m_cfg.post_event_cooldown_minutes);
      const bool logger_ok = m_logger.Init(m_cfg.log_filename);
      m_initialized = true;
      return logger_ok;
     }

   void Deinit() { m_logger.Close(); }

   //+---------------------------------------------------------------+
   //| Feed breadth from wherever it actually lives (spec section 9  |
   //| notes MT5 has no native market-breadth feed).                  |
   //+---------------------------------------------------------------+
   void SetBreadthInputs(const double advancers, const double decliners,
                          const double pct_above_50ma, const double semis_participation,
                          const datetime as_of)
     {
      m_regime.SetBreadthInputs(advancers, decliners, pct_above_50ma, semis_participation, as_of);
     }

   void AddManualEvent(const datetime event_time, const string label) { m_event.AddManualEvent(event_time, label); }

   //+---------------------------------------------------------------+
   //| Report THIS bot's own Nasdaq-linked exposure so the             |
   //| correlation engine can see the aggregate across every EA on    |
   //| this terminal, not just this one.                               |
   //+---------------------------------------------------------------+
   void ReportOwnExposure(const string symbol, const double notional_value)
     {
      m_corr.ReportExposure(symbol, notional_value, AccountInfoDouble(ACCOUNT_EQUITY));
     }

   //+---------------------------------------------------------------+
   //| The main tick/bar entry point. Everything else is a getter    |
   //| against the snapshot this produces.                            |
   //+---------------------------------------------------------------+
   bool Update()
     {
      if(!m_initialized) return false;

      const double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      m_risk.UpdateDrawdown(equity);

      const bool vol_ok   = m_vol.Update();
      const bool macro_ok = m_macro.Update();
      const bool regime_ok = m_regime.Update();

      const datetime now = TimeCurrent();
      m_event.RefreshCalendar(now - 86400, now + 7 * 86400);
      const AxEventState ev = m_event.Evaluate(now);

      // Worst-of across every engine — never let one healthy feed mask
      // another engine's degraded/critical read (spec section 20).
      ENUM_AX_DATA_STATUS data_status = AX_DATA_OK;
      if(!regime_ok) data_status = AX_DATA_CRITICAL;
      else
        {
         ENUM_AX_DATA_STATUS candidates[3];
         candidates[0] = m_vol.GetDataStatus();
         candidates[1] = m_macro.GetDataStatus();
         candidates[2] = m_regime.GetDataStatus();
         for(int i = 0; i < 3; i++) if(candidates[i] > data_status) data_status = candidates[i];
        }
      if(!vol_ok && data_status != AX_DATA_CRITICAL) data_status = AX_DATA_DEGRADED;
      if(!macro_ok && data_status != AX_DATA_CRITICAL) data_status = AX_DATA_DEGRADED;

      const bool shock = vol_ok && m_vol.IsShock();
      const ENUM_AX_REGIME regime = regime_ok ? m_regime.ClassifyRegime(m_vol.GetVolState(), shock)
                                               : AX_REGIME_R3_RANGE_CHOP;
      const double confidence = regime_ok
                               ? m_regime.ComputeCompositeConfidence(m_vol.GetVolatilityScore(), m_macro.GetMacroScore(), m_cfg.weights)
                               : 0.0;

      const AxRegimeBand band = m_regime.GetRegimeBand(regime);
      const double regime_multiplier = band.trade_allowed ? AxLerp(band.risk_mult_lo, band.risk_mult_hi, confidence / 100.0) : 0.0;

      const double correlation_multiplier = m_corr.GetCorrelationMultiplier();

      double final_risk_pct = m_risk.ComputeFinalRiskPct(regime_multiplier, confidence,
                                                          m_vol.GetVolatilityMultiplier(),
                                                          correlation_multiplier, data_status);
      final_risk_pct *= ev.risk_multiplier; // event governor applies on top, per spec section 16

      const bool halted = m_risk.IsHalted();
      const bool corr_blocked = m_corr.IsOverLimit();
      const bool allow_new_trade = band.trade_allowed && ev.new_trades_allowed && !halted &&
                                    !corr_blocked && data_status != AX_DATA_CRITICAL && final_risk_pct > 0.0;

      const ENUM_AX_BIAS bias = regime_ok ? m_regime.GetBias() : AX_BIAS_NEUTRAL;
      bool allow_long = false, allow_short = false;
      switch(regime)
        {
         case AX_REGIME_R1_PERSISTENT_BULLISH:
         case AX_REGIME_R2_BULLISH_UNSTABLE:
            allow_long = true; break;
         case AX_REGIME_R4_BEARISH_TRANSITION:
         case AX_REGIME_R5_PERSISTENT_BEARISH:
            allow_short = true; break;
         case AX_REGIME_R3_RANGE_CHOP:
            allow_long = band.trade_allowed; allow_short = band.trade_allowed; break;
         case AX_REGIME_R6_VOLATILITY_SHOCK:
         default:
            break;
        }
      allow_long  = allow_long  && allow_new_trade;
      allow_short = allow_short && allow_new_trade;

      const bool aggressive_mode = band.aggressive_permitted && allow_new_trade &&
                                    (confidence >= m_cfg.aggressive_min_confidence);

      ENUM_AX_DECISION decision = AX_DECISION_BLOCK;
      if(allow_new_trade) decision = (final_risk_pct < m_cfg.base_risk_pct * 0.999) ? AX_DECISION_REDUCE : AX_DECISION_APPROVE;

      string note = "";
      if(shock) note += "SHOCK:" + m_vol.GetShockReason();
      if(halted) note += "DRAWDOWN_HALT;";
      if(corr_blocked) note += "CORRELATION_LIMIT;";
      if(ev.state != AX_EVENT_NORMAL) note += "EVENT:" + EnumToString(ev.state) + ":" + ev.nearest_event_label + ";";
      if(data_status != AX_DATA_OK) note += "DATA:" + AxDataStatusToString(data_status) + ";" + m_macro.GetNote();
      if(StringLen(note) == 0) note = "nominal";

      m_last.Clear();
      m_last.time                   = now;
      m_last.regime                 = regime;
      m_last.bias                   = bias;
      m_last.direction_score        = m_regime.GetDirectionScore();
      m_last.trend_efficiency       = m_regime.GetTrendEfficiency();
      m_last.trend_efficiency_score = m_regime.GetTrendEfficiencyScore();
      m_last.vol_state              = m_vol.GetVolState();
      m_last.volatility_score       = m_vol.GetVolatilityScore();
      m_last.volatility_multiplier  = m_vol.GetVolatilityMultiplier();
      m_last.macro_score            = m_macro.GetMacroScore();
      m_last.breadth_score          = m_regime.GetBreadthScore();
      m_last.liquidity_score        = m_regime.GetLiquidityScore();
      m_last.confidence_score       = confidence;
      m_last.regime_multiplier      = regime_multiplier;
      m_last.correlation_multiplier = correlation_multiplier;
      m_last.drawdown_multiplier    = m_risk.GetDrawdownMultiplier();
      m_last.risk_multiplier        = (m_cfg.base_risk_pct > 0.0) ? final_risk_pct / m_cfg.base_risk_pct : 0.0;
      m_last.allow_long             = allow_long;
      m_last.allow_short            = allow_short;
      m_last.allow_new_trade        = allow_new_trade;
      m_last.aggressive_mode        = aggressive_mode;
      m_last.shock_mode             = shock;
      m_last.data_status            = data_status;
      m_last.decision               = decision;
      m_last.decision_note          = note;

      m_logger.LogSnapshot(m_last);

      if(ev.force_regime_recompute)
        {
         // The cooldown just ended — the next call to Update() will
         // naturally recompute everything fresh; nothing further to do
         // here beyond flagging it in this run's log line above.
        }

      return true;
     }

   // --- Entry Permission API (spec sections 17 & 21) ------------------------
   ENUM_AX_REGIME GetRegime() const { return m_last.regime; }
   ENUM_AX_BIAS   GetDirection() const { return m_last.bias; } // a.k.a. NASDAQ_BIAS
   double         GetConfidence() const { return m_last.confidence_score; }
   double         GetRiskMultiplier() const { return m_last.risk_multiplier; }
   bool           AllowLong() const { return m_last.allow_long; }
   bool           AllowShort() const { return m_last.allow_short; }
   bool           AllowNewTrade() const { return m_last.allow_new_trade; }
   bool           IsAggressiveModePermitted() const { return m_last.aggressive_mode; }
   bool           IsVolatilityShock() const { return m_last.shock_mode; }
   ENUM_AX_VOL_STATE GetVolatilityState() const { return m_last.vol_state; }
   double         GetTrendEfficiency() const { return m_last.trend_efficiency; }
   double         GetMacroScore() const { return m_last.macro_score; }
   double         GetBreadthScore() const { return m_last.breadth_score; }
   double         GetLiquidityScore() const { return m_last.liquidity_score; }
   ENUM_AX_DATA_STATUS GetDataStatus() const { return m_last.data_status; }
   ENUM_AX_DECISION    GetDecision() const { return m_last.decision; }
   string              GetDecisionNote() const { return m_last.decision_note; }
   AxSnapshot          GetSnapshot() const { return m_last; }

   double GetAggregateExposure() { return m_corr.GetAggregateExposurePct(); }

   bool ResetRiskGovernor(const bool force_override = false) { return m_risk.ResetRiskGovernor(force_override); }
  };

//+------------------------------------------------------------------+
//| Global singleton + the exact free-function names from spec       |
//| section 21, so a host EA can use this without ever touching a    |
//| class. #include this file once in the EA and call these.         |
//+------------------------------------------------------------------+
CAutopsyX g_AutopsyX;

bool InitializeRegimeEngine(const AxConfig &cfg) { return g_AutopsyX.Init(cfg); }
bool InitializeRegimeEngine() { AxConfig cfg; cfg.Defaults(); return g_AutopsyX.Init(cfg); }
void DeinitializeRegimeEngine() { g_AutopsyX.Deinit(); }

bool UpdateMarketState() { return g_AutopsyX.Update(); }

ENUM_AX_REGIME GetRegime() { return g_AutopsyX.GetRegime(); }
ENUM_AX_BIAS   GetDirection() { return g_AutopsyX.GetDirection(); }
ENUM_AX_BIAS   GetNasdaqBias() { return g_AutopsyX.GetDirection(); }
double         GetConfidence() { return g_AutopsyX.GetConfidence(); }
double         GetRiskMultiplier() { return g_AutopsyX.GetRiskMultiplier(); }
bool           AllowLong() { return g_AutopsyX.AllowLong(); }
bool           AllowShort() { return g_AutopsyX.AllowShort(); }
bool           AllowNewTrade() { return g_AutopsyX.AllowNewTrade(); }
bool           IsAggressiveModePermitted() { return g_AutopsyX.IsAggressiveModePermitted(); }
bool           IsVolatilityShock() { return g_AutopsyX.IsVolatilityShock(); }
ENUM_AX_VOL_STATE GetVolatilityState() { return g_AutopsyX.GetVolatilityState(); }
double         GetTrendEfficiency() { return g_AutopsyX.GetTrendEfficiency(); }
double         GetMacroScore() { return g_AutopsyX.GetMacroScore(); }
double         GetBreadthScore() { return g_AutopsyX.GetBreadthScore(); }
double         GetLiquidityScore() { return g_AutopsyX.GetLiquidityScore(); }
ENUM_AX_DATA_STATUS GetDataStatus() { return g_AutopsyX.GetDataStatus(); }
ENUM_AX_DECISION    GetDecision() { return g_AutopsyX.GetDecision(); }
string              GetDecisionNote() { return g_AutopsyX.GetDecisionNote(); }

double GetAggregateExposure() { return g_AutopsyX.GetAggregateExposure(); }
void   ReportOwnExposure(const string symbol, const double notional_value) { g_AutopsyX.ReportOwnExposure(symbol, notional_value); }
void   SetBreadthInputs(const double advancers, const double decliners, const double pct_above_50ma,
                         const double semis_participation, const datetime as_of)
  { g_AutopsyX.SetBreadthInputs(advancers, decliners, pct_above_50ma, semis_participation, as_of); }
void   AddManualEvent(const datetime event_time, const string label) { g_AutopsyX.AddManualEvent(event_time, label); }

bool ResetRiskGovernor(const bool force_override = false) { return g_AutopsyX.ResetRiskGovernor(force_override); }
