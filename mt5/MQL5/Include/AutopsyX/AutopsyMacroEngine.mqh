//+------------------------------------------------------------------+
//|                                        AutopsyMacroEngine.mqh    |
//|  AUTOPSY X — Macro Confirmation Engine                           |
//|  Spec section 8.                                                 |
//|                                                                    |
//|  MT5 itself has no native feed for "real yields," Fed funds, or  |
//|  CPI. This engine builds its score from two possible sources per |
//|  leg, in preference order:                                        |
//|                                                                    |
//|    1. External data (SetExternalInputs) — real Treasury yields,  |
//|       Fed funds momentum, and actual CPI YoY, typically fed by    |
//|       AutopsyAlphaVantageBridge.mqh from the bridge server's      |
//|       /macro/snapshot. Preferred whenever it's fresh, because     |
//|       it's real data, not a CFD price proxy.                      |
//|    2. Broker CFD symbols (DXY, and 2Y/10Y if your broker lists    |
//|       them), used for anything external data didn't cover.       |
//|                                                                    |
//|  A leg with neither source available is dropped from the score   |
//|  entirely — never invented, never assumed bullish or bearish.    |
//|  DXY has no external-data path (Alpha Vantage doesn't publish a  |
//|  dollar index); it only ever comes from a broker CFD symbol.      |
//+------------------------------------------------------------------+
#property strict
#include "AutopsyTypes.mqh"

struct AxMacroThresholds
  {
   int    trend_lookback_bars;       // bars used to measure DXY momentum (CFD-symbol path only)
   double inflation_expectation_pct; // manual fallback when no external CPI print is available
   double external_stale_minutes;    // how long a SetExternalInputs() reading stays valid

   double dxy_weight;
   double yield10y_weight;
   double yield2y_weight;
   double real_yield_weight;
   double fedfunds_weight;

   void Defaults()
     {
      trend_lookback_bars       = 10;
      inflation_expectation_pct = 2.5; // rough long-run breakeven proxy; overridden by real CPI when available
      external_stale_minutes    = 180.0;

      dxy_weight        = 0.25;
      yield10y_weight    = 0.25;
      yield2y_weight     = 0.15;
      real_yield_weight  = 0.20;
      fedfunds_weight    = 0.15;
     }
  };

