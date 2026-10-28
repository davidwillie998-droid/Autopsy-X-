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

   //--- Write a complete temporary registry first, flush it, then replace the active file.
   //--- This prevents ordinary write/open failures from truncating the last known-good registry.
   //--- The MQL5 file API does not promise power-loss atomicity; callers still fail closed on errors.
   bool               RewriteFile(void)
     {
      string tempName=m_fileName+".tmp";
      int handle=FileOpen(tempName,FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
      if(handle==INVALID_HANDLE)
        {
         m_persistOk=false;
         PrintFormat("FLIPDEMON RECOVERY ERROR: cannot open temporary registry %s (error=%d).",
                     tempName,GetLastError());
         return(false);
        }

      bool writeOk=true;
      for(int i=0;i<m_count;i++)
        {
         string line = StringFormat("%s|%s|%s|%d|%s",
                        IntegerToString((long)m_records[i].ticket),
                        m_records[i].setupId,
                        m_records[i].symbol,
                        (int)m_records[i].dir,
                        TimeToString(m_records[i].entryTime,TIME_DATE|TIME_SECONDS));
         uint written=FileWriteString(handle,line+"\\r\\n");
         if(written==0)
           {
            writeOk=false;
            break;
           }
        }

      FileFlush(handle);
      FileClose(handle);
      if(!writeOk)
        {
         m_persistOk=false;
         PrintFormat("FLIPDEMON RECOVERY ERROR: temporary registry write failed (%s); previous registry retained.",
                     tempName);
         return(false);
        }

      ResetLastError();
      if(!FileMove(tempName,0,m_fileName,FILE_REWRITE))
        {
         int moveError=GetLastError();
         m_persistOk=false;
         PrintFormat("FLIPDEMON RECOVERY ERROR: could not replace registry %s from %s (error=%d); entries remain blocked.",
                     m_fileName,tempName,moveError);
         return(false);
        }

      m_persistOk=true;
      return(true);
     }

public:
                      CRestartRecovery(void) { m_count=0; m_persistOk=false; }

   bool               Init(const string eaName,const string symbol,const ulong magic)
     {
      m_fileName = StringFormat("%s_%s_%s_OpenSetups.csv",eaName,symbol,IntegerToString((long)magic));
      m_count=0;

      // Fail closed on an existing registry that cannot be read. The previous implementation
      // treated every FileOpen failure as "no registry" and immediately rewrote an empty file,
      // which could destroy the only saved SetupID mapping after a transient access/format error.
      int readHandle = FileOpen(m_fileName,FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
      if(readHandle==INVALID_HANDLE)
        {
         if(FileIsExist(m_fileName))
           {
            PrintFormat("FLIPDEMON RECOVERY ERROR: registry exists but cannot be read (%s, error=%d); refusing to overwrite it.",
                        m_fileName,GetLastError());
            m_persistOk=false;
            return(false);
           }

         // A genuinely new registry is safe to create. Do not confuse this with an unreadable file.
         m_count=0;
         return(RewriteFile());
        }

      bool registryValid=true;
      while(!FileIsEnding(readHandle))
        {
         string line = FileReadString(readHandle);
         if(StringLen(line)==0) continue;

         if(m_count>=AX_RECOVERY_MAX_ENTRIES)
           {
            PrintFormat("FLIPDEMON RECOVERY ERROR: registry exceeds capacity (%d); refusing to truncate or overwrite it.",
                        AX_RECOVERY_MAX_ENTRIES);
            registryValid=false;
            break;
           }

         string fields[];
         int n = StringSplit(line,'|',fields);
         if(n!=AX_RECOVERY_FIELD_COUNT)
           {
            PrintFormat("FLIPDEMON RECOVERY ERROR: malformed registry row; refusing to rewrite %s.",m_fileName);
            registryValid=false;
            break;
           }

         long ticketLong = StringToInteger(fields[0]);
         long dirLong = StringToInteger(fields[3]);
         datetime entryTime = StringToTime(fields[4]);
         if(ticketLong<=0 || StringLen(fields[1])==0 || StringLen(fields[2])==0 ||
            (dirLong!=(long)AX_DIR_BUY && dirLong!=(long)AX_DIR_SELL) || entryTime<=0)
           {
            PrintFormat("FLIPDEMON RECOVERY ERROR: invalid registry record; refusing to rewrite %s.",m_fileName);
            registryValid=false;
            break;
           }

         // Duplicate tickets make the recovered state ambiguous; never silently pick one.
         for(int i=0;i<m_count;i++)
           {
            if(m_records[i].ticket==(ulong)ticketLong)
              {
               PrintFormat("FLIPDEMON RECOVERY ERROR: duplicate ticket %I64d; refusing to rewrite %s.",
                           ticketLong,m_fileName);
               registryValid=false;
               break;
              }
           }
         if(!registryValid) break;

         m_records[m_count].ticket    = (ulong)ticketLong;
         m_records[m_count].setupId   = fields[1];
         m_records[m_count].symbol    = fields[2];
         m_records[m_count].dir       = (ENUM_AX_DIR)dirLong;
         m_records[m_count].entryTime = entryTime;
         m_count++;
        }
      FileClose(readHandle);

      if(!registryValid)
        {
         m_count=0;
         m_persistOk=false;
         return(false);
        }

      return(RewriteFile());
     }

   //--- no explicit file handle is held open between calls (each write opens/closes its own handle),---
   //--- so there is nothing to release here - kept for symmetry with the rest of the codebase's      ---
   //--- Init()/Deinit() pattern and as a place a future caller-visible flush could go. ---
   void               Deinit(void) {}

   bool               IsPersisting(void) const { return(m_persistOk); }

   // Returns true only when the registry update is durable. Callers must block new
   // entries if this returns false; in-memory state is rolled back on a failed write.
   bool               RecordOpenSetup(const ulong ticket,const string setupId,const string symbol,
                                       const ENUM_AX_DIR dir,const datetime entryTime)
     {
      if(ticket==0 || StringLen(setupId)==0 || StringLen(symbol)==0 || entryTime<=0 ||
         (dir!=AX_DIR_BUY && dir!=AX_DIR_SELL))
        {
         Print("FLIPDEMON RECOVERY ERROR: invalid open-setup record rejected.");
         return(false);
        }

      for(int i=0;i<m_count;i++)
         if(m_records[i].ticket==ticket) return(true); // already tracked, idempotent success

      if(m_count>=AX_RECOVERY_MAX_ENTRIES)
        {
         PrintFormat("FLIPDEMON RECOVERY ERROR: registry capacity %d reached; refusing new record.",
                     AX_RECOVERY_MAX_ENTRIES);
         m_persistOk=false;
         return(false);
        }

      int previousCount=m_count;
      m_records[m_count].ticket=ticket; m_records[m_count].setupId=setupId;
      m_records[m_count].symbol=symbol; m_records[m_count].dir=dir; m_records[m_count].entryTime=entryTime;
      m_count++;

      if(RewriteFile()) return(true);

      // Disk persistence failed. Restore the in-memory count so RAM does not claim a
      // record was saved when it was not. The caller receives false and must fail closed.
      m_count=previousCount;
      PrintFormat("FLIPDEMON RECOVERY ERROR: could not persist open setup ticket %I64u.",ticket);
      return(false);
     }

   bool               RemoveOpenSetup(const ulong ticket)
     {
      int found=-1;
      for(int i=0;i<m_count;i++)
         if(m_records[i].ticket==ticket) { found=i; break; }
      if(found<0) return(true); // already absent is an idempotent success

      SAxOpenSetupRecord removed=m_records[found];
      for(int i=found;i<m_count-1;i++) m_records[i]=m_records[i+1];
      m_count--;

      if(RewriteFile()) return(true);

      // Preserve the in-memory record if the disk update failed. This may leave a stale
      // record on disk, but it is safer than pretending removal was persisted.
      for(int i=m_count;i>found;i--) m_records[i]=m_records[i-1];
      m_records[found]=removed;
      m_count++;
      PrintFormat("FLIPDEMON RECOVERY ERROR: could not persist removal of ticket %I64u.",ticket);
      return(false);
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
         if(FindByTicket(ticket,rec))
           {
            // A ticket match alone is not sufficient: validate the persisted identity against
            // the broker's actual symbol, magic and direction before trusting its setup mapping.
            long liveType=PositionGetInteger(POSITION_TYPE);
            ENUM_AX_DIR liveDir=(liveType==POSITION_TYPE_BUY)?AX_DIR_BUY:AX_DIR_SELL;
            if(rec.symbol==symbol && rec.dir==liveDir)
               matchedOut++;
            else
              {
               untrackedOut++;
               PrintFormat("FLIPDEMON RECOVERY ERROR: ticket %I64u metadata does not match broker state; new entries must remain blocked.",
                           ticket);
              }
           }
         else
            untrackedOut++; // real position, no history - never fabricate its thesis
        }

      //--- pass 2: every registry entry with no matching real position - the position closed while ---
      //--- this EA was offline. Removed from memory only here; ONE rewrite happens after the loop. ---
      SAxOpenSetupRecord snapshot[AX_RECOVERY_MAX_ENTRIES];
      int previousCount=m_count;
      for(int i=0;i<previousCount;i++) snapshot[i]=m_records[i];

      bool anyRemoved=false;
      for(int i=m_count-1;i>=0;i--)
        {
         bool recordStillValid=false;
         if(PositionSelectByTicket(m_records[i].ticket))
           {
            string liveSymbol=PositionGetString(POSITION_SYMBOL);
            ulong liveMagic=(ulong)PositionGetInteger(POSITION_MAGIC);
            long liveType=PositionGetInteger(POSITION_TYPE);
            ENUM_AX_DIR liveDir=(liveType==POSITION_TYPE_BUY)?AX_DIR_BUY:AX_DIR_SELL;
            recordStillValid=(liveSymbol==symbol && liveMagic==magic &&
                              m_records[i].symbol==symbol && m_records[i].dir==liveDir);
           }

         if(!recordStillValid)
           {
            if(RemoveFromMemory(m_records[i].ticket))
              {
               staleRemovedOut++;
               anyRemoved=true;
              }
           }
        }

      if(anyRemoved && !RewriteFile())
        {
         // The broker reconciliation succeeded, but the updated registry did not persist.
         // Restore the in-memory snapshot and keep entries disabled until persistence recovers.
         m_count=previousCount;
         for(int i=0;i<previousCount;i++) m_records[i]=snapshot[i];
         m_persistOk=false;
         staleRemovedOut=0;
         Print("FLIPDEMON RECOVERY ERROR: stale-record cleanup was not persisted; original registry restored in memory.");
        }
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
