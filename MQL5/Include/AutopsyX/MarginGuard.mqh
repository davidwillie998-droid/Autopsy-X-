//+------------------------------------------------------------------+
//|                                                    MarginGuard.mqh|
//| Dynamic symbol-specific margin preflight and emergency monitor.  |
//| Does not size risk or replace the account-wide risk coordinator. |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_MARGINGUARD_MQH
#define AX_MARGINGUARD_MQH

class CMarginGuard
  {
private:
   bool Valid(const double value) const
     {
      return(MathIsValidNumber(value) && value>0.0);
     }

   int VolumeDigits(const double step) const
     {
      for(int digits=0;digits<=8;digits++)
         if(MathAbs(step-NormalizeDouble(step,digits))<1e-10)
            return(digits);
      return(8);
     }

   bool MarginForVolume(const string symbol,const ENUM_ORDER_TYPE orderType,
                        const double volume,const double price,
                        double &required,string &reason) const
     {
      required=0.0;
      ResetLastError();
      if(!OrderCalcMargin(orderType,symbol,volume,price,required) ||
         !MathIsValidNumber(required) || required<=0.0)
        {
         reason=StringFormat("ORDER_CALC_MARGIN_FAILED volume=%.8f price=%.10g error=%d",
                             volume,price,GetLastError());
         return(false);
        }
      return(true);
     }

public:
                     CMarginGuard(void) {}

   // The strategy/risk engine supplies requestedLots. This method only scales
   // that approved risk-sized volume down to fit a percentage of current free
   // margin. Every candidate is re-priced through OrderCalcMargin, so symbol
   // HMR and broker-specific margin tiers are respected without reading leverage.
   bool              FitVolumeToFreeMargin(const string symbol,
                                           const ENUM_ORDER_TYPE orderType,
                                           const double executablePrice,
                                           const double requestedLots,
                                           const double maxFreeMarginUsagePct,
                                           double &approvedLots,
                                           double &requiredMargin,
                                           string &reason) const
     {
      approvedLots=0.0;
      requiredMargin=0.0;
      reason="";

      if(symbol=="" || (orderType!=ORDER_TYPE_BUY && orderType!=ORDER_TYPE_SELL) ||
         !Valid(executablePrice) || !Valid(requestedLots) ||
         !MathIsValidNumber(maxFreeMarginUsagePct) ||
         maxFreeMarginUsagePct<=0.0 || maxFreeMarginUsagePct>100.0)
        {
         reason="INVALID_MARGIN_GUARD_INPUT";
         return(false);
        }

      double freeMargin=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(!Valid(freeMargin))
        {
         reason="FREE_MARGIN_UNAVAILABLE";
         return(false);
        }
      double budget=freeMargin*maxFreeMarginUsagePct/100.0;
      if(!Valid(budget))
        {
         reason="MARGIN_BUDGET_INVALID";
         return(false);
        }

      double volumeMin=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
      double volumeMax=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX);
      double volumeStep=SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
      if(!Valid(volumeMin) || !Valid(volumeMax) || !Valid(volumeStep) ||
         volumeMax<volumeMin)
        {
         reason="BROKER_VOLUME_GRID_UNAVAILABLE";
         return(false);
        }

      int digits=VolumeDigits(volumeStep);
      double cappedRequest=MathMin(requestedLots,volumeMax);
      long maxUnits=(long)MathFloor((cappedRequest+volumeStep*1e-8)/volumeStep);
      long minUnits=(long)MathCeil((volumeMin-volumeStep*1e-8)/volumeStep);
      if(maxUnits<minUnits || minUnits<=0)
        {
         reason="REQUESTED_VOLUME_BELOW_BROKER_MINIMUM";
         return(false);
        }

      double requestedGrid=NormalizeDouble((double)maxUnits*volumeStep,digits);
      double requestedMargin=0.0;
      if(!MarginForVolume(symbol,orderType,requestedGrid,executablePrice,
                          requestedMargin,reason))
         return(false);

      if(requestedMargin<=budget)
        {
         approvedLots=requestedGrid;
         requiredMargin=requestedMargin;
         return(true);
        }

      // First prove that the broker minimum itself is affordable. If not, do not
      // round upward or force a minimum lot that violates the free-margin ceiling.
      double minimumLots=NormalizeDouble((double)minUnits*volumeStep,digits);
      double minimumMargin=0.0;
      if(!MarginForVolume(symbol,orderType,minimumLots,executablePrice,
                          minimumMargin,reason))
         return(false);
      if(minimumMargin>budget)
        {
         reason=StringFormat("MINIMUM_VOLUME_EXCEEDS_MARGIN_BUDGET minLots=%.8f required=%.2f budget=%.2f",
                             minimumLots,minimumMargin,budget);
         return(false);
        }

      // Margin is normally monotonic in volume, but we still re-check the final
      // broker-calculated amount instead of assuming a leverage ratio.
      long low=minUnits;
      long high=maxUnits;
      long best=minUnits;
      while(low<=high)
        {
         long mid=low+(high-low)/2;
         double candidateLots=NormalizeDouble((double)mid*volumeStep,digits);
         double candidateMargin=0.0;
         if(!MarginForVolume(symbol,orderType,candidateLots,executablePrice,
                             candidateMargin,reason))
            return(false);
         if(candidateMargin<=budget)
           {
            best=mid;
            low=mid+1;
           }
         else
            high=mid-1;
        }

      approvedLots=NormalizeDouble((double)best*volumeStep,digits);
      if(!MarginForVolume(symbol,orderType,approvedLots,executablePrice,
                          requiredMargin,reason))
        {
         approvedLots=0.0;
         return(false);
        }
      if(approvedLots<volumeMin || requiredMargin>budget)
        {
         approvedLots=0.0;
         requiredMargin=0.0;
         reason="FINAL_MARGIN_SCALED_VOLUME_FAILED_REVALIDATION";
         return(false);
        }

      reason=StringFormat("SCALED_TO_FREE_MARGIN requested=%.8f approved=%.8f required=%.2f budget=%.2f",
                          requestedLots,approvedLots,requiredMargin,budget);
      return(true);
     }

   bool              EmergencyMarginLevelBreached(const double thresholdPct,
                                                   double &currentLevel) const
     {
      currentLevel=AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
      double usedMargin=AccountInfoDouble(ACCOUNT_MARGIN);
      if(!Valid(thresholdPct) || !MathIsValidNumber(usedMargin) || usedMargin<=0.0)
         return(false);
      // A zero/invalid margin level while margin is in use is treated as critical.
      if(!MathIsValidNumber(currentLevel) || currentLevel<=0.0)
         return(true);
      return(currentLevel<thresholdPct);
     }
  };

#endif // AX_MARGINGUARD_MQH
