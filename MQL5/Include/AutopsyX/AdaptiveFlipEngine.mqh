//+------------------------------------------------------------------+
//| AdaptiveFlipEngine.mqh                                             |
//| AUTOPSY X VX - account-agnostic adaptive gating/sizing layer.      |
//|                                                                    |
//| Sits between the existing risk check and order entry. It does NOT |
//| replace CAXRisk's hard kill switch / daily-loss / drawdown limits -|
//| it adds probability, expected value (in R-multiples, so it means  |
//| the same thing on a $500 account as a $500,000 one), account       |
//| health, an approximate risk-of-ruin guardrail, a bounded capital   |
//| state machine, and edge-decay detection on top of them. A severe   |
//| risk-of-ruin breach is surfaced as a flag for the caller to route  |
//| into the existing kill switch, rather than a second, competing     |
//| stop-trading mechanism.                                            |
//+------------------------------------------------------------------+
#pragma once
#include <AutopsyX/Defines.mqh>

#define AX_FLIP_HISTORY 300

struct AXFlipOutcome
{
   double   rMultiple;
   bool     win;
   ENUM_AX_REGIME regime;
   double   slippagePts;
   datetime time;
};

struct AXFlipDecision
{
   bool     allowed;
   bool     warmingUp;
   bool     criticalRiskOfRuin;
   bool     edgeDecayDetected;
   string   reason;
   double   sizeMultiplier;
   double   probability;
   double   expectedValueR;
   double   accountHealth;
   double   riskOfRuinPct;
   ENUM_AX_CAPITAL_STATE capitalState;
};

class CAXAdaptiveFlip
{
private:
   AXFlipOutcome m_history[AX_FLIP_HISTORY];
   int      m_count;

   double   m_baselineAvgSlippage;   // set once enough samples exist, then held as the reference

   int      m_minSampleSize;
   int      m_minBucketSamples;
   int      m_recentWindow;
   int      m_baselineWindow;
   double   m_edgeDecayThresholdR;

   double   m_minExpectedValueR;
   double   m_maxRiskOfRuinPct;
   double   m_cautionHealthThreshold;
   double   m_recoveryHealthThreshold;
   double   m_confidentHealthThreshold;
   double   m_confidentEvThresholdR;

   double   m_confidentSizeMult;
   double   m_cautionSizeMult;
   double   m_recoverySizeMult;

   ENUM_AX_CAPITAL_STATE m_capitalState;

public:
   CAXAdaptiveFlip(void) : m_count(0), m_baselineAvgSlippage(0),
      m_minSampleSize(20), m_minBucketSamples(15), m_recentWindow(15), m_baselineWindow(60),
      m_edgeDecayThresholdR(0.15), m_minExpectedValueR(-0.02), m_maxRiskOfRuinPct(20.0),
      m_cautionHealthThreshold(55.0), m_recoveryHealthThreshold(35.0), m_confidentHealthThreshold(80.0),
      m_confidentEvThresholdR(0.10), m_confidentSizeMult(1.15), m_cautionSizeMult(0.6),
      m_recoverySizeMult(0.3), m_capitalState(AX_CAPSTATE_NORMAL) {}

   void Init(const int minSampleSize, const int minBucketSamples, const int recentWindow,
             const int baselineWindow, const double edgeDecayThresholdR, const double minExpectedValueR,
             const double maxRiskOfRuinPct, const double cautionHealthThreshold,
             const double recoveryHealthThreshold, const double confidentHealthThreshold,
             const double confidentEvThresholdR, const double confidentSizeMult,
             const double cautionSizeMult, const double recoverySizeMult)
   {
      m_minSampleSize    = MathMax(5, minSampleSize);
      m_minBucketSamples = MathMax(5, minBucketSamples);
      m_recentWindow      = MathMax(5, recentWindow);
      m_baselineWindow    = MathMax(m_recentWindow + 5, baselineWindow);
      m_edgeDecayThresholdR = MathMax(0.01, edgeDecayThresholdR);
      m_minExpectedValueR   = minExpectedValueR;
      m_maxRiskOfRuinPct     = AXClamp(maxRiskOfRuinPct, 1.0, AX_FLIP_MAX_RISK_OF_RUIN_PCT);
      m_cautionHealthThreshold    = AXClamp(cautionHealthThreshold, 0.0, 100.0);
      m_recoveryHealthThreshold   = AXClamp(recoveryHealthThreshold, 0.0, 100.0);
      m_confidentHealthThreshold  = AXClamp(confidentHealthThreshold, 0.0, 100.0);
      m_confidentEvThresholdR      = confidentEvThresholdR;
      m_confidentSizeMult = AXClamp(confidentSizeMult, 1.0, AX_FLIP_SIZE_MULT_MAX);
      m_cautionSizeMult    = AXClamp(cautionSizeMult, AX_FLIP_SIZE_MULT_MIN, 1.0);
      m_recoverySizeMult   = AXClamp(recoverySizeMult, AX_FLIP_SIZE_MULT_MIN, 1.0);
   }

