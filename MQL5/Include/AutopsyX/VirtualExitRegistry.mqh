//+------------------------------------------------------------------+
//|                                           VirtualExitRegistry.mqh |
//| Persistent virtual SL/TP state, keyed by broker POSITION_IDENTIFIER|
//+------------------------------------------------------------------+
#property strict
#ifndef AX_VIRTUALEXITREGISTRY_MQH
#define AX_VIRTUALEXITREGISTRY_MQH
#include "Defs.mqh"

#define AX_VIRTUAL_EXIT_MAX_RECORDS 64
#define AX_VIRTUAL_EXIT_FIELD_COUNT 12

struct SAxVirtualExitRecord
  {
   ulong       ticket;
   ulong       positionIdentifier;
   string      symbol;
   ENUM_AX_DIR dir;
   double      initialSlPrice;
   double      emergencySlPrice;
   double      virtualSlPrice;
   double      virtualTpPrice;
   double      originalRiskDistance;
   bool        breakEvenDone;
   datetime    entryTime;
   datetime    updatedAt;
  };

class CVirtualExitRegistry
  {
private:
   string                 m_fileName;
   SAxVirtualExitRecord   m_records[AX_VIRTUAL_EXIT_MAX_RECORDS];
   int                    m_count;
   bool                   m_persistOk;

   string Number(const double value) const
     {
      return(DoubleToString(value,16));
     }

   bool RewriteFile(void)
     {
      string tempName=m_fileName+".tmp";
      int handle=FileOpen(tempName,FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
      if(handle==INVALID_HANDLE)
        {
         m_persistOk=false;
         PrintFormat("FLIPDEMON VIRTUAL EXIT ERROR: cannot open temporary state file %s (error=%d).",
                     tempName,GetLastError());
         return(false);
        }

      bool writeOk=true;
      for(int i=0;i<m_count;i++)
        {
         SAxVirtualExitRecord r=m_records[i];
         string line=StringFormat("%I64u|%I64u|%s|%d|%s|%s|%s|%s|%s|%d|%s|%s",
                        r.ticket,r.positionIdentifier,r.symbol,(int)r.dir,
                        Number(r.initialSlPrice),Number(r.emergencySlPrice),
                        Number(r.virtualSlPrice),Number(r.virtualTpPrice),
                        Number(r.originalRiskDistance),r.breakEvenDone?1:0,
                        TimeToString(r.entryTime,TIME_DATE|TIME_SECONDS),
                        TimeToString(r.updatedAt,TIME_DATE|TIME_SECONDS));
         string payload=line+"\r\n";
         uint expected=(uint)StringLen(payload);
         uint written=FileWriteString(handle,payload);
         if(written!=expected)
           {
            writeOk=false;
            PrintFormat("FLIPDEMON VIRTUAL EXIT ERROR: short write at row %d (expected=%u written=%u).",
                        i,expected,written);
            break;
           }
        }
      FileFlush(handle);
      FileClose(handle);
      if(!writeOk)
        {
         m_persistOk=false;
         return(false);
        }

      ResetLastError();
      if(!FileMove(tempName,0,m_fileName,FILE_REWRITE))
        {
         m_persistOk=false;
         PrintFormat("FLIPDEMON VIRTUAL EXIT ERROR: atomic replacement failed for %s (error=%d).",
                     m_fileName,GetLastError());
         return(false);
        }
      m_persistOk=true;
      return(true);
     }

   int FindIndex(const ulong positionIdentifier) const
     {
      for(int i=0;i<m_count;i++)
         if(m_records[i].positionIdentifier==positionIdentifier) return(i);
      return(-1);
     }

public:
   CVirtualExitRegistry(void) { m_count=0; m_persistOk=false; }

   bool Init(const string eaName,const string symbol,const ulong magic)
     {
      m_fileName=StringFormat("%s_%s_%I64u_VirtualExits_v1.csv",eaName,symbol,magic);
      m_count=0;
      int handle=FileOpen(m_fileName,FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
      if(handle==INVALID_HANDLE)
        {
         if(FileIsExist(m_fileName))
           {
            m_persistOk=false;
            PrintFormat("FLIPDEMON VIRTUAL EXIT ERROR: state file exists but cannot be read (%s, error=%d).",
                        m_fileName,GetLastError());
            return(false);
           }
         return(RewriteFile());
        }

      bool valid=true;
      while(!FileIsEnding(handle))
        {
         string line=FileReadString(handle);
         if(StringLen(line)==0) continue;
         if(m_count>=AX_VIRTUAL_EXIT_MAX_RECORDS)
           {
            valid=false;
            Print("FLIPDEMON VIRTUAL EXIT ERROR: state capacity exceeded; refusing to truncate records.");
            break;
           }

         string f[];
         if(StringSplit(line,'|',f)!=AX_VIRTUAL_EXIT_FIELD_COUNT)
           {
            valid=false;
            Print("FLIPDEMON VIRTUAL EXIT ERROR: malformed state row; recovery refused.");
            break;
           }

         long ticket=StringToInteger(f[0]);
         long positionId=StringToInteger(f[1]);
         long dir=StringToInteger(f[3]);
         long be=StringToInteger(f[9]);
         datetime entry=StringToTime(f[10]);
         datetime updated=StringToTime(f[11]);
         double initialSl=StringToDouble(f[4]);
         double emergencySl=StringToDouble(f[5]);
         double virtualSl=StringToDouble(f[6]);
         double virtualTp=StringToDouble(f[7]);
         double riskDistance=StringToDouble(f[8]);
         if(ticket<=0 || positionId<=0 || StringLen(f[2])==0 ||
            (dir!=(long)AX_DIR_BUY && dir!=(long)AX_DIR_SELL) ||
            (be!=0 && be!=1) || entry<=0 || updated<=0 ||
            initialSl<=0 || emergencySl<=0 || virtualSl<=0 ||
            riskDistance<=0 || virtualTp<0)
           {
            valid=false;
            Print("FLIPDEMON VIRTUAL EXIT ERROR: invalid persisted levels; recovery refused.");
            break;
           }
         if(FindIndex((ulong)positionId)>=0)
           {
            valid=false;
            Print("FLIPDEMON VIRTUAL EXIT ERROR: duplicate position identifier; recovery refused.");
            break;
           }

         SAxVirtualExitRecord r;
         r.ticket=(ulong)ticket;
         r.positionIdentifier=(ulong)positionId;
         r.symbol=f[2];
         r.dir=(ENUM_AX_DIR)dir;
         r.initialSlPrice=initialSl;
         r.emergencySlPrice=emergencySl;
         r.virtualSlPrice=virtualSl;
         r.virtualTpPrice=virtualTp;
         r.originalRiskDistance=riskDistance;
         r.breakEvenDone=(be==1);
         r.entryTime=entry;
         r.updatedAt=updated;
         m_records[m_count]=r;
         m_count++;
        }
      FileClose(handle);
      if(!valid)
        {
         m_count=0;
         m_persistOk=false;
         return(false);
        }
      m_persistOk=true;
      return(true);
     }

   bool Save(const SAxVirtualExitRecord &record)
     {
      if(record.ticket==0 || record.positionIdentifier==0 ||
         StringLen(record.symbol)==0 ||
         (record.dir!=AX_DIR_BUY && record.dir!=AX_DIR_SELL) ||
         record.initialSlPrice<=0 || record.emergencySlPrice<=0 ||
         record.virtualSlPrice<=0 || record.originalRiskDistance<=0 ||
         record.virtualTpPrice<0 || record.entryTime<=0)
        {
         Print("FLIPDEMON VIRTUAL EXIT ERROR: invalid record rejected.");
         return(false);
        }

      int index=FindIndex(record.positionIdentifier);
      if(index<0 && m_count>=AX_VIRTUAL_EXIT_MAX_RECORDS)
        {
         m_persistOk=false;
         Print("FLIPDEMON VIRTUAL EXIT ERROR: registry full; refusing new state.");
         return(false);
        }

      int previousCount=m_count;
      SAxVirtualExitRecord previous;
      if(index>=0) previous=m_records[index];
      SAxVirtualExitRecord next=record;
      next.updatedAt=TimeCurrent();
      if(index<0)
        {
         index=m_count;
         m_count++;
        }
      m_records[index]=next;
      if(RewriteFile()) return(true);

      if(index<previousCount) m_records[index]=previous;
      else m_count=previousCount;
      return(false);
     }

   bool Find(const ulong positionIdentifier,SAxVirtualExitRecord &out) const
     {
      int index=FindIndex(positionIdentifier);
      if(index<0) return(false);
      out=m_records[index];
      return(true);
     }

   bool Remove(const ulong positionIdentifier)
     {
      int index=FindIndex(positionIdentifier);
      if(index<0) return(true);
      SAxVirtualExitRecord removed=m_records[index];
      for(int i=index;i<m_count-1;i++) m_records[i]=m_records[i+1];
      m_count--;
      if(RewriteFile()) return(true);
      for(int i=m_count;i>index;i--) m_records[i]=m_records[i-1];
      m_records[index]=removed;
      m_count++;
      return(false);
     }

   int Count(void) const { return(m_count); }
   bool IsPersisting(void) const { return(m_persistOk); }
  };
#endif // AX_VIRTUALEXITREGISTRY_MQH
