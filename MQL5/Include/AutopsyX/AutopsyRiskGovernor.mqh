//+------------------------------------------------------------------+
//| AutopsyRiskGovernor.mqh                                             |
//| Section 13's leverage model: FINAL_RISK = BASE_RISK x REGIME_MULT |
//| x CONFIDENCE_MULT x VOLATILITY_MULT x CORRELATION_MULT x           |
//| DRAWDOWN_MULT. NEVER position_size x 3 - TQQQ's leverage is        |
//| treated as a conditional risk state, not a permanent multiplier.  |
//| Also owns the drawdown governor (section 14): a banded risk cut   |
//| as drawdown deepens, with a hard halt that requires an explicit   |
//| reset - never auto-cleared just because equity ticks back up.     |
//+------------------------------------------------------------------+
#property strict
#ifndef AUTOPSYX_RISKGOVERNOR_MQH
#define AUTOPSYX_RISKGOVERNOR_MQH
#include "AutopsyTypes.mqh"

class CAutopsyRiskGovernor
  {
private:
   string m_prefix;
   double m_peakEquity;
   bool   m_halted;
   double m_ddThresholds[4];  // upper bound (%) of each drawdown band, ascending
   double m_ddMultipliers[4]; // risk multiplier for that band; beyond the last threshold = halt (0.0)

   string GvName(const string key) const { return m_prefix+"_"+key; }

   double GvGetOrInit(const string key, double defVal)
     {
      string name = GvName(key);
      if(GlobalVariableCheck(name)) return GlobalVariableGet(name);
      GlobalVariableSet(name, defVal);
      return defVal;
     }

   void GvSet(const string key, double val) { GlobalVariableSet(GvName(key), val); }

public:
   //--- idPrefix should be unique per account/instance (e.g. symbol+magic, or just the EA name) so
   //--- multiple existing bots attaching their own governor instance don't collide on global variables
   void Init(const string idPrefix,
             double ddThresh1=3.0, double ddThresh2=5.0, double ddThresh3=8.0, double ddThresh4=10.0,
             double ddMult1=1.00, double ddMult2=0.75, double ddMult3=0.50, double ddMult4=0.25)
     {
      m_prefix = "AXR_RISKGOV_"+idPrefix;
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      m_peakEquity = GvGetOrInit("peak", equity);
      m_halted = GvGetOrInit("halted", 0.0) > 0.5;

      m_ddThresholds[0]=ddThresh1; m_ddThresholds[1]=ddThresh2; m_ddThresholds[2]=ddThresh3; m_ddThresholds[3]=ddThresh4;
      m_ddMultipliers[0]=ddMult1;  m_ddMultipliers[1]=ddMult2;  m_ddMultipliers[2]=ddMult3;  m_ddMultipliers[3]=ddMult4;
     }

   //--- call once per bar/tick: rolls the peak-equity high-water mark forward - drawdown is always
   //--- measured from the peak, never a fixed baseline that would understate a partial recovery
   void Update()
     {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity > m_peakEquity) { m_peakEquity = equity; GvSet("peak", equity); }
     }

   double CurrentDrawdownPercent() const
     {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(m_peakEquity<=0.0) return 0.0;
      return MathMax(0.0, (m_peakEquity-equity)/m_peakEquity*100.0);
     }

   bool IsHalted() const { return m_halted; }

   //--- the DRAWDOWN_MULTIPLIER component, banded per section 14. Crossing past the last configured
   //--- band latches a halt (persisted) rather than just returning 0 for one call - the halt survives
   //--- until ResetRiskGovernor() runs, even if equity recovers above the band on its own.
   double DrawdownMultiplier()
     {
      if(m_halted) return 0.0;
      double dd = CurrentDrawdownPercent();
      for(int i=0;i<4;i++)
         if(dd <= m_ddThresholds[i]) return m_ddMultipliers[i];

      m_halted = true;
      GvSet("halted", 1.0);
      return 0.0;
     }

   //--- required before trading resumes after a halt - never automatic. Re-baselines the peak to
   //--- current equity so the next drawdown reading starts fresh from here.
   void ResetRiskGovernor()
     {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      m_halted = false;
      m_peakEquity = equity;
      GvSet("halted", 0.0);
      GvSet("peak", equity);
     }

   //--- FINAL_RISK, section 13. Every incoming multiplier is clamped to a sane band before composing
   //--- so one runaway component (e.g. a mis-configured confidence multiplier) can't blow out the whole
   //--- formula; correlation and drawdown can only ever REDUCE risk, never raise it above 1.0x.
   double ComposeFinalRiskPercent(double baseRiskPercent, double regimeMultiplier, double confidenceMultiplier,
                                   double volatilityMultiplier, double correlationMultiplier, double maxRiskPercentPerTrade)
     {
      double dd   = DrawdownMultiplier();
      double reg  = MathMax(0.0, MathMin(2.0, regimeMultiplier));
      double conf = MathMax(0.0, MathMin(1.5, confidenceMultiplier));
      double vol  = MathMax(0.0, MathMin(1.5, volatilityMultiplier));
      double corr = MathMax(0.0, MathMin(1.0, correlationMultiplier));

      double finalRisk = MathMax(0.0, baseRiskPercent) * reg * conf * vol * corr * dd;
      return MathMax(0.0, MathMin(MathMax(0.0,maxRiskPercentPerTrade), finalRisk));
     }
  };
#endif // AUTOPSYX_RISKGOVERNOR_MQH
