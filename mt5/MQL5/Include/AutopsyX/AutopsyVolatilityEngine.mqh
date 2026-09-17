//+------------------------------------------------------------------+
//|                                     AutopsyVolatilityEngine.mqh  |
//|  AUTOPSY X — Volatility Engine + Volatility Shock Detector       |
//|  Spec sections 6 and 7.                                          |
//|                                                                    |
//|  Distinguishes LOW VOL + TREND from HIGH VOL + TREND — these are |
//|  not the same trading environment, and high vol does not by      |
//|  itself mean bearish. It means risk conditions changed.          |
//+------------------------------------------------------------------+
#property strict
#include "AutopsyTypes.mqh"

//+------------------------------------------------------------------+
//| Configurable thresholds. Nothing here is hard-coded permanently  |
//| — every number is a tunable input on the class.                  |
//+------------------------------------------------------------------+
struct AxVolThresholds
  {
   int    atr_period;               // ATR averaging period
   int    percentile_lookback;      // bars used to rank current ATR/realized vol
   int    realized_vol_period;      // bars used for the realized-vol stdev window

   double atr_pct_low;              // ATR percentile below this => LOW
   double atr_pct_elevated;         // ATR percentile above this => ELEVATED
   double atr_pct_high;             // ATR percentile above this => HIGH
   double atr_pct_extreme;          // ATR percentile above this => EXTREME

   double vix_change_shock_pct;     // VIX % move over vix_change_bars that alone signals a shock
   int    vix_change_bars;
   double atr_expansion_shock_mult; // current ATR / SMA(ATR) ratio that alone signals a shock
   double abnormal_move_atr_mult;   // |today's move| > this * ATR => abnormal displacement
   double abnormal_volume_rel_mult; // relative volume > this => abnormal participation

   void Defaults()
     {
      atr_period               = 14;
      percentile_lookback       = 252;
      realized_vol_period       = 20;

      atr_pct_low               = 25.0;
      atr_pct_elevated          = 60.0;
      atr_pct_high              = 85.0;
      atr_pct_extreme           = 95.0;

      vix_change_shock_pct      = 20.0;  // VIX up 20%+ over vix_change_bars
      vix_change_bars           = 3;
      atr_expansion_shock_mult  = 2.0;   // ATR doubling vs its own average
      abnormal_move_atr_mult    = 3.0;   // a >3 ATR daily move
      abnormal_volume_rel_mult  = 3.0;   // 3x average volume
     }
  };

