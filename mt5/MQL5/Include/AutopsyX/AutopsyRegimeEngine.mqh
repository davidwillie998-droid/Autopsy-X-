//+------------------------------------------------------------------+
//|                                        AutopsyRegimeEngine.mqh   |
//|  AUTOPSY X — Direction, Trend-Efficiency, Breadth, Liquidity     |
//|  engines and the R1-R6 Regime Decision Matrix.                  |
//|  Spec sections 3, 4, 5, 9, 10, 11, 12.                          |
//|                                                                    |
//|  Kept as one file because the decision matrix in section 12     |
//|  reads all of these together — splitting them further would     |
//|  just move the coupling into extra #includes without removing   |
//|  it. Breadth and liquidity are exposed as pluggable external     |
//|  feeds (see SetBreadthInputs below) because MT5 itself has no   |
//|  market-wide advance/decline feed; leaving them unfed degrades   |
//|  their weight to neutral, it never fakes a number.               |
//+------------------------------------------------------------------+
#property strict
#include "AutopsyTypes.mqh"

//+------------------------------------------------------------------+
//| Configurable thresholds — every band in spec sections 4, 5, 12   |
//| is a tunable input here, not a hard-coded constant.               |
//+------------------------------------------------------------------+
struct AxRegimeThresholds
  {
   int    ema_fast, ema_medium, ema_slow;      // section 4 recommends 20/50/200
   int    structure_lookback;                  // bars used for HH/HL/LH/LL and breakout/breakdown
   int    momentum_lookback;                   // bars used for the momentum sub-score
   int    trend_eff_lookback;                  // section 5 recommends 10 or 20

   double direction_strong;                    // |score| >= this => "strong" bullish/bearish (70)
   double direction_moderate;                  // |score| >= this => bullish/bearish (40)

   double trend_eff_high;                      // section 12 R1/R5 "high" efficiency (0..1)
   double trend_eff_low;                       // section 12 R3 "low" efficiency (0..1)

   double breadth_supportive;                  // -100..100 threshold for "supportive" breadth
   double breadth_weak;                        // -100..100 threshold for "weak" breadth

   bool   allow_range_strategy;                // EA has a dedicated range strategy => R3 gets a small allowance
   double breadth_stale_minutes;               // how long a manually-fed breadth reading stays valid

   void Defaults()
     {
      ema_fast = 20; ema_medium = 50; ema_slow = 200;
      structure_lookback = 20;
      momentum_lookback   = 10;
      trend_eff_lookback  = 20;

      direction_strong   = 70.0;
      direction_moderate = 40.0;

      trend_eff_high = 0.60;
      trend_eff_low  = 0.30;

      breadth_supportive = 30.0;
      breadth_weak       = -10.0;

      allow_range_strategy  = false;
      breadth_stale_minutes = 24 * 60;
     }
  };

//+------------------------------------------------------------------+
//| Per-regime permission/risk band (spec section 12). Configurable. |
//+------------------------------------------------------------------+
struct AxRegimeBand
  {
   bool   trade_allowed;
   bool   aggressive_permitted;
   double risk_mult_lo;
   double risk_mult_hi;
  };

