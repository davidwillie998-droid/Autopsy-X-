//+------------------------------------------------------------------+
//|                                        AutopsyRiskGovernor.mqh    |
//|  AUTOPSY X — Regime Decision Matrix, TQQQ Leverage Model,          |
//|  Drawdown Governor, and the section-20 fail-safe.                  |
//|  Spec sections 12, 13, 14, 20.                                     |
//|                                                                     |
//|  This is the only file that is allowed to turn a regime read into  |
//|  a number of percent-risk. Nothing here ever multiplies size by a  |
//|  fixed 3x for TQQQ — leverage is a conditional state, computed     |
//|  fresh from five independent multipliers every time.               |
//+------------------------------------------------------------------+
#property strict
#include "AutopsyXCommon.mqh"

struct AxRegimeRiskConfig
  {
   double riskMultMin;
   double riskMultMax;
   bool   tradeAllowedDefault;
   bool   aggressiveAllowed;
  };

struct AxLeverageBreakdown
  {
   double baseRiskPct;
   double regimeMultiplier;
   double confidenceMultiplier;
   double volatilityMultiplier;
   double correlationMultiplier;
   double drawdownMultiplier;
   double finalRiskPct;
   bool   failSafeCapped;   // true if the section-20 data-quality cap bound the result
  };

//+------------------------------------------------------------------+
//| Section 12 — Regime Decision Matrix                               |
//+------------------------------------------------------------------+
class CAxRegimeDecisionMatrix
  {
private:
   AxRegimeRiskConfig m_cfg[7]; // indexed by ENUM_AX_REGIME, slot 0 (UNKNOWN) unused
   bool               m_hasRangeStrategy; // R3: does the underlying EA have a dedicated range playbook?

public:
   CAxRegimeDecisionMatrix()
     {
      m_hasRangeStrategy = false;

      m_cfg[AX_R1_PERSISTENT_BULL].riskMultMin = 1.00; m_cfg[AX_R1_PERSISTENT_BULL].riskMultMax = 1.50;
      m_cfg[AX_R1_PERSISTENT_BULL].tradeAllowedDefault = true; m_cfg[AX_R1_PERSISTENT_BULL].aggressiveAllowed = true;

      m_cfg[AX_R2_BULL_UNSTABLE].riskMultMin = 0.50; m_cfg[AX_R2_BULL_UNSTABLE].riskMultMax = 0.75;
      m_cfg[AX_R2_BULL_UNSTABLE].tradeAllowedDefault = true; m_cfg[AX_R2_BULL_UNSTABLE].aggressiveAllowed = false;

      m_cfg[AX_R3_RANGE_CHOP].riskMultMin = 0.00; m_cfg[AX_R3_RANGE_CHOP].riskMultMax = 0.25;
      m_cfg[AX_R3_RANGE_CHOP].tradeAllowedDefault = false; m_cfg[AX_R3_RANGE_CHOP].aggressiveAllowed = false;

      m_cfg[AX_R4_BEAR_TRANSITION].riskMultMin = 0.25; m_cfg[AX_R4_BEAR_TRANSITION].riskMultMax = 0.50;
      m_cfg[AX_R4_BEAR_TRANSITION].tradeAllowedDefault = true; m_cfg[AX_R4_BEAR_TRANSITION].aggressiveAllowed = false;

      m_cfg[AX_R5_PERSISTENT_BEAR].riskMultMin = 1.00; m_cfg[AX_R5_PERSISTENT_BEAR].riskMultMax = 1.50;
      m_cfg[AX_R5_PERSISTENT_BEAR].tradeAllowedDefault = true; m_cfg[AX_R5_PERSISTENT_BEAR].aggressiveAllowed = true;

      m_cfg[AX_R6_VOL_SHOCK].riskMultMin = 0.00; m_cfg[AX_R6_VOL_SHOCK].riskMultMax = 0.00;
      m_cfg[AX_R6_VOL_SHOCK].tradeAllowedDefault = false; m_cfg[AX_R6_VOL_SHOCK].aggressiveAllowed = false;
     }

   //--- Override any regime's band/permissions. Call during setup if the
   //    defaults above don't match your account's risk appetite.
   void Configure(ENUM_AX_REGIME regime, double riskMultMin, double riskMultMax,
                   bool tradeAllowedDefault, bool aggressiveAllowed)
     {
      if(regime == AX_REGIME_UNKNOWN) return;
      m_cfg[regime].riskMultMin = riskMultMin;
      m_cfg[regime].riskMultMax = riskMultMax;
      m_cfg[regime].tradeAllowedDefault = tradeAllowedDefault;
      m_cfg[regime].aggressiveAllowed = aggressiveAllowed;
     }

   void SetHasRangeStrategy(bool hasIt) { m_hasRangeStrategy = hasIt; }

   bool IsTradeAllowed(ENUM_AX_REGIME regime)
     {
      if(regime == AX_REGIME_UNKNOWN) return false;
      if(regime == AX_R3_RANGE_CHOP) return m_hasRangeStrategy; // spec: FALSE by default, opt-in override
      return m_cfg[regime].tradeAllowedDefault;
     }

   bool IsAggressiveAllowed(ENUM_AX_REGIME regime)
     {
      if(regime == AX_REGIME_UNKNOWN) return false;
      return m_cfg[regime].aggressiveAllowed;
     }

   //--- Risk multiplier scales linearly across the regime's configured band
   //    with composite confidence — a low-confidence R1 read sits near the
   //    band floor, a high-confidence one near the ceiling. Never extrapolates
   //    past the band regardless of how high confidence goes.
   double GetRegimeMultiplier(ENUM_AX_REGIME regime, double confidence0to100)
     {
      if(regime == AX_REGIME_UNKNOWN) return 0.0;
      if(regime == AX_R3_RANGE_CHOP && !m_hasRangeStrategy) return 0.0;
      double t = AxClamp(confidence0to100, 0.0, 100.0) / 100.0;
      return AxLerp(m_cfg[regime].riskMultMin, m_cfg[regime].riskMultMax, t);
     }

   double GetMin(ENUM_AX_REGIME regime) { return (regime == AX_REGIME_UNKNOWN) ? 0.0 : m_cfg[regime].riskMultMin; }
   double GetMax(ENUM_AX_REGIME regime) { return (regime == AX_REGIME_UNKNOWN) ? 0.0 : m_cfg[regime].riskMultMax; }
  };

