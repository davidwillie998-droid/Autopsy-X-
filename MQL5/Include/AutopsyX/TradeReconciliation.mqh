//+------------------------------------------------------------------+
//|                                           TradeReconciliation.mqh|
//|  OnTradeTransaction Reconciliation (FLIPDEMON EXTREME upgrade,   |
//|  spec section 22) - classifies real broker trade-transaction     |
//|  events so the journal reflects what the broker actually did,    |
//|  not what the EA assumed would happen.                            |
//|                                                                    |
//|  MQL5's OnTradeTransaction() is a global special function, not a  |
//|  class method, so this class does not implement it directly - it |
//|  gives the EA's own OnTradeTransaction() a single Classify() call |
//|  to delegate to, keeping the classification logic reviewable and  |
//|  testable in isolation. Wiring the actual global OnTradeTransaction|
//|  handler (and having it mutate g_posState / trigger journal       |
//|  writes) is an integration step, same as every other module built |
//|  this phase - this file is the classification engine, not the     |
//|  wired-in event handler itself.                                   |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_TRADERECONCILIATION_MQH
#define AX_TRADERECONCILIATION_MQH
#include "Defs.mqh"

class CTradeReconciler
  {
public:
   //--- returns a concise, honest description of what this transaction actually represents. Never  ---
   //--- infers more than the transaction data supports - an unrecognized type is reported as such,  ---
   //--- not silently mapped to the nearest known case. ---
   string            Classify(const MqlTradeTransaction &trans,const MqlTradeRequest &request,
                               const MqlTradeResult &result) const
     {
      switch(trans.type)
        {
         case TRADE_TRANSACTION_ORDER_ADD:
            return(StringFormat("ORDER_PLACED order=%I64u symbol=%s type=%s vol=%.2f price=%.5f",
                   trans.order,trans.symbol,EnumToString(trans.order_type),trans.volume,trans.price));

         case TRADE_TRANSACTION_ORDER_UPDATE:
            return(StringFormat("ORDER_MODIFIED order=%I64u state=%s",trans.order,EnumToString(trans.order_state)));

         case TRADE_TRANSACTION_ORDER_DELETE:
            //--- an order leaving the active list can mean cancelled, expired, OR filled-then-      ---
            //--- removed - this transaction type alone cannot distinguish those cases. The           ---
            //--- corresponding DEAL_ADD (if any) is what actually confirms a fill; this event by     ---
            //--- itself only confirms the order is no longer pending. ---
            return(StringFormat("ORDER_REMOVED_FROM_PENDING order=%I64u (cancel/expiry/filled - see deal history)",
                   trans.order));

         case TRADE_TRANSACTION_DEAL_ADD:
            return(ClassifyDeal(trans));

         case TRADE_TRANSACTION_POSITION:
            return(StringFormat("POSITION_UPDATED position=%I64u symbol=%s",trans.position,trans.symbol));

         case TRADE_TRANSACTION_REQUEST:
            return(ClassifyRequestResult(request,result));

         case TRADE_TRANSACTION_HISTORY_ADD:
            return(StringFormat("HISTORY_ADD deal=%I64u order=%I64u",trans.deal,trans.order));

         default:
            return(StringFormat("UNCLASSIFIED_TRANSACTION_TYPE_%s",EnumToString(trans.type)));
        }
     }

   //--- true only for a transaction type that represents a REAL, broker-confirmed position-closing ---
   //--- or position-opening event - the caller uses this to decide whether journal/g_posState logic ---
   //--- should react at all, versus purely informational transaction types (order updates, etc.) ---
   bool              IsDealTransaction(const MqlTradeTransaction &trans) const
     {
      return(trans.type==TRADE_TRANSACTION_DEAL_ADD);
     }

private:
   //--- a DEAL_ADD transaction's own fields don't carry DEAL_ENTRY - that requires looking the deal ---
   //--- up in trade history. HistoryDealSelect can legitimately fail for a deal from before this EA ---
   //--- attached, or in a race right as the deal lands - that failure is reported honestly rather    ---
   //--- than guessed at. ---
   string            ClassifyDeal(const MqlTradeTransaction &trans) const
     {
      if(!HistoryDealSelect(trans.deal))
         return(StringFormat("DEAL_ADD deal=%I64u (history lookup unavailable yet)",trans.deal));

      long entry = HistoryDealGetInteger(trans.deal,DEAL_ENTRY);
      double dealVolume = HistoryDealGetDouble(trans.deal,DEAL_VOLUME);
      double dealProfit = HistoryDealGetDouble(trans.deal,DEAL_PROFIT);
      ulong  posId       = (ulong)HistoryDealGetInteger(trans.deal,DEAL_POSITION_ID);

      string entryLabel="UNKNOWN_ENTRY_TYPE";
      if(entry==DEAL_ENTRY_IN)     entryLabel="POSITION_OPENED";
      else if(entry==DEAL_ENTRY_OUT)    entryLabel="POSITION_CLOSED_OR_PARTIAL";
      else if(entry==DEAL_ENTRY_INOUT)  entryLabel="POSITION_REVERSED";
      else if(entry==DEAL_ENTRY_OUT_BY) entryLabel="POSITION_CLOSED_BY_OPPOSITE";

      return(StringFormat("%s deal=%I64u position=%I64u vol=%.2f profit=%.2f",
             entryLabel,trans.deal,posId,dealVolume,dealProfit));
     }

   string            ClassifyRequestResult(const MqlTradeRequest &request,const MqlTradeResult &result) const
     {
      if(result.retcode==TRADE_RETCODE_DONE || result.retcode==TRADE_RETCODE_DONE_PARTIAL)
         return(StringFormat("REQUEST_DONE symbol=%s action=%s retcode=%u order=%I64u deal=%I64u",
                request.symbol,EnumToString(request.action),result.retcode,result.order,result.deal));
      return(StringFormat("REQUEST_FAILED symbol=%s action=%s retcode=%u comment=%s",
             request.symbol,EnumToString(request.action),result.retcode,result.comment));
     }
  };
//+------------------------------------------------------------------+
#endif // AX_TRADERECONCILIATION_MQH
