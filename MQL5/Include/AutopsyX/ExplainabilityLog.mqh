//+------------------------------------------------------------------+
//|                                            ExplainabilityLog.mqh|
//|  Data Storage for per-decision explanations (spec section,           |
//|  institutional engine upgrade) - ENGINEERING DESIGN, not paper-       |
//|  sourced.                                                              |
//|                                                                    |
//|  DELIBERATELY A SEPARATE FILE from TradeAutopsy.mqh's existing,         |
//|  already-reviewed Journal v2 CSV: that schema is per-CLOSED-TRADE         |
//|  (one row per trade outcome), while this is per-DECISION (one row          |
//|  per permission-matrix evaluation - which may be far more frequent           |
//|  than trades, including every WAIT/NO_TRADE verdict a real trade              |
//|  never resulted from). Extending TradeAutopsy's CSV schema to carry            |
//|  this would (a) misalign its already-reviewed column count/order for           |
//|  every existing downstream reader (the same reasoning that already              |
//|  produced the "_v2" filename split documented in that file), and (b)             |
//|  conflate two genuinely different record granularities. "Each engine              |
//|  owns its own state/read" is this codebase's own established                       |
//|  convention (VolatilityEngine's own ATR handle, DrawdownEngine's own                 |
//|  independent day/week rollover, etc.) - extended here to "each log                    |
//|  owns its own file."                                                                    |
//|                                                                    |
//|  Format: JSONL (one JSON object per line, from                        |
//|  CExplainabilityEngine::BuildDecisionExplanation()) rather than CSV -    |
//|  the gate breakdown is a nested array that doesn't flatten into a         |
//|  fixed CSV column count without losing information.                        |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_EXPLAINABILITYLOG_MQH
#define AX_EXPLAINABILITYLOG_MQH
#include "Defs.mqh"

class CExplainabilityLog
  {
private:
   int      m_fileHandle;
   string   m_fileName;

public:
                     CExplainabilityLog(void) { m_fileHandle=INVALID_HANDLE; }

   bool              Init(const string eaName,const string symbol)
     {
      m_fileName = StringFormat("%s_%s_Explainability.jsonl",eaName,symbol);
      m_fileHandle = FileOpen(m_fileName,FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
      if(m_fileHandle==INVALID_HANDLE) return(false);
      FileSeek(m_fileHandle,0,SEEK_END); // append, never truncate an existing session's log
      return(true);
     }

   void              Deinit(void)
     {
      if(m_fileHandle!=INVALID_HANDLE) { FileClose(m_fileHandle); m_fileHandle=INVALID_HANDLE; }
     }

   //--- writes one already-built JSON object (from CExplainabilityEngine) as its own line. Caller       ---
   //--- controls call frequency - this class does not decide when a decision is "worth" logging, it      ---
   //--- only persists what it's given, matching this codebase's "deliberately thin" engine convention. ---
   bool              WriteDecision(const string decisionJson)
     {
      if(m_fileHandle==INVALID_HANDLE) return(false);
      FileWriteString(m_fileHandle,decisionJson+"\n");
      return(true);
     }

   bool              IsOpen(void) const { return(m_fileHandle!=INVALID_HANDLE); }
   string            FileName(void) const { return(m_fileName); }
  };
//+------------------------------------------------------------------+
#endif // AX_EXPLAINABILITYLOG_MQH
