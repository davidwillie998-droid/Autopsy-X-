//+------------------------------------------------------------------+
//|                              HedgingPartialCloseLedger.mqh       |
//| Durable, per-position partial-exit deal ledger.                  |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_HEDGINGPARTIALCLOSELEDGER_MQH
#define AX_HEDGINGPARTIALCLOSELEDGER_MQH

#include "Defs.mqh"

#define AX_PARTIAL_LEDGER_FIELD_COUNT 14

struct SAxPartialCloseLedgerRecord
  {
   ulong positionIdentifier;
   ulong dealTicket;
   string symbol;
   ulong magic;
   ENUM_AX_DIR direction;
   datetime entryTime;
   double entryPrice;
   double entryVolume;
   datetime closeTime;
   double closePrice;
   double closedVolume;
   double grossProfit;
   double commission;
   double swap;
  };

class CHedgingPartialCloseLedger
  {
private:
   string m_fileName;
   SAxPartialCloseLedgerRecord m_records[];
   int m_count;
   bool m_persistOk;

   int FindIndex(const ulong positionIdentifier,const ulong dealTicket) const
     {
      if(positionIdentifier==0 || dealTicket==0) return(-1);
      for(int i=0;i<m_count;i++)
         if(m_records[i].positionIdentifier==positionIdentifier &&
            m_records[i].dealTicket==dealTicket) return(i);
      return(-1);
     }

   bool Validate(const SAxPartialCloseLedgerRecord &r) const
     {
      if(r.positionIdentifier==0 || r.dealTicket==0 || StringLen(r.symbol)==0 ||
         r.magic==0 || (r.direction!=AX_DIR_BUY && r.direction!=AX_DIR_SELL) ||
         r.entryTime<=0 || r.entryPrice<=0.0 || r.entryVolume<=0.0 ||
         r.closeTime<=0 || r.closePrice<=0.0 || r.closedVolume<=0.0 ||
         r.closedVolume>=r.entryVolume ||
         !MathIsValidNumber(r.entryPrice) || !MathIsValidNumber(r.entryVolume) ||
         !MathIsValidNumber(r.closePrice) || !MathIsValidNumber(r.closedVolume) ||
         !MathIsValidNumber(r.grossProfit) || !MathIsValidNumber(r.commission) ||
         !MathIsValidNumber(r.swap))
         return(false);
      return(true);
     }

   string Serialize(const SAxPartialCloseLedgerRecord &r) const
     {
      return(StringFormat("%I64u|%I64u|%s|%I64u|%d|%s|%.16f|%.16f|%s|%.16f|%.16f|%.16f|%.16f|%.16f",
                          r.positionIdentifier,r.dealTicket,r.symbol,r.magic,(int)r.direction,
                          TimeToString(r.entryTime,TIME_DATE|TIME_SECONDS),
                          r.entryPrice,r.entryVolume,
                          TimeToString(r.closeTime,TIME_DATE|TIME_SECONDS),
                          r.closePrice,r.closedVolume,r.grossProfit,r.commission,r.swap));
     }

   bool Parse(const string line,SAxPartialCloseLedgerRecord &r) const
     {
      string f[];
      if(StringSplit(line,'|',f)!=AX_PARTIAL_LEDGER_FIELD_COUNT) return(false);
      long positionId=StringToInteger(f[0]);
      long deal=StringToInteger(f[1]);
      long magic=StringToInteger(f[3]);
      long direction=StringToInteger(f[4]);
      if(positionId<=0 || deal<=0 || magic<=0 ||
         (direction!=(long)AX_DIR_BUY && direction!=(long)AX_DIR_SELL))
         return(false);
      r.positionIdentifier=(ulong)positionId;
      r.dealTicket=(ulong)deal;
      r.symbol=f[2];
      r.magic=(ulong)magic;
      r.direction=(ENUM_AX_DIR)direction;
      r.entryTime=StringToTime(f[5]);
      r.entryPrice=StringToDouble(f[6]);
      r.entryVolume=StringToDouble(f[7]);
      r.closeTime=StringToTime(f[8]);
      r.closePrice=StringToDouble(f[9]);
      r.closedVolume=StringToDouble(f[10]);
      r.grossProfit=StringToDouble(f[11]);
      r.commission=StringToDouble(f[12]);
      r.swap=StringToDouble(f[13]);
      return(Validate(r));
     }

   bool Rewrite(void)
     {
      string tempName=m_fileName+".tmp";
      int handle=FileOpen(tempName,FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
      if(handle==INVALID_HANDLE)
        {
         m_persistOk=false;
         return(false);
        }
      bool ok=true;
      for(int i=0;i<m_count;i++)
        {
         string payload=Serialize(m_records[i])+"\r\n";
         uint expected=(uint)StringLen(payload);
         if(FileWriteString(handle,payload)!=expected)
           {
            ok=false;
            break;
           }
        }
      FileFlush(handle);
      FileClose(handle);
      if(!ok)
        {
         m_persistOk=false;
         return(false);
        }
      ResetLastError();
      if(!FileMove(tempName,0,m_fileName,FILE_REWRITE))
        {
         m_persistOk=false;
         return(false);
        }
      m_persistOk=true;
      return(true);
     }

public:
   CHedgingPartialCloseLedger(void)
     {
      m_count=0;
      m_persistOk=false;
     }

   bool Init(const string eaName,const string symbol,const ulong magic)
     {
      if(StringLen(eaName)==0 || StringLen(symbol)==0 || magic==0)
         return(false);
      m_fileName=StringFormat("%s_%s_%I64u_HedgingPartialCloses_v1.csv",
                              eaName,symbol,magic);
      m_count=0;
      if(ArrayResize(m_records,0)!=0) return(false);
      int handle=FileOpen(m_fileName,FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
      if(handle==INVALID_HANDLE)
        {
         if(FileIsExist(m_fileName)) return(false);
         return(Rewrite());
        }
      bool valid=true;
      while(!FileIsEnding(handle))
        {
         string line=FileReadString(handle);
         if(StringLen(line)==0) continue;
         SAxPartialCloseLedgerRecord parsed;
         if(!Parse(line,parsed) ||
            FindIndex(parsed.positionIdentifier,parsed.dealTicket)>=0)
           {
            valid=false;
            break;
           }
         int next=m_count+1;
         if(ArrayResize(m_records,next)!=next)
           {
            valid=false;
            break;
           }
         m_records[m_count]=parsed;
         m_count++;
        }
      FileClose(handle);
      if(!valid)
        {
         m_count=0;
         ArrayResize(m_records,0);
         m_persistOk=false;
         return(false);
        }
      m_persistOk=true;
      return(true);
     }

   // A deal ticket is unique only inside its broker position identity.
   // Duplicate replay is accepted only when every persisted value matches.
   bool Record(const SAxPartialCloseLedgerRecord &record)
     {
      if(!Validate(record)) return(false);
      int index=FindIndex(record.positionIdentifier,record.dealTicket);
      if(index>=0)
        {
         SAxPartialCloseLedgerRecord old=m_records[index];
         return(old.symbol==record.symbol && old.magic==record.magic &&
                old.direction==record.direction && old.entryTime==record.entryTime &&
                MathAbs(old.entryPrice-record.entryPrice)<=0.00000001 &&
                MathAbs(old.entryVolume-record.entryVolume)<=0.00000001 &&
                old.closeTime==record.closeTime &&
                MathAbs(old.closePrice-record.closePrice)<=0.00000001 &&
                MathAbs(old.closedVolume-record.closedVolume)<=0.00000001 &&
                MathAbs(old.grossProfit-record.grossProfit)<=0.00000001 &&
                MathAbs(old.commission-record.commission)<=0.00000001 &&
                MathAbs(old.swap-record.swap)<=0.00000001);
        }
      int next=m_count+1;
      if(ArrayResize(m_records,next)!=next) return(false);
      m_records[m_count]=record;
      m_count++;
      if(Rewrite()) return(true);
      m_count--;
      ArrayResize(m_records,m_count);
      return(false);
     }

   bool Find(const ulong positionIdentifier,const ulong dealTicket,
             SAxPartialCloseLedgerRecord &recordOut) const
     {
      int index=FindIndex(positionIdentifier,dealTicket);
      if(index<0) return(false);
      recordOut=m_records[index];
      return(true);
     }

   ulong LastDealTicket(const ulong positionIdentifier) const
     {
      ulong last=0;
      for(int i=0;i<m_count;i++)
         if(m_records[i].positionIdentifier==positionIdentifier &&
            m_records[i].dealTicket>last) last=m_records[i].dealTicket;
      return(last);
     }

   int Count(void) const { return(m_count); }
   bool IsPersisting(void) const { return(m_persistOk); }
  };

#endif // AX_HEDGINGPARTIALCLOSELEDGER_MQH
