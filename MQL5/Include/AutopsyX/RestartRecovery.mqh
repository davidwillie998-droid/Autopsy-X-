//+------------------------------------------------------------------+
//|                                                RestartRecovery.mqh|
//|  Restart Recovery (FLIPDEMON EXTREME upgrade, spec section 28)    |
//|                                                                    |
//|  On a fresh EA start, in-memory state (which SetupID a currently- |
//|  open position belongs to, adaptive statistics, etc.) is gone -   |
//|  but the broker's own open positions/pending orders are not, and  |
//|  this EA's own journal file is not. This class bridges the two:   |
//|  it keeps a small persistent registry (a plain text file,         |
//|  <EAName>_<Symbol>_<Magic>_OpenSetups.csv - keyed by magic too, so |
//|  two differently-configured instances on the same symbol never    |
//|  share one file) mapping ticket -> SetupID, written at entry and  |
//|  cleared at exit, and on restart reconciles that registry against |
//|  what the broker ACTUALLY has open right now.                     |
//|                                                                    |
//|  Each record is written as ONE line, fields joined by "|" - read  |
//|  back a full line at a time (FileReadString in non-CSV text mode  |
//|  reads to the next line break) and split explicitly, rather than  |
//|  reading field-by-field from a comma/newline token stream. A      |
//|  malformed or short row is detected (wrong field count) and       |
//|  skipped on its own line instead of silently bleeding into the    |
//|  next row's fields.                                                |
//|                                                                    |
//|  Three explicit outcomes per broker position found, matching spec |
//|  section 28's "do not duplicate orders, do not fabricate           |
//|  historical signal states":                                        |
//|   - MATCHED: a registry entry exists for this ticket - its         |
//|     SetupID is restored, real data, nothing invented.               |
//|   - UNTRACKED: a real open position exists with NO matching        |
//|     registry entry (opened before this registry existed, or the    |
//|     registry file was lost). This class does NOT invent an entry   |
//|     reason, score, or regime for it - the main EA decides how to   |
//|     treat an untracked position (typically: manage it defensively).|
//|   - STALE: a registry entry exists for a ticket that is NO LONGER  |
//|     an open position (closed while the EA was offline) - removed  |
//|     from the registry; its outcome is not fabricated here either, |
//|     since this class has no way to know the real close price/time |
//|     without a full deal-history reconciliation, a separate,       |
//|     heavier feature than restart recovery itself.                  |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_RESTARTRECOVERY_MQH
#define AX_RESTARTRECOVERY_MQH
#include "Defs.mqh"

#define AX_RECOVERY_MAX_ENTRIES 64
#define AX_RECOVERY_FIELD_COUNT 5

struct SAxOpenSetupRecord
  {
   ulong       ticket;
   string      setupId;
   string      symbol;
   ENUM_AX_DIR dir;
   datetime    entryTime;
  };