class CAxRegimeEngine
  {
private:
   string             m_symbol;             // the instrument driving direction/efficiency — QQQ or NDX/US100 CFD
   string             m_symbol_liquidity;   // usually the same symbol; volume comes from here
   AxRegimeThresholds m_th;

   // Direction engine state
   double             m_ema_fast, m_ema_medium, m_ema_slow, m_price;
   bool               m_bullish_structure, m_bearish_structure;
   bool               m_higher_high, m_higher_low, m_lower_high, m_lower_low;
   bool               m_breakout_20, m_breakdown_20;
   double             m_momentum_roc_pct;
   double             m_direction_score;    // -100..+100

   // Trend efficiency
   double             m_trend_efficiency;         // 0..1
   double             m_trend_efficiency_score;   // 0..100

   // Breadth (externally fed — see SetBreadthInputs)
   bool               m_breadth_fed;
   datetime           m_breadth_as_of;
   double             m_breadth_advancers, m_breadth_decliners, m_breadth_pct_above_50ma, m_breadth_semis;
   double             m_breadth_score;            // -100..+100

   // Liquidity/volume
   double             m_liquidity_score;          // 0..100
   double             m_relative_volume;

   ENUM_AX_DATA_STATUS m_data_status;

public:
   void Init(const string symbol, const AxRegimeThresholds &thresholds)
     {
      m_symbol           = symbol;
      m_symbol_liquidity = symbol;
      m_th               = thresholds;
      m_breadth_fed      = false;
      m_data_status      = AX_DATA_OK;
     }

   //+---------------------------------------------------------------+
   //| Feed market-breadth numbers from wherever your data actually  |
   //| lives (a bridge server, a CSV a script drops, another feed).  |
   //| Until this is called at least once, breadth stays neutral and |
   //| the composite confidence weight for it contributes nothing.   |
   //+---------------------------------------------------------------+
   void SetBreadthInputs(const double advancers, const double decliners,
                          const double pct_above_50ma, const double semis_participation,
                          const datetime as_of)
     {
      m_breadth_advancers      = advancers;
      m_breadth_decliners      = decliners;
      m_breadth_pct_above_50ma = pct_above_50ma;
      m_breadth_semis          = semis_participation;
      m_breadth_as_of          = as_of;
      m_breadth_fed            = true;
     }

   bool Update()
     {
      m_data_status = AX_DATA_OK;
      if(!UpdateDirection())    { m_data_status = AX_DATA_CRITICAL; return false; }
      UpdateTrendEfficiency();
      UpdateBreadth();
      UpdateLiquidity();
      return true;
     }

private:
   //+---------------------------------------------------------------+
   //| Section 4 — Direction Engine                                  |
   //+---------------------------------------------------------------+
   bool UpdateDirection()
     {
      int h_fast   = iMA(m_symbol, PERIOD_D1, m_th.ema_fast,   0, MODE_EMA, PRICE_CLOSE);
      int h_medium = iMA(m_symbol, PERIOD_D1, m_th.ema_medium, 0, MODE_EMA, PRICE_CLOSE);
      int h_slow   = iMA(m_symbol, PERIOD_D1, m_th.ema_slow,   0, MODE_EMA, PRICE_CLOSE);
      if(h_fast == INVALID_HANDLE || h_medium == INVALID_HANDLE || h_slow == INVALID_HANDLE)
        {
         if(h_fast   != INVALID_HANDLE) IndicatorRelease(h_fast);
         if(h_medium != INVALID_HANDLE) IndicatorRelease(h_medium);
         if(h_slow   != INVALID_HANDLE) IndicatorRelease(h_slow);
         return false;
        }

      double buf_fast[], buf_medium[], buf_slow[];
      ArraySetAsSeries(buf_fast, true); ArraySetAsSeries(buf_medium, true); ArraySetAsSeries(buf_slow, true);
      const bool have_fast   = CopyBuffer(h_fast,   0, 0, 2, buf_fast)   >= 2;
      const bool have_medium = CopyBuffer(h_medium, 0, 0, 2, buf_medium) >= 2;
      const bool have_slow   = CopyBuffer(h_slow,   0, 0, 2, buf_slow)   >= 2;
      IndicatorRelease(h_fast); IndicatorRelease(h_medium); IndicatorRelease(h_slow);
      if(!have_fast || !have_medium || !have_slow) return false;

      m_ema_fast = buf_fast[0]; m_ema_medium = buf_medium[0]; m_ema_slow = buf_slow[0];

      double close_buf[], high_buf[], low_buf[];
      ArraySetAsSeries(close_buf, true); ArraySetAsSeries(high_buf, true); ArraySetAsSeries(low_buf, true);
      const int need = m_th.structure_lookback + m_th.momentum_lookback + 2;
      if(CopyClose(m_symbol, PERIOD_D1, 0, need, close_buf) < need) return false;
      if(CopyHigh(m_symbol,  PERIOD_D1, 0, need, high_buf)  < need) return false;
      if(CopyLow(m_symbol,   PERIOD_D1, 0, need, low_buf)   < need) return false;

      m_price = close_buf[0];
      m_bullish_structure = (m_price > m_ema_fast) && (m_ema_fast > m_ema_medium) && (m_ema_medium > m_ema_slow);
      m_bearish_structure = (m_price < m_ema_fast) && (m_ema_fast < m_ema_medium) && (m_ema_medium < m_ema_slow);

      // Simplified swing structure: split the lookback window in half and
      // compare recent extremes to the older half's extremes. This avoids
      // fragile single-bar fractal detection while still capturing whether
      // structure is making higher highs/lows or lower highs/lows.
      const int half = m_th.structure_lookback / 2;
      double recent_high = high_buf[ArrayMaximum(high_buf, 0, half)];
      double older_high  = high_buf[ArrayMaximum(high_buf, half, half)];
      double recent_low  = low_buf[ArrayMinimum(low_buf, 0, half)];
      double older_low   = low_buf[ArrayMinimum(low_buf, half, half)];

      m_higher_high = recent_high > older_high;
      m_lower_high  = recent_high < older_high;
      m_higher_low  = recent_low  > older_low;
      m_lower_low   = recent_low  < older_low;

      // 20-day breakout/breakdown, measured against the prior N bars
      // (excluding today so today's own bar can actually break it).
      double prior_high = high_buf[ArrayMaximum(high_buf, 1, m_th.structure_lookback)];
      double prior_low  = low_buf[ArrayMinimum(low_buf, 1, m_th.structure_lookback)];
      m_breakout_20  = m_price > prior_high;
      m_breakdown_20 = m_price < prior_low;

      const int mlb = m_th.momentum_lookback;
      m_momentum_roc_pct = (close_buf[mlb] != 0.0) ? 100.0 * (close_buf[0] - close_buf[mlb]) / close_buf[mlb] : 0.0;

      ComputeDirectionScore();
      return true;
     }

   void ComputeDirectionScore()
     {
      // Each sub-component is individually capped so no single indicator
      // can dominate the composite (spec section 4's explicit rule).
      double structure_score = 0.0;
      if(m_bullish_structure) structure_score = 40.0;
      else if(m_bearish_structure) structure_score = -40.0;
      else
        {
         // Partial credit: count how many of the three EMA conditions hold.
         int bull_count = (m_price > m_ema_fast ? 1 : 0) + (m_ema_fast > m_ema_medium ? 1 : 0) + (m_ema_medium > m_ema_slow ? 1 : 0);
         structure_score = AxLerp(-40.0, 40.0, bull_count / 3.0);
        }

      double swing_score = 0.0;
      if(m_higher_high && m_higher_low) swing_score = 20.0;
      else if(m_lower_high && m_lower_low) swing_score = -20.0;

      double breakout_score = 0.0;
      if(m_breakout_20) breakout_score = 20.0;
      else if(m_breakdown_20) breakout_score = -20.0;

      const double momentum_cap_pct = 10.0; // a 10% move over momentum_lookback bars saturates this sub-score
      double momentum_score = AxClamp(m_momentum_roc_pct / momentum_cap_pct, -1.0, 1.0) * 20.0;

      m_direction_score = AxClamp(structure_score + swing_score + breakout_score + momentum_score, -100.0, 100.0);
     }

   //+---------------------------------------------------------------+
   //| Section 5 — Trend-Efficiency Engine                           |
   //+---------------------------------------------------------------+
   void UpdateTrendEfficiency()
     {
      double close_buf[];
      ArraySetAsSeries(close_buf, true);
      const int n = m_th.trend_eff_lookback;
      if(CopyClose(m_symbol, PERIOD_D1, 0, n + 1, close_buf) < n + 1)
        {
         m_trend_efficiency = 0.0;
         m_trend_efficiency_score = 0.0;
         if(m_data_status == AX_DATA_OK) m_data_status = AX_DATA_DEGRADED;
         return;
        }

      const double net_change = MathAbs(close_buf[0] - close_buf[n]);
      double sum_abs_changes = 0.0;
      for(int i = 0; i < n; i++) sum_abs_changes += MathAbs(close_buf[i] - close_buf[i + 1]);

      m_trend_efficiency = (sum_abs_changes > 0.0) ? AxClamp(net_change / sum_abs_changes, 0.0, 1.0) : 0.0;
      m_trend_efficiency_score = m_trend_efficiency * 100.0;
     }

   //+---------------------------------------------------------------+
   //| Section 9 — Breadth Engine (externally fed)                   |
   //+---------------------------------------------------------------+
   void UpdateBreadth()
     {
      if(!m_breadth_fed)
        {
         m_breadth_score = 0.0; // neutral — never invent participation data
         return;
        }
      const double age_minutes = (double)(TimeCurrent() - m_breadth_as_of) / 60.0;
      if(age_minutes > m_th.breadth_stale_minutes)
        {
         m_breadth_score = 0.0;
         if(m_data_status == AX_DATA_OK) m_data_status = AX_DATA_DEGRADED;
         return;
        }

      double adv_decl_score = 0.0;
      const double total = m_breadth_advancers + m_breadth_decliners;
      if(total > 0.0) adv_decl_score = 100.0 * (m_breadth_advancers - m_breadth_decliners) / total;

      const double pct_above_score = AxClamp((m_breadth_pct_above_50ma - 50.0) * 2.0, -100.0, 100.0);
      const double semis_score     = AxClamp((m_breadth_semis - 50.0) * 2.0, -100.0, 100.0);

      m_breadth_score = AxClamp((adv_decl_score * 0.5) + (pct_above_score * 0.35) + (semis_score * 0.15), -100.0, 100.0);
     }

   //+---------------------------------------------------------------+
   //| Section 10 — Liquidity / Volume Engine                        |
   //+---------------------------------------------------------------+
   void UpdateLiquidity()
     {
      long vol_buf[];
      ArraySetAsSeries(vol_buf, true);
      const int n = 21;
      if(CopyTickVolume(m_symbol_liquidity, PERIOD_D1, 0, n, vol_buf) < n)
        {
         m_liquidity_score = 50.0; // neutral, not favorable — missing data never reads as healthy
         m_relative_volume  = 1.0;
         if(m_data_status == AX_DATA_OK) m_data_status = AX_DATA_DEGRADED;
         return;
        }

      long sum = 0;
      for(int i = 1; i < n; i++) sum += vol_buf[i]; // average of the prior 20 bars, excludes today
      const double avg_vol = sum / (double)(n - 1);
      m_relative_volume = (avg_vol > 0.0) ? vol_buf[0] / avg_vol : 1.0;

      double base = AxClamp(50.0 + (m_relative_volume - 1.0) * 50.0, 0.0, 100.0);

      // Penalize a big price move that isn't backed by participation —
      // a bullish/bearish print on thin volume is a fragile signal.
      double close_buf[], open_buf[];
      ArraySetAsSeries(close_buf, true); ArraySetAsSeries(open_buf, true);
      if(CopyClose(m_symbol_liquidity, PERIOD_D1, 0, 1, close_buf) == 1 &&
         CopyOpen(m_symbol_liquidity,  PERIOD_D1, 0, 1, open_buf)  == 1 && open_buf[0] != 0.0)
        {
         const double move_pct = 100.0 * MathAbs(close_buf[0] - open_buf[0]) / open_buf[0];
         if(move_pct > 1.5 && m_relative_volume < 0.7) base -= 30.0;
        }

      m_liquidity_score = AxClamp(base, 0.0, 100.0);
     }

public:
   // --- Direction / structure getters -------------------------------------
   double GetDirectionScore() const { return m_direction_score; }
   ENUM_AX_BIAS GetBias() const
     {
      if(m_direction_score >= m_th.direction_moderate) return AX_BIAS_BULLISH;
      if(m_direction_score <= -m_th.direction_moderate) return AX_BIAS_BEARISH;
      return AX_BIAS_NEUTRAL;
     }
   bool IsBullishStructure() const { return m_bullish_structure; }
   bool IsBearishStructure() const { return m_bearish_structure; }
   bool IsBreakout20() const { return m_breakout_20; }
   bool IsBreakdown20() const { return m_breakdown_20; }

   // --- Trend efficiency ----------------------------------------------------
   double GetTrendEfficiency() const { return m_trend_efficiency; }
   double GetTrendEfficiencyScore() const { return m_trend_efficiency_score; }

   // --- Breadth / liquidity ---------------------------------------------
   double GetBreadthScore() const { return m_breadth_score; }
   bool   IsBreadthFed() const { return m_breadth_fed; }
   double GetLiquidityScore() const { return m_liquidity_score; }
   double GetRelativeVolume() const { return m_relative_volume; }

   ENUM_AX_DATA_STATUS GetDataStatus() const { return m_data_status; }

   //+---------------------------------------------------------------+
   //| Section 11 — Composite Confidence                              |
   //| direction/macro/breadth are -100..100 and get remapped to      |
   //| 0..100 before weighting; trend-efficiency/volatility/liquidity  |
   //| already arrive as 0..100.                                       |
   //+---------------------------------------------------------------+
   double ComputeCompositeConfidence(const double volatility_score, const double macro_score, AxWeights weights) const
     {
      double wsum = weights.w_direction + weights.w_trend_efficiency + weights.w_volatility +
                    weights.w_macro + weights.w_breadth + weights.w_liquidity;
      if(wsum <= 0.0) { AxWeights d; d.Defaults(); weights = d; wsum = 1.0; }

      const double direction_0_100 = (m_direction_score + 100.0) / 2.0;
      const double macro_0_100     = (macro_score + 100.0) / 2.0;
      const double breadth_0_100   = (m_breadth_score + 100.0) / 2.0;

      double score = weights.w_direction        * direction_0_100
                    + weights.w_trend_efficiency * m_trend_efficiency_score
                    + weights.w_volatility       * volatility_score
                    + weights.w_macro            * macro_0_100
                    + weights.w_breadth          * breadth_0_100
                    + weights.w_liquidity        * m_liquidity_score;

      return AxClamp(score / wsum, 0.0, 100.0);
     }

   //+---------------------------------------------------------------+
   //| Section 12 — Regime Decision Matrix                           |
   //+---------------------------------------------------------------+
   ENUM_AX_REGIME ClassifyRegime(const ENUM_AX_VOL_STATE vol_state, const bool shock_active) const
     {
      if(shock_active) return AX_REGIME_R6_VOLATILITY_SHOCK;

      const bool strong_bull = m_direction_score >= m_th.direction_strong;
      const bool bull        = m_direction_score >= m_th.direction_moderate;
      const bool strong_bear = m_direction_score <= -m_th.direction_strong;
      const bool bear        = m_direction_score <= -m_th.direction_moderate;

      const bool vol_calm       = (vol_state == AX_VOL_LOW || vol_state == AX_VOL_NORMAL);
      const bool vol_controlled = (vol_state <= AX_VOL_ELEVATED);
      const bool trend_eff_high = (m_trend_efficiency >= m_th.trend_eff_high);
      const bool trend_eff_low  = (m_trend_efficiency < m_th.trend_eff_low);
      const bool breadth_supportive = (m_breadth_score >= m_th.breadth_supportive);
      const bool breadth_weak_flag  = (m_breadth_score <= m_th.breadth_weak);

      if(strong_bull && trend_eff_high && vol_calm && breadth_supportive)
         return AX_REGIME_R1_PERSISTENT_BULLISH;

      if(strong_bear && trend_eff_high && vol_controlled && breadth_weak_flag)
         return AX_REGIME_R5_PERSISTENT_BEARISH;

      if(bull) return AX_REGIME_R2_BULLISH_UNSTABLE;
      if(bear) return AX_REGIME_R4_BEARISH_TRANSITION;

      // Direction is near-neutral either way.
      return AX_REGIME_R3_RANGE_CHOP;
      // (trend_eff_low is informative for logging/diagnostics but the
      // neutral direction band alone is sufficient to call this chop —
      // a slow, grindy neutral tape is still not a directional regime.)
     }

   AxRegimeBand GetRegimeBand(const ENUM_AX_REGIME regime) const
     {
      AxRegimeBand b;
      switch(regime)
        {
         case AX_REGIME_R1_PERSISTENT_BULLISH:
            b.trade_allowed = true;  b.aggressive_permitted = true;  b.risk_mult_lo = 1.00; b.risk_mult_hi = 1.50; break;
         case AX_REGIME_R2_BULLISH_UNSTABLE:
            b.trade_allowed = true;  b.aggressive_permitted = false; b.risk_mult_lo = 0.50; b.risk_mult_hi = 0.75; break;
         case AX_REGIME_R3_RANGE_CHOP:
            b.trade_allowed = m_th.allow_range_strategy; b.aggressive_permitted = false;
            b.risk_mult_lo = m_th.allow_range_strategy ? 0.25 : 0.0;
            b.risk_mult_hi = m_th.allow_range_strategy ? 0.25 : 0.0;
            break;
         case AX_REGIME_R4_BEARISH_TRANSITION:
            b.trade_allowed = true;  b.aggressive_permitted = false; b.risk_mult_lo = 0.25; b.risk_mult_hi = 0.50; break;
         case AX_REGIME_R5_PERSISTENT_BEARISH:
            b.trade_allowed = true;  b.aggressive_permitted = true;  b.risk_mult_lo = 1.00; b.risk_mult_hi = 1.50; break;
         case AX_REGIME_R6_VOLATILITY_SHOCK:
         default:
            b.trade_allowed = false; b.aggressive_permitted = false; b.risk_mult_lo = 0.0;  b.risk_mult_hi = 0.0;  break;
        }
      return b;
     }
  };
