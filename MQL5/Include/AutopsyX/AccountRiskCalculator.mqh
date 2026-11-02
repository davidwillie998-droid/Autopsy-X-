//+------------------------------------------------------------------+
//|                                      AccountRiskCalculator.mqh   |
//|  Broker-confirmed account-wide stop-risk calculation.            |
//|  This component observes exposure; it does not send orders.      |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_ACCOUNTRISKCALCULATOR_MQH
#define AX_ACCOUNTRISKCALCULATOR_MQH

#define AX_ACCOUNT_RISK_HARD_CAP_PCT 2.0

struct SAxAccountRiskSnapshot
  {
   double equity;
   double existingRiskMoney;
   double existingRiskPercent;
   double hardRiskBudgetMoney;
   double remainingRiskBudgetMoney;
   int    positionCount;
   int    pendingOrderCount;
   bool   exposureKnown;
   string failureReason;
  };

struct SAxAccountRiskDecision
  {
   datetime evaluatedAt;
   long     login;
   string   server;
   double   equity;
   double   existingRiskMoney;
   double   existingRiskPercent;
   double   proposedRiskMoney;
   double   remainingRiskBudgetMoney;
   int      positionCount;
   int      pendingOrderCount;
   bool     approved;
   string   decision;
   string   rejectionReason;
   string   calculationError;
  };

