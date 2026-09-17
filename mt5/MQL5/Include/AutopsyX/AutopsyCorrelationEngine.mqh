//+------------------------------------------------------------------+
//|                                    AutopsyCorrelationEngine.mqh  |
//|  AUTOPSY X — Correlation Protection                              |
//|  Spec section 15.                                                |
//|                                                                    |
//|  Multiple EAs on the same terminal trading QQQ/TQQQ/NQ/MNQ/US100/ |
//|  NAS100 are one synthetic Nasdaq position, not independent bets.  |
//|  MT5 has no cross-account shared memory, but GlobalVariable_*     |
//|  values ARE shared across every EA and chart on the same         |
//|  terminal — that's the real, honest scope of "correlation        |
//|  protection" here: same terminal, multiple EAs/charts. It will   |
//|  not see exposure held in a different terminal or account.       |
//+------------------------------------------------------------------+
#property strict
#include "AutopsyTypes.mqh"

//+------------------------------------------------------------------+
//| Rough beta of a Nasdaq-linked instrument against the cash index, |
//| used to convert "how much of this am I holding" into a common    |
//| Nasdaq-equivalent notional. TQQQ's 3x is the obvious case;       |
//| anything unrecognized gets a conservative partial weight rather  |
//| than being ignored (0) or fully counted (1).                     |
//+------------------------------------------------------------------+
double AxNasdaqBeta(const string symbol)
  {
   string s = symbol;
   StringToUpper(s);
   if(StringFind(s, "TQQQ")  >= 0) return 3.0;
   if(StringFind(s, "SQQQ")  >= 0) return -3.0;
   if(StringFind(s, "QQQ")   >= 0) return 1.0;
   if(StringFind(s, "MNQ")   >= 0) return 1.0;
   if(StringFind(s, "NQ")    >= 0) return 1.0;
   if(StringFind(s, "US100") >= 0) return 1.0;
   if(StringFind(s, "NAS100")>= 0) return 1.0;
   return 0.5; // unrecognized tech-correlated instrument — conservative partial beta
  }

class CAxCorrelationEngine
  {
private:
   string m_bot_id;
   string m_prefix;
   double m_limit_pct_equity;      // max aggregate Nasdaq-equivalent exposure, as % of equity
   double m_taper_start_ratio;     // multiplier starts tapering once usage crosses this fraction of the limit

   double m_last_aggregate_pct;
   int    m_last_reporter_count;

   string ExposureVarName() const { return m_prefix + m_bot_id; }
   string TimeVarName() const { return m_prefix + m_bot_id + "_T"; }

public:
   void Init(const string bot_id, const double limit_pct_equity, const double taper_start_ratio = 0.7)
     {
      m_bot_id            = bot_id;
      m_prefix             = "AX_EXPOSURE_";
      m_limit_pct_equity   = limit_pct_equity;
      m_taper_start_ratio  = taper_start_ratio;
      m_last_aggregate_pct = 0.0;
      m_last_reporter_count = 0;
     }

   //+---------------------------------------------------------------+
   //| Call whenever this bot's own Nasdaq-linked exposure changes.  |
   //| notional_value is this bot's own position size in account      |
   //| currency (e.g. lots * contract size * price); the symbol name  |
   //| decides the beta weighting automatically.                      |
   //+---------------------------------------------------------------+
   void ReportExposure(const string symbol, const double notional_value, const double account_equity)
     {
      const double beta_weighted = notional_value * AxNasdaqBeta(symbol);
      const double pct_of_equity = (account_equity > 0.0) ? 100.0 * MathAbs(beta_weighted) / account_equity : 0.0;
      GlobalVariableSet(ExposureVarName(), pct_of_equity);
      GlobalVariableSet(TimeVarName(), (double)TimeCurrent());
     }

   void ClearExposure()
     {
      GlobalVariableDel(ExposureVarName());
      GlobalVariableDel(TimeVarName());
     }

   //+---------------------------------------------------------------+
   //| Sums every "AX_EXPOSURE_*" global variable on this terminal —  |
   //| every bot that has ever called ReportExposure(), including     |
   //| this one. Stale entries are still counted: a crashed bot's     |
   //| forgotten position doesn't stop being real risk just because   |
   //| it stopped checking in, so exposure only clears via             |
   //| ClearExposure() or the reporting bot posting a lower number.    |
   //+---------------------------------------------------------------+
   double GetAggregateExposurePct()
     {
      double total = 0.0;
      int reporters = 0;
      const int n = GlobalVariablesTotal();
      for(int i = 0; i < n; i++)
        {
         const string name = GlobalVariableName(i);
         if(StringFind(name, m_prefix) != 0) continue;
         if(StringFind(name, "_T", StringLen(name) - 2) >= 0) continue; // skip the timestamp companions
         total += GlobalVariableGet(name);
         reporters++;
        }
      m_last_aggregate_pct   = total;
      m_last_reporter_count  = reporters;
      return total;
     }

   int GetReporterCount() const { return m_last_reporter_count; }

   //+---------------------------------------------------------------+
   //| 1.0 while well under the configured limit, tapering linearly   |
   //| to 0.0 once aggregate exposure reaches the limit. This feeds   |
   //| the risk governor's CORRELATION_MULTIPLIER directly.           |
   //+---------------------------------------------------------------+
   double GetCorrelationMultiplier()
     {
      GetAggregateExposurePct();
      if(m_limit_pct_equity <= 0.0) return 1.0;
      const double usage_ratio = m_last_aggregate_pct / m_limit_pct_equity;
      if(usage_ratio <= m_taper_start_ratio) return 1.0;
      if(usage_ratio >= 1.0) return 0.0;
      return AxLerp(1.0, 0.0, (usage_ratio - m_taper_start_ratio) / (1.0 - m_taper_start_ratio));
     }

   bool IsOverLimit()
     {
      GetAggregateExposurePct();
      return m_last_aggregate_pct >= m_limit_pct_equity;
     }

   double GetLimitPctEquity() const { return m_limit_pct_equity; }
  };
