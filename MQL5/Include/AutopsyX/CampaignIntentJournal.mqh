//+------------------------------------------------------------------+
//|                                         CampaignIntentJournal.mqh |
//| Durable pre-order campaign intent ledger.                        |
//| This component never sends orders or changes risk limits.         |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_CAMPAIGNINTENTJOURNAL_MQH
#define AX_CAMPAIGNINTENTJOURNAL_MQH

#define AX_CAMPAIGN_INTENT_SCHEMA 1

struct SAxCampaignIntent
  {
   string   intentId;
   string   campaignId;
   string   signalKey;
   string   symbol;
   string   direction;
   double   requestedVolume;
   double   intendedStop;
   double   riskBudgetMoney;
   datetime createdAt;
   ulong    orderTicket;
   string   status; // PREPARED, BOUND, REJECTED
  };

class CCampaignIntentJournal
  {
private:
   string             m_fileName;
   long               m_login;
   ulong              m_magic;
   uint               m_serverHash;
   string             m_symbol;
   int                m_handle;
   long               m_sequence;
   bool               m_ready;
   SAxCampaignIntent  m_items[];

   uint HashText(const string value) const
     {
      uint hash=2166136261;
      for(int i=0;i<StringLen(value);i++)
        {
         hash^=(uint)StringGetCharacter(value,i);
         hash*=16777619;
        }
      return(hash);
     }

   bool Safe(const string value) const
     {
      return(StringLen(value)>0 && StringFind(value,"|")<0 &&
             StringFind(value,"\r")<0 && StringFind(value,"\n")<0);
     }

   string Header(void) const
     {
      return(StringFormat("AXCI|%d|%I64d|%I64u|%u|%s",
                          AX_CAMPAIGN_INTENT_SCHEMA,m_login,m_magic,m_serverHash,m_symbol));
     }

   int Find(const string intentId) const
     {
      for(int i=0;i<ArraySize(m_items);i++)
         if(m_items[i].intentId==intentId) return(i);
      return(-1);
     }

   string Serialize(const SAxCampaignIntent &item,const string eventType,const long sequence) const
     {
      string payload=StringFormat("AXCI|%d|%I64d|%I64d|%I64d|%u|%s|%s|%s|%s|%s|%s|%s|%s|%I64d|%I64u|%s",
         AX_CAMPAIGN_INTENT_SCHEMA,sequence,m_login,m_magic,m_serverHash,eventType,
         item.intentId,item.campaignId,item.signalKey,item.symbol,item.direction,
         DoubleToString(item.requestedVolume,12),DoubleToString(item.intendedStop,12),
         DoubleToString(item.riskBudgetMoney,8),(long)item.createdAt,item.orderTicket,item.status);
      return(payload+"|"+IntegerToString((long)HashText(payload)));
     }

   bool Parse(const string line,long &sequence,string &eventType,SAxCampaignIntent &item) const
     {
      string f[];
      if(StringSplit(line,'|',f)!=19) return(false);
      if(f[0]!="AXCI" || StringToInteger(f[1])!=AX_CAMPAIGN_INTENT_SCHEMA) return(false);
      if(StringToInteger(f[3])!=m_login || (ulong)StringToInteger(f[4])!=m_magic ||
         (uint)StringToInteger(f[5])!=m_serverHash) return(false);
      int last=StringLen(line)-1,delimiter=-1;
      for(int i=last;i>=0;i--)
         if(StringGetCharacter(line,i)=='|') { delimiter=i; break; }
      if(delimiter<=0 || (uint)StringToInteger(f[18])!=HashText(StringSubstr(line,0,delimiter)))
         return(false);
      sequence=StringToInteger(f[2]);
      eventType=f[6];
      item.intentId=f[7];
      item.campaignId=f[8];
      item.signalKey=f[9];
      item.symbol=f[10];
      item.direction=f[11];
      item.requestedVolume=StringToDouble(f[12]);
      item.intendedStop=StringToDouble(f[13]);
      item.riskBudgetMoney=StringToDouble(f[14]);
      item.createdAt=(datetime)StringToInteger(f[15]);
      item.orderTicket=(ulong)StringToInteger(f[16]);
      item.status=f[17];
      if(sequence<=0 || !Safe(item.intentId) || !Safe(item.campaignId) ||
         !Safe(item.signalKey) || item.symbol!=m_symbol ||
         (item.direction!="BUY" && item.direction!="SELL") ||
         item.requestedVolume<=0.0 || !MathIsValidNumber(item.requestedVolume) ||
         item.intendedStop<=0.0 || !MathIsValidNumber(item.intendedStop) ||
         item.riskBudgetMoney<=0.0 || !MathIsValidNumber(item.riskBudgetMoney) ||
         item.createdAt<=0 ||
         (item.status!="PREPARED" && item.status!="BOUND" && item.status!="REJECTED"))
         return(false);
      return(eventType=="PREPARE" || eventType=="BIND" || eventType=="REJECT");
     }

   bool WriteEvent(const SAxCampaignIntent &item,const string eventType)
     {
      if(!m_ready || m_handle==INVALID_HANDLE) return(false);
      long next=m_sequence+1;
      string line=Serialize(item,eventType,next)+"\r\n";
      FileSeek(m_handle,0,SEEK_END);
      uint expected=(uint)StringLen(line);
      uint written=FileWriteString(m_handle,line);
      FileFlush(m_handle);
      if(written!=expected)
        {
         m_ready=false;
         Print("FLIPDEMON INTENT JOURNAL: short write; new entries blocked.");
         return(false);
        }
      m_sequence=next;
      return(true);
     }

   bool CreateNew(void)
     {
      int h=FileOpen(m_fileName,FILE_WRITE|FILE_TXT|FILE_ANSI);
      if(h==INVALID_HANDLE) return(false);
      string line=Header()+"\r\n";
      uint expected=(uint)StringLen(line),written=FileWriteString(h,line);
      FileFlush(h);
      FileClose(h);
      return(written==expected);
     }

public:
                     CCampaignIntentJournal(void)
     {
      m_fileName="";
      m_login=0;
      m_magic=0;
      m_serverHash=0;
      m_symbol="";
      m_handle=INVALID_HANDLE;
      m_sequence=0;
      m_ready=false;
      ArrayResize(m_items,0);
     }

   bool Init(const ulong magic,const string symbol)
     {
      Deinit();
      ArrayResize(m_items,0);
      m_sequence=0;
      m_login=AccountInfoInteger(ACCOUNT_LOGIN);
      string server=AccountInfoString(ACCOUNT_SERVER);
      if(m_login<=0 || magic==0 || server=="" || symbol=="") return(false);
      m_magic=magic;
      m_symbol=symbol;
      m_serverHash=HashText(server);
      m_fileName=StringFormat("FlipDemon_CampaignIntents_%I64d_%I64u_%u_%s.log",
                              m_login,m_magic,m_serverHash,m_symbol);
      if(!FileIsExist(m_fileName) && !CreateNew()) return(false);
      m_handle=FileOpen(m_fileName,FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
      if(m_handle==INVALID_HANDLE) return(false);
      if(FileIsEnding(m_handle)) { Deinit(); return(false); }
      if(FileReadString(m_handle)!=Header()) { Deinit(); return(false); }

      long previous=0;
      while(!FileIsEnding(m_handle))
        {
         string line=FileReadString(m_handle);
         if(line=="") continue;
         long sequence=0;
         string eventType="";
         SAxCampaignIntent item;
         if(!Parse(line,sequence,eventType,item) || sequence!=previous+1)
           { Deinit(); return(false); }
         int index=Find(item.intentId);
         if(eventType=="PREPARE")
           {
            if(index>=0 || item.status!="PREPARED" || item.orderTicket!=0)
              { Deinit(); return(false); }
            int n=ArraySize(m_items);
            if(ArrayResize(m_items,n+1)!=n+1) { Deinit(); return(false); }
            m_items[n]=item;
           }
         else
           {
            if(index<0) { Deinit(); return(false); }
            SAxCampaignIntent old=m_items[index];
            if(old.campaignId!=item.campaignId || old.signalKey!=item.signalKey ||
               old.symbol!=item.symbol || old.direction!=item.direction ||
               old.requestedVolume!=item.requestedVolume ||
               old.intendedStop!=item.intendedStop ||
               old.riskBudgetMoney!=item.riskBudgetMoney || old.createdAt!=item.createdAt)
              { Deinit(); return(false); }
            if(eventType=="BIND")
              {
               if(item.status!="BOUND" || item.orderTicket==0 ||
                  (old.status=="BOUND" && old.orderTicket!=item.orderTicket))
                 { Deinit(); return(false); }
               m_items[index]=item;
              }
            else if(eventType=="REJECT")
              {
               if(item.status!="REJECTED" || item.orderTicket!=0 || old.status=="BOUND")
                 { Deinit(); return(false); }
               m_items[index]=item;
              }
           }
         previous=sequence;
        }
      m_sequence=previous;
      m_ready=true;
      return(true);
     }

   bool IsReady(void) const { return(m_ready && m_handle!=INVALID_HANDLE); }

   bool CreateIntent(const SAxCampaignIntent &item)
     {
      if(!IsReady() || !Safe(item.intentId) || !Safe(item.campaignId) ||
         !Safe(item.signalKey) || item.symbol!=m_symbol ||
         (item.direction!="BUY" && item.direction!="SELL") ||
         item.requestedVolume<=0.0 || item.intendedStop<=0.0 ||
         item.riskBudgetMoney<=0.0 || item.createdAt<=0 ||
         item.orderTicket!=0 || item.status!="PREPARED" || Find(item.intentId)>=0)
         return(false);
      if(!WriteEvent(item,"PREPARE")) return(false);
      int n=ArraySize(m_items);
      if(ArrayResize(m_items,n+1)!=n+1) { m_ready=false; return(false); }
      m_items[n]=item;
      return(true);
     }

   bool BindOrder(const string intentId,const ulong orderTicket)
     {
      int i=Find(intentId);
      if(!IsReady() || i<0 || orderTicket==0) return(false);
      SAxCampaignIntent item=m_items[i];
      if(item.status=="BOUND") return(item.orderTicket==orderTicket);
      if(item.status!="PREPARED") return(false);
      item.orderTicket=orderTicket;
      item.status="BOUND";
      if(!WriteEvent(item,"BIND")) return(false);
      m_items[i]=item;
      return(true);
     }

   bool RejectIntent(const string intentId)
     {
      int i=Find(intentId);
      if(!IsReady() || i<0) return(false);
      SAxCampaignIntent item=m_items[i];
      if(item.status=="REJECTED") return(true);
      if(item.status!="PREPARED") return(false);
      item.status="REJECTED";
      if(!WriteEvent(item,"REJECT")) return(false);
      m_items[i]=item;
      return(true);
     }

   bool FindByOrderTicket(const ulong orderTicket,SAxCampaignIntent &item) const
     {
      if(orderTicket==0) return(false);
      for(int i=0;i<ArraySize(m_items);i++)
         if(m_items[i].orderTicket==orderTicket && m_items[i].status=="BOUND")
           { item=m_items[i]; return(true); }
      return(false);
     }

   bool HasUnresolvedIntent(void) const
     {
      for(int i=0;i<ArraySize(m_items);i++)
         if(m_items[i].status=="PREPARED") return(true);
      return(false);
     }

   int PreparedIntentCount(void) const
     {
      int count=0;
      for(int i=0;i<ArraySize(m_items);i++)
         if(m_items[i].status=="PREPARED") count++;
      return(count);
     }

   bool FindOnlyPreparedIntent(SAxCampaignIntent &item) const
     {
      int found=-1;
      for(int i=0;i<ArraySize(m_items);i++)
         if(m_items[i].status=="PREPARED")
           {
            if(found>=0) return(false);
            found=i;
           }
      if(found<0) return(false);
      item=m_items[found];
      return(true);
     }

   void Deinit(void)
     {
      if(m_handle!=INVALID_HANDLE) FileClose(m_handle);
      m_handle=INVALID_HANDLE;
      m_ready=false;
     }
  };
#endif // AX_CAMPAIGNINTENTJOURNAL_MQH
