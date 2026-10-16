//+------------------------------------------------------------------+
//| EntryEngine.mqh                                                    |
//| Final pre-trade validation gate. Execution quality first: every   |
//| condition is re-checked immediately before an order is sent, and  |
//| if anything has deteriorated since the signal fired, the trade is |
//| cancelled outright rather than chased.                            |
//+------------------------------------------------------------------+
#pragma once
#include <AutopsyX/Defines.mqh>
#include <AutopsyX/SymbolProfile.mqh>

class CAXEntry
{
public:
   bool Validate(const CAXSymbolProfile &profile, const ENUM_AX_DIRECTION direction, double &lots,
                 const double spreadPts, const double spreadExpansionRatio,
                 const double maxSpreadPts, const double maxSpreadExpansion,
                 const ENUM_AX_DIRECTION currentSignalDirection, string &reason)
   {
      reason = "";

      if(direction == AX_DIR_NONE)
      {
         reason = "no direction";
         return false;
      }
      if(currentSignalDirection != direction)
      {
         reason = "signal invalidated between decision and execution";
         return false;
      }
      if(!profile.IsTradingAllowed())
      {
         reason = "symbol trade mode not tradable";
         return false;
      }
      if(!profile.IsMarketOpen())
      {
         reason = "market/session closed";
         return false;
      }
      if(spreadPts > maxSpreadPts)
      {
         reason = StringFormat("spread too wide (%.1f > %.1f pts)", spreadPts, maxSpreadPts);
         return false;
      }
      if(spreadExpansionRatio > maxSpreadExpansion)
      {
         reason = StringFormat("abnormal spread expansion (x%.2f)", spreadExpansionRatio);
         return false;
      }

      double bid = SymbolInfoDouble(profile.symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(profile.symbol, SYMBOL_ASK);
      if(bid <= 0.0 || ask <= 0.0 || ask <= bid)
      {
         reason = "invalid quote";
         return false;
      }

      lots = profile.NormalizeVolume(lots);
      if(lots < profile.volume_min)
      {
         reason = "computed lot size below broker minimum";
         return false;
      }

      double price = (direction == AX_DIR_BUY) ? ask : bid;
      ENUM_ORDER_TYPE otype = (direction == AX_DIR_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double marginRequired = 0.0;
      if(!OrderCalcMargin(otype, profile.symbol, lots, price, marginRequired))
      {
         reason = "margin calculation failed";
         return false;
      }
      double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(marginRequired > freeMargin)
      {
         reason = "insufficient free margin";
         return false;
      }

      return true;
   }
};