//+------------------------------------------------------------------+
//| CAxVolatilityEngine                                               |
//+------------------------------------------------------------------+
class CAxVolatilityEngine
  {
private:
   string            m_symbol_qqq;
   string            m_symbol_vix;
   bool              m_vix_available;
   AxVolThresholds   m_th;

   double            m_atr_current;
   double            m_atr_percentile;
   double            m_atr_sma;
   double            m_realized_vol_annualized;
   double            m_vix_level;
   double            m_vix_change_pct;

   ENUM_AX_VOL_STATE m_vol_state;
   bool              m_shock_active;
   string            m_shock_reason;
   ENUM_AX_DATA_STATUS m_data_status;

   int               ArrayPercentileRank(double &history[], const double value)
     {
      const int n = ArraySize(history);
      if(n == 0) return 50; // no history yet — assume the middle rather than an extreme
      int below = 0;
      for(int i = 0; i < n; i++)
         if(history[i] <= value) below++;
      return (int)MathRound(100.0 * below / n);
     }

public:
   void Init(const string symbol_qqq, const string symbol_vix, const AxVolThresholds &thresholds)
     {
      m_symbol_qqq = symbol_qqq;
      m_symbol_vix = symbol_vix;
      m_th         = thresholds;
      m_vix_available = (StringLen(m_symbol_vix) > 0 && SymbolSelect(m_symbol_vix, true));
      m_vol_state  = AX_VOL_NORMAL;
      m_shock_active = false;
      m_data_status  = AX_DATA_OK;
     }

   //+---------------------------------------------------------------+
   //| Pull fresh ATR/realized-vol/VIX numbers. Call once per bar/tick|
   //| before reading any getter below.                               |
   //+---------------------------------------------------------------+
   bool Update()
     {
      m_data_status = AX_DATA_OK;
      m_shock_reason = "";

      int atr_handle = iATR(m_symbol_qqq, PERIOD_D1, m_th.atr_period);
      if(atr_handle == INVALID_HANDLE)
        {
         m_data_status = AX_DATA_CRITICAL;
         return false;
        }

      double atr_buf[];
      ArraySetAsSeries(atr_buf, true);
      const int need = MathMax(m_th.percentile_lookback, m_th.atr_period) + 5;
      if(CopyBuffer(atr_handle, 0, 0, need, atr_buf) < need)
        {
         IndicatorRelease(atr_handle);
         m_data_status = AX_DATA_DEGRADED; // not enough history yet — degrade, don't guess
         if(ArraySize(atr_buf) < 2) return false;
        }
      IndicatorRelease(atr_handle);

      m_atr_current = atr_buf[0];

      // ATR percentile vs its own trailing history.
      double history[];
      const int hist_n = MathMin(m_th.percentile_lookback, ArraySize(atr_buf) - 1);
      ArrayResize(history, MathMax(hist_n, 0));
      for(int i = 0; i < hist_n; i++) history[i] = atr_buf[i + 1];
      m_atr_percentile = ArrayPercentileRank(history, m_atr_current);

      double sum = 0.0;
      const int sma_n = MathMin(m_th.atr_period, ArraySize(atr_buf));
      for(int i = 0; i < sma_n; i++) sum += atr_buf[i];
      m_atr_sma = (sma_n > 0) ? sum / sma_n : m_atr_current;

      // Realized volatility: annualized stdev of daily log returns.
      double close_buf[];
      ArraySetAsSeries(close_buf, true);
      const int rv_need = m_th.realized_vol_period + 1;
      if(CopyClose(m_symbol_qqq, PERIOD_D1, 0, rv_need, close_buf) < rv_need)
        {
         m_realized_vol_annualized = 0.0;
         if(m_data_status == AX_DATA_OK) m_data_status = AX_DATA_DEGRADED;
        }
      else
        {
         double rets[];
         ArrayResize(rets, m_th.realized_vol_period);
         double mean = 0.0;
         for(int i = 0; i < m_th.realized_vol_period; i++)
           {
            rets[i] = MathLog(close_buf[i] / close_buf[i + 1]);
            mean += rets[i];
           }
         mean /= m_th.realized_vol_period;
         double var = 0.0;
         for(int i = 0; i < m_th.realized_vol_period; i++) var += MathPow(rets[i] - mean, 2);
         var /= MathMax(m_th.realized_vol_period - 1, 1);
         m_realized_vol_annualized = MathSqrt(var) * MathSqrt(252.0) * 100.0;
        }

      // VIX level/change — genuinely optional. Not every broker lists it;
      // absence degrades this engine, it never gets treated as "calm".
      m_vix_level = 0.0;
      m_vix_change_pct = 0.0;
      if(m_vix_available)
        {
         double vix_buf[];
         ArraySetAsSeries(vix_buf, true);
         const int vneed = m_th.vix_change_bars + 1;
         if(CopyClose(m_symbol_vix, PERIOD_D1, 0, vneed, vix_buf) >= vneed && vix_buf[m_th.vix_change_bars] > 0.0)
           {
            m_vix_level = vix_buf[0];
            m_vix_change_pct = 100.0 * (vix_buf[0] - vix_buf[m_th.vix_change_bars]) / vix_buf[m_th.vix_change_bars];
           }
         else
           {
            if(m_data_status == AX_DATA_OK) m_data_status = AX_DATA_DEGRADED;
           }
        }
      else
        {
         if(m_data_status == AX_DATA_OK) m_data_status = AX_DATA_DEGRADED;
        }

      ClassifyVolatility();
      DetectShock();
      return true;
     }

private:
   void ClassifyVolatility()
     {
      // ATR percentile drives the primary read; a VIX spike can push the
      // classification up (never down — missing/calm VIX never softens
      // what price action itself is already saying).
      if(m_atr_percentile >= m_th.atr_pct_extreme) m_vol_state = AX_VOL_EXTREME;
      else if(m_atr_percentile >= m_th.atr_pct_high) m_vol_state = AX_VOL_HIGH;
      else if(m_atr_percentile >= m_th.atr_pct_elevated) m_vol_state = AX_VOL_ELEVATED;
      else if(m_atr_percentile <= m_th.atr_pct_low) m_vol_state = AX_VOL_LOW;
      else m_vol_state = AX_VOL_NORMAL;

      if(m_vix_available && m_vix_change_pct >= m_th.vix_change_shock_pct)
        {
         if(m_vol_state == AX_VOL_LOW || m_vol_state == AX_VOL_NORMAL) m_vol_state = AX_VOL_ELEVATED;
         else if(m_vol_state == AX_VOL_ELEVATED) m_vol_state = AX_VOL_HIGH;
        }
     }

   void DetectShock()
     {
      // Primary triggers — any single one is sufficient on its own.
      bool vix_rapid_expansion  = m_vix_available && (m_vix_change_pct >= m_th.vix_change_shock_pct);
      bool atr_expansion_shock  = (m_atr_sma > 0.0) && (m_atr_current / m_atr_sma >= m_th.atr_expansion_shock_mult);
      bool realized_vol_extreme = (m_atr_percentile >= m_th.atr_pct_extreme);

      // Secondary triggers — individually moderate, but two or more firing
      // together also constitutes "multiple risk variables deteriorating
      // simultaneously" per spec section 7.
      int secondary = 0;
      if(m_atr_percentile >= m_th.atr_pct_high) secondary++;
      if(m_vix_available && m_vix_change_pct >= (m_th.vix_change_shock_pct * 0.5)) secondary++;
      if(m_data_status != AX_DATA_OK) secondary++; // degraded data is itself a risk deterioration

      m_shock_active = vix_rapid_expansion || atr_expansion_shock || realized_vol_extreme || (secondary >= 2);

      if(m_shock_active)
        {
         string reasons = "";
         if(vix_rapid_expansion)  reasons += "VIX_RAPID_EXPANSION;";
         if(atr_expansion_shock)  reasons += "ATR_EXPANSION;";
         if(realized_vol_extreme) reasons += "ATR_PERCENTILE_EXTREME;";
         if(secondary >= 2 && !vix_rapid_expansion && !atr_expansion_shock && !realized_vol_extreme)
            reasons += "MULTIPLE_SECONDARY_DETERIORATION;";
         m_shock_reason = reasons;
        }
     }

public:
   ENUM_AX_VOL_STATE GetVolState() const { return m_vol_state; }
   bool              IsShock() const { return m_shock_active; }
   string            GetShockReason() const { return m_shock_reason; }
   double            GetAtrPercentile() const { return m_atr_percentile; }
   double            GetRealizedVolAnnualizedPct() const { return m_realized_vol_annualized; }
   double            GetVixLevel() const { return m_vix_level; }
   double            GetVixChangePct() const { return m_vix_change_pct; }
   ENUM_AX_DATA_STATUS GetDataStatus() const { return m_data_status; }

   //+---------------------------------------------------------------+
   //| 0..100 "favorable conditions" read for the composite confidence|
   //| score (spec section 11) — LOW/NORMAL vol scores high, EXTREME  |
   //| scores near zero. This is NOT a directional signal.            |
   //+---------------------------------------------------------------+
   double GetVolatilityScore() const
     {
      switch(m_vol_state)
        {
         case AX_VOL_LOW:      return 90.0;
         case AX_VOL_NORMAL:   return 100.0; // dead-flat vol can also mean no participation; NORMAL is the sweet spot
         case AX_VOL_ELEVATED: return 60.0;
         case AX_VOL_HIGH:     return 30.0;
         case AX_VOL_EXTREME:  return 5.0;
        }
      return 50.0;
     }

   //+---------------------------------------------------------------+
   //| 0..1 multiplier fed straight into the risk governor's leverage |
   //| model (spec section 13). Separate from the score above because |
   //| sizing and "is this a good regime" are different questions.    |
   //+---------------------------------------------------------------+
   double GetVolatilityMultiplier() const
     {
      if(m_shock_active) return 0.0;
      switch(m_vol_state)
        {
         case AX_VOL_LOW:      return 1.00;
         case AX_VOL_NORMAL:   return 1.00;
         case AX_VOL_ELEVATED: return 0.70;
         case AX_VOL_HIGH:     return 0.40;
         case AX_VOL_EXTREME:  return 0.10;
        }
      return 0.50;
     }
  };
