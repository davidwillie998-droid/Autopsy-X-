//+------------------------------------------------------------------+
//|                                              CampaignJournal.mqh |
//| Append-only broker-deal attribution journal for FlipDemon.       |
//| This component does not place trades or calculate live risk.    |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_CAMPAIGNJOURNAL_MQH
#define AX_CAMPAIGNJOURNAL_MQH

#define AX_CAMPAIGN_JOURNAL_SCHEMA 2
#define AX_CAMPAIGN_JOURNAL_FIELD_COUNT 25

struct SAxCampaignDealRecord
  {
   ulong       dealTicket;
   ulong       orderTicket;
   ulong       positionIdentifier;
   string      symbol;
   string      direction;       // BUY or SELL, as recorded by the deal
   string      entryType;       // IN, OUT, INOUT, or OUT_BY
   double      volume;          // actual broker-confirmed deal volume
   double      price;           // actual broker-confirmed deal price
   double      dealStopSnapshot;       // zero means unavailable in broker history
   double      riskAtFillMoney;  // zero means unavailable, never treated as zero live risk
   double      commission;
   double      swap;
   double      fee;
   double      profit;
   datetime    dealTime;
   string      campaignId;      // empty means broker deal is not yet attributed
   string      signalKey;
  };

class CCampaignJournal
  {
private:
   string                 m_fileName;
   long                   m_login;
   ulong                  m_magic;
   string                 m_symbol;
   uint                   m_serverHash;
   int                    m_handle;
   long                   m_sequence;
   bool                   m_ready;
   SAxCampaignDealRecord  m_deals[];

   uint HashText(const string value) const
     {
      uint hash=2166136261;
      int length=StringLen(value);
      for(int i=0;i<length;i++)
        {
         hash^=(uint)StringGetCharacter(value,i);
         hash*=16777619;
        }
      return(hash);
     }

   bool SafeToken(const string value,const bool allowEmpty=false) const
     {
      if(!allowEmpty && StringLen(value)==0) return(false);
      if(StringFind(value,"|")>=0 || StringFind(value,"\r")>=0 ||
         StringFind(value,"\n")>=0) return(false);
      return(true);
     }

   bool ValidRecord(const SAxCampaignDealRecord &record) const
     {
      if(record.dealTicket==0 || record.positionIdentifier==0 ||
         record.orderTicket==0 || !SafeToken(record.symbol) ||
         !SafeToken(record.direction) || !SafeToken(record.entryType) ||
         !SafeToken(record.campaignId,true) || !SafeToken(record.signalKey,true) || record.symbol!=m_symbol)
         return(false);
      if(record.direction!="BUY" && record.direction!="SELL") return(false);
      if(record.entryType!="IN" && record.entryType!="OUT" &&
         record.entryType!="INOUT" && record.entryType!="OUT_BY") return(false);
      if(!MathIsValidNumber(record.volume) || record.volume<=0.0 ||
         !MathIsValidNumber(record.price) || record.price<=0.0 ||
         !MathIsValidNumber(record.dealStopSnapshot) || record.dealStopSnapshot<0.0 ||
         !MathIsValidNumber(record.riskAtFillMoney) || record.riskAtFillMoney<0.0 ||
         !MathIsValidNumber(record.commission) || !MathIsValidNumber(record.swap) ||
         !MathIsValidNumber(record.fee) || !MathIsValidNumber(record.profit) ||
         record.dealTime<=0)
         return(false);
      return(true);
     }

   bool SameDeal(const SAxCampaignDealRecord &a,const SAxCampaignDealRecord &b) const
     {
      return(a.dealTicket==b.dealTicket &&
             a.orderTicket==b.orderTicket &&
             a.positionIdentifier==b.positionIdentifier &&
             a.symbol==b.symbol && a.direction==b.direction &&
             a.entryType==b.entryType &&
             MathAbs(a.volume-b.volume)<0.00000001 &&
             MathAbs(a.price-b.price)<0.00000001 &&
             MathAbs(a.dealStopSnapshot-b.dealStopSnapshot)<0.00000001 &&
             MathAbs(a.riskAtFillMoney-b.riskAtFillMoney)<0.00000001 &&
             MathAbs(a.commission-b.commission)<0.00000001 &&
             MathAbs(a.swap-b.swap)<0.00000001 &&
             MathAbs(a.fee-b.fee)<0.00000001 &&
             MathAbs(a.profit-b.profit)<0.00000001 &&
             a.dealTime==b.dealTime &&
             a.campaignId==b.campaignId && a.signalKey==b.signalKey);
     }

   int FindDealIndex(const ulong dealTicket) const
     {
      for(int i=0;i<ArraySize(m_deals);i++)
         if(m_deals[i].dealTicket==dealTicket) return(i);
      return(-1);
     }

   string Header(void) const
     {
      return(StringFormat("AXCJ|%d|%I64d|%I64u|%u|%s",
                          AX_CAMPAIGN_JOURNAL_SCHEMA,m_login,m_magic,m_serverHash,m_symbol));
     }

   string Serialize(const SAxCampaignDealRecord &r,const long sequence) const
     {
      string payload=StringFormat(
         "AXCJ|%d|%I64d|%I64d|%I64u|%u|DEAL|%I64u|%I64u|%I64u|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%I64d|%s|%s",
         AX_CAMPAIGN_JOURNAL_SCHEMA,sequence,m_login,m_magic,m_serverHash,
         r.dealTicket,r.orderTicket,r.positionIdentifier,r.symbol,r.direction,r.entryType,
         DoubleToString(r.volume,12),DoubleToString(r.price,12),
         DoubleToString(r.dealStopSnapshot,12),DoubleToString(r.riskAtFillMoney,8),
         DoubleToString(r.commission,8),DoubleToString(r.swap,8),
         DoubleToString(r.fee,8),DoubleToString(r.profit,8),
         (long)r.dealTime,r.campaignId,r.signalKey);
      return(payload+"|"+IntegerToString((long)HashText(payload)));
     }

   bool ParseHeader(const string line) const
     {
      string fields[];
      if(StringSplit(line,'|',fields)!=6) return(false);
      if(fields[0]!="AXCJ" || StringToInteger(fields[1])!=AX_CAMPAIGN_JOURNAL_SCHEMA)
         return(false);
      if(StringToInteger(fields[2])!=m_login ||
         (ulong)StringToInteger(fields[3])!=m_magic ||
         (uint)StringToInteger(fields[4])!=m_serverHash || fields[5]!=m_symbol)
         return(false);
      return(true);
     }

   bool ParseDeal(const string line,long &sequence,SAxCampaignDealRecord &r) const
     {
      string fields[];
      if(StringSplit(line,'|',fields)!=AX_CAMPAIGN_JOURNAL_FIELD_COUNT) return(false);
      if(fields[0]!="AXCJ" || StringToInteger(fields[1])!=AX_CAMPAIGN_JOURNAL_SCHEMA ||
         fields[6]!="DEAL") return(false);
      if(StringToInteger(fields[3])!=m_login ||
         (ulong)StringToInteger(fields[4])!=m_magic ||
         (uint)StringToInteger(fields[5])!=m_serverHash) return(false);

      int checksumDelimiter=-1;
      for(int i=StringLen(line)-1;i>=0;i--)
         if(StringGetCharacter(line,i)=='|') { checksumDelimiter=i; break; }
      if(checksumDelimiter<=0) return(false);
      string payload=StringSubstr(line,0,checksumDelimiter);
      if((uint)StringToInteger(fields[24])!=HashText(payload)) return(false);

      sequence=StringToInteger(fields[2]);
      r.dealTicket=(ulong)StringToInteger(fields[7]);
      r.orderTicket=(ulong)StringToInteger(fields[8]);
      r.positionIdentifier=(ulong)StringToInteger(fields[9]);
      r.symbol=fields[10];
      r.direction=fields[11];
      r.entryType=fields[12];
      r.volume=StringToDouble(fields[13]);
      r.price=StringToDouble(fields[14]);
      r.dealStopSnapshot=StringToDouble(fields[15]);
      r.riskAtFillMoney=StringToDouble(fields[16]);
      r.commission=StringToDouble(fields[17]);
      r.swap=StringToDouble(fields[18]);
      r.fee=StringToDouble(fields[19]);
      r.profit=StringToDouble(fields[20]);
      r.dealTime=(datetime)StringToInteger(fields[21]);
      r.campaignId=fields[22];
      r.signalKey=fields[23];
      return(sequence>0 && ValidRecord(r));
     }

   bool CreateNewFile(void)
     {
      int createHandle=FileOpen(m_fileName,FILE_WRITE|FILE_TXT|FILE_ANSI);
      if(createHandle==INVALID_HANDLE) return(false);
      string header=Header()+"\r\n";
      uint expected=(uint)StringLen(header);
      uint written=FileWriteString(createHandle,header);
      FileFlush(createHandle);
      FileClose(createHandle);
      return(written==expected);
     }

public:
                     CCampaignJournal(void)
     {
      m_fileName="";
      m_login=0;
      m_magic=0;
      m_serverHash=0;
      m_handle=INVALID_HANDLE;
      m_sequence=0;
      m_ready=false;
      ArrayResize(m_deals,0);
     }

   bool              Init(const ulong magic,const string symbol)
     {
      Deinit();
      ArrayResize(m_deals,0);
      m_sequence=0;
      m_login=AccountInfoInteger(ACCOUNT_LOGIN);
      string server=AccountInfoString(ACCOUNT_SERVER);
      if(m_login<=0 || magic==0 || StringLen(server)==0 || symbol=="") return(false);
      m_magic=magic;
      m_symbol=symbol;
      m_serverHash=HashText(server);
      m_fileName=StringFormat("FlipDemon_CampaignJournal_%I64d_%I64u_%u_%s.log",
                              m_login,m_magic,m_serverHash,m_symbol);

      if(!FileIsExist(m_fileName) && !CreateNewFile())
        {
         PrintFormat("FLIPDEMON CAMPAIGN JOURNAL: could not create %s (error=%d)",
                     m_fileName,GetLastError());
         return(false);
        }

      // Keep the file handle open. FILE_SHARE_READ permits inspection while preventing
      // another writer from silently racing this instance's sequence numbers.
      m_handle=FileOpen(m_fileName,FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
      if(m_handle==INVALID_HANDLE)
        {
         PrintFormat("FLIPDEMON CAMPAIGN JOURNAL: exclusive writer open failed %s (error=%d)",
                     m_fileName,GetLastError());
         return(false);
        }

      if(FileIsEnding(m_handle))
        {
         Deinit();
         return(false);
        }
      string header=FileReadString(m_handle);
      if(!ParseHeader(header))
        {
         PrintFormat("FLIPDEMON CAMPAIGN JOURNAL: header/account identity invalid in %s",m_fileName);
         Deinit();
         return(false);
        }

      long previousSequence=0;
      while(!FileIsEnding(m_handle))
        {
         string line=FileReadString(m_handle);
         if(StringLen(line)==0) continue;
         SAxCampaignDealRecord record;
         long sequence=0;
         if(!ParseDeal(line,sequence,record) || sequence!=previousSequence+1)
           {
            PrintFormat("FLIPDEMON CAMPAIGN JOURNAL: corrupt or non-monotonic row in %s; entries blocked",
                        m_fileName);
            Deinit();
            return(false);
           }
         int existing=FindDealIndex(record.dealTicket);
         if(existing>=0 && !SameDeal(m_deals[existing],record))
           {
            PrintFormat("FLIPDEMON CAMPAIGN JOURNAL: conflicting duplicate deal %I64u",record.dealTicket);
            Deinit();
            return(false);
           }
         if(existing<0)
           {
            int next=ArraySize(m_deals);
            if(ArrayResize(m_deals,next+1)!=next+1)
              {
               Deinit();
               return(false);
              }
            m_deals[next]=record;
           }
         previousSequence=sequence;
        }

      m_sequence=previousSequence;
      FileSeek(m_handle,0,SEEK_END);
      m_ready=true;
      return(true);
     }

   void              Deinit(void)
     {
      if(m_handle!=INVALID_HANDLE) FileClose(m_handle);
      m_handle=INVALID_HANDLE;
      m_ready=false;
     }

   bool              IsReady(void) const { return(m_ready); }
   long              LastSequence(void) const { return(m_sequence); }
   int               DealCount(void) const { return(ArraySize(m_deals)); }
   string            FileName(void) const { return(m_fileName); }

   bool              FindDeal(const ulong dealTicket,SAxCampaignDealRecord &out) const
     {
      int index=FindDealIndex(dealTicket);
      if(index<0) return(false);
      out=m_deals[index];
      return(true);
     }

   bool              HasAttributedPosition(const ulong positionIdentifier) const
     {
      if(positionIdentifier==0) return(false);
      for(int i=0;i<ArraySize(m_deals);i++)
         if(m_deals[i].positionIdentifier==positionIdentifier &&
            (m_deals[i].entryType=="IN" || m_deals[i].entryType=="INOUT") &&
            m_deals[i].campaignId!="")
            return(true);
      return(false);
     }

   bool              AppendDeal(const SAxCampaignDealRecord &record)
     {
      if(!m_ready || m_handle==INVALID_HANDLE || !ValidRecord(record)) return(false);
      int existing=FindDealIndex(record.dealTicket);
      if(existing>=0) return(SameDeal(m_deals[existing],record));

      int oldSize=ArraySize(m_deals);
      if(ArrayResize(m_deals,oldSize+1)!=oldSize+1) return(false);

      long nextSequence=m_sequence+1;
      string line=Serialize(record,nextSequence)+"\r\n";
      FileSeek(m_handle,0,SEEK_END);
      uint expected=(uint)StringLen(line);
      uint written=FileWriteString(m_handle,line);
      FileFlush(m_handle);
      if(written!=expected)
        {
         ArrayResize(m_deals,oldSize);
         m_ready=false;
         PrintFormat("FLIPDEMON CAMPAIGN JOURNAL: short write for deal %I64u; entries blocked",
                     record.dealTicket);
         return(false);
        }

      m_deals[oldSize]=record;
      m_sequence=nextSequence;
      return(true);
     }
  };
//+------------------------------------------------------------------+
#endif // AX_CAMPAIGNJOURNAL_MQH
