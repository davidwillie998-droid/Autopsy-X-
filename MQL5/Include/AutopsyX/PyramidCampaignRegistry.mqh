//+------------------------------------------------------------------+
//|                                           PyramidCampaignRegistry.mqh |
//| Persistent, broker-position-identified pyramid campaign state.   |
//| Deal history remains the source of truth for individual tier fills.|
//+------------------------------------------------------------------+
#property strict
#ifndef AX_PYRAMIDCAMPAIGNREGISTRY_MQH
#define AX_PYRAMIDCAMPAIGNREGISTRY_MQH

#include "Defs.mqh"

#define AX_PYRAMID_CAMPAIGN_MAX 32
#define AX_PYRAMID_CAMPAIGN_FIELD_COUNT 17
#define AX_PYRAMID_CAMPAIGN_MAX_TIERS 10

struct SAxPyramidCampaignRecord
  {
   ulong       ticket;                 // current broker position ticket, refreshed after reconciliation
   ulong       positionIdentifier;     // stable broker identity, primary key
   ulong       lastTierDealTicket;     // last confirmed entry deal, not an assumed order ticket
   string      symbol;
   ENUM_AX_DIR dir;
   int         tierCount;
   double      baseTierLots;
   double      lastTierFillPrice;
   double      lastTierFilledLots;
   double      peakBasketPnl;          // account-currency net campaign peak
   double      basketTrailStopPnl;     // account-currency trailing floor
   datetime    campaignStartTime;
   datetime    lastTriggerBarTime;     // prevents repeated adds on the same completed bar
   bool        active;
  };