//+------------------------------------------------------------------+
//| Section 14 — Drawdown Governor                                    |
//+------------------------------------------------------------------+
class CAxDrawdownGovernor
  {
private:
   double m_thresholds[5]; // upper bound of each drawdown bracket, %: 3,5,8,10,+inf(halt)
   double m_factors[5];    // risk factor for that bracket: 1.00,0.75,0.50,0.25,0.00
   double m_haltThresholdPct;
   double m_recoveryBufferPct;  // must recover to (halt - buffer) before auto-reset is even considered
   int    m_cooldownSeconds;    // minimum time in halted state before auto-reset is considered

   double   m_peakEquity;
   bool     m_halted;
   datetime m_haltedAt;
   bool     m_initialized;

public:
   CAxDrawdownGovernor()
     {
      m_thresholds[0] = 3.0;  m_factors[0] = 1.00;
      m_thresholds[1] = 5.0;  m_factors[1] = 0.75;
      m_thresholds[2] = 8.0;  m_factors[2] = 0.50;
      m_thresholds[3] = 10.0; m_factors[3] = 0.25;
      m_thresholds[4] = 1.0e9; m_factors[4] = 0.00; // effectively "anything past halt"

      m_haltThresholdPct  = 10.0;
      m_recoveryBufferPct = 2.0;    // recover to <= 8% DD before auto-reset is eligible
      m_cooldownSeconds   = 24 * 3600;

      m_peakEquity = 0.0;
      m_halted = false;
      m_haltedAt = 0;
      m_initialized = false;
     }

   //--- Replace the default 4-bracket table. Pass parallel arrays where
   //    thresholds[i] is the upper bound (%) of bracket i and factors[i]
   //    is the risk factor for that bracket; the last bracket should use a
   //    very large threshold to catch "everything beyond the halt line".
   void ConfigureBrackets(const double &thresholds[], const double &factors[])
     {
      int n = MathMin(5, MathMin(ArraySize(thresholds), ArraySize(factors)));
      for(int i = 0; i < n; i++) { m_thresholds[i] = thresholds[i]; m_factors[i] = factors[i]; }
     }

   void SetHaltPolicy(double haltThresholdPct, double recoveryBufferPct, int cooldownSeconds)
     {
      m_haltThresholdPct  = haltThresholdPct;
      m_recoveryBufferPct = MathMax(0.0, recoveryBufferPct);
      m_cooldownSeconds   = MathMax(0, cooldownSeconds);
     }

   void Init(double startingEquity)
     {
      m_peakEquity = MathMax(startingEquity, 1e-8);
      m_halted = false;
      m_haltedAt = 0;
      m_initialized = true;
     }

   //--- Call once per bar/tick with current account equity. Returns the
   //    drawdown risk factor (0..1) to fold into the leverage model.
   double Update(double currentEquity)
     {
      if(!m_initialized) Init(currentEquity);
      m_peakEquity = MathMax(m_peakEquity, currentEquity);
      double ddPct = (m_peakEquity > 0.0) ? (m_peakEquity - currentEquity) / m_peakEquity * 100.0 : 0.0;

      if(ddPct >= m_haltThresholdPct && !m_halted)
        {
         m_halted = true;
         m_haltedAt = TimeCurrent();
        }

      if(m_halted)
        {
         bool recovered = ddPct <= (m_haltThresholdPct - m_recoveryBufferPct);
         bool cooledDown = (TimeCurrent() - m_haltedAt) >= m_cooldownSeconds;
         if(recovered && cooledDown)
           {
            m_halted = false;
            m_haltedAt = 0;
           }
         else
            return 0.0;
        }

      for(int i = 0; i < 5; i++)
         if(ddPct <= m_thresholds[i])
            return m_factors[i];
      return 0.0;
     }

   bool   IsHalted() const { return m_halted; }
   double PeakEquity() const { return m_peakEquity; }

   //--- Manual reset per spec section 14/21 (ResetRiskGovernor()). Use with
   //    intent — this is meant for a deliberate, human-reviewed restart, not
   //    something the EA should ever call automatically to route around a halt.
   void ForceReset(double newPeakEquity)
     {
      m_halted = false;
      m_haltedAt = 0;
      m_peakEquity = MathMax(newPeakEquity, 1e-8);
     }
  };

