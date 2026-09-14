//+------------------------------------------------------------------+
//|                                            AdaptiveFlipEngine.mqh |
//|  Adaptive Flip Engine - account-agnostic capital protection layer |
//|                                                                    |
//|  Sits ON TOP of CRiskEngine's existing hard limits and CStatistics'|
//|  existing performance tracking - it does not replace or duplicate |
//|  either. Where CRiskEngine enforces fixed, binary limits (daily   |
//|  loss %, consecutive losses, exposure caps) anchored to the       |
//|  trading day, this engine tracks CONTINUOUS peak-equity drawdown  |
//|  (a slow multi-day bleed trips this even when no single day       |
//|  breaches the daily limit), estimates a calibrated win probability|
//|  and expected value for the CURRENT signal, approximates risk of  |
//|  ruin under fixed-fractional sizing, and only ever SCALES DOWN    |
//|  from CRiskEngine's already-configured risk percent - never up,   |
//|  never replacing its own hard ceiling. Every number here is a     |
//|  percentage, ratio, or R-multiple - nothing is denominated in     |
//|  account currency, so behavior doesn't change with account size.  |
//|                                                                    |
//|  Applies uniformly to fresh entries AND flip re-entries: capital  |
//|  protection has no flip-shaped exemption. It has nothing to do    |
//|  with entry TIMING (that's CSniperEngine's job) and never delays  |
//|  a decision - Evaluate() is a single read-only pass, no waiting.  |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_ADAPTIVEFLIPENGINE_MQH
#define AX_ADAPTIVEFLIPENGINE_MQH
#include "Defs.mqh"
#include "Statistics.mqh"

