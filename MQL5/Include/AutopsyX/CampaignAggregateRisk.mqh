//+------------------------------------------------------------------+
//| CampaignAggregateRisk.mqh                                        |
//| Fail-closed account stop-risk reconstruction for pyramid sizing. |
//| Does not authorize execution; caller must run all other EA gates. |
//+------------------------------------------------------------------+
#ifndef AUTOPSYX_CAMPAIGN_AGGREGATE_RISK_MQH
#define AUTOPSYX_CAMPAIGN_AGGREGATE_RISK_MQH
#property strict

class CCampaignAggregateRisk
  {
private:
   bool PositionRisk(const string symbol,const ENUM_POSITION_TYPE positionType,
                     const double volume,const double openPrice,const double stopLoss,
                     const double commissionPerLot,double &risk,string &reason) const
     {
      risk=0.0;
      if(symbol=="" || volume<=0.0 || openPrice<=0.0 || stopLoss<=0.0)
        { reason="Open position lacks symbol, volume, entry price, or protective stop"; return(false); }
      ENUM_ORDER_TYPE side;
      if(positionType==POSITION_TYPE_BUY) side=ORDER_TYPE_BUY;
      else if(positionType==POSITION_TYPE_SELL) side=ORDER_TYPE_SELL;
      else { reason="Unsupported open position type"; return(false); }
      if((side==ORDER_TYPE_BUY && stopLoss>=openPrice) ||
         (side==ORDER_TYPE_SELL && stopLoss<=openPrice))
        { reason="Open position stop is not on the loss side of its entry"; return(false); }
      double pnl=0.0;
      if(!OrderCalcProfit(side,symbol,volume,openPrice,stopLoss,pnl))
        { reason="OrderCalcProfit failed for an open position"; return(false); }
      risk=MathAbs(pnl)+commissionPerLot*volume;
      if(risk<=0.0 || risk!=risk)
        { reason="Open position stop-risk is invalid"; return(false); }
      return(true);
     }

   bool PendingRisk(const ulong ticket,const double commissionPerLot,
                    double &risk,string &reason) const
     {
      risk=0.0;
      if(!OrderSelect(ticket))
        { reason="Pending order could not be selected for risk reconciliation"; return(false); }
      ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      ENUM_ORDER_TYPE side;
      if(type==ORDER_TYPE_BUY_LIMIT || type==ORDER_TYPE_BUY_STOP ||
         type==ORDER_TYPE_BUY_STOP_LIMIT) side=ORDER_TYPE_BUY;
      else if(type==ORDER_TYPE_SELL_LIMIT || type==ORDER_TYPE_SELL_STOP ||
              type==ORDER_TYPE_SELL_STOP_LIMIT) side=ORDER_TYPE_SELL;
      else { reason="Unsupported pending order type"; return(false); }

      string symbol=OrderGetString(ORDER_SYMBOL);
      double volume=OrderGetDouble(ORDER_VOLUME_CURRENT);
      double entry=OrderGetDouble(ORDER_PRICE_OPEN);
      double stop=OrderGetDouble(ORDER_SL);
      if(symbol=="" || volume<=0.0 || entry<=0.0 || stop<=0.0)
        { reason="Pending order lacks a valid entry, volume, or protective stop"; return(false); }
      if((side==ORDER_TYPE_BUY && stop>=entry) ||
         (side==ORDER_TYPE_SELL && stop<=entry))
        { reason="Pending order stop is not on the loss side of its entry"; return(false); }
      double pnl=0.0;
      if(!OrderCalcProfit(side,symbol,volume,entry,stop,pnl))
        { reason="OrderCalcProfit failed for a pending order"; return(false); }
      risk=MathAbs(pnl)+commissionPerLot*volume;
      if(risk<=0.0 || risk!=risk)
        { reason="Pending-order stop-risk is invalid"; return(false); }
      return(true);
     }

public:
   CCampaignAggregateRisk(void) {}

   // Includes all account positions and pending orders, not only this EA's
   // magic number. This is intentionally conservative: manual/foreign exposure
   // also consumes account risk capacity. Missing stops or failed calculations
   // make the total unverified and must block new exposure.
   bool CalculateCurrentRiskMoney(const double commissionPerLotRoundTurn,
                                  double &riskMoneyOut,string &reason) const
     {
      riskMoneyOut=0.0;
      reason="";
      if(commissionPerLotRoundTurn<0.0)
        { reason="Commission estimate cannot be negative"; return(false); }
      double total=0.0;

      int positionCount=PositionsTotal();
      for(int i=0;i<positionCount;i++)
        {
         ulong ticket=PositionGetTicket(i);
         if(ticket==0)
           { reason="Could not enumerate account positions"; return(false); }
         string symbol=PositionGetString(POSITION_SYMBOL);
         ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double volume=PositionGetDouble(POSITION_VOLUME);
         double openPrice=PositionGetDouble(POSITION_PRICE_OPEN);
         double stopLoss=PositionGetDouble(POSITION_SL);
         double risk=0.0;
         if(!PositionRisk(symbol,type,volume,openPrice,stopLoss,
                          commissionPerLotRoundTurn,risk,reason))
           return(false);
         total+=risk;
         if(total<0.0 || total!=total)
           { reason="Aggregate open-position risk overflow/invalid"; return(false); }
        }

      int orderCount=OrdersTotal();
      for(int j=0;j<orderCount;j++)
        {
         ulong ticket=OrderGetTicket(j);
         if(ticket==0)
           { reason="Could not enumerate pending orders"; return(false); }
         double risk=0.0;
         if(!PendingRisk(ticket,commissionPerLotRoundTurn,risk,reason))
           return(false);
         total+=risk;
         if(total<0.0 || total!=total)
           { reason="Aggregate pending-order risk overflow/invalid"; return(false); }
        }

      riskMoneyOut=total;
      reason="Aggregate stop-risk reconstructed from all account positions and pending orders";
      return(true);
     }
  };

#endif // AUTOPSYX_CAMPAIGN_AGGREGATE_RISK_MQH
