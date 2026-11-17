//+------------------------------------------------------------------+
//|                                      ExecutionQualityJournal.mqh  |
//|  Durable, analysis-only execution observations. No trade authority.|
//+------------------------------------------------------------------+
#property strict
#ifndef AX_EXECUTION_QUALITY_JOURNAL_MQH
#define AX_EXECUTION_QUALITY_JOURNAL_MQH

#define AX_EXEC_QUALITY_FIELDS 13

class CExecutionQualityJournal
  {
private:
   int      m_handle;
   string   m_fileName;
   string   m_symbol;
   ulong    m_magic;
   bool     m_persistenceHealthy;
   bool     m_needsLineBreak;
   ulong    m_rowsWritten;

   string SafeSymbol(const string symbol) const
     {
      string value=symbol;
      StringReplace(value,"/","_");
      StringReplace(value,"\\","_");
      StringReplace(value,":","_");
      StringReplace(value,"*","_");
      StringReplace(value,"?","_");
      StringReplace(value,"\"","_");
      StringReplace(value,"<","_");
      StringReplace(value,">","_");
      StringReplace(value,"|","_");
      return(value);
     }

   string Header(void) const
     {
      return("timestamp,symbol,magic,event,direction,bid,ask,spread_points,atr_points,regime,volatility_state,adverse_slippage_points,latency_ms");
     }

   bool RecoverTail(void)
     {
      int reader=FileOpen(m_fileName,FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
      if(reader==INVALID_HANDLE) return(false);
      bool firstLine=true;
      bool lastNonEmptyValid=true;
      while(!FileIsEnding(reader))
        {
         string line=FileReadString(reader);
         if(firstLine)
           {
            firstLine=false;
            if(line!=Header())
              {
               FileClose(reader);
               return(false);
              }
            continue;
           }
         if(StringLen(line)==0) continue;
         string fields[];
         int count=StringSplit(line,StringGetCharacter(",",0),fields);
         lastNonEmptyValid=(count==AX_EXEC_QUALITY_FIELDS);
        }
      FileClose(reader);
      if(firstLine) return(false);
      m_needsLineBreak=!lastNonEmptyValid;
      return(true);
     }

   bool WriteHeader(void)
     {
      string header=Header()+"\r\n";
      uint expected=(uint)StringLen(header);
      uint written=FileWriteString(m_handle,header);
      FileFlush(m_handle);
      return(written==expected && FileSize(m_handle)==written);
     }

public:
                     CExecutionQualityJournal(void)
     {
      m_handle=INVALID_HANDLE;
      m_fileName="";
      m_symbol="";
      m_magic=0;
      m_persistenceHealthy=false;
      m_needsLineBreak=false;
      m_rowsWritten=0;
     }

   bool Init(const string symbol,const ulong magic)
     {
      Deinit();
      m_symbol=symbol;
      m_magic=magic;
      m_persistenceHealthy=false;
      m_needsLineBreak=false;
      m_rowsWritten=0;
      if(StringLen(symbol)==0 || magic==0) return(false);
      m_fileName=StringFormat("AX_ExecutionQuality_%s_%I64u.csv",SafeSymbol(symbol),magic);

      int createHandle=FileOpen(m_fileName,FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
      if(createHandle==INVALID_HANDLE) return(false);
      if(FileSize(createHandle)==0)
        {
         m_handle=createHandle;
         bool headerOk=WriteHeader();
         FileClose(m_handle);
         m_handle=INVALID_HANDLE;
         if(!headerOk) return(false);
        }
      else
         FileClose(createHandle);

      if(!RecoverTail()) return(false);
      m_handle=FileOpen(m_fileName,FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
      if(m_handle==INVALID_HANDLE) return(false);
      if(!FileSeek(m_handle,0,SEEK_END))
        {
         FileClose(m_handle);
         m_handle=INVALID_HANDLE;
         return(false);
        }
      m_persistenceHealthy=true;
      return(true);
     }

   bool Record(const datetime timestamp,const string eventType,const int direction,
               const double bid,const double ask,const double point,
               const double atrPoints,const int regime,const int volatilityState,
               const double adverseSlippagePts,const int latencyMs)
     {
      if(!m_persistenceHealthy || m_handle==INVALID_HANDLE) return(false);
      if(timestamp<=0 || (eventType!="ENTRY" && eventType!="EXIT") ||
         direction<0 || direction>2 ||
         !MathIsValidNumber(bid) || !MathIsValidNumber(ask) ||
         !MathIsValidNumber(point) || !MathIsValidNumber(atrPoints) ||
         !MathIsValidNumber(adverseSlippagePts) ||
         bid<=0.0 || ask<bid || point<=0.0 || atrPoints<0.0 ||
         adverseSlippagePts<0.0 || latencyMs<0)
         return(false);

      double spreadPoints=(ask-bid)/point;
      if(!MathIsValidNumber(spreadPoints) || spreadPoints<0.0) return(false);
      string payload=StringFormat("%I64d,%s,%I64u,%s,%d,%.10f,%.10f,%.3f,%.3f,%d,%d,%.3f,%d\r\n",
                                  (long)timestamp,SafeSymbol(m_symbol),m_magic,eventType,direction,
                                  bid,ask,spreadPoints,atrPoints,regime,volatilityState,
                                  adverseSlippagePts,latencyMs);
      if(m_needsLineBreak) payload="\r\n"+payload;
      if(!FileSeek(m_handle,0,SEEK_END))
        {
         m_persistenceHealthy=false;
         PrintFormat("FLIPDEMON EXECUTION JOURNAL ERROR: cannot seek append position (error=%d).",GetLastError());
         return(false);
        }
      ulong sizeBefore=FileSize(m_handle);
      uint expected=(uint)StringLen(payload);
      uint written=FileWriteString(m_handle,payload);
      FileFlush(m_handle);
      ulong sizeAfter=FileSize(m_handle);
      if(written!=expected || sizeAfter<=sizeBefore)
        {
         m_persistenceHealthy=false;
         PrintFormat("FLIPDEMON EXECUTION JOURNAL ERROR: append/flush verification failed for %s. Journal latched unhealthy; trading decisions are unchanged.",m_symbol);
         return(false);
        }
      m_needsLineBreak=false;
      m_rowsWritten++;
      return(true);
     }

   bool IsPersisting(void) const { return(m_persistenceHealthy); }
   string FileName(void) const { return(m_fileName); }
   ulong RowsWritten(void) const { return(m_rowsWritten); }

   void Deinit(void)
     {
      if(m_handle!=INVALID_HANDLE)
        {
         FileFlush(m_handle);
         FileClose(m_handle);
        }
      m_handle=INVALID_HANDLE;
      m_persistenceHealthy=false;
     }
  };

#endif // AX_EXECUTION_QUALITY_JOURNAL_MQH
