//+------------------------------------------------------------------+
//|                         HedgingFullCloseLedger.mqh               |
//| Durable, per-position final liquidation journal.                  |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_HEDGINGFULLCLOSELEDGER_MQH
#define AX_HEDGINGFULLCLOSELEDGER_MQH

#include "Defs.mqh"

#define AX_FULL_CLOSE_LEDGER_FIELD_COUNT 19

struct SAxFullCloseLedgerRecord
  {
   ulong positionIdentifier;
   ulong finalDealTicket;
   ulong lastExitDealTicket;
   string symbol;
   ulong magic;
   ENUM_AX_DIR direction;
   datetime entryTime;
   double entryPrice;
   double entryVolume;
   datetime closeTime;
   double weightedClosePrice;
   double totalClosedVolume;
   int exitDealCount;
   double grossProfit;
   double commission;
   double swap;
   double fees;
   double netProfit;
   double partialClosedVolume;
  };

class CHedgingFullCloseLedger
  {
private:
   string m_fileName;
   SAxFullCloseLedgerRecord m_records[];
   int m_count;
   bool m_persistOk;

   int FindIndex(const ulong positionIdentifier) const
     {
      if(positionIdentifier==0) return(-1);
      for(int i=0;i<m_count;i++)
         if(m_records[i].positionIdentifier==positionIdentifier) return(i);
      return(-1);
     }

   bool Validate(const SAxFullCloseLedgerRecord &r) const
     {
      if(r.positionIdentifier==0 || r.finalDealTicket==0 ||
         r.lastExitDealTicket==0 || StringLen(r.symbol)==0 || r.magic==0 ||
         (r.direction!=AX_DIR_BUY && r.direction!=AX_DIR_SELL) ||
         r.entryTime<=0 || r.entryPrice<=0.0 || r.entryVolume<=0.0 ||
         r.closeTime<=0 || r.weightedClosePrice<=0.0 ||
         r.totalClosedVolume<=0.0 || r.exitDealCount<=0 ||
         r.partialClosedVolume<0.0 ||
         !MathIsValidNumber(r.entryPrice) || !MathIsValidNumber(r.entryVolume) ||
         !MathIsValidNumber(r.weightedClosePrice) ||
         !MathIsValidNumber(r.totalClosedVolume) ||
         !MathIsValidNumber(r.partialClosedVolume) ||
         !MathIsValidNumber(r.grossProfit) || !MathIsValidNumber(r.commission) ||
         !MathIsValidNumber(r.swap) || !MathIsValidNumber(r.fees) ||
         !MathIsValidNumber(r.netProfit))
         return(false);
      if(r.partialClosedVolume>r.totalClosedVolume+0.00000001 ||
         r.totalClosedVolume+0.00000001<r.entryVolume)
         return(false);
      return(true);
     }

   string Serialize(const SAxFullCloseLedgerRecord &r) const
     {
      return(StringFormat("%I64u|%I64u|%I64u|%s|%I64u|%d|%s|%.16f|%.16f|%s|%.16f|%.16f|%d|%.16f|%.16f|%.16f|%.16f|%.16f|%.16f",
                          r.positionIdentifier,r.finalDealTicket,r.lastExitDealTicket,
                          r.symbol,r.magic,(int)r.direction,
                          TimeToString(r.entryTime,TIME_DATE|TIME_SECONDS),
                          r.entryPrice,r.entryVolume,
                          TimeToString(r.closeTime,TIME_DATE|TIME_SECONDS),
                          r.weightedClosePrice,r.totalClosedVolume,r.exitDealCount,
                          r.grossProfit,r.commission,r.swap,r.fees,r.netProfit,
                          r.partialClosedVolume));
     }

   bool Parse(const string line,SAxFullCloseLedgerRecord &r) const
     {
      string f[];
      if(StringSplit(line,'|',f)!=AX_FULL_CLOSE_LEDGER_FIELD_COUNT) return(false);
      long positionId=StringToInteger(f[0]);
      long finalDeal=StringToInteger(f[1]);
      long lastDeal=StringToInteger(f[2]);
      long magic=StringToInteger(f[4]);
      long direction=StringToInteger(f[5]);
      if(positionId<=0 || finalDeal<=0 || lastDeal<=0 || magic<=0 ||
         (direction!=(long)AX_DIR_BUY && direction!=(long)AX_DIR_SELL))
         return(false);
      r.positionIdentifier=(ulong)positionId;
      r.finalDealTicket=(ulong)finalDeal;
      r.lastExitDealTicket=(ulong)lastDeal;
      r.symbol=f[3];
      r.magic=(ulong)magic;
      r.direction=(ENUM_AX_DIR)direction;
      r.entryTime=StringToTime(f[6]);
      r.entryPrice=StringToDouble(f[7]);
      r.entryVolume=StringToDouble(f[8]);
      r.closeTime=StringToTime(f[9]);
      r.weightedClosePrice=StringToDouble(f[10]);
      r.totalClosedVolume=StringToDouble(f[11]);
      r.exitDealCount=(int)StringToInteger(f[12]);
      r.grossProfit=StringToDouble(f[13]);
      r.commission=StringToDouble(f[14]);
      r.swap=StringToDouble(f[15]);
      r.fees=StringToDouble(f[16]);
      r.netProfit=StringToDouble(f[17]);
      r.partialClosedVolume=StringToDouble(f[18]);
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

   bool SameRecord(const SAxFullCloseLedgerRecord &a,
                   const SAxFullCloseLedgerRecord &b) const
     {
      return(a.positionIdentifier==b.positionIdentifier &&
             a.finalDealTicket==b.finalDealTicket &&
             a.lastExitDealTicket==b.lastExitDealTicket &&
             a.symbol==b.symbol && a.magic==b.magic &&
             a.direction==b.direction && a.entryTime==b.entryTime &&
             a.closeTime==b.closeTime && a.exitDealCount==b.exitDealCount &&
             MathAbs(a.entryPrice-b.entryPrice)<=0.00000001 &&
             MathAbs(a.entryVolume-b.entryVolume)<=0.00000001 &&
             MathAbs(a.weightedClosePrice-b.weightedClosePrice)<=0.00000001 &&
             MathAbs(a.totalClosedVolume-b.totalClosedVolume)<=0.00000001 &&
             MathAbs(a.grossProfit-b.grossProfit)<=0.00000001 &&
             MathAbs(a.commission-b.commission)<=0.00000001 &&
             MathAbs(a.swap-b.swap)<=0.00000001 &&
             MathAbs(a.fees-b.fees)<=0.00000001 &&
             MathAbs(a.netProfit-b.netProfit)<=0.00000001 &&
             MathAbs(a.partialClosedVolume-b.partialClosedVolume)<=0.00000001);
     }

public:
   CHedgingFullCloseLedger(void)
     {
      m_count=0;
      m_persistOk=false;
     }

   bool Init(const string eaName,const string symbol,const ulong magic)
     {
      long accountLogin=AccountInfoInteger(ACCOUNT_LOGIN);
      if(StringLen(eaName)==0 || StringLen(symbol)==0 || magic==0 || accountLogin<=0)
         return(false);
      m_fileName=StringFormat("%s_%s_%I64d_%I64u_HedgingFullCloses_v1.csv",
                              eaName,symbol,accountLogin,magic);
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
         SAxFullCloseLedgerRecord parsed;
         if(!Parse(line,parsed) || FindIndex(parsed.positionIdentifier)>=0)
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

   // One immutable final journal row per stable broker position identity.
   // A replay is accepted only when every persisted field matches exactly.
   bool Record(const SAxFullCloseLedgerRecord &record)
     {
      if(!Validate(record)) return(false);
      int index=FindIndex(record.positionIdentifier);
      if(index>=0) return(SameRecord(m_records[index],record));
      int next=m_count+1;
      if(ArrayResize(m_records,next)!=next) return(false);
      m_records[m_count]=record;
      m_count++;
      if(Rewrite()) return(true);
      m_count--;
      ArrayResize(m_records,m_count);
      return(false);
     }

   bool Find(const ulong positionIdentifier,SAxFullCloseLedgerRecord &recordOut) const
     {
      int index=FindIndex(positionIdentifier);
      if(index<0) return(false);
      recordOut=m_records[index];
      return(true);
     }

   int Count(void) const { return(m_count); }
   bool IsPersisting(void) const { return(m_persistOk); }
  };

#endif // AX_HEDGINGFULLCLOSELEDGER_MQH
