//+------------------------------------------------------------------+
//|                                        AutopsyRiskGovernor.mqh   |
//|  AUTOPSY X — TQQQ Leverage Model, Drawdown Governor, Fail-Safe   |
//|  Spec sections 13, 14, 20.                                       |
//|                                                                    |
//|  Never POSITION_SIZE × 3. Final risk is a product of independent |
//|  multipliers so any single deteriorating input can only ever     |
//|  scale risk down, never up.                                       |
//+------------------------------------------------------------------+
#property strict
#include "AutopsyTypes.mqh"

class CAxRiskGovernor
  {
private:
   double         m_base_risk_pct;

   AxDrawdownBand m_bands[5];
   double         m_reset_buffer_pct;   // must recover this far back inside the halt band's lower edge to reset
   double         m_halt_threshold_pct; // drawdown % at/above which trading halts entirely

   double         m_peak_equity;
   double         m_current_drawdown_pct;
   double         m_drawdown_multiplier;
   bool           m_halted;
   bool           m_initialized_peak;

public:
   void Init(const double base_risk_pct, const double reset_buffer_pct = 1.0)
     {
      m_base_risk_pct    = base_risk_pct;
      m_reset_buffer_pct = reset_buffer_pct;
      m_peak_equity       = 0.0;
      m_current_drawdown_pct = 0.0;
      m_drawdown_multiplier  = 1.00;
      m_halted            = false;
      m_initialized_peak  = false;

      // Spec section 14 default bands — override with SetDrawdownBands().
      m_bands[0].drawdown_from_pct = 0.0;  m_bands[0].drawdown_to_pct = 3.0;  m_bands[0].risk_multiplier = 1.00;
      m_bands[1].drawdown_from_pct = 3.0;  m_bands[1].drawdown_to_pct = 5.0;  m_bands[1].risk_multiplier = 0.75;
      m_bands[2].drawdown_from_pct = 5.0;  m_bands[2].drawdown_to_pct = 8.0;  m_bands[2].risk_multiplier = 0.50;
      m_bands[3].drawdown_from_pct = 8.0;  m_bands[3].drawdown_to_pct = 10.0; m_bands[3].risk_multiplier = 0.25;
      m_bands[4].drawdown_from_pct = 10.0; m_bands[4].drawdown_to_pct = 0.0;  m_bands[4].risk_multiplier = 0.00; // 0 upper bound = open-ended halt band
      m_halt_threshold_pct = m_bands[4].drawdown_from_pct;
     }

   //+---------------------------------------------------------------+
   //| Override the default drawdown bands. Pass exactly 5 bands,    |
   //| ascending, with the last one's drawdown_to_pct = 0 (halt).    |
   //+---------------------------------------------------------------+
   void SetDrawdownBands(const AxDrawdownBand &bands[])
     {
      const int n = MathMin(ArraySize(bands), 5);
      for(int i = 0; i < n; i++) m_bands[i] = bands[i];
      m_halt_threshold_pct = m_bands[4].drawdown_from_pct;
     }

   //+---------------------------------------------------------------+
   //| Call once per update cycle with current account equity. Peak  |
   //| equity is tracked internally — drawdown is always measured    |
   //| from the account's own high-water mark, not from the deposit. |
   //+---------------------------------------------------------------+
   void UpdateDrawdown(const double current_equity)
     {
      if(!m_initialized_peak || current_equity > m_peak_equity)
        {
         m_peak_equity = current_equity;
         m_initialized_peak = true;
        }

      m_current_drawdown_pct = (m_peak_equity > 0.0) ? 100.0 * (m_peak_equity - current_equity) / m_peak_equity : 0.0;

      m_drawdown_multiplier = 0.0;
      for(int i = 0; i < 5; i++)
        {
         const bool in_band = (m_current_drawdown_pct >= m_bands[i].drawdown_from_pct) &&
                               (m_bands[i].drawdown_to_pct == 0.0 || m_current_drawdown_pct < m_bands[i].drawdown_to_pct);
         if(in_band) { m_drawdown_multiplier = m_bands[i].risk_multiplier; break; }
        }

      if(m_current_drawdown_pct >= m_halt_threshold_pct)
         m_halted = true; // stays halted until ResetRiskGovernor() explicitly clears it
     }

   //+---------------------------------------------------------------+
   //| A halt never clears itself just because equity ticked up one  |
   //| bar. The account must recover past the halt threshold by the  |
   //| configured buffer, or the caller must explicitly force it     |
   //| (a deliberate human decision, not an automatic one).           |
   //+---------------------------------------------------------------+
   bool ResetRiskGovernor(const bool force_override = false)
     {
      if(!m_halted) return true;
      const bool recovered = m_current_drawdown_pct < (m_halt_threshold_pct - m_reset_buffer_pct);
      if(recovered || force_override)
        {
         m_halted = false;
         return true;
        }
      return false;
     }

   bool   IsHalted() const { return m_halted; }
   double GetDrawdownPct() const { return m_current_drawdown_pct; }
   double GetDrawdownMultiplier() const { return m_halted ? 0.0 : m_drawdown_multiplier; }
   double GetPeakEquity() const { return m_peak_equity; }

   //+---------------------------------------------------------------+
   //| Section 13's leverage model, as a product of independent      |
   //| multipliers — never a flat ×3. Section 20's fail-safe clamps   |
   //| are applied last and can only ever tighten the result.         |
   //+---------------------------------------------------------------+
   double ComputeFinalRiskPct(const double regime_multiplier,
                               const double confidence_score_0_100,
                               const double volatility_multiplier,
                               const double correlation_multiplier,
                               const ENUM_AX_DATA_STATUS data_status) const
     {
      if(m_halted) return 0.0;
      if(data_status == AX_DATA_CRITICAL) return 0.0;

      const double confidence_multiplier = AxClamp(confidence_score_0_100 / 100.0, 0.0, 1.0);
      double final_risk = m_base_risk_pct
                         * AxClamp(regime_multiplier, 0.0, 2.0)
                         * confidence_multiplier
                         * AxClamp(volatility_multiplier, 0.0, 1.0)
                         * AxClamp(correlation_multiplier, 0.0, 1.0)
                         * (m_halted ? 0.0 : m_drawdown_multiplier);

      if(data_status == AX_DATA_DEGRADED)
         final_risk = MathMin(final_risk, m_base_risk_pct * 0.25); // section 20: degraded data caps risk at 0.25x base

      return MathMax(final_risk, 0.0);
     }

   double GetBaseRiskPct() const { return m_base_risk_pct; }
   void   SetBaseRiskPct(const double base_risk_pct) { m_base_risk_pct = base_risk_pct; }
  };