class CAxMacroEngine
  {
private:
   string             m_symbol_dxy;
   string             m_symbol_us2y;   // optional broker CFD proxy — only used if external 2Y momentum isn't fed
   string             m_symbol_us10y;  // optional broker CFD proxy — only used if external 10Y isn't fed
   bool               m_dxy_available;
   bool               m_us2y_available;
   bool               m_us10y_available;
   AxMacroThresholds  m_th;

   AxExternalMacroInputs m_ext;
   bool                  m_ext_fed;

   double             m_dxy_momentum_pct;
   double             m_yield10y_momentum_bps;
   double             m_yield2y_momentum_bps;
   double             m_fedfunds_momentum_bps;
   double             m_yield10y_level;
   double             m_real_yield_proxy;
   bool               m_real_yield_from_real_cpi;

   double             m_macro_score;
   ENUM_AX_DATA_STATUS m_data_status;
   string             m_note;

   bool SymbolMomentumPct(const string symbol, const int bars, double &momentum_pct, double &last_level)
     {
      double buf[];
      ArraySetAsSeries(buf, true);
      if(CopyClose(symbol, PERIOD_D1, 0, bars + 1, buf) < bars + 1 || buf[bars] == 0.0)
        {
         momentum_pct = 0.0;
         last_level   = 0.0;
         return false;
        }
      last_level   = buf[0];
      momentum_pct = 100.0 * (buf[0] - buf[bars]) / buf[bars];
      return true;
     }

   bool IsExternalFresh() const
     {
      if(!m_ext_fed) return false;
      const double age_minutes = (double)(TimeCurrent() - m_ext.as_of) / 60.0;
      return age_minutes <= m_th.external_stale_minutes;
     }

public:
   void Init(const string symbol_dxy, const string symbol_us2y, const string symbol_us10y,
             const AxMacroThresholds &thresholds)
     {
      m_symbol_dxy   = symbol_dxy;
      m_symbol_us2y  = symbol_us2y;
      m_symbol_us10y = symbol_us10y;
      m_th           = thresholds;

      m_dxy_available   = (StringLen(m_symbol_dxy)   > 0 && SymbolSelect(m_symbol_dxy,   true));
      m_us2y_available  = (StringLen(m_symbol_us2y)  > 0 && SymbolSelect(m_symbol_us2y,  true));
      m_us10y_available = (StringLen(m_symbol_us10y) > 0 && SymbolSelect(m_symbol_us10y, true));
      m_macro_score = 0.0;
      m_data_status = AX_DATA_OK;
      m_ext_fed = false;
      m_ext.Clear();
     }

   //+---------------------------------------------------------------+
   //| Feed real Treasury/Fed/CPI data — typically called right after |
   //| CAxAlphaVantageBridge::Fetch() succeeds. Whatever this engine  |
   //| was told before gets replaced, not merged, so feed every leg   |
   //| you have each time you call this.                              |
   //+---------------------------------------------------------------+
   void SetExternalInputs(const AxExternalMacroInputs &ext)
     {
      m_ext = ext;
      m_ext_fed = true;
     }

   bool Update()
     {
      m_data_status = AX_DATA_OK;
      m_note = "";
      m_real_yield_from_real_cpi = false;

      const bool ext_fresh = IsExternalFresh();
      if(m_ext_fed && !ext_fresh) m_note += "EXTERNAL_MACRO_STALE;";

      double weight_sum = 0.0;
      double score_sum  = 0.0;
      int    available_legs = 0;

      // --- DXY: CFD-symbol only, external data has no dollar-index leg ---
      if(m_dxy_available)
        {
         double lvl;
         if(SymbolMomentumPct(m_symbol_dxy, m_th.trend_lookback_bars, m_dxy_momentum_pct, lvl))
           {
            score_sum  += m_th.dxy_weight * AxClamp(-m_dxy_momentum_pct * 20.0, -100.0, 100.0);
            weight_sum += m_th.dxy_weight;
            available_legs++;
           }
         else { m_dxy_momentum_pct = 0.0; m_data_status = AX_DATA_DEGRADED; m_note += "DXY_STALE;"; }
        }
      else { m_data_status = AX_DATA_DEGRADED; m_note += "DXY_UNAVAILABLE;"; }

      // --- 10Y: prefer external (real Treasury data), else CFD proxy ---
      bool have_10y_level = false;
      if(ext_fresh && m_ext.has_us10y)
        {
         m_yield10y_momentum_bps = m_ext.us10y_momentum_bps;
         m_yield10y_level        = m_ext.us10y_level;
         have_10y_level = true;
         score_sum  += m_th.yield10y_weight * AxClamp(-m_yield10y_momentum_bps * 15.0, -100.0, 100.0);
         weight_sum += m_th.yield10y_weight;
         available_legs++;
        }
      else if(m_us10y_available)
        {
         double lvl;
         if(SymbolMomentumPct(m_symbol_us10y, m_th.trend_lookback_bars, m_yield10y_momentum_bps, lvl))
           {
            m_yield10y_level = lvl;
            have_10y_level = true;
            score_sum  += m_th.yield10y_weight * AxClamp(-m_yield10y_momentum_bps * 15.0, -100.0, 100.0);
            weight_sum += m_th.yield10y_weight;
            available_legs++;
           }
         else { m_yield10y_momentum_bps = 0.0; m_data_status = AX_DATA_DEGRADED; m_note += "US10Y_STALE;"; }
        }
      else { m_data_status = AX_DATA_DEGRADED; m_note += "US10Y_UNAVAILABLE;"; }

      // --- Real yield: nominal 10Y minus inflation. Prefer an actual CPI
      // print (external) over the manual inflation-expectation input. ---
      if(have_10y_level)
        {
         double inflation_used = m_th.inflation_expectation_pct;
         if(ext_fresh && m_ext.has_cpi) { inflation_used = m_ext.cpi_yoy_pct; m_real_yield_from_real_cpi = true; }
         else m_note += "REAL_YIELD_USES_MANUAL_INFLATION_INPUT;";

         m_real_yield_proxy = m_yield10y_level - inflation_used;
         score_sum  += m_th.real_yield_weight * AxClamp(-m_real_yield_proxy * 10.0, -100.0, 100.0);
         weight_sum += m_th.real_yield_weight;
        }

      // --- 2Y momentum: prefer external, else CFD proxy ---
      if(ext_fresh && m_ext.has_us2y_momentum)
        {
         m_yield2y_momentum_bps = m_ext.us2y_momentum_bps;
         score_sum  += m_th.yield2y_weight * AxClamp(-m_yield2y_momentum_bps * 15.0, -100.0, 100.0);
         weight_sum += m_th.yield2y_weight;
         available_legs++;
        }
      else if(m_us2y_available)
        {
         double lvl;
         if(SymbolMomentumPct(m_symbol_us2y, m_th.trend_lookback_bars, m_yield2y_momentum_bps, lvl))
           {
            score_sum  += m_th.yield2y_weight * AxClamp(-m_yield2y_momentum_bps * 15.0, -100.0, 100.0);
            weight_sum += m_th.yield2y_weight;
            available_legs++;
           }
         else { m_yield2y_momentum_bps = 0.0; m_data_status = AX_DATA_DEGRADED; m_note += "US2Y_STALE;"; }
        }
      else { m_data_status = AX_DATA_DEGRADED; m_note += "US2Y_UNAVAILABLE;"; }

      // --- Fed funds momentum: external-only leg, no CFD equivalent ---
      if(ext_fresh && m_ext.has_fed_funds_momentum)
        {
         m_fedfunds_momentum_bps = m_ext.fed_funds_momentum_bps;
         // Fed funds rising faster tightens conditions — headwind, same sign convention as yields.
         score_sum  += m_th.fedfunds_weight * AxClamp(-m_fedfunds_momentum_bps * 15.0, -100.0, 100.0);
         weight_sum += m_th.fedfunds_weight;
         available_legs++;
        }
      else { m_fedfunds_momentum_bps = 0.0; m_note += "FED_FUNDS_UNAVAILABLE;"; }

      if(available_legs == 0)
        {
         m_macro_score = 0.0;
         m_data_status = AX_DATA_DEGRADED;
         m_note += "NO_MACRO_LEGS_AVAILABLE;";
         return false;
        }

      m_macro_score = AxClamp(score_sum / weight_sum, -100.0, 100.0);
      return true;
     }

   double GetMacroScore() const { return m_macro_score; }
   double GetDxyMomentumPct() const { return m_dxy_momentum_pct; }
   double GetYield10yMomentumBps() const { return m_yield10y_momentum_bps; }
   double GetYield2yMomentumBps() const { return m_yield2y_momentum_bps; }
   double GetFedFundsMomentumBps() const { return m_fedfunds_momentum_bps; }
   double GetRealYieldProxy() const { return m_real_yield_proxy; }
   bool   IsRealYieldFromRealCpi() const { return m_real_yield_from_real_cpi; }
   ENUM_AX_DATA_STATUS GetDataStatus() const { return m_data_status; }
   string GetNote() const { return m_note; }

   string GetMacroLabel() const
     {
      if(m_macro_score >= 30.0)  return "SUPPORTIVE";
      if(m_macro_score <= -30.0) return "HEADWIND";
      return "MIXED";
     }
  };