class CAccountRiskCalculator
  {
private:
   string m_auditFile;

   bool ValidNumber(const double value) const
     {
      return(MathIsValidNumber(value));
     }

   // OrderCalcProfit returns P/L in the account deposit currency. A positive
   // stop outcome locks profit and therefore contributes zero downside risk.
   bool CalculateStopRisk(const ENUM_ORDER_TYPE orderType,const string symbol,
                          const double volume,const double entryPrice,
                          const double stopPrice,const bool pending,
                          double &riskMoney,string &error) const
     {
      riskMoney=0.0;
      if(StringLen(symbol)==0 || volume<=0.0 || entryPrice<=0.0 ||
         stopPrice<=0.0 || !ValidNumber(volume) ||
         !ValidNumber(entryPrice) || !ValidNumber(stopPrice))
        {
         error="INVALID_SYMBOL_VOLUME_ENTRY_OR_STOP";
         return(false);
        }

      if(pending)
        {
         if((orderType==ORDER_TYPE_BUY && stopPrice>=entryPrice) ||
            (orderType==ORDER_TYPE_SELL && stopPrice<=entryPrice))
           {
            error="PENDING_ORDER_STOP_NOT_ON_LOSS_SIDE";
            return(false);
           }
        }

      double result=0.0;
      ResetLastError();
      if(!OrderCalcProfit(orderType,symbol,volume,entryPrice,stopPrice,result))
        {
         error=StringFormat("ORDERCALCPROFIT_FAILED symbol=%s error=%d",symbol,GetLastError());
         return(false);
        }
      if(!ValidNumber(result))
        {
         error=StringFormat("ORDERCALCPROFIT_NONFINITE symbol=%s",symbol);
         return(false);
        }
      riskMoney=(result<0.0)?MathAbs(result):0.0;
      return(true);
     }

   bool PositionRisk(const ulong ticket,double &riskMoney,string &error) const
     {
      riskMoney=0.0;
      if(ticket==0 || !PositionSelectByTicket(ticket))
        {
         error="POSITION_SELECTION_FAILED";
         return(false);
        }

      string symbol=PositionGetString(POSITION_SYMBOL);
      long type=PositionGetInteger(POSITION_TYPE);
      double volume=PositionGetDouble(POSITION_VOLUME);
      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      double stop=PositionGetDouble(POSITION_SL);
      if(type!=POSITION_TYPE_BUY && type!=POSITION_TYPE_SELL)
        {
         error=StringFormat("UNKNOWN_POSITION_TYPE ticket=%I64u",ticket);
         return(false);
        }
      if(stop<=0.0)
        {
         error=StringFormat("UNPROTECTED_POSITION ticket=%I64u symbol=%s",ticket,symbol);
         return(false);
        }

      // A stop already crossed by the current market is not accepted as reliable
      // protection. The broker may still be processing a stop-triggered close.
      MqlTick tick;
      if(!SymbolInfoTick(symbol,tick) || tick.bid<=0.0 || tick.ask<=0.0 || tick.ask<tick.bid)
        {
         error=StringFormat("POSITION_QUOTE_UNAVAILABLE ticket=%I64u symbol=%s",ticket,symbol);
         return(false);
        }
      if((type==POSITION_TYPE_BUY && stop>=tick.bid) ||
         (type==POSITION_TYPE_SELL && stop<=tick.ask))
        {
         error=StringFormat("POSITION_STOP_CROSSED_OR_INVALID ticket=%I64u symbol=%s",ticket,symbol);
         return(false);
        }

      ENUM_ORDER_TYPE orderType=(type==POSITION_TYPE_BUY)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
      return(CalculateStopRisk(orderType,symbol,volume,entry,stop,false,riskMoney,error));
     }

   bool PendingOrderRisk(const ulong ticket,double &riskMoney,string &error) const
     {
      riskMoney=0.0;
      if(ticket==0 || !OrderSelect(ticket))
        {
         error="PENDING_ORDER_SELECTION_FAILED";
         return(false);
        }

      ENUM_ORDER_TYPE pendingType=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      ENUM_ORDER_TYPE calcType;
      if(pendingType==ORDER_TYPE_BUY_LIMIT || pendingType==ORDER_TYPE_BUY_STOP ||
         pendingType==ORDER_TYPE_BUY_STOP_LIMIT)
         calcType=ORDER_TYPE_BUY;
      else if(pendingType==ORDER_TYPE_SELL_LIMIT || pendingType==ORDER_TYPE_SELL_STOP ||
              pendingType==ORDER_TYPE_SELL_STOP_LIMIT)
         calcType=ORDER_TYPE_SELL;
      else
        {
         error=StringFormat("UNSUPPORTED_ACTIVE_ORDER_TYPE ticket=%I64u type=%s",
                            ticket,EnumToString(pendingType));
         return(false);
        }

      string symbol=OrderGetString(ORDER_SYMBOL);
      double volume=OrderGetDouble(ORDER_VOLUME_CURRENT); // remaining, unfilled volume only
      double entry=OrderGetDouble(ORDER_PRICE_OPEN);
      if(pendingType==ORDER_TYPE_BUY_STOP_LIMIT || pendingType==ORDER_TYPE_SELL_STOP_LIMIT)
        {
         double limitPrice=OrderGetDouble(ORDER_PRICE_STOPLIMIT);
         if(limitPrice>0.0) entry=limitPrice;
        }
      double stop=OrderGetDouble(ORDER_SL);
      if(stop<=0.0)
        {
         error=StringFormat("UNPROTECTED_PENDING_ORDER ticket=%I64u symbol=%s",ticket,symbol);
         return(false);
        }

      // The position scan counts only broker-filled volume. ORDER_VOLUME_CURRENT
      // is the unfilled remainder, so a partial fill is not counted twice.
      return(CalculateStopRisk(calcType,symbol,volume,entry,stop,true,riskMoney,error));
     }

   bool WriteAudit(const SAxAccountRiskDecision &decision) const
     {
      int handle=FileOpen(m_auditFile,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|
                         FILE_SHARE_READ|FILE_SHARE_WRITE,',');
      if(handle==INVALID_HANDLE)
        {
         PrintFormat("FLIPDEMON RISK AUDIT ERROR: FileOpen failed file=%s error=%d",
                     m_auditFile,GetLastError());
         return(false);
        }

      if(FileSize(handle)==0)
         FileWrite(handle,"timestamp","login","server","equity","existing_risk_money",
                   "existing_risk_percent","proposed_risk_money","remaining_budget_money",
                   "positions","pending_orders","decision","rejection_reason","calculation_error");
      FileSeek(handle,0,SEEK_END);
      uint written=FileWrite(handle,TimeToString(decision.evaluatedAt,TIME_DATE|TIME_SECONDS),
                              decision.login,decision.server,decision.equity,
                              decision.existingRiskMoney,decision.existingRiskPercent,
                              decision.proposedRiskMoney,decision.remainingRiskBudgetMoney,
                              decision.positionCount,decision.pendingOrderCount,
                              decision.decision,decision.rejectionReason,decision.calculationError);
      FileFlush(handle);
      FileClose(handle);
      if(written==0)
        {
         Print("FLIPDEMON RISK AUDIT ERROR: decision row write failed; entry must remain blocked.");
         return(false);
        }
      return(true);
     }

public:
                     CAccountRiskCalculator(void)
     {
      m_auditFile=StringFormat("FlipDemon_AccountRisk_%I64d.csv",
                               AccountInfoInteger(ACCOUNT_LOGIN));
     }

   bool              Scan(SAxAccountRiskSnapshot &snapshot) const
     {
      snapshot.equity=AccountInfoDouble(ACCOUNT_EQUITY);
      snapshot.existingRiskMoney=0.0;
      snapshot.existingRiskPercent=0.0;
      snapshot.hardRiskBudgetMoney=0.0;
      snapshot.remainingRiskBudgetMoney=0.0;
      snapshot.positionCount=0;
      snapshot.pendingOrderCount=0;
      snapshot.exposureKnown=false;
      snapshot.failureReason="UNINITIALIZED";

      if(!ValidNumber(snapshot.equity) || snapshot.equity<=0.0)
        {
         snapshot.failureReason="INVALID_ACCOUNT_EQUITY";
         return(false);
        }
      snapshot.hardRiskBudgetMoney=snapshot.equity*(AX_ACCOUNT_RISK_HARD_CAP_PCT/100.0);

      bool hedging=(AccountInfoInteger(ACCOUNT_MARGIN_MODE)==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
      string seenSymbols[];
      int seenCount=0;

      int positions=PositionsTotal();
      for(int i=0;i<positions;i++)
        {
         ulong ticket=PositionGetTicket(i);
         if(ticket==0)
           {
            snapshot.failureReason=StringFormat("POSITION_ENUMERATION_FAILED index=%d",i);
            return(false);
           }
         string symbol=PositionGetString(POSITION_SYMBOL);
         if(!hedging)
           {
            for(int j=0;j<seenCount;j++)
               if(seenSymbols[j]==symbol)
                 {
                  snapshot.failureReason=StringFormat("AMBIGUOUS_NETTING_DUPLICATE_SYMBOL symbol=%s",symbol);
                  return(false);
                 }
            ArrayResize(seenSymbols,seenCount+1);
            seenSymbols[seenCount]=symbol;
            seenCount++;
           }

         double risk=0.0;
         string error="";
         if(!PositionRisk(ticket,risk,error))
           {
            snapshot.failureReason=error;
            return(false);
           }
         snapshot.existingRiskMoney+=risk;
         snapshot.positionCount++;
        }

      int orders=OrdersTotal();
      for(int i=0;i<orders;i++)
        {
         ulong ticket=OrderGetTicket(i);
         if(ticket==0)
           {
            snapshot.failureReason=StringFormat("PENDING_ORDER_ENUMERATION_FAILED index=%d",i);
            return(false);
           }
         double risk=0.0;
         string error="";
         if(!PendingOrderRisk(ticket,risk,error))
           {
            snapshot.failureReason=error;
            return(false);
           }
         snapshot.existingRiskMoney+=risk;
         snapshot.pendingOrderCount++;
        }

      if(!ValidNumber(snapshot.existingRiskMoney) || snapshot.existingRiskMoney<0.0)
        {
         snapshot.failureReason="INVALID_AGGREGATE_RISK";
         return(false);
        }
      snapshot.existingRiskPercent=snapshot.existingRiskMoney/snapshot.equity*100.0;
      snapshot.remainingRiskBudgetMoney=MathMax(0.0,
                                         snapshot.hardRiskBudgetMoney-snapshot.existingRiskMoney);
      snapshot.exposureKnown=true;
      snapshot.failureReason="";
      return(true);
     }

   // Re-run this immediately before submission. It is a read-only check, not an
   // atomic reservation; cross-terminal serialization is a separate coordinator task.
   bool              Evaluate(const string symbol,const ENUM_AX_DIR direction,
                              const double volume,const double stopPrice,
                              const int maxAdverseSlippagePoints,
                              const double perEntryRiskPercent,
                              SAxAccountRiskDecision &decision,string &reason) const
     {
      decision.evaluatedAt=TimeCurrent();
      decision.login=AccountInfoInteger(ACCOUNT_LOGIN);
      decision.server=AccountInfoString(ACCOUNT_SERVER);
      decision.equity=AccountInfoDouble(ACCOUNT_EQUITY);
      decision.existingRiskMoney=0.0;
      decision.existingRiskPercent=0.0;
      decision.proposedRiskMoney=0.0;
      decision.remainingRiskBudgetMoney=0.0;
      decision.positionCount=0;
      decision.pendingOrderCount=0;
      decision.approved=false;
      decision.decision="REJECTED";
      decision.rejectionReason="";
      decision.calculationError="";
      reason="";

      SAxAccountRiskSnapshot snapshot;
      if(!Scan(snapshot))
        {
         reason="EXISTING_EXPOSURE_UNKNOWN";
         decision.calculationError=snapshot.failureReason;
        }
      else
        {
         decision.equity=snapshot.equity;
         decision.existingRiskMoney=snapshot.existingRiskMoney;
         decision.existingRiskPercent=snapshot.existingRiskPercent;
         decision.remainingRiskBudgetMoney=snapshot.remainingRiskBudgetMoney;
         decision.positionCount=snapshot.positionCount;
         decision.pendingOrderCount=snapshot.pendingOrderCount;

         if(direction!=AX_DIR_BUY && direction!=AX_DIR_SELL)
            reason="INVALID_PROPOSED_DIRECTION";
         else if(!ValidNumber(perEntryRiskPercent) || perEntryRiskPercent<=0.0)
            reason="INVALID_PER_ENTRY_RISK_LIMIT";
         else if(perEntryRiskPercent>AX_ACCOUNT_RISK_HARD_CAP_PCT)
            reason="PER_ENTRY_RISK_LIMIT_EXCEEDS_ABSOLUTE_CAP";
         else
           {
            MqlTick tick;
            double point=SymbolInfoDouble(symbol,SYMBOL_POINT);
            if(!SymbolInfoTick(symbol,tick) || tick.bid<=0.0 || tick.ask<=0.0 || tick.ask<tick.bid)
               reason="PROPOSED_SYMBOL_QUOTE_UNAVAILABLE";
            else if(maxAdverseSlippagePoints<0 || !ValidNumber(point) || point<=0.0)
               reason="INVALID_ADVERSE_SLIPPAGE_ALLOWANCE";
            else
              {
               // Reserve the full configured CTrade deviation against adverse movement.
               // BUY risk uses ask + allowance; SELL risk uses bid - allowance.
               // Market-execution brokers may not enforce deviation as a hard bound.
               double slippageBuffer=maxAdverseSlippagePoints*point;
               double entry=(direction==AX_DIR_BUY)?tick.ask+slippageBuffer:tick.bid-slippageBuffer;
               if(!ValidNumber(entry) || entry<=0.0)
                  reason="INVALID_WORST_CASE_ENTRY_PRICE";
               else
                 {
                  ENUM_ORDER_TYPE orderType=(direction==AX_DIR_BUY)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
                  string calcError="";
                  bool stopOnLossSide=(direction==AX_DIR_BUY)?(stopPrice<entry):(stopPrice>entry);
                  if(!stopOnLossSide)
                     reason="PROPOSED_STOP_NOT_ON_LOSS_SIDE";
                  else if(!CalculateStopRisk(orderType,symbol,volume,entry,stopPrice,false,
                                             decision.proposedRiskMoney,calcError))
                    {
                     reason="PROPOSED_ORDER_RISK_UNKNOWN";
                     decision.calculationError=calcError;
                    }
                  else if(snapshot.existingRiskMoney>snapshot.hardRiskBudgetMoney+0.01)
                     reason="EXISTING_ACCOUNT_RISK_ALREADY_EXCEEDS_2_PERCENT";
                  else if(decision.proposedRiskMoney>
                          snapshot.equity*perEntryRiskPercent/100.0+0.01)
                     reason="PROPOSED_ORDER_EXCEEDS_PER_ENTRY_RISK_LIMIT";
                  else if(snapshot.existingRiskMoney+decision.proposedRiskMoney>
                          snapshot.hardRiskBudgetMoney+0.01)
                     reason="PROPOSED_ORDER_EXCEEDS_ACCOUNT_WIDE_2_PERCENT_CAP";
                 }
              }
           }
        }

      if(reason=="")
        {
         decision.approved=true;
         decision.decision="APPROVED";
         decision.rejectionReason="NONE";
        }
      else
        {
         decision.approved=false;
         decision.decision="REJECTED";
         decision.rejectionReason=reason;
        }

      if(!WriteAudit(decision))
        {
         decision.approved=false;
         decision.decision="REJECTED";
         decision.rejectionReason="RISK_AUDIT_PERSISTENCE_FAILED";
         reason=decision.rejectionReason;
         return(false);
        }
      if(!decision.approved)
        {
         reason=decision.rejectionReason;
         PrintFormat("FLIPDEMON ACCOUNT RISK BLOCK: %s existing=%.2f proposed=%.2f remaining=%.2f equity=%.2f",
                     reason,decision.existingRiskMoney,decision.proposedRiskMoney,
                     decision.remainingRiskBudgetMoney,decision.equity);
         return(false);
        }

      PrintFormat("FLIPDEMON ACCOUNT RISK APPROVED: existing=%.2f proposed=%.2f remaining=%.2f equity=%.2f",
                  decision.existingRiskMoney,decision.proposedRiskMoney,
                  decision.remainingRiskBudgetMoney,decision.equity);
      return(true);
     }
  };
//+------------------------------------------------------------------+
#endif // AX_ACCOUNTRISKCALCULATOR_MQH
