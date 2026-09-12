//+------------------------------------------------------------------+
//| BrokerAdapter.mqh                                                     |
//| Section 26 — pre-trade broker/execution safety checks. Every gate    |
//| here must pass before an order is ever prepared. This is the         |
//| "BROKER / EXECUTION SAFETY" rung of the decision hierarchy.          |
//+------------------------------------------------------------------+
#ifndef AXF_BROKERADAPTER_MQH
#define AXF_BROKERADAPTER_MQH

#include "../Common/Defines.mqh"

class CAxfBrokerAdapter
  {
public:
   //--- returns "" if all checks pass, otherwise a short reason string.
   string            PreTradeCheck(const string symbol,const double max_spread_points,
                                    const double stop_distance_price)
     {
      if(!SymbolInfoInteger(symbol,SYMBOL_SELECT)) return "symbol not selected";

      long trade_mode = SymbolInfoInteger(symbol,SYMBOL_TRADE_MODE);
      if(trade_mode==SYMBOL_TRADE_MODE_DISABLED) return "trading disabled on symbol";
      if(trade_mode==SYMBOL_TRADE_MODE_CLOSEONLY) return "symbol close-only";

      if(!(bool)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return "terminal trading not allowed";
      if(!(bool)MQLInfoInteger(MQL_TRADE_ALLOWED)) return "EA trading not allowed";
      if(!(bool)AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)) return "account trading not allowed";
      if(!(bool)AccountInfoInteger(ACCOUNT_TRADE_EXPERT)) return "expert trading disabled for account";

      double bid = SymbolInfoDouble(symbol,SYMBOL_BID);
      double ask = SymbolInfoDouble(symbol,SYMBOL_ASK);
      if(bid<=0 || ask<=0 || ask<bid) return "invalid quote";

      double point = SymbolInfoDouble(symbol,SYMBOL_POINT);
      double spread_points = (point>0) ? (ask-bid)/point : 999999;
      if(spread_points > max_spread_points) return StringFormat("spread too wide (%.1f pts)",spread_points);

      int stops_level = (int)SymbolInfoInteger(symbol,SYMBOL_TRADE_STOPS_LEVEL);
      int freeze_level = (int)SymbolInfoInteger(symbol,SYMBOL_TRADE_FREEZE_LEVEL);
      double min_stop_price = MathMax(stops_level,freeze_level)*point;
      if(stop_distance_price>0 && stop_distance_price < min_stop_price)
         return "stop distance below broker minimum";

      double margin_free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(margin_free<=0) return "no free margin";

      return "";
     }

   bool              VerifyPositionExists(const ulong ticket)
     {
      return PositionSelectByTicket(ticket);
     }
  };

#endif // AXF_BROKERADAPTER_MQH