class CRestartRecovery
  {
private:
   string             m_fileName;
   SAxOpenSetupRecord m_records[AX_RECOVERY_MAX_ENTRIES];
   int                m_count;
   bool               m_persistOk; // false if the last write attempt failed - exposed so the caller
                                    // can know the registry is not actually being saved right now,
                                    // rather than silently believing it is (code-review finding)

   //--- rewrites the whole file from m_records in one pass. Returns false (and leaves m_persistOk   ---
   //--- false) if the file could not be opened for writing - the caller can check IsPersisting(). ---
   bool               RewriteFile(void)
     {
      int handle = FileOpen(m_fileName,FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
      if(handle==INVALID_HANDLE) { m_persistOk=false; return(false); }
      for(int i=0;i<m_count;i++)
        {
         string line = StringFormat("%s|%s|%s|%d|%s",
                        IntegerToString((long)m_records[i].ticket),
                        m_records[i].setupId,
                        m_records[i].symbol,
                        (int)m_records[i].dir,
                        TimeToString(m_records[i].entryTime,TIME_DATE|TIME_SECONDS));
         FileWriteString(handle,line+"\r\n");
        }
      FileFlush(handle);
      FileClose(handle);
      m_persistOk=true;
      return(true);
     }

public:
                      CRestartRecovery(void) { m_count=0; m_persistOk=false; }

   bool               Init(const string eaName,const string symbol,const ulong magic)
     {
      m_fileName = StringFormat("%s_%s_%s_OpenSetups.csv",eaName,symbol,IntegerToString((long)magic));
      m_count=0;

      //--- load whatever the registry already contains BEFORE this session rewrites anything - this ---
      //--- is the state from before the restart, which is the entire point of this class ---
      int readHandle = FileOpen(m_fileName,FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
      if(readHandle!=INVALID_HANDLE)
        {
         while(!FileIsEnding(readHandle) && m_count<AX_RECOVERY_MAX_ENTRIES)
           {
            string line = FileReadString(readHandle);
            if(StringLen(line)==0) continue;

            string fields[];
            int n = StringSplit(line,'|',fields);
            if(n!=AX_RECOVERY_FIELD_COUNT) continue; // malformed row - skip it, does not affect any other row

            long ticketLong = StringToInteger(fields[0]);
            if(ticketLong<=0) continue;

            m_records[m_count].ticket    = (ulong)ticketLong;
            m_records[m_count].setupId   = fields[1];
            m_records[m_count].symbol    = fields[2];
            m_records[m_count].dir       = (ENUM_AX_DIR)StringToInteger(fields[3]);
            m_records[m_count].entryTime = StringToTime(fields[4]);
            m_count++;
           }
         FileClose(readHandle);
        }

      return(RewriteFile());
     }

   //--- no explicit file handle is held open between calls (each write opens/closes its own handle),---
   //--- so there is nothing to release here - kept for symmetry with the rest of the codebase's      ---
   //--- Init()/Deinit() pattern and as a place a future caller-visible flush could go. ---
   void               Deinit(void) {}

   bool               IsPersisting(void) const { return(m_persistOk); }

   void               RecordOpenSetup(const ulong ticket,const string setupId,const string symbol,
                                       const ENUM_AX_DIR dir,const datetime entryTime)
     {
      for(int i=0;i<m_count;i++)
         if(m_records[i].ticket==ticket) return; // already tracked, do not duplicate

      if(m_count>=AX_RECOVERY_MAX_ENTRIES) return; // registry full - caller should log this via IsPersisting()/RegistryCount()
      m_records[m_count].ticket=ticket; m_records[m_count].setupId=setupId;
      m_records[m_count].symbol=symbol; m_records[m_count].dir=dir; m_records[m_count].entryTime=entryTime;
      m_count++;
      RewriteFile();
     }

   void               RemoveOpenSetup(const ulong ticket)
     {
      if(!RemoveFromMemory(ticket)) return;
      RewriteFile();
     }

   bool               FindByTicket(const ulong ticket,SAxOpenSetupRecord &out) const
     {
      for(int i=0;i<m_count;i++)
         if(m_records[i].ticket==ticket) { out=m_records[i]; return(true); }
      return(false);
     }

   int                RegistryCount(void) const { return(m_count); }
   bool               GetRecord(const int i,SAxOpenSetupRecord &out) const
     {
      if(i<0 || i>=m_count) return(false);
      out=m_records[i];
      return(true);
     }

   //--- reconciliation pass: compares the loaded registry against REAL broker state right now.      ---
   //--- matchedOut/untrackedOut/staleRemovedOut are simple counters for the caller to log/report.    ---
   //--- Stale entries are removed from memory during the scan and the file is rewritten ONCE at the  ---
   //--- end, not once per removal - a registry with many stale entries no longer costs one full file ---
   //--- rewrite per entry (code-review finding). ---
   void               Reconcile(const string symbol,const ulong magic,
                                 int &matchedOut,int &untrackedOut,int &staleRemovedOut)
     {
      matchedOut=0; untrackedOut=0; staleRemovedOut=0;

      //--- pass 1: every REAL open position under this symbol/magic - matched or untracked ---
      int posTotal = PositionsTotal();
      for(int i=0;i<posTotal;i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket==0) continue;
         if(PositionGetString(POSITION_SYMBOL)!=symbol) continue;
         if((ulong)PositionGetInteger(POSITION_MAGIC)!=magic) continue;

         SAxOpenSetupRecord rec;
         if(FindByTicket(ticket,rec)) matchedOut++;
         else                          untrackedOut++; // real position, no history - never fabricate its thesis
        }

      //--- pass 2: every registry entry with no matching real position - the position closed while ---
      //--- this EA was offline. Removed from memory only here; ONE rewrite happens after the loop. ---
      bool anyRemoved=false;
      for(int i=m_count-1;i>=0;i--)
        {
         if(!PositionSelectByTicket(m_records[i].ticket))
           {
            staleRemovedOut++;
            RemoveFromMemory(m_records[i].ticket);
            anyRemoved=true;
           }
        }
      if(anyRemoved) RewriteFile();
     }

private:
   //--- shifts the array in memory only - does NOT touch the file. Returns false if the ticket   ---
   //--- wasn't found (nothing to remove). Callers that need the file updated call RewriteFile()   ---
   //--- themselves, once, after all memory-side removals for that operation are done. ---
   bool               RemoveFromMemory(const ulong ticket)
     {
      int idx=-1;
      for(int i=0;i<m_count;i++) if(m_records[i].ticket==ticket) { idx=i; break; }
      if(idx<0) return(false);
      for(int i=idx;i<m_count-1;i++) m_records[i]=m_records[i+1];
      m_count--;
      return(true);
     }
  };
//+------------------------------------------------------------------+
#endif // AX_RESTARTRECOVERY_MQH
