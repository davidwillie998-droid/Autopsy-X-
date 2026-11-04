//+------------------------------------------------------------------+
//|                                  CampaignHistoryReconciler.mqh   |
//| Replays broker-confirmed deals into the durable campaign journal|
//+------------------------------------------------------------------+
#property strict
#ifndef AX_CAMPAIGNHISTORYRECONCILER_MQH
#define AX_CAMPAIGNHISTORYRECONCILER_MQH

#include "CampaignJournal.mqh"
#include "CampaignIntentJournal.mqh"
#include "RestartRecovery.mqh"

class CCampaignHistoryReconciler
  {
public:
   // Replays broker history for this EA magic. It deliberately does not infer
   // campaign IDs from comments. Unattributed records remain unresolved and
   // must block campaign additions until a separate trusted attribution step.
   bool Replay(const datetime fromTime,const datetime toTime,
               const ulong magic,const string symbol,
               CRestartRecovery &recovery,CCampaignJournal &journal,
               CCampaignIntentJournal &intentJournal,
               int &appended,int &alreadyKnown,int &unattributed,
               string &error) const
     {
      appended=0;
      alreadyKnown=0;
      unattributed=0;
      error="";

      if(magic==0 || symbol=="" || fromTime<0 || toTime<fromTime)
        {
         error="INVALID_REPLAY_RANGE_OR_MAGIC";
         return(false);
        }
      if(!journal.IsReady())
        {
         error="CAMPAIGN_JOURNAL_NOT_READY";
         return(false);
        }
      ResetLastError();
      if(!HistorySelect(fromTime,toTime))
        {
         error=StringFormat("HISTORY_SELECT_FAILED_%d",GetLastError());
         return(false);
        }

      // A terminal crash can occur after the broker accepts the market order
      // but before the caller appends its BIND event. Recover only one outstanding
      // intent and only from a unique exact broker-history order match.
      int preparedCount=intentJournal.PreparedIntentCount();
      if(preparedCount>1)
        {
         error="MULTIPLE_UNRESOLVED_CAMPAIGN_INTENTS";
         return(false);
        }
      if(preparedCount==1)
        {
         SAxCampaignIntent pendingIntent;
         if(!intentJournal.FindOnlyPreparedIntent(pendingIntent))
           {
            error="UNRESOLVED_CAMPAIGN_INTENT_LOOKUP_FAILED";
            return(false);
           }
         double volumeStep=SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
         double tickSize=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_SIZE);
         if(volumeStep<=0.0 || tickSize<=0.0)
           {
            error="BROKER_ORDER_MATCH_REQUIRES_VALID_VOLUME_STEP_AND_TICK_SIZE";
            return(false);
           }
         int matches=0;
         ulong matchedOrder=0;
         for(int o=0;o<HistoryOrdersTotal();o++)
           {
            ulong orderTicket=HistoryOrderGetTicket(o);
            if(orderTicket==0) continue;
            if((ulong)HistoryOrderGetInteger(orderTicket,ORDER_MAGIC)!=magic ||
               HistoryOrderGetString(orderTicket,ORDER_SYMBOL)!=symbol) continue;
            ENUM_ORDER_TYPE orderType=(ENUM_ORDER_TYPE)HistoryOrderGetInteger(orderTicket,ORDER_TYPE);
            string direction=(orderType==ORDER_TYPE_BUY)?"BUY":
                             (orderType==ORDER_TYPE_SELL)?"SELL":"";
            if(direction!=pendingIntent.direction) continue;
            datetime setupTime=(datetime)HistoryOrderGetInteger(orderTicket,ORDER_TIME_SETUP);
            if(setupTime<(pendingIntent.createdAt-5)) continue;
            double orderVolume=HistoryOrderGetDouble(orderTicket,ORDER_VOLUME_INITIAL);
            double orderStop=HistoryOrderGetDouble(orderTicket,ORDER_SL);
            if(MathAbs(orderVolume-pendingIntent.requestedVolume)>MathMax(volumeStep*0.5,0.00000001) ||
               MathAbs(orderStop-pendingIntent.intendedStop)>MathMax(tickSize*0.5,0.00000001))
               continue;
            matches++;
            matchedOrder=orderTicket;
           }
         if(matches>1)
           {
            error="AMBIGUOUS_BROKER_ORDER_MATCH_FOR_PREPARED_INTENT";
            return(false);
           }
         if(matches==1 && !intentJournal.BindOrder(pendingIntent.intentId,matchedOrder))
           {
            error="PREPARED_INTENT_ORDER_BIND_FAILED";
            return(false);
           }
         // Zero matches leaves the PREPARED intent untouched. OnInit will keep
         // entries disabled rather than assume that the broker never accepted it.
        }

      int total=HistoryDealsTotal();
      for(int i=0;i<total;i++)
        {
         ulong ticket=HistoryDealGetTicket(i);
         if(ticket==0)
           {
            error=StringFormat("HISTORY_DEAL_TICKET_UNAVAILABLE_INDEX_%d",i);
            return(false);
           }

         ulong dealMagic=(ulong)HistoryDealGetInteger(ticket,DEAL_MAGIC);
         if(dealMagic!=magic) continue;
         if(HistoryDealGetString(ticket,DEAL_SYMBOL)!=symbol) continue;

         long dealType=HistoryDealGetInteger(ticket,DEAL_TYPE);
         if(dealType!=DEAL_TYPE_BUY && dealType!=DEAL_TYPE_SELL)
            continue; // balance, credit, charge and non-directional records

         SAxCampaignDealRecord record;
         record.dealTicket=ticket;
         record.orderTicket=(ulong)HistoryDealGetInteger(ticket,DEAL_ORDER);
         record.positionIdentifier=(ulong)HistoryDealGetInteger(ticket,DEAL_POSITION_ID);
         record.symbol=HistoryDealGetString(ticket,DEAL_SYMBOL);
         record.direction=(dealType==DEAL_TYPE_BUY)?"BUY":"SELL";

         long entry=HistoryDealGetInteger(ticket,DEAL_ENTRY);
         if(entry==DEAL_ENTRY_IN) record.entryType="IN";
         else if(entry==DEAL_ENTRY_OUT) record.entryType="OUT";
         else if(entry==DEAL_ENTRY_INOUT) record.entryType="INOUT";
         else if(entry==DEAL_ENTRY_OUT_BY) record.entryType="OUT_BY";
         else
           {
            error=StringFormat("UNKNOWN_DEAL_ENTRY_TYPE_DEAL_%I64u",ticket);
            return(false);
           }

         record.volume=HistoryDealGetDouble(ticket,DEAL_VOLUME);
         record.price=HistoryDealGetDouble(ticket,DEAL_PRICE);
         record.dealStopSnapshot=HistoryDealGetDouble(ticket,DEAL_SL);
         record.riskAtFillMoney=0.0; // broker history does not provide reliable risk-at-fill
         record.commission=HistoryDealGetDouble(ticket,DEAL_COMMISSION);
         record.swap=HistoryDealGetDouble(ticket,DEAL_SWAP);
         record.fee=HistoryDealGetDouble(ticket,DEAL_FEE);
         record.profit=HistoryDealGetDouble(ticket,DEAL_PROFIT);
         record.dealTime=(datetime)HistoryDealGetInteger(ticket,DEAL_TIME);
         SAxCampaignIntent intent;
         if(intentJournal.IsReady() &&
            intentJournal.FindByOrderTicket(record.orderTicket,intent))
           {
            record.campaignId=intent.campaignId;
            record.signalKey=intent.signalKey;
           }
         else
           {
            SAxOpenSetupRecord setupRecord;
            if(recovery.FindByPositionIdentifier(record.positionIdentifier,setupRecord) &&
               setupRecord.symbol==symbol)
              {
               record.campaignId=setupRecord.setupId;
               record.signalKey=setupRecord.setupId;
              }
            else
              {
               record.campaignId="";
               record.signalKey="";
              }
           }

         if(record.dealTicket==0 || record.orderTicket==0 ||
            record.positionIdentifier==0 || record.symbol=="" ||
            record.volume<=0.0 || record.price<=0.0 || record.dealTime<=0)
           {
            error=StringFormat("INCOMPLETE_BROKER_DEAL_%I64u",ticket);
            return(false);
           }

         SAxCampaignDealRecord existing;
         if(journal.FindDeal(ticket,existing))
           {
            // Existing broker economics are immutable. Attribution can be
            // upgraded only from the exact persisted open-position mapping.
            bool same=(existing.orderTicket==record.orderTicket &&
                       existing.positionIdentifier==record.positionIdentifier &&
                       existing.symbol==record.symbol &&
                       existing.direction==record.direction &&
                       existing.entryType==record.entryType &&
                       MathAbs(existing.volume-record.volume)<0.00000001 &&
                       MathAbs(existing.price-record.price)<0.00000001 &&
                       existing.dealTime==record.dealTime);
            if(!same)
              {
               error=StringFormat("BROKER_JOURNAL_DEAL_CONFLICT_%I64u",ticket);
               return(false);
              }
            if(existing.campaignId=="")
              {
               if(record.campaignId!="" &&
                  !journal.AmendAttribution(ticket,record.campaignId,record.signalKey))
                 {
                  error=StringFormat("JOURNAL_ATTRIBUTION_AMENDMENT_FAILED_DEAL_%I64u",ticket);
                  return(false);
                 }
               if(record.campaignId=="") unattributed++;
              }
            else if(record.campaignId!="" && existing.campaignId!=record.campaignId)
              {
               error=StringFormat("BROKER_JOURNAL_ATTRIBUTION_CONFLICT_%I64u",ticket);
               return(false);
              }
            alreadyKnown++;
            continue;
           }

         if(!journal.AppendDeal(record))
           {
            error=StringFormat("JOURNAL_APPEND_FAILED_DEAL_%I64u",ticket);
            return(false);
           }
         appended++;
         if(record.campaignId=="") unattributed++;
        }

      return(true);
     }
  };

#endif // AX_CAMPAIGNHISTORYRECONCILER_MQH
