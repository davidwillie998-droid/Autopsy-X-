//+------------------------------------------------------------------+
//| PositionStateRegistry.mqh: durable per-position lifecycle ledger |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_POSITIONSTATEREGISTRY_MQH
#define AX_POSITIONSTATEREGISTRY_MQH
#include "Defs.mqh"

#define AX_POSITION_STATE_FIELD_COUNT 45
#define AX_POSITION_STATE_MAX_RECORDS 2048

struct SAxPositionLifecycleRecord
  {
   ulong positionIdentifier;
   ulong ticket;
   string symbol;
   ulong magic;
   SAxPositionState state;
  };

class CPositionStateRegistry
  {
private:
   SAxPositionLifecycleRecord m_records[];
   int m_count;
   bool m_ready;
   bool m_persisting;
   string m_fileName;
   string m_failureReason;

   string N(const double value) const { return(DoubleToString(value,16)); }
   string U(const ulong value) const { return(StringFormat("%I64u",value)); }

   string Encode(const string value) const
     {
      string encoded=value;
      StringReplace(encoded,"%","%25");
      StringReplace(encoded,"|","%7C");
      StringReplace(encoded,"\r","%0D");
      StringReplace(encoded,"\n","%0A");
      return(encoded);
     }

   string Decode(const string value) const
     {
      string decoded=value;
      StringReplace(decoded,"%7C","|");
      StringReplace(decoded,"%0D","\r");
      StringReplace(decoded,"%0A","\n");
      StringReplace(decoded,"%25","%");
      return(decoded);
     }

   int FindIndex(const ulong id) const
     {
      if(id==0) return(-1);
      for(int i=0;i<m_count;i++)
         if(m_records[i].positionIdentifier==id) return(i);
      return(-1);
     }

   bool ValidState(const SAxPositionLifecycleRecord &r) const
     {
      const SAxPositionState s=r.state;
      if(r.positionIdentifier==0 || r.ticket==0 || r.symbol=="" || r.magic==0 ||
         !s.active || s.ticket!=r.ticket ||
         (s.dir!=AX_DIR_BUY && s.dir!=AX_DIR_SELL) ||
         s.entryTime<=0 || !MathIsValidNumber(s.entryPrice) || s.entryPrice<=0.0 ||
         !MathIsValidNumber(s.lots) || s.lots<=0.0 ||
         !MathIsValidNumber(s.initialSlPrice) || s.initialSlPrice<=0.0 ||
         !MathIsValidNumber(s.initialTpPrice) || s.initialTpPrice<0.0 ||
         !MathIsValidNumber(s.originalSlPrice) || s.originalSlPrice<=0.0 ||
         !MathIsValidNumber(s.bestFavorablePrice) || s.bestFavorablePrice<=0.0 ||
         !MathIsValidNumber(s.mfeCurrency) || !MathIsValidNumber(s.maeCurrency) ||
         !MathIsValidNumber(s.entryBuyScore) || !MathIsValidNumber(s.entrySellScore) ||
         !MathIsValidNumber(s.entryConfidence) ||
         !MathIsValidNumber(s.entrySpreadPts) || !MathIsValidNumber(s.entrySlippagePts) ||
         !MathIsValidNumber(s.afeRiskOfRuinPct) || !MathIsValidNumber(s.afeExpectedValueR) ||
         !MathIsValidNumber(s.afeWinProbability) || !MathIsValidNumber(s.afeRiskMultiplier) ||
         !MathIsValidNumber(s.impactCostPct))
         return(false);
      return(true);
     }

   string Serialize(const SAxPositionLifecycleRecord &r) const
     {
      const SAxPositionState s=r.state;
      string fields[];
      ArrayResize(fields,AX_POSITION_STATE_FIELD_COUNT);
      fields[0]=U(r.positionIdentifier);
      fields[1]=U(r.ticket);
      fields[2]=Encode(r.symbol);
      fields[3]=U(r.magic);
      fields[4]=U(s.ticket);
      fields[5]=IntegerToString((long)s.entryTime);
      fields[6]=N(s.entryPrice);
      fields[7]=IntegerToString((int)s.dir);
      fields[8]=N(s.lots);
      fields[9]=N(s.initialSlPrice);
      fields[10]=N(s.initialTpPrice);
      fields[11]=N(s.originalSlPrice);
      fields[12]=s.breakEvenDone?"1":"0";
      fields[13]=N(s.bestFavorablePrice);
      fields[14]=N(s.mfeCurrency);
      fields[15]=N(s.maeCurrency);
      fields[16]=N(s.entryBuyScore);
      fields[17]=N(s.entrySellScore);
      fields[18]=N(s.entryConfidence);
      fields[19]=IntegerToString((int)s.entryRegime);
      fields[20]=Encode(s.entryReason);
      fields[21]=Encode(s.setupId);
      fields[22]=U(s.entryDealId);
      fields[23]=Encode(s.vwapStateAtEntry);
      fields[24]=Encode(s.vpMacdStateAtEntry);
      fields[25]=Encode(s.orderFlowStateAtEntry);
      fields[26]=Encode(s.structureStateAtEntry);
      fields[27]=Encode(s.liquidityStateAtEntry);
      fields[28]=Encode(s.newsStateAtEntry);
      fields[29]=Encode(s.sessionAtEntry);
      fields[30]=N(s.entrySpreadPts);
      fields[31]=N(s.entrySlippagePts);
      fields[32]=IntegerToString(s.flipSeq);
      fields[33]=s.active?"1":"0";
      fields[34]=IntegerToString(s.modifyFailCount);
      fields[35]=s.partialTaken?"1":"0";
      fields[36]=U(s.lastAccountedDealTicket);
      fields[37]=IntegerToString((int)s.afeCapitalState);
      fields[38]=N(s.afeRiskOfRuinPct);
      fields[39]=N(s.afeExpectedValueR);
      fields[40]=N(s.afeWinProbability);
      fields[41]=N(s.afeRiskMultiplier);
      fields[42]=N(s.impactCostPct);
      fields[43]=s.vwapAlignedAtEntry?"1":"0";
      fields[44]=Encode(s.entryModel);
      string line=fields[0];
      for(int i=1;i<AX_POSITION_STATE_FIELD_COUNT;i++) line+="|"+fields[i];
      return(line);
     }

   bool Deserialize(const string line,SAxPositionLifecycleRecord &r) const
     {
      string f[];
      int fieldCount=StringSplit(line,'|',f);
      if(fieldCount!=44 && fieldCount!=AX_POSITION_STATE_FIELD_COUNT) return(false);
      long id=StringToInteger(f[0]),ticket=StringToInteger(f[1]),magic=StringToInteger(f[3]);
      long stateTicket=StringToInteger(f[4]);
      if(id<=0 || ticket<=0 || magic<=0 || stateTicket<=0) return(false);
      r.positionIdentifier=(ulong)id;
      r.ticket=(ulong)ticket;
      r.symbol=Decode(f[2]);
      r.magic=(ulong)magic;
      SAxPositionState s;
      s.ticket=(ulong)stateTicket;
      s.entryTime=(datetime)StringToInteger(f[5]);
      s.entryPrice=StringToDouble(f[6]);
      s.dir=(ENUM_AX_DIR)StringToInteger(f[7]);
      s.lots=StringToDouble(f[8]);
      s.initialSlPrice=StringToDouble(f[9]);
      s.initialTpPrice=StringToDouble(f[10]);
      s.originalSlPrice=StringToDouble(f[11]);
      s.breakEvenDone=(StringToInteger(f[12])==1);
      s.bestFavorablePrice=StringToDouble(f[13]);
      s.mfeCurrency=StringToDouble(f[14]);
      s.maeCurrency=StringToDouble(f[15]);
      s.entryBuyScore=StringToDouble(f[16]);
      s.entrySellScore=StringToDouble(f[17]);
      s.entryConfidence=StringToDouble(f[18]);
      s.entryRegime=(ENUM_AX_REGIME)StringToInteger(f[19]);
      s.entryReason=Decode(f[20]);
      s.setupId=Decode(f[21]);
      s.entryDealId=(ulong)StringToInteger(f[22]);
      s.vwapStateAtEntry=Decode(f[23]);
      s.vpMacdStateAtEntry=Decode(f[24]);
      s.orderFlowStateAtEntry=Decode(f[25]);
      s.structureStateAtEntry=Decode(f[26]);
      s.liquidityStateAtEntry=Decode(f[27]);
      s.newsStateAtEntry=Decode(f[28]);
      s.sessionAtEntry=Decode(f[29]);
      s.entrySpreadPts=StringToDouble(f[30]);
      s.entrySlippagePts=StringToDouble(f[31]);
      s.flipSeq=(int)StringToInteger(f[32]);
      s.active=(StringToInteger(f[33])==1);
      s.modifyFailCount=(int)StringToInteger(f[34]);
      s.partialTaken=(StringToInteger(f[35])==1);
      s.lastAccountedDealTicket=(ulong)StringToInteger(f[36]);
      s.afeCapitalState=(ENUM_AX_CAPITAL_STATE)StringToInteger(f[37]);
      s.afeRiskOfRuinPct=StringToDouble(f[38]);
      s.afeExpectedValueR=StringToDouble(f[39]);
      s.afeWinProbability=StringToDouble(f[40]);
      s.afeRiskMultiplier=StringToDouble(f[41]);
      s.impactCostPct=StringToDouble(f[42]);
      s.vwapAlignedAtEntry=(StringToInteger(f[43])==1);
      s.entryModel=(fieldCount>=45 && f[44]!="")?Decode(f[44]):"UNKNOWN";
      r.state=s;
      return(ValidState(r));
     }

   bool RewriteFile(void)
     {
      string tempName=m_fileName+".tmp";
      int h=FileOpen(tempName,FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
      if(h==INVALID_HANDLE) { m_persisting=false; m_failureReason="POSITION_STATE_TEMP_OPEN_FAILED"; return(false); }
      bool ok=true;
      string header="AXPOSSTATE|1\r\n";
      if(FileWriteString(h,header)!=(uint)StringLen(header)) ok=false;
      for(int i=0;ok && i<m_count;i++)
        {
         string payload=Serialize(m_records[i])+"\r\n";
         if(FileWriteString(h,payload)!=(uint)StringLen(payload)) ok=false;
        }
      FileFlush(h);
      FileClose(h);
      if(!ok) { m_persisting=false; m_failureReason="POSITION_STATE_SHORT_WRITE"; return(false); }
      ResetLastError();
      if(!FileMove(tempName,0,m_fileName,FILE_REWRITE))
        { m_persisting=false; m_failureReason="POSITION_STATE_REPLACE_FAILED_"+IntegerToString(GetLastError()); return(false); }
      m_persisting=true;
      m_failureReason="";
      return(true);
     }

public:
   CPositionStateRegistry(void)
     {
      m_count=0; m_ready=(ArrayResize(m_records,0)==0);
      m_persisting=false; m_fileName=""; m_failureReason="";
     }

   bool Init(const string eaName,const string symbol,const ulong magic)
     {
      m_fileName=StringFormat("%s_%s_%I64u_%I64u_PositionState_v1.csv",
                              eaName,symbol,(ulong)AccountInfoInteger(ACCOUNT_LOGIN),magic);
      m_count=0;
      if(ArrayResize(m_records,0)!=0) { m_ready=false; m_failureReason="POSITION_STATE_ALLOC_FAILED"; return(false); }
      m_ready=true;
      int h=FileOpen(m_fileName,FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
      if(h==INVALID_HANDLE)
        {
         if(FileIsExist(m_fileName)) { m_persisting=false; m_failureReason="POSITION_STATE_FILE_UNREADABLE"; return(false); }
         return(RewriteFile());
        }
      bool valid=true;
      if(FileIsEnding(h) || FileReadString(h)!="AXPOSSTATE|1") valid=false;
      while(valid && !FileIsEnding(h))
        {
         string line=FileReadString(h);
         if(line=="") continue;
         if(m_count>=AX_POSITION_STATE_MAX_RECORDS) { valid=false; break; }
         SAxPositionLifecycleRecord record;
         if(!Deserialize(line,record) || FindIndex(record.positionIdentifier)>=0)
           { valid=false; break; }
         for(int duplicateIndex=0;duplicateIndex<m_count;duplicateIndex++)
            if(m_records[duplicateIndex].ticket==record.ticket)
              { valid=false; break; }
         if(!valid) break;
         int next=m_count+1;
         if(ArrayResize(m_records,next)!=next) { valid=false; break; }
         m_records[m_count]=record;
         m_count=next;
        }
      FileClose(h);
      if(!valid)
        {
         m_count=0; ArrayResize(m_records,0);
         m_persisting=false; m_failureReason="POSITION_STATE_FILE_CORRUPT_OR_UNSUPPORTED";
         return(false);
        }
      m_persisting=true;
      return(true);
     }

   bool Upsert(const ulong id,const ulong ticket,const string symbol,
               const ulong magic,const SAxPositionState &state)
     {
      if(!m_ready || !m_persisting) return(false);
      SAxPositionLifecycleRecord candidate;
      candidate.positionIdentifier=id; candidate.ticket=ticket;
      candidate.symbol=symbol; candidate.magic=magic; candidate.state=state;
      if(!ValidState(candidate)) { m_failureReason="INVALID_POSITION_STATE_RECORD"; return(false); }
      int index=FindIndex(id);
      for(int ticketIndex=0;ticketIndex<m_count;ticketIndex++)
         if(m_records[ticketIndex].ticket==ticket && ticketIndex!=index)
           { m_failureReason="BROKER_TICKET_OWNERSHIP_CONFLICT"; return(false); }
      if(index<0)
        {
         if(m_count>=AX_POSITION_STATE_MAX_RECORDS) { m_failureReason="POSITION_STATE_CAPACITY_REACHED"; return(false); }
         if(ArrayResize(m_records,m_count+1)!=m_count+1) { m_ready=false; m_failureReason="POSITION_STATE_ALLOCATION_FAILED"; return(false); }
         index=m_count++;
        }
      else if(m_records[index].symbol!=symbol || m_records[index].magic!=magic)
        { m_failureReason="POSITION_IDENTITY_OWNERSHIP_CONFLICT"; return(false); }
      SAxPositionLifecycleRecord previous=m_records[index];
      m_records[index]=candidate;
      if(RewriteFile()) return(true);
      m_records[index]=previous;
      return(false);
     }

   bool FindByIdentifier(const ulong id,SAxPositionLifecycleRecord &out) const
     {
      int i=FindIndex(id);
      if(!m_ready || i<0) return(false);
      out=m_records[i]; return(true);
     }

   bool Remove(const ulong id)
     {
      if(!m_ready || !m_persisting) return(false);
      int index=FindIndex(id);
      if(index<0) return(true);
      SAxPositionLifecycleRecord removed=m_records[index];
      for(int i=index;i<m_count-1;i++) m_records[i]=m_records[i+1];
      m_count--;
      if(ArrayResize(m_records,m_count)!=m_count)
        { m_ready=false; m_failureReason="POSITION_STATE_COMPACTION_FAILED"; return(false); }
      if(RewriteFile()) return(true);
      if(ArrayResize(m_records,m_count+1)==m_count+1)
        {
         for(int i=m_count;i>index;i--) m_records[i]=m_records[i-1];
         m_records[index]=removed; m_count++;
        }
      return(false);
     }

   bool GetAt(const int index,SAxPositionLifecycleRecord &out) const
     { if(!m_ready || index<0 || index>=m_count) return(false); out=m_records[index]; return(true); }
   int Count(void) const { return(m_count); }
   bool IsReady(void) const { return(m_ready); }
   bool IsPersisting(void) const { return(m_persisting); }
   string FailureReason(void) const { return(m_failureReason); }
  };
#endif
