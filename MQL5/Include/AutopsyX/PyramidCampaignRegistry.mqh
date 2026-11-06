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

   // Rebuild one live campaign from broker deal history. Entry deals are grouped by
   // DEAL_ORDER so partial fills of one request remain one tier. Any reversal,
   // foreign entry, missing order link, or volume mismatch fails closed.
   bool ReconcileLivePosition(const ulong ticket,bool &recoveredOut)
     {
      recoveredOut=false;
      if(ticket==0 || !PositionSelectByTicket(ticket)) return(false);
      if(PositionGetString(POSITION_SYMBOL)!=m_symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC)!=m_magic)
         return(false);

      ulong positionId=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
      long liveType=PositionGetInteger(POSITION_TYPE);
      ENUM_AX_DIR liveDir=(liveType==POSITION_TYPE_BUY)?AX_DIR_BUY:AX_DIR_SELL;
      double liveVolume=PositionGetDouble(POSITION_VOLUME);
      double volumeStep=SymbolInfoDouble(m_symbol,SYMBOL_VOLUME_STEP);
      double tolerance=MathMax(volumeStep*0.51,0.00000001);
      if(positionId==0 || liveVolume<=0.0 || volumeStep<=0.0 ||
         (liveDir!=AX_DIR_BUY && liveDir!=AX_DIR_SELL))
         return(false);
      if(!HistorySelectByPosition((long)positionId)) return(false);

      ulong orderIds[AX_PYRAMID_CAMPAIGN_MAX_TIERS];
      double orderVolumes[AX_PYRAMID_CAMPAIGN_MAX_TIERS];
      double orderPriceValues[AX_PYRAMID_CAMPAIGN_MAX_TIERS];
      ArrayInitialize(orderIds,0);
      ArrayInitialize(orderVolumes,0.0);
      ArrayInitialize(orderPriceValues,0.0);
      int tierCount=0;
      int lastOrderIndex=-1;
      ulong lastDealTicket=0;
      datetime campaignStart=0;
      double expectedRemaining=0.0;

      int deals=HistoryDealsTotal();
      for(int i=0;i<deals;i++)
        {
         ulong deal=HistoryDealGetTicket(i);
         if(deal==0) return(false);
         long entry=HistoryDealGetInteger(deal,DEAL_ENTRY);
         if(entry!=DEAL_ENTRY_IN && entry!=DEAL_ENTRY_OUT &&
            entry!=DEAL_ENTRY_OUT_BY && entry!=DEAL_ENTRY_INOUT)
            continue;
         if(HistoryDealGetString(deal,DEAL_SYMBOL)!=m_symbol) return(false);
         double volume=HistoryDealGetDouble(deal,DEAL_VOLUME);
         if(volume<=0.0 || !MathIsValidNumber(volume)) return(false);

         if(entry==DEAL_ENTRY_INOUT)
           {
            // Netting reversal destroys the old campaign's direction identity.
            return(false);
           }
         if(entry==DEAL_ENTRY_IN)
           {
            if((ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)!=m_magic)
               return(false);
            long dealType=HistoryDealGetInteger(deal,DEAL_TYPE);
            if((liveDir==AX_DIR_BUY && dealType!=DEAL_TYPE_BUY) ||
               (liveDir==AX_DIR_SELL && dealType!=DEAL_TYPE_SELL))
               return(false);
            ulong order=(ulong)HistoryDealGetInteger(deal,DEAL_ORDER);
            double price=HistoryDealGetDouble(deal,DEAL_PRICE);
            datetime dealTime=(datetime)HistoryDealGetInteger(deal,DEAL_TIME);
            if(order==0 || price<=0.0 || dealTime<=0 ||
               !MathIsValidNumber(price))
               return(false);

            int orderIndex=-1;
            for(int j=0;j<tierCount;j++)
               if(orderIds[j]==order) { orderIndex=j; break; }
            if(orderIndex<0)
              {
               if(tierCount>=AX_PYRAMID_CAMPAIGN_MAX_TIERS) return(false);
               orderIndex=tierCount;
               orderIds[orderIndex]=order;
               tierCount++;
              }
            orderVolumes[orderIndex]+=volume;
            orderPriceValues[orderIndex]+=price*volume;
            expectedRemaining+=volume;
            if(campaignStart==0 || dealTime<campaignStart) campaignStart=dealTime;
            if(deal>lastDealTicket)
              {
               lastDealTicket=deal;
               lastOrderIndex=orderIndex;
              }
           }
         else if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY)
           {
            expectedRemaining-=volume;
            if(expectedRemaining < -tolerance) return(false);
           }
        }

      if(tierCount<1 || lastOrderIndex<0 || lastDealTicket==0 ||
         MathAbs(expectedRemaining-liveVolume)>tolerance)
         return(false);

      SAxPyramidCampaignRecord record;
      bool existed=Find(positionId,record);
      if(existed)
        {
         if(!record.active || record.symbol!=m_symbol || record.dir!=liveDir ||
            record.lastTierDealTicket>lastDealTicket)
            return(false);
        }
      else
        {
         record.ticket=0;
         record.positionIdentifier=0;
         record.lastTierDealTicket=0;
         record.symbol=m_symbol;
         record.dir=liveDir;
         record.tierCount=0;
         record.baseTierLots=0.0;
         record.lastTierFillPrice=0.0;
         record.lastTierFilledLots=0.0;
         record.peakBasketPnl=0.0;
         record.basketTrailStopPnl=0.0;
         record.campaignStartTime=0;
         record.lastTriggerBarTime=0;
         record.active=false;
        }

      record.ticket=ticket;
      record.positionIdentifier=positionId;
      record.lastTierDealTicket=lastDealTicket;
      record.symbol=m_symbol;
      record.dir=liveDir;
      record.tierCount=tierCount;
      record.baseTierLots=orderVolumes[0];
      record.lastTierFillPrice=orderPriceValues[lastOrderIndex]/orderVolumes[lastOrderIndex];
      record.lastTierFilledLots=orderVolumes[lastOrderIndex];
      record.campaignStartTime=campaignStart;
      record.active=true;
      if(!Save(record)) return(false);
      recoveredOut=true;
      return(true);
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
