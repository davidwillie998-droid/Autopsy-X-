//+------------------------------------------------------------------+
//| AutopsyLogger.mqh                                                    |
//| Every regime decision logged to the terminal (compact one-liner)  |
//| and to a CSV audit trail (full snapshot) - section 23. Same       |
//| FileOpen/FileWrite append-only CSV convention as TradeJournal.mqh |
//| in AUTOPSY X SWINGDEMON X15, so both modules' journals are        |
//| readable the same way.                                            |
//+------------------------------------------------------------------+
#property strict
#ifndef AUTOPSYX_LOGGER_MQH
#define AUTOPSYX_LOGGER_MQH
#include "AutopsyTypes.mqh"

class CAutopsyLogger
  {
private:
   string m_fileName;

   void WriteHeader(int handle)
     {
      FileWrite(handle, "timestamp","regime","bias","confidence","trendEfficiency","volState",
                "macroScore","breadthScore","liquidityScore","aggregateExposurePct","riskMultiplier",
                "longPermission","shortPermission","allowNewTrade","aggressiveMode","shockMode",
                "dataStatus","decision","reason");
     }

public:
   void Init(const string idPrefix)
     {
      m_fileName = StringFormat("AutopsyX_RegimeLog_%s.csv", idPrefix);
     }

   void Log(const AXRPermission &p, const string decision)
     {
      PrintFormat("AXR %s REGIME=%s BIAS=%s CONF=%.0f TRENDEFF=%.2f VOL=%s MACRO=%+.0f BREADTH=%+.0f RISK_MULT=%.2f LONG=%s SHORT=%s DECISION=%s%s",
                  TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES),
                  AXRRegimeToString(p.regime), AXRBiasToString(p.bias), p.confidence, p.trendEfficiency,
                  AXRVolStateToString(p.volState), p.macroScore, p.breadthScore, p.riskMultiplier,
                  p.allowLong?"TRUE":"FALSE", p.allowShort?"TRUE":"FALSE", decision,
                  p.reason!="" ? (" ("+p.reason+")") : "");

      bool exists = FileIsExist(m_fileName);
      int handle = FileOpen(m_fileName, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_SHARE_READ, ',');
      if(handle==INVALID_HANDLE) return;
      if(!exists) WriteHeader(handle);
      FileSeek(handle, 0, SEEK_END);
      FileWrite(handle,
                TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
                AXRRegimeToString(p.regime), AXRBiasToString(p.bias), DoubleToString(p.confidence,1),
                DoubleToString(p.trendEfficiency,3), AXRVolStateToString(p.volState),
                DoubleToString(p.macroScore,1), DoubleToString(p.breadthScore,1), DoubleToString(p.liquidityScore,1),
                DoubleToString(p.aggregateExposurePct,2), DoubleToString(p.riskMultiplier,3),
                p.allowLong?"TRUE":"FALSE", p.allowShort?"TRUE":"FALSE", p.allowNewTrade?"TRUE":"FALSE",
                p.aggressiveMode?"TRUE":"FALSE", p.shockMode?"TRUE":"FALSE",
                AXRDataStatusToString(p.dataStatus), decision, p.reason);
      FileClose(handle);
     }
  };
#endif // AUTOPSYX_LOGGER_MQH