class CPyramidCampaignRegistry
  {
private:
   string                    m_fileName;
   long                      m_accountLogin;
   ulong                     m_magic;
   string                    m_symbol;
   SAxPyramidCampaignRecord  m_records[AX_PYRAMID_CAMPAIGN_MAX];
   int                       m_count;
   bool                      m_persistOk;

   int FindIndex(const ulong positionIdentifier) const
     {
      if(positionIdentifier==0) return(-1);
      for(int i=0;i<m_count;i++)
         if(m_records[i].positionIdentifier==positionIdentifier) return(i);
      return(-1);
     }

   bool ValidateRecord(const SAxPyramidCampaignRecord &record) const
     {
      if(record.ticket==0 || record.positionIdentifier==0 || record.symbol!=m_symbol ||
         (record.dir!=AX_DIR_BUY && record.dir!=AX_DIR_SELL) ||
         record.tierCount<1 || record.tierCount>AX_PYRAMID_CAMPAIGN_MAX_TIERS ||
         record.baseTierLots<=0.0 || record.lastTierFillPrice<=0.0 ||
         record.lastTierFilledLots<=0.0 || record.campaignStartTime<=0 ||
         record.lastTriggerBarTime<0 ||
         !MathIsValidNumber(record.baseTierLots) ||
         !MathIsValidNumber(record.lastTierFillPrice) ||
         !MathIsValidNumber(record.lastTierFilledLots) ||
         !MathIsValidNumber(record.peakBasketPnl) ||
         !MathIsValidNumber(record.basketTrailStopPnl))
         return(false);
      return(true);
     }

   string Serialize(const SAxPyramidCampaignRecord &record) const
     {
      return(StringFormat("AXPC1|%I64d|%I64u|%s|%I64u|%I64u|%d|%d|%I64u|%.16f|%.16f|%.16f|%.16f|%.16f|%s|%s|%d",
                          m_accountLogin,m_magic,record.symbol,
                          record.positionIdentifier,record.ticket,(int)record.dir,
                          record.tierCount,record.lastTierDealTicket,
                          record.baseTierLots,record.lastTierFillPrice,
                          record.lastTierFilledLots,record.peakBasketPnl,
                          record.basketTrailStopPnl,
                          TimeToString(record.campaignStartTime,TIME_DATE|TIME_SECONDS),
                          TimeToString(record.lastTriggerBarTime,TIME_DATE|TIME_SECONDS),
                          record.active?1:0));
     }

   bool ParseRecord(const string line,SAxPyramidCampaignRecord &recordOut) const
     {
      string fields[];
      if(StringSplit(line,'|',fields)!=AX_PYRAMID_CAMPAIGN_FIELD_COUNT) return(false);
      if(fields[0]!="AXPC1" ||
         StringToInteger(fields[1])!=m_accountLogin ||
         (ulong)StringToInteger(fields[2])!=m_magic ||
         fields[3]!=m_symbol)
         return(false);

      long positionId=StringToInteger(fields[4]);
      long ticket=StringToInteger(fields[5]);
      long dir=StringToInteger(fields[6]);
      long tiers=StringToInteger(fields[7]);
      long lastDeal=StringToInteger(fields[8]);
      long active=StringToInteger(fields[16]);
      if(positionId<=0 || ticket<=0 || lastDeal<0 ||
         (dir!=(long)AX_DIR_BUY && dir!=(long)AX_DIR_SELL) ||
         tiers<1 || tiers>AX_PYRAMID_CAMPAIGN_MAX_TIERS ||
         (active!=0 && active!=1))
         return(false);

      recordOut.positionIdentifier=(ulong)positionId;
      recordOut.ticket=(ulong)ticket;
      recordOut.lastTierDealTicket=(ulong)lastDeal;
      recordOut.symbol=fields[3];
      recordOut.dir=(ENUM_AX_DIR)dir;
      recordOut.tierCount=(int)tiers;
      recordOut.baseTierLots=StringToDouble(fields[9]);
      recordOut.lastTierFillPrice=StringToDouble(fields[10]);
      recordOut.lastTierFilledLots=StringToDouble(fields[11]);
      recordOut.peakBasketPnl=StringToDouble(fields[12]);
      recordOut.basketTrailStopPnl=StringToDouble(fields[13]);
      recordOut.campaignStartTime=StringToTime(fields[14]);
      recordOut.lastTriggerBarTime=StringToTime(fields[15]);
      recordOut.active=(active==1);
      return(ValidateRecord(recordOut));
     }

   bool RewriteFile(void)
     {
      string tempName=m_fileName+".tmp";
      int handle=FileOpen(tempName,FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
      if(handle==INVALID_HANDLE)
        {
         m_persistOk=false;
         PrintFormat("FLIPDEMON PYRAMID ERROR: cannot open staged campaign registry (error=%d).",GetLastError());
         return(false);
        }

      bool writeOk=true;
      for(int i=0;i<m_count;i++)
        {
         string payload=Serialize(m_records[i])+"\r\n";
         uint expected=(uint)StringLen(payload);
         uint written=FileWriteString(handle,payload);
         if(written!=expected)
           {
            writeOk=false;
            PrintFormat("FLIPDEMON PYRAMID ERROR: short campaign registry write at row %d.",i);
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
         PrintFormat("FLIPDEMON PYRAMID ERROR: staged campaign registry replacement failed (error=%d).",GetLastError());
         return(false);
        }
      m_persistOk=true;
      return(true);
     }

public:
   CPyramidCampaignRegistry(void)
     {
      m_accountLogin=0;
      m_magic=0;
      m_symbol="";
      m_count=0;
      m_persistOk=false;
     }

   bool Init(const string eaName,const string symbol,const ulong magic)
     {
      m_accountLogin=AccountInfoInteger(ACCOUNT_LOGIN);
      m_magic=magic;
      m_symbol=symbol;
      m_count=0;
      if(StringLen(eaName)==0 || StringLen(symbol)==0 || m_accountLogin<=0 || magic==0)
        {
         m_persistOk=false;
         Print("FLIPDEMON PYRAMID ERROR: invalid campaign registry identity.");
         return(false);
        }

      m_fileName=StringFormat("%s_%s_%I64d_%I64u_PyramidCampaigns_v1.csv",
                              eaName,symbol,m_accountLogin,m_magic);
      int handle=FileOpen(m_fileName,FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
      if(handle==INVALID_HANDLE)
        {
         if(FileIsExist(m_fileName))
           {
            m_persistOk=false;
            PrintFormat("FLIPDEMON PYRAMID ERROR: existing campaign registry is unreadable (%s); refusing to overwrite it.",m_fileName);
            return(false);
           }
         return(RewriteFile());
        }

      bool valid=true;
      while(!FileIsEnding(handle))
        {
         string line=FileReadString(handle);
         if(StringLen(line)==0) continue;
         if(m_count>=AX_PYRAMID_CAMPAIGN_MAX)
           {
            valid=false;
            Print("FLIPDEMON PYRAMID ERROR: campaign registry capacity exceeded; refusing to truncate.");
            break;
           }
         SAxPyramidCampaignRecord parsed;
         if(!ParseRecord(line,parsed))
           {
            valid=false;
            Print("FLIPDEMON PYRAMID ERROR: malformed or mismatched campaign registry row; entries must remain blocked.");
            break;
           }
         for(int i=0;i<m_count;i++)
            if(m_records[i].positionIdentifier==parsed.positionIdentifier)
              {
               valid=false;
               Print("FLIPDEMON PYRAMID ERROR: duplicate position identifier in campaign registry.");
               break;
              }
         if(!valid) break;
         m_records[m_count]=parsed;
         m_count++;
        }
      FileClose(handle);
      if(!valid)
        {
         m_count=0;
         m_persistOk=false;
         return(false);
        }
      return(RewriteFile());
     }

   void Deinit(void) {}
   bool IsPersisting(void) const { return(m_persistOk); }
   int Count(void) const { return(m_count); }

   bool Find(const ulong positionIdentifier,SAxPyramidCampaignRecord &recordOut) const
     {
      int index=FindIndex(positionIdentifier);
      if(index<0) return(false);
      recordOut=m_records[index];
      return(true);
     }

   // A confirmed broker fill updates the existing campaign row. Callers must pass
   // actual filled volume, actual fill price and the broker's DEAL ticket.
   bool Save(const SAxPyramidCampaignRecord &record)
     {
      if(!ValidateRecord(record))
        {
         m_persistOk=false;
         Print("FLIPDEMON PYRAMID ERROR: invalid campaign state rejected.");
         return(false);
        }

      int index=FindIndex(record.positionIdentifier);
      if(index>=0)
        {
         if(m_records[index].symbol!=record.symbol || m_records[index].dir!=record.dir ||
            !m_records[index].active)
           {
            m_persistOk=false;
            Print("FLIPDEMON PYRAMID ERROR: campaign identity/direction conflict; refusing overwrite.");
            return(false);
           }
         SAxPyramidCampaignRecord previous=m_records[index];
         if(record.tierCount<previous.tierCount ||
            record.lastTierDealTicket<previous.lastTierDealTicket)
           {
            m_persistOk=false;
            Print("FLIPDEMON PYRAMID ERROR: campaign tier/deal sequence regressed; refusing overwrite.");
            return(false);
           }
         m_records[index]=record;
         if(RewriteFile()) return(true);
         m_records[index]=previous;
         return(false);
        }

      if(m_count>=AX_PYRAMID_CAMPAIGN_MAX)
        {
         m_persistOk=false;
         Print("FLIPDEMON PYRAMID ERROR: campaign registry full; refusing new campaign.");
         return(false);
        }
      m_records[m_count]=record;
      m_count++;
      if(RewriteFile()) return(true);
      m_count--;
      return(false);
     }

   bool Remove(const ulong positionIdentifier)
     {
      int index=FindIndex(positionIdentifier);
      if(index<0) return(true);
      SAxPyramidCampaignRecord removed=m_records[index];
      for(int i=index;i<m_count-1;i++) m_records[i]=m_records[i+1];
      m_count--;
      if(RewriteFile()) return(true);
      for(int i=m_count;i>index;i--) m_records[i]=m_records[i-1];
      m_records[index]=removed;
      m_count++;
      return(false);
     }
  };

#endif // AX_PYRAMIDCAMPAIGNREGISTRY_MQH