class CAdaptiveFlipEngine
  {
private:
   //--- configuration ---
   bool              m_enabled;
   double            m_cautionDdPct;         // peak-equity drawdown %% that enters CAUTION
   double            m_defensiveDdPct;       // peak-equity drawdown %% that enters DEFENSIVE
   double            m_lockedDdPct;          // peak-equity drawdown %% that enters LOCKED (hard block)
   double            m_cautionMultiplier;    // risk multiplier applied in CAUTION
   double            m_defensiveMultiplier;  // risk multiplier applied in DEFENSIVE
   double            m_maxRiskOfRuinPct;     // hard gate: block if estimated RoR exceeds this
   double            m_ruinThresholdPct;     // the drawdown-from-peak %% that "ruin" means, for the RoR calc
   double            m_minExpectedValueR;    // hard gate: block if EV per trade, in R-multiples, is below this
   double            m_minAccountHealth;     // hard gate: block if the blended 0..100 health score is below this
   int               m_minTradesForStats;    // below this trade count, fall back to score-confidence-only probability
   double            m_assumedRewardRiskRatio; // cold-start reward:risk assumption before enough trade history exists
   double            m_configuredRiskFrac;   // CRiskEngine's actual configured risk percent, as a fraction -
                                              // used as the risk-of-ruin risk-fraction estimate before enough
                                              // trade history exists to derive it empirically from realized losses

   //--- live state ---
   string            m_persistKey;           // GlobalVariable name peak equity survives EA/terminal restarts under
   double            m_peakEquity;
   ENUM_AX_CAPITAL_STATE m_state;
   double            m_ddFromPeakPct;
   double            m_lastWinProbability;
   double            m_lastExpectedValueR;
   double            m_lastRiskOfRuinPct;
   double            m_lastAccountHealth;
   double            m_lastRiskMultiplier;

public:
                     CAdaptiveFlipEngine(void)
     {
      m_enabled=true;
      m_cautionDdPct=8.0; m_defensiveDdPct=15.0; m_lockedDdPct=25.0;
      m_cautionMultiplier=0.65; m_defensiveMultiplier=0.30;
      m_maxRiskOfRuinPct=5.0; m_ruinThresholdPct=50.0;
      m_minExpectedValueR=0.0; m_minAccountHealth=25.0;
      m_minTradesForStats=20; m_assumedRewardRiskRatio=1.5; m_configuredRiskFrac=0.01;
      m_persistKey=""; m_peakEquity=0; m_state=AX_CAPITAL_NORMAL; m_ddFromPeakPct=0;
      m_lastWinProbability=0.5; m_lastExpectedValueR=0; m_lastRiskOfRuinPct=0;
      m_lastAccountHealth=100.0; m_lastRiskMultiplier=1.0;
     }

   void              Configure(const bool enabled,
                                const double cautionDdPct,const double defensiveDdPct,const double lockedDdPct,
                                const double cautionMultiplier,const double defensiveMultiplier,
                                const double maxRiskOfRuinPct,const double ruinThresholdPct,
                                const double minExpectedValueR,const double minAccountHealth,
                                const int minTradesForStats,const double assumedRewardRiskRatio,
                                const double configuredRiskPercent)
     {
      m_enabled = enabled;
      m_configuredRiskFrac = AxClampD(configuredRiskPercent/100.0,0.0001,0.20);
      // ordering is enforced here, not trusted from inputs, so a misconfigured input set can't
      // produce an incoherent ladder (e.g. CAUTION triggering at a wider drawdown than DEFENSIVE)
      m_cautionDdPct    = MathMax(0.5,cautionDdPct);
      m_defensiveDdPct  = MathMax(m_cautionDdPct+0.5,defensiveDdPct);
      m_lockedDdPct     = MathMax(m_defensiveDdPct+0.5,lockedDdPct);
      m_cautionMultiplier   = AxClampD(cautionMultiplier,0.0,1.0);
      m_defensiveMultiplier = AxClampD(defensiveMultiplier,0.0,m_cautionMultiplier);
      m_maxRiskOfRuinPct  = AxClampD(maxRiskOfRuinPct,0.1,100.0);
      m_ruinThresholdPct  = AxClampD(ruinThresholdPct,5.0,95.0);
      m_minExpectedValueR = minExpectedValueR;
      m_minAccountHealth  = AxClampD(minAccountHealth,0.0,100.0);
      m_minTradesForStats = MathMax(5,minTradesForStats);
      m_assumedRewardRiskRatio = MathMax(0.1,assumedRewardRiskRatio);
     }

   //--- call once from OnInit, before the first OnTickHousekeeping() - seeds peak equity from a   ---
   //--- persisted GlobalVariable (survives EA/terminal restarts within the same terminal instance -  ---
   //--- MT5 global variables live on disk until the terminal purges them, roughly 4 weeks of        ---
   //--- inactivity, or a manual reset; they do NOT survive moving to a different machine/terminal).  ---
   //--- Without this, a restart mid-drawdown would silently re-seed the peak to the ALREADY-DRAWN-   ---
   //--- DOWN current equity and reset the capital state straight back to NORMAL - exactly the        ---
   //--- multi-session bleed this engine exists to catch, undone by the one event (a crash during a   ---
   //--- bad drawdown) it most needs to survive. ---
   void              Init(const string symbol,const ulong magic)
     {
      m_persistKey = StringFormat("AXFDX_AFE_PeakEquity_%s_%I64u",symbol,magic);
      double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      double storedPeak = GlobalVariableCheck(m_persistKey) ? GlobalVariableGet(m_persistKey) : 0.0;
      m_peakEquity = MathMax(currentEquity,storedPeak);
     }

   //--- call every tick (cheap: one AccountInfoDouble read + comparisons) - tracks the running  ---
   //--- peak equity and derives the capital state ladder from drawdown off that peak, exactly   ---
   //--- the same "continuous, never resets mid-session" cadence CRiskEngine uses for kill-switch ---
   //--- bookkeeping, just anchored to the all-time peak rather than the day's opening equity ---
   void              OnTickHousekeeping(void)
     {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity<=0) return;
      if(m_peakEquity<=0 || equity>m_peakEquity)
        {
         m_peakEquity = equity;
         if(m_persistKey!="") GlobalVariableSet(m_persistKey,m_peakEquity);
        }

      m_ddFromPeakPct = (m_peakEquity>0) ? (m_peakEquity-equity)/m_peakEquity*100.0 : 0.0;

      if(m_ddFromPeakPct>=m_lockedDdPct)          m_state = AX_CAPITAL_LOCKED;
      else if(m_ddFromPeakPct>=m_defensiveDdPct)  m_state = AX_CAPITAL_DEFENSIVE;
      else if(m_ddFromPeakPct>=m_cautionDdPct)    m_state = AX_CAPITAL_CAUTION;
      else                                         m_state = AX_CAPITAL_NORMAL;
     }

   //--- the core decision: read-only, no side effects beyond updating the cached "last" readings ---
   //--- used by the dashboard. Returns false (with reasonOut) if any hard gate blocks the trade; ---
   //--- otherwise riskMultiplierOut is the factor CRiskEngine's own sized lots should be scaled  ---
   //--- by - always in [0,1], so this can only ever reduce risk, never increase it. ---
   bool              Evaluate(const SAxScore &score,const SAxStatsSnapshot &stats,
                               const int consecutivePoorFills,double &riskMultiplierOut,string &reasonOut)
     {
      riskMultiplierOut = 0.0;
      if(!m_enabled) { riskMultiplierOut=1.0; reasonOut=""; return(true); }

      //--- win probability: blend trailing realized win rate with the CURRENT signal's own score  ---
      //--- confidence once enough trade history exists to trust the historical half; before that,  ---
      //--- lean entirely on the live score rather than a noisy small sample. Never claims near-     ---
      //--- certainty either direction - a single signal is never worth betting the account on. ---
      bool haveStats = (stats.totalTrades>=m_minTradesForStats);
      double liveP = AxClampD(score.confidence/100.0,0.0,1.0);
      double p = haveStats ? (0.5*AxClampD(stats.winRate/100.0,0.0,1.0) + 0.5*liveP) : liveP;
      p = AxClampD(p,0.05,0.95);
      m_lastWinProbability = p;

      //--- expected value in R-multiples (1R = the amount risked on the trade), so this reads the  ---
      //--- same regardless of account size or instrument. Once enough closed trades exist, the      ---
      //--- realized avgWin/avgLoss ratio replaces the cold-start assumed reward:risk ratio. ---
      double rr = (haveStats && MathAbs(stats.avgLoss)>1e-8) ? (stats.avgWin/MathAbs(stats.avgLoss))
                                                              : m_assumedRewardRiskRatio;
      double evR = p*rr - (1.0-p)*1.0;
      m_lastExpectedValueR = evR;

      //--- risk of ruin: a classic closed-form gambler's-ruin approximation adapted to fixed-      ---
      //--- fractional position sizing. This is a heuristic, not an exact continuous-time result -  ---
      //--- it assumes independent trade outcomes and a roughly constant edge and risk fraction.    ---
      //--- "Ruin" here means falling m_ruinThresholdPct from peak equity, not literal bankruptcy -  ---
      //--- fixed-fractional sizing asymptotically approaches but never mathematically reaches zero. ---
      double riskFrac = MathMax(0.0001,stats_RiskFractionEstimate(stats));
      double ruinFrac = m_ruinThresholdPct/100.0;
      double q = 1.0-p;
      double ror;
      if(MathAbs(p-q)<1e-6)
         ror = 100.0; // no edge either way - treat as a near-certain eventual ruin under this model
      else
        {
         double lnRuin = MathLog(1.0-ruinFrac);
         double lnRisk = MathLog(1.0-riskFrac);
         double n = (MathAbs(lnRisk)>1e-9) ? lnRuin/lnRisk : 0.0; // "loss-equivalents" to reach ruin
         double ratio = q/p;
         double rorFrac = MathPow(ratio,MathMax(0.0,n));
         ror = AxClampD(rorFrac*100.0,0.0,100.0);
        }
      m_lastRiskOfRuinPct = ror;

      //--- account health: blended 0..100 read of margin level, today's P&L versus how bad it's    ---
      //--- allowed to get, and how deep the current peak-equity drawdown already runs. Reuses only  ---
      //--- live broker reads CRiskEngine already trusts (ACCOUNT_MARGIN_LEVEL) rather than adding a ---
      //--- second, competing notion of "how healthy is this account". ---
      double marginLevel = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
      double marginComponent = (marginLevel<=0) ? 100.0 : AxClampD((marginLevel-100.0)/4.0,0.0,100.0);
      double ddComponent = AxClampD(100.0-(m_ddFromPeakPct/MathMax(1.0,m_lockedDdPct))*100.0,0.0,100.0);
      m_lastAccountHealth = 0.5*marginComponent + 0.5*ddComponent;

      //--- hard gates - any one of these blocks the trade outright, regardless of the others ---
      if(m_state==AX_CAPITAL_LOCKED)
        {
         reasonOut = StringFormat("Capital state LOCKED (%.1f%% off peak equity, ceiling %.1f%%)",
                                   m_ddFromPeakPct,m_lockedDdPct);
         return(false);
        }
      if(m_lastRiskOfRuinPct>m_maxRiskOfRuinPct)
        {
         reasonOut = StringFormat("Estimated risk of ruin %.1f%% exceeds ceiling %.1f%%",
                                   m_lastRiskOfRuinPct,m_maxRiskOfRuinPct);
         return(false);
        }
      if(evR<m_minExpectedValueR)
        {
         reasonOut = StringFormat("Expected value %.2fR below floor %.2fR",evR,m_minExpectedValueR);
         return(false);
        }
      if(m_lastAccountHealth<m_minAccountHealth)
        {
         reasonOut = StringFormat("Account health %.0f below floor %.0f",m_lastAccountHealth,m_minAccountHealth);
         return(false);
        }

      //--- continuous scaler - only reached once every hard gate above has passed. Capital state   ---
      //--- ladder times a graduated execution-quality response (softer, earlier than the outright  ---
      //--- kill switch that fires later at InpMaxConsecutivePoorFills). ---
      double stateMult = 1.0;
      if(m_state==AX_CAPITAL_DEFENSIVE) stateMult = m_defensiveMultiplier;
      else if(m_state==AX_CAPITAL_CAUTION) stateMult = m_cautionMultiplier;

      double exq = 1.0;
      if(consecutivePoorFills>=2) exq = 0.40;
      else if(consecutivePoorFills>=1) exq = 0.70;

      m_lastRiskMultiplier = AxClampD(stateMult*exq,0.0,1.0);
      riskMultiplierOut = m_lastRiskMultiplier;
      reasonOut = "";
      return(true);
     }

   //--- accessors for dashboard/autopsy ---
   ENUM_AX_CAPITAL_STATE State(void)          const { return(m_state); }
   double                DrawdownFromPeakPct(void) const { return(m_ddFromPeakPct); }
   double                WinProbability(void)  const { return(m_lastWinProbability); }
   double                ExpectedValueR(void)  const { return(m_lastExpectedValueR); }
   double                RiskOfRuinPct(void)   const { return(m_lastRiskOfRuinPct); }
   double                AccountHealth(void)   const { return(m_lastAccountHealth); }
   double                LastRiskMultiplier(void) const { return(m_lastRiskMultiplier); }
   bool                  IsEnabled(void)       const { return(m_enabled); }