//+------------------------------------------------------------------+
//| Section 13 — TQQQ Leverage Model                                  |
//+------------------------------------------------------------------+
double AxVolatilityMultiplier(ENUM_AX_VOL_STATE state)
  {
   switch(state)
     {
      case AX_VOL_LOW:      return 1.00;
      case AX_VOL_NORMAL:   return 0.85;
      case AX_VOL_ELEVATED: return 0.70;
      case AX_VOL_HIGH:     return 0.40;
      case AX_VOL_EXTREME:  return 0.00;
      default:              return 0.25; // unknown state — treat like degraded data, not like "normal"
     }
  }

//--- Section 20 fail-safe: the worst data status seen across every engine
//    this decision depended on caps (never boosts) the final multiplier.
double AxFailSafeCap(ENUM_AX_DATA_STATUS worstStatus)
  {
   switch(worstStatus)
     {
      case AX_DATA_OK:          return 1.0;   // no cap
      case AX_DATA_DEGRADED:    return 0.25;  // spec section 20 default
      case AX_DATA_UNAVAILABLE: return 0.0;   // caller should also set ALLOW_NEW_TRADE=false
      default:                  return 0.0;
     }
  }

//--- Never uses POSITION_SIZE x 3. Combines five independent multipliers
//    on top of a base risk percentage, then applies the fail-safe cap last
//    so a data problem can only ever shrink the result.
AxLeverageBreakdown AxComputeLeverage(double baseRiskPct, double regimeMultiplier, double confidence0to100,
                                       ENUM_AX_VOL_STATE volState, double correlationMultiplier,
                                       double drawdownMultiplier, ENUM_AX_DATA_STATUS worstDataStatus)
  {
   AxLeverageBreakdown r;
   r.baseRiskPct = MathMax(0.0, baseRiskPct);
   r.regimeMultiplier = MathMax(0.0, regimeMultiplier);
   r.confidenceMultiplier = AxClamp(confidence0to100, 0.0, 100.0) / 100.0;
   r.volatilityMultiplier = AxVolatilityMultiplier(volState);
   r.correlationMultiplier = AxClamp(correlationMultiplier, 0.0, 1.0);
   r.drawdownMultiplier = AxClamp(drawdownMultiplier, 0.0, 1.0);

   double raw = r.baseRiskPct * r.regimeMultiplier * r.confidenceMultiplier *
                r.volatilityMultiplier * r.correlationMultiplier * r.drawdownMultiplier;

   double cap = AxFailSafeCap(worstDataStatus);
   double capped = MathMin(raw, r.baseRiskPct * cap);
   r.failSafeCapped = (worstDataStatus != AX_DATA_OK) && (capped < raw - 1e-12);
   r.finalRiskPct = MathMax(0.0, capped);
   return r;
  }