   // call once per closed trade
   void RegisterOutcome(const double rMultiple, const ENUM_AX_REGIME regime, const double slippagePts, const datetime time)
   {
      for(int i = AX_FLIP_HISTORY - 1; i > 0; i--)
         m_history[i] = m_history[i - 1];
      m_history[0].rMultiple  = rMultiple;
      m_history[0].win        = (rMultiple >= 0.0);
      m_history[0].regime     = regime;
      m_history[0].slippagePts = slippagePts;
      m_history[0].time       = time;
      if(m_count < AX_FLIP_HISTORY) m_count++;

      if(m_baselineAvgSlippage <= 0.0 && m_count >= m_minSampleSize)
      {
         double sum = 0.0;
         for(int i = 0; i < m_count; i++) sum += m_history[i].slippagePts;
         m_baselineAvgSlippage = sum / m_count;
      }
   }

   int SampleCount(void) const { return m_count; }
   ENUM_AX_CAPITAL_STATE CapitalState(void) const { return m_capitalState; }

   // master evaluation - call once per candidate entry. equity/marginLevelPct
   // must come from live AccountInfoDouble() calls in the caller, never cached.
   AXFlipDecision Evaluate(const ENUM_AX_REGIME regime, const double equity, const double peakEquity,
                            const double marginLevelPct, const int consecutiveLosses,
                            const double riskPerTradePct)
   {
      AXFlipDecision d;
      d.allowed = true;
      d.warmingUp = false;
      d.criticalRiskOfRuin = false;
      d.edgeDecayDetected = false;
      d.reason = "";
      d.sizeMultiplier = 1.0;
      d.probability = 0.5;
      d.expectedValueR = 0.0;
      d.riskOfRuinPct = 0.0;
      d.capitalState = AX_CAPSTATE_NORMAL;

      double ddPct = (peakEquity > 0.0) ? MathMax(0.0, (peakEquity - equity) / peakEquity * 100.0) : 0.0;
      d.accountHealth = AccountHealthPartial(ddPct, marginLevelPct);

      if(m_count < m_minSampleSize)
      {
         d.warmingUp = true;
         d.reason = StringFormat("warming up (%d/%d trades recorded)", m_count, m_minSampleSize);
         m_capitalState = AX_CAPSTATE_NORMAL;
         d.capitalState = m_capitalState;
         return d; // never block or resize on data we don't have yet
      }

      double avgWinR, avgLossR;
      ComputeStats(0, m_count, avgWinR, avgLossR);
      double pOverall = WinProbabilityRange(0, m_count);
      double p = WinProbabilityBucketed(regime, pOverall);

      d.probability = p;
      d.expectedValueR = p * avgWinR - (1.0 - p) * avgLossR;
      d.riskOfRuinPct = RiskOfRuinPct(p, avgWinR, avgLossR, riskPerTradePct);
      d.criticalRiskOfRuin = (d.riskOfRuinPct >= m_maxRiskOfRuinPct);

      double recentAvgSlippage = RecentAvgSlippage(MathMin(m_recentWindow, m_count));
      double execHealth = (m_baselineAvgSlippage > 0.0)
         ? AXClamp(100.0 - (recentAvgSlippage / m_baselineAvgSlippage - 1.0) * 50.0, 0.0, 100.0)
         : 100.0;

      double recentWinRate = WinProbabilityRange(0, MathMin(m_recentWindow, m_count));
      double winTrendHealth = AXClamp(50.0 + (recentWinRate - pOverall) * 100.0, 0.0, 100.0);

      d.accountHealth = AXClamp(d.accountHealth * 0.60 + winTrendHealth * 0.20 + execHealth * 0.20, 0.0, 100.0);

      d.edgeDecayDetected = DetectEdgeDecay();

      //--- capital state machine (bounded transitions, see header comment) --
      if(d.edgeDecayDetected || d.accountHealth < m_recoveryHealthThreshold)
         m_capitalState = AX_CAPSTATE_RECOVERY;
      else if(d.accountHealth < m_cautionHealthThreshold)
         m_capitalState = AX_CAPSTATE_CAUTION;
      else if(d.accountHealth >= m_confidentHealthThreshold && d.expectedValueR >= m_confidentEvThresholdR)
         m_capitalState = AX_CAPSTATE_CONFIDENT;
      else
         m_capitalState = AX_CAPSTATE_NORMAL;

      d.capitalState = m_capitalState;

      switch(m_capitalState)
      {
         case AX_CAPSTATE_CONFIDENT: d.sizeMultiplier = m_confidentSizeMult; break;
         case AX_CAPSTATE_CAUTION:   d.sizeMultiplier = m_cautionSizeMult; break;
         case AX_CAPSTATE_RECOVERY:  d.sizeMultiplier = m_recoverySizeMult; break;
         default:                    d.sizeMultiplier = 1.0; break;
      }
      d.sizeMultiplier = AXClamp(d.sizeMultiplier, AX_FLIP_SIZE_MULT_MIN, AX_FLIP_SIZE_MULT_MAX);

      //--- gating: negative-edge trades are blocked outright, not just downsized --
      if(d.expectedValueR < m_minExpectedValueR)
      {
         d.allowed = false;
         d.reason = StringFormat("expected value %.3fR below floor %.3fR", d.expectedValueR, m_minExpectedValueR);
      }
      else if(d.criticalRiskOfRuin)
      {
         d.allowed = false;
         d.reason = StringFormat("risk of ruin %.1f%% >= limit %.1f%%", d.riskOfRuinPct, m_maxRiskOfRuinPct);
      }
      else
      {
         d.reason = StringFormat("%s state, EV %.3fR, health %.0f", AXCapitalStateToString(m_capitalState),
                                  d.expectedValueR, d.accountHealth);
      }

      return d;
   }

private:
   double AccountHealthPartial(const double ddPct, const double marginLevelPct) const
   {
      double healthDD = AXClamp(100.0 - ddPct * 8.0, 0.0, 100.0);
      double healthMargin;
      if(marginLevelPct <= 0.0) healthMargin = 100.0; // no positions open - nothing to penalize
      else healthMargin = AXClamp((marginLevelPct - 100.0) / 2.0, 0.0, 100.0);
      return AXClamp(healthDD * 0.65 + healthMargin * 0.35, 0.0, 100.0);
   }

