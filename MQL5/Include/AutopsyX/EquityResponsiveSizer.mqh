//+------------------------------------------------------------------+
//| EquityResponsiveSizer.mqh                                        |
//| Fail-closed stop-risk sizing primitive for conditional pyramiding|
//| Not wired into order execution until campaign-risk integration is |
//| implemented and validated for both MT5 netting and hedging modes. |
//+------------------------------------------------------------------+
#ifndef AUTOPSYX_EQUITY_RESPONSIVE_SIZER_MQH
#define AUTOPSYX_EQUITY_RESPONSIVE_SIZER_MQH
#property strict

class CEquityResponsiveSizer
  {
private:
   double FloorToVolumeStep(const double requested,const double minimum,
                            const double maximum,const double step) const
     {
      if(requested<minimum || minimum<=0.0 || maximum<minimum || step<=0.0)
         return(0.0);
      double capped=MathMin(requested,maximum);
      double steps=MathFloor((capped-minimum)/step+1e-9);
      if(steps<0.0) return(0.0);
      double volume=NormalizeDouble(minimum+steps*step,8);
      if(volume<minimum-1e-8 || volume>maximum+1e-8) return(0.0);
      double aligned=(volume-minimum)/step;
      if(MathAbs(aligned-MathRound(aligned))>1e-6) return(0.0);
      return(volume);
     }

public:
   CEquityResponsiveSizer(void) {}

   // existingAggregateRiskMoney must include every relevant open EA-managed
   // position and pending order at stop, including conservative costs. The
   // caller must set existingRiskVerified=false if ownership/exposure cannot
   // be completely reconstructed. This class never guesses missing exposure.
   bool Calculate(const string symbol,
                  const ENUM_ORDER_TYPE orderType,
                  const double entryPrice,
                  const double stopLoss,
                  const double perTradeRiskPercent,
                  const double maxAggregateRiskPercent,
                  const double existingAggregateRiskMoney,
                  const bool existingRiskVerified,
                  const double maxMarginUsagePercent,
                  const double commissionPerLotRoundTurn,
                  const double slippageBufferPoints,
                  double &lotsOut,
                  double &riskMoneyOut,
                  string &reason) const
     {
      lotsOut=0.0;
      riskMoneyOut=0.0;
      reason="";

      if(symbol=="" ||
         (orderType!=ORDER_TYPE_BUY && orderType!=ORDER_TYPE_SELL))
        { reason="Invalid symbol or unsupported order type"; return(false); }
      if(entryPrice<=0.0 || stopLoss<=0.0 ||
         perTradeRiskPercent<=0.0 || perTradeRiskPercent>2.0 ||
         maxAggregateRiskPercent<=0.0 || maxAggregateRiskPercent>5.0 ||
         existingAggregateRiskMoney<0.0 ||
         maxMarginUsagePercent<=0.0 || maxMarginUsagePercent>100.0 ||
         commissionPerLotRoundTurn<0.0 || slippageBufferPoints<0.0)
        { reason="Invalid sizing input or risk configuration"; return(false); }
      if(!existingRiskVerified)
        { reason="Existing aggregate exposure is unverified; new risk rejected"; return(false); }

      if((orderType==ORDER_TYPE_BUY && stopLoss>=entryPrice) ||
         (orderType==ORDER_TYPE_SELL && stopLoss<=entryPrice))
        { reason="Stop-loss is not on the loss side of entry"; return(false); }

      double equity=AccountInfoDouble(ACCOUNT_EQUITY);
      double usedMargin=AccountInfoDouble(ACCOUNT_MARGIN);
      double freeMargin=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      double point=SymbolInfoDouble(symbol,SYMBOL_POINT);
      double volumeMin=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
      double volumeMax=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX);
      double volumeStep=SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
      if(equity<=0.0 || usedMargin<0.0 || freeMargin<0.0 ||
         point<=0.0 || volumeMin<=0.0 || volumeMax<volumeMin || volumeStep<=0.0)
        { reason="Account or broker sizing metadata is invalid"; return(false); }

      // Price the stop beyond the requested level by the configured adverse
      // slippage buffer. A gap can still exceed this estimate.
      double bufferedStop=stopLoss;
      if(orderType==ORDER_TYPE_BUY) bufferedStop-=slippageBufferPoints*point;
      else bufferedStop+=slippageBufferPoints*point;
      if(bufferedStop<=0.0 ||
         (orderType==ORDER_TYPE_BUY && bufferedStop>=entryPrice) ||
         (orderType==ORDER_TYPE_SELL && bufferedStop<=entryPrice))
        { reason="Buffered stop is invalid"; return(false); }

      double oneLotPnl=0.0;
      if(!OrderCalcProfit(orderType,symbol,1.0,entryPrice,bufferedStop,oneLotPnl))
        { reason="OrderCalcProfit failed; stop-risk cannot be verified"; return(false); }
      double riskPerLot=MathAbs(oneLotPnl)+commissionPerLotRoundTurn;
      if(riskPerLot<=0.0 || riskPerLot!=riskPerLot)
        { reason="Calculated per-lot stop risk is invalid"; return(false); }

      double tradeBudget=equity*perTradeRiskPercent/100.0;
      double aggregateBudget=equity*maxAggregateRiskPercent/100.0-existingAggregateRiskMoney;
      double candidateBudget=MathMin(tradeBudget,aggregateBudget);
      if(candidateBudget<=0.0)
        { reason="No remaining aggregate stop-risk budget"; return(false); }

      double rawLots=candidateBudget/riskPerLot;
      double lots=FloorToVolumeStep(rawLots,volumeMin,volumeMax,volumeStep);
      if(lots<=0.0)
        { reason="Risk budget cannot support broker minimum volume"; return(false); }

      double candidatePnl=0.0;
      if(!OrderCalcProfit(orderType,symbol,lots,entryPrice,bufferedStop,candidatePnl))
        { reason="Final-volume OrderCalcProfit failed"; return(false); }
      double candidateRisk=MathAbs(candidatePnl)+commissionPerLotRoundTurn*lots;
      if(candidateRisk<=0.0 || candidateRisk>candidateBudget+0.01)
        { reason="Rounded volume exceeds permitted stop-risk budget"; return(false); }

      double requiredMargin=0.0;
      if(!OrderCalcMargin(orderType,symbol,lots,entryPrice,requiredMargin) ||
         requiredMargin<0.0)
        { reason="OrderCalcMargin failed; projected margin cannot be verified"; return(false); }
      if(requiredMargin>freeMargin)
        { reason="Insufficient free margin for candidate volume"; return(false); }
      double projectedUsage=((usedMargin+requiredMargin)/equity)*100.0;
      if(projectedUsage>maxMarginUsagePercent+1e-8)
        { reason=StringFormat("Projected margin usage %.3f%% exceeds %.3f%% ceiling",
                              projectedUsage,maxMarginUsagePercent); return(false); }

      lotsOut=lots;
      riskMoneyOut=candidateRisk;
      reason="Sizing candidate passed local stop-risk and margin checks; caller must still run all entry and campaign gates";
      return(true);
     }
  };

#endif // AUTOPSYX_EQUITY_RESPONSIVE_SIZER_MQH
