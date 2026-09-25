//+------------------------------------------------------------------+
//|                                       ExplainabilityEngine.mqh|
//|  Explainability (spec section, institutional engine upgrade) -      |
//|  ENGINEERING DESIGN, not paper-sourced. The paper does not specify   |
//|  a JSON schema or logging format; the spec's own instruction is a    |
//|  "machine-readable per-decision explanation" - this file's only       |
//|  job is producing that, nothing more.                                  |
//|                                                                    |
//|  DELIBERATELY THIN, matching InformationContentEngine.mqh's/          |
//|  HiddenRiskDetector.mqh's own convention: every field serialized       |
//|  here is an ALREADY-COMPUTED reason string or struct from another       |
//|  engine (TradePermissionMatrix, DynamicPositionSizing, AlphaEngine,       |
//|  DrawdownEngine, CrisisEngine, HiddenRiskDetector, CapacityCrowding-       |
//|  Engine). This class recomputes no risk/quality logic whatsoever -         |
//|  it is pure serialization, which keeps its own bug surface to            |
//|  string-formatting correctness only.                                       |
//|                                                                    |
//|  MQL5 has no built-in JSON library, so this hand-builds a minimal      |
//|  JSON object via StringFormat/concatenation. AxJsonEscape() below        |
//|  escapes backslashes and double-quotes in any string value before        |
//|  it is embedded, so a symbol name or reason string containing either      |
//|  character can never produce invalid/injected JSON.                        |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_EXPLAINABILITYENGINE_MQH
#define AX_EXPLAINABILITYENGINE_MQH
#include "Defs.mqh"
#include "TradePermissionMatrix.mqh"
#include "DynamicPositionSizing.mqh"

//--- escapes backslash (FIRST, so quote-escaping below doesn't get re-escaped) and double-quote -       ---
//--- the only two characters that can break a hand-built JSON string literal here. Control characters   ---
//--- (newlines etc.) are not expected in any of this codebase's reason strings (all built via            ---
//--- StringFormat with fixed templates, never from raw external/user text), so are not escaped.           ---
string AxJsonEscape(const string s)
  {
   string out=s;
   StringReplace(out,"\\","\\\\");
   StringReplace(out,"\"","\\\"");
   return(out);
  }

class CExplainabilityEngine
  {
public:
   //--- assembles ONE JSON object string per decision - alphaReason/ddReason/crisisReason/               ---
   //--- hiddenRiskReason/capacityCrowdingReason are each engine's own already-built .reason string        ---
   //--- (SAxAlphaBreakdown, SAxDrawdownState, SAxCrisisState, SAxHiddenRiskState,                          ---
   //--- SAxCapacityCrowdingState all already carry one), embedded verbatim rather than re-parsed or         ---
   //--- re-derived - this function's only responsibility is putting them all in one place. ---
   string            BuildDecisionExplanation(const datetime now,const string symbol,const ENUM_AX_DIR proposedDir,
                                                const SAxPermissionVerdict &verdict,const SAxSizingResult &sizing,
                                                const string alphaReason,const string drawdownReason,
                                                const string crisisReason,const string hiddenRiskReason,
                                                const string capacityCrowdingReason) const
     {
      string gatesJson="[";
      for(int i=0;i<AX_GATE_COUNT;i++)
        {
         if(i>0) gatesJson+=",";
         gatesJson+=StringFormat(
            "{\"name\":\"%s\",\"passed\":%s,\"hard\":%s,\"reason\":\"%s\"}",
            AxJsonEscape(verdict.gates[i].name),
            verdict.gates[i].passed?"true":"false",
            verdict.gates[i].isHardGate?"true":"false",
            AxJsonEscape(verdict.gates[i].reason));
        }
      gatesJson+="]";

      return(StringFormat(
         "{\"timestamp\":\"%s\",\"symbol\":\"%s\",\"proposedDirection\":\"%s\",\"decision\":\"%s\","
         "\"hardGatesFailed\":%d,\"softGatesFailed\":%d,\"gates\":%s,"
         "\"sizing\":{\"baseRiskPercent\":%.4f,\"finalRiskPercent\":%.4f,\"totalMultiplier\":%.4f},"
         "\"alpha\":\"%s\",\"drawdown\":\"%s\",\"crisis\":\"%s\",\"hiddenRisk\":\"%s\",\"capacityCrowding\":\"%s\"}",
         TimeToString(now,TIME_DATE|TIME_SECONDS),AxJsonEscape(symbol),AxDirToString(proposedDir),
         AxFinalDecisionToString(verdict.decision),verdict.hardGatesFailed,verdict.softGatesFailed,gatesJson,
         sizing.baseRiskPercent,sizing.finalRiskPercent,sizing.totalMultiplier,
         AxJsonEscape(alphaReason),AxJsonEscape(drawdownReason),AxJsonEscape(crisisReason),
         AxJsonEscape(hiddenRiskReason),AxJsonEscape(capacityCrowdingReason)));
     }
  };
//+------------------------------------------------------------------+
#endif // AX_EXPLAINABILITYENGINE_MQH