   void ComputeStats(const int start, const int count, double &avgWinR, double &avgLossR) const
   {
      double winSum = 0.0, lossSum = 0.0;
      int wins = 0, losses = 0;
      int end = MathMin(start + count, m_count);
      for(int i = start; i < end; i++)
      {
         if(m_history[i].rMultiple >= 0.0) { winSum += m_history[i].rMultiple; wins++; }
         else { lossSum += -m_history[i].rMultiple; losses++; }
      }
      avgWinR  = (wins > 0)   ? winSum / wins   : 0.0;
      avgLossR = (losses > 0) ? lossSum / losses : 0.0;
   }

   double WinProbabilityRange(const int start, const int count) const
   {
      int end = MathMin(start + count, m_count);
      int n = end - start;
      if(n <= 0) return 0.5;
      int wins = 0;
      for(int i = start; i < end; i++)
         if(m_history[i].win) wins++;
      return AXClamp((double)wins / n, 0.02, 0.98);
   }

   double WinProbabilityBucketed(const ENUM_AX_REGIME regime, const double fallback) const
   {
      int wins = 0, total = 0;
      for(int i = 0; i < m_count; i++)
      {
         if(m_history[i].regime != regime) continue;
         total++;
         if(m_history[i].win) wins++;
      }
      if(total < m_minBucketSamples) return fallback;
      return AXClamp((double)wins / total, 0.02, 0.98);
   }

   double RecentAvgSlippage(const int n) const
   {
      if(n <= 0) return 0.0;
      double sum = 0.0;
      for(int i = 0; i < n; i++) sum += m_history[i].slippagePts;
      return sum / n;
   }

   // approximate practical risk-of-ruin, not a rigorous closed-form derivation -
   // used only as a guardrail trigger, not a precise probability claim
   double RiskOfRuinPct(const double p, const double avgWinR, const double avgLossR, const double riskPerTradePct) const
   {
      if(riskPerTradePct <= 0.0) return 0.0;
      double b = (avgLossR > 0.0) ? (avgWinR / avgLossR) : 1.0;
      if(b <= 0.0) b = 1.0;
      double edge = p * (1.0 + b) - 1.0;
      if(edge <= 0.0) return 100.0;

      double units = 100.0 / riskPerTradePct;
      double ratio = ((1.0 - p) / p) / b;
      ratio = AXClamp(ratio, 0.0001, 0.9999);
      double ror = MathPow(ratio, units) * 100.0;
      return AXClamp(ror, 0.0, 100.0);
   }

   bool DetectEdgeDecay(void)
   {
      if(m_count < m_recentWindow + m_baselineWindow) return false;

      double recentWinR, recentLossR, baseWinR, baseLossR;
      ComputeStats(0, m_recentWindow, recentWinR, recentLossR);
      ComputeStats(m_recentWindow, m_baselineWindow, baseWinR, baseLossR);

      double pRecent = WinProbabilityRange(0, m_recentWindow);
      double pBase    = WinProbabilityRange(m_recentWindow, m_baselineWindow);

      double evRecent = pRecent * recentWinR - (1.0 - pRecent) * recentLossR;
      double evBase    = pBase * baseWinR - (1.0 - pBase) * baseLossR;

      if(evBase > 0.0 && (evBase - evRecent) >= m_edgeDecayThresholdR) return true;
      return false;
   }
};
