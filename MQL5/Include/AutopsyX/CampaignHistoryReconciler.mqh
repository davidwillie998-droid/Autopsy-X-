//+------------------------------------------------------------------+
//|                                  CampaignHistoryReconciler.mqh   |
//| Replays broker-confirmed deals into the durable campaign journal|
//+------------------------------------------------------------------+
#property strict
#ifndef AX_CAMPAIGNHISTORYRECONCILER_MQH
#define AX_CAMPAIGNHISTORYRECONCILER_MQH

#include "CampaignJournal.mqh"
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
         record.stopAtFill=HistoryDealGetDouble(ticket,DEAL_SL);
         record.riskAtFillMoney=0.0; // broker history does not provide reliable risk-at-fill
         record.commission=HistoryDealGetDouble(ticket,DEAL_COMMISSION);
         record.swap=HistoryDealGetDouble(ticket,DEAL_SWAP);
         record.fee=HistoryDealGetDouble(ticket,DEAL_FEE);
         record.profit=HistoryDealGetDouble(ticket,DEAL_PROFIT);
         record.dealTime=(datetime)HistoryDealGetInteger(ticket,DEAL_TIME);
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
            // Existing record must match the broker's immutable deal identity
            // and fill economics. Stop snapshots may differ if broker history
            // omits them on later reads, so compare the durable deal fields here.
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
            alreadyKnown++;
            if(existing.campaignId=="") unattributed++;
            continue;
           }

         if(!journal.AppendDeal(record))
           {
            error=StringFormat("JOURNAL_APPEND_FAILED_DEAL_%I64u",ticket);
            return(false);
           }
         appended++;
         unattributed++;
        }

      return(true);
     }
  };

#endif // AX_CAMPAIGNHISTORYRECONCILER_MQH