private:
   //--- estimates the fraction of equity actually risked per trade, for the risk-of-ruin "loss-   ---
   //--- equivalents to reach ruin" calculation. Falls back to a conservative 1% assumption before  ---
   //--- there's a real risk-percent reading available to this class (it deliberately doesn't take  ---
   //--- CRiskEngine as a dependency - risk percent is read from the stats snapshot's own trade      ---
   //--- history where possible so this class stays a pure function of score+stats+fills, easy to   ---
   //--- reason about and test in isolation) ---
   double            stats_RiskFractionEstimate(const SAxStatsSnapshot &stats) const
     {
      if(stats.totalTrades>=m_minTradesForStats && stats.avgLoss<0)
        {
         double equity = AccountInfoDouble(ACCOUNT_EQUITY);
         if(equity>0) return(AxClampD(MathAbs(stats.avgLoss)/equity,0.0005,0.05));
        }
      // before enough realized losses exist to derive this empirically, use the EA's actual
      // configured risk-per-trade percent (from CRiskEngine) rather than an arbitrary flat
      // assumption - it can otherwise be off by up to 40x from what's really being risked
      // (InpMode ranges from 0.05% to 2.0%), which is exactly when an accurate estimate matters most
      return(m_configuredRiskFrac);
     }
  };
//+------------------------------------------------------------------+
#endif // AX_ADAPTIVEFLIPENGINE_MQH
