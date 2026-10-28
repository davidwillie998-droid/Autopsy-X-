//+------------------------------------------------------------------+
//| AccountStopRisk.mqh                                               |
//| Conservative account-wide stop-risk snapshot for FLIPDEMON EXTREME|
//+------------------------------------------------------------------+
#ifndef AX_ACCOUNTSTOPRISK_MQH
#define AX_ACCOUNTSTOPRISK_MQH

// Returns false when any live position or pending order has no usable
// stop-loss or MT5 cannot value its loss. Unknown risk is never treated as zero.
bool AxCalculateAccountStopRisk(double &riskMoney,int &riskItems,string &reason)
  {
   riskMoney=0.0;
   riskItems=0;
   reason="";
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity<=0.0)
     {
      reason="account equity unavailable for stop-risk calculation";
      return(false);
     }

   int positions=PositionsTotal();
   for(int i=0;i<positions;i++)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) { reason="could not select an open position"; return(false); }
      string symbol=PositionGetString(POSITION_SYMBOL);
      double volume=PositionGetDouble(POSITION_VOLUME);
      double openPrice=PositionGetDouble(POSITION_PRICE_OPEN);
      double stop=PositionGetDouble(POSITION_SL);
      long type=PositionGetInteger(POSITION_TYPE);
      if(volume<=0.0 || openPrice<=0.0) { reason="invalid open-position data"; return(false); }
      if(stop<=0.0)
        {
         reason=StringFormat("open position %I64u on %s has no stop-loss; account risk unknown",ticket,symbol);
         return(false);
        }
      ENUM_ORDER_TYPE orderType=(type==POSITION_TYPE_BUY)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
      double pnl=0.0;
      if(!OrderCalcProfit(orderType,symbol,volume,openPrice,stop,pnl))
        {
         reason=StringFormat("cannot value stop-loss risk for position %I64u on %s (error %d)",ticket,symbol,GetLastError());
         return(false);
        }
      riskMoney+=MathMax(0.0,-pnl);
      riskItems++;
     }

   int orders=OrdersTotal();
   for(int j=0;j<orders;j++)
     {
      ulong ticket=OrderGetTicket(j);
      if(ticket==0) { reason="could not select a pending order"; return(false); }
      ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      bool buy=(type==ORDER_TYPE_BUY_LIMIT || type==ORDER_TYPE_BUY_STOP ||
                type==ORDER_TYPE_BUY_STOP_LIMIT);
      bool sell=(type==ORDER_TYPE_SELL_LIMIT || type==ORDER_TYPE_SELL_STOP ||
                 type==ORDER_TYPE_SELL_STOP_LIMIT);
      if(!buy && !sell) continue;
      string symbol=OrderGetString(ORDER_SYMBOL);
      double volume=OrderGetDouble(ORDER_VOLUME_CURRENT);
      double openPrice=OrderGetDouble(ORDER_PRICE_OPEN);
      double stop=OrderGetDouble(ORDER_SL);
      if(volume<=0.0 || openPrice<=0.0) { reason="invalid pending-order data"; return(false); }
      if(stop<=0.0)
        {
         reason=StringFormat("pending order %I64u on %s has no stop-loss; account risk unknown",ticket,symbol);
         return(false);
        }
      double pnl=0.0;
      if(!OrderCalcProfit(buy?ORDER_TYPE_BUY:ORDER_TYPE_SELL,symbol,volume,openPrice,stop,pnl))
        {
         reason=StringFormat("cannot value stop-loss risk for pending order %I64u on %s (error %d)",ticket,symbol,GetLastError());
         return(false);
        }
      riskMoney+=MathMax(0.0,-pnl);
      riskItems++;
     }
   return(true);
  }

#endif // AX_ACCOUNTSTOPRISK_MQH
