//+------------------------------------------------------------------+
//| TradeJournal.mqh                                                      |
//| Layer 15 (data side) — AUTOPSY ENGINE. Section 34.                    |
//| Every closed trade gets a forensic record, appended to a CSV file     |
//| under MQL5/Files so it survives terminal restarts and is directly     |
//| inspectable/exportable (e.g. into the web dashboard's bridge).        |
//| Also keeps the last N records in memory for the ProbabilityEngine     |
//| and DriftEngine.                                                       |
//+------------------------------------------------------------------+
#ifndef AXF_TRADEJOURNAL_MQH
#define AXF_TRADEJOURNAL_MQH

#include "../Common/Defines.mqh"

#define AXF_JOURNAL_MAX_MEMORY 500

class CAxfTradeJournal
  {
private:
   string            m_filename;
   SAxfTradeRecord   m_memory[AXF_JOURNAL_MAX_MEMORY];
   int               m_count; // number of valid entries (ring buffer)
   int               m_head;

   string            DirString(const ENUM_AXF_DIRECTION d) { return (d==DIR_LONG)?"LONG":(d==DIR_SHORT?"SHORT":"NONE"); }
   string            TagString(const ENUM_AXF_AUTOPSY_TAG t)
     {
      switch(t)
        {
         case AUTOPSY_APLUS_WIN: return "A+_WIN";
         case AUTOPSY_A_WIN: return "A_WIN";
         case AUTOPSY_B_WIN: return "B_WIN";
         case AUTOPSY_APLUS_LOSS: return "A+_LOSS";
         case AUTOPSY_A_LOSS: return "A_LOSS";
         case AUTOPSY_STRUCTURAL_FAILURE: return "STRUCTURAL_FAILURE";
         case AUTOPSY_LIQUIDITY_FAILURE: return "LIQUIDITY_FAILURE";
         case AUTOPSY_MACRO_FAILURE: return "MACRO_FAILURE";
         case AUTOPSY_EXECUTION_FAILURE: return "EXECUTION_FAILURE";
         case AUTOPSY_REGIME_FAILURE: return "REGIME_FAILURE";
         case AUTOPSY_PREMATURE_EXIT: return "PREMATURE_EXIT";
         case AUTOPSY_LATE_EXIT: return "LATE_EXIT";
         default: return "NONE";
        }
     }

public:
                     CAxfTradeJournal(void) { m_count=0; m_head=0; }

   void              Init(const ulong magic)
     {
      m_filename = "AXF15_journal_"+IntegerToString((long)magic)+".csv";
      LoadFromDisk();
     }

   ENUM_AXF_AUTOPSY_TAG Classify(const SAxfTradeRecord &t) const
     {
      if(t.r_multiple > 0)
        {
         if(t.flip_score>=80 && t.r_multiple>=2.0) return AUTOPSY_APLUS_WIN;
         if(t.flip_score>=70) return AUTOPSY_A_WIN;
         return AUTOPSY_B_WIN;
        }
      // losses: classify by what actually broke, using the exit_reason tag the
      // caller supplies (set by the state machine at close time)
      if(StringFind(t.exit_reason,"STRUCTURE")>=0)  return AUTOPSY_STRUCTURAL_FAILURE;
      if(StringFind(t.exit_reason,"LIQUIDITY")>=0)   return AUTOPSY_LIQUIDITY_FAILURE;
      if(StringFind(t.exit_reason,"MACRO")>=0)       return AUTOPSY_MACRO_FAILURE;
      if(StringFind(t.exit_reason,"EXECUTION")>=0)   return AUTOPSY_EXECUTION_FAILURE;
      if(StringFind(t.exit_reason,"REGIME")>=0)      return AUTOPSY_REGIME_FAILURE;
      if(StringFind(t.exit_reason,"PREMATURE")>=0)   return AUTOPSY_PREMATURE_EXIT;
      if(StringFind(t.exit_reason,"LATE")>=0)        return AUTOPSY_LATE_EXIT;
      if(t.flip_score>=80) return AUTOPSY_APLUS_LOSS;
      return AUTOPSY_A_LOSS;
     }

   void              Record(SAxfTradeRecord &t)
     {
      t.tag = Classify(t);
      m_memory[m_head] = t;
      m_head = (m_head+1) % AXF_JOURNAL_MAX_MEMORY;
      if(m_count<AXF_JOURNAL_MAX_MEMORY) m_count++;
      AppendToDisk(t);
     }

   //--- newest-first copy of up to 'max_n' records, optionally filtered by
   //--- regime+direction ("setup class") for the ProbabilityEngine.
   int               GetRecords(SAxfTradeRecord &out[],const int max_n,
                                 const bool filter_by_setup=false,
                                 const ENUM_AXF_REGIME regime=REGIME_UNKNOWN,
                                 const ENUM_AXF_DIRECTION dir=DIR_NONE)
     {
      ArrayResize(out,0);
      int n=0;
      for(int i=0;i<m_count && n<max_n;i++)
        {
         int idx = (m_head-1-i+AXF_JOURNAL_MAX_MEMORY*2) % AXF_JOURNAL_MAX_MEMORY;
         if(filter_by_setup)
           {
            if(m_memory[idx].regime!=regime || m_memory[idx].direction!=dir) continue;
           }
         ArrayResize(out,n+1);
         out[n]=m_memory[idx];
         n++;
        }
      return n;
     }

   int               Count(void) const { return m_count; }

private:
   void              AppendToDisk(const SAxfTradeRecord &t)
     {
      int handle = FileOpen(m_filename,FILE_READ|FILE_WRITE|FILE_CSV|FILE_COMMON|FILE_ANSI);
      if(handle==INVALID_HANDLE) return;
      FileSeek(handle,0,SEEK_END);
      int digits = (int)SymbolInfoInteger(t.symbol,SYMBOL_DIGITS);
      FileWrite(handle,
                t.ticket, t.symbol, DirString(t.direction), AxfRegimeToString(t.regime),
                TimeToString(t.open_time,TIME_DATE|TIME_SECONDS),
                TimeToString(t.close_time,TIME_DATE|TIME_SECONDS),
                DoubleToString(t.entry,digits), DoubleToString(t.stop,digits),
                DoubleToString(t.target,digits), DoubleToString(t.exit_price,digits),
                DoubleToString(t.risk_pct,3), DoubleToString(t.r_multiple,3),
                DoubleToString(t.mfe_r,3), DoubleToString(t.mae_r,3),
                DoubleToString(t.spread_cost,5), DoubleToString(t.commission_cost,5),
                DoubleToString(t.swap_cost,5), DoubleToString(t.slippage_cost,5),
                AxfModeToString(t.mode), DoubleToString(t.flip_score,1),
                t.entry_reason, t.exit_reason, TagString(t.tag));
      FileClose(handle);
     }

   void              LoadFromDisk(void)
     {
      // memory cache is best-effort — a fresh cache after restart is acceptable;
      // the ProbabilityEngine simply operates with sample_size=0 until new
      // trades accrue. The CSV file itself is the durable record.
      m_count=0; m_head=0;
     }
  };

#endif // AXF_TRADEJOURNAL_MQH
