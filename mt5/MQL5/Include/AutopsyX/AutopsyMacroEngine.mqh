//+------------------------------------------------------------------+
//|                                        AutopsyMacroEngine.mqh    |
//|  AUTOPSY X — Macro Confirmation Engine                           |
//|  Spec section 8.                                                 |
//|                                                                    |
//|  Honest limitation: MT5 has no native feed for "real yields" or  |
//|  "Fed expectations" as such. This engine builds them from price  |
//|  action on whatever symbols the broker actually lists (DXY, and  |
//|  2Y/10Y yield CFDs where the broker offers them) and degrades     |
//|  gracefully — never silently — when a symbol isn't there. Macro  |
//|  confirms the trade per section 8; it never independently         |
//|  dictates it, so a missing macro leg lowers confidence, it does  |
//|  not by itself block trading.                                    |
//+------------------------------------------------------------------+
#property strict
#include "AutopsyTypes.mqh"

struct AxMacroThresholds
  {
   int    trend_lookback_bars;     // bars used to measure DXY/yield momentum
   double inflation_expectation_pct; // manual override — no live breakeven feed in MT5
   double dxy_weight;
   double yield10y_weight;
   double yield2y_weight;
   double real_yield_weight;

   void Defaults()
     {
      trend_lookback_bars       = 10;
      inflation_expectation_pct = 2.5; // rough long-run breakeven proxy; override per input
      dxy_weight        = 0.30;
      yield10y_weight    = 0.30;
      yield2y_weight     = 0.20;
      real_yield_weight  = 0.20;
     }
  };

class CAxMacroEngine
  {
private:
   string             m_symbol_dxy;
   string             m_symbol_us2y;
   string             m_symbol_us10y;
   bool               m_dxy_available;
   bool               m_us2y_available;
   bool               m_us10y_available;
   AxMacroThresholds  m_th;

   double             m_dxy_momentum_pct;
   double             m_yield10y_momentum_bps;
   double             m_yield2y_momentum_bps;
   double             m_yield10y_level;
   double             m_real_yield_proxy;

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
     }

   bool Update()
     {
      m_data_status = AX_DATA_OK;
      m_note = "";

      double weight_sum = 0.0;
      double score_sum  = 0.0;
      int    available_legs = 0;

      // DXY strengthening is a headwind for Nasdaq (risk-off / tighter
      // financial conditions), so its contribution to the bullish macro
      // score is the negative of its own momentum.
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

      // Rising long yields tighten the discount rate on growth/tech cash
      // flows — headwind. Falling yields — tailwind.
      if(m_us10y_available)
        {
         double lvl;
         if(SymbolMomentumPct(m_symbol_us10y, m_th.trend_lookback_bars, m_yield10y_momentum_bps, lvl))
           {
            m_yield10y_level = lvl;
            score_sum  += m_th.yield10y_weight * AxClamp(-m_yield10y_momentum_bps * 15.0, -100.0, 100.0);
            weight_sum += m_th.yield10y_weight;
            available_legs++;

            // Real-yield proxy: nominal 10Y minus a manual inflation-expectation
            // input (no live breakeven feed in MT5 — this is a documented
            // approximation, not a market-sourced real yield).
            m_real_yield_proxy = lvl - m_th.inflation_expectation_pct;
            score_sum  += m_th.real_yield_weight * AxClamp(-m_real_yield_proxy * 10.0, -100.0, 100.0);
            weight_sum += m_th.real_yield_weight;
           }
         else { m_yield10y_momentum_bps = 0.0; m_data_status = AX_DATA_DEGRADED; m_note += "US10Y_STALE;"; }
        }
      else { m_data_status = AX_DATA_DEGRADED; m_note += "US10Y_UNAVAILABLE;"; }

      // 2Y yield momentum as a Fed-expectations proxy: 2Y repricing higher
      // means the market is pulling forward hawkish expectations.
      if(m_us2y_available)
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

      if(available_legs == 0)
        {
         // No macro leg sourced at all — never invent a number. Neutral
         // score, degraded status, and the composite weight for macro
         // effectively contributes nothing useful this run.
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
   double GetRealYieldProxy() const { return m_real_yield_proxy; }
   ENUM_AX_DATA_STATUS GetDataStatus() const { return m_data_status; }
   string GetNote() const { return m_note; }

   string GetMacroLabel() const
     {
      if(m_macro_score >= 30.0)  return "SUPPORTIVE";
      if(m_macro_score <= -30.0) return "HEADWIND";
      return "MIXED";
     }
  };
