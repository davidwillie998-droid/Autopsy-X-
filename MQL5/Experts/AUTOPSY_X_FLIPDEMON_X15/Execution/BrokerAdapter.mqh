//+------------------------------------------------------------------+
//| BrokerAdapter.mqh                                                     |
//| Section 26 — pre-trade broker/execution safety checks. Every gate    |
//| here must pass before an order is ever prepared. This is the         |
//| "BROKER / EXECUTION SAFETY" rung of the decision hierarchy.          |
//|                                                                        |
//| LIVE VS DEMO: a demo server routinely shows tighter, steadier spreads |
//| than the live server the account actually trades on, so a single      |
//| fixed spread ceiling is not enough on its own — this adapter also      |
//| rejects a spread that is a blowout relative to THIS symbol's own      |
//| recent normal (median), and blocks the rollover window where live     |
//| spread/slippage is well known to spike in ways demo often does not.   |
//+------------------------------------------------------------------+
#ifndef AXF_BROKERADAPTER_MQH
#define AXF_BROKERADAPTER_MQH

#include "../Common/Defines.mqh"

class CAxfBrokerAdapter
  {
public:
   //--- returns "" if all checks pass, otherwise a short reason string.
   //--- 'median_spread_points' <=0 or 'spread_samples' below the configured
   //--- minimum means "not enough history yet" — falls back to the absolute
   //--- ceiling alone rather than judging against an unreliable median.
   string            PreTradeCheck(const string symbol,const double max_spread_points,
                                    const double stop_distance_price,
                                    const double median_spread_points=-1,
                                    const int spread_samples=0,
                                    const int min_samples_to_judge=30,
                                    const double spread_anomaly_multiple=1.8)
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

      if(spread_samples >= min_samples_to_judge && median_spread_points>0)
        {
         double ratio = spread_points/median_spread_points;
         if(ratio > spread_anomaly_multiple)
            return StringFormat("spread %.1f pts is %.1fx this symbol's own normal (%.1f pts) — live blowout, not a fixed limit",
                                 spread_points,ratio,median_spread_points);
        }

      int stops_level = (int)SymbolInfoInteger(symbol,SYMBOL_TRADE_STOPS_LEVEL);
      int freeze_level = (int)SymbolInfoInteger(symbol,SYMBOL_TRADE_FREEZE_LEVEL);
      double min_stop_price = MathMax(stops_level,freeze_level)*point;
      if(stop_distance_price>0 && stop_distance_price < min_stop_price)
         return "stop distance below broker minimum";

      double margin_free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(margin_free<=0) return "no free margin";

      return "";
     }

   //--- live rollover (typically ~23:00-00:00 server time, broker-specific) is
   //--- when spreads/slippage on a REAL account widen the most and demo
   //--- testing usually under-represents this; block new entries in a window
   //--- around it. Existing positions are still managed normally.
   bool              IsRolloverWindow(const int rollover_hour_server,const int blackout_mins)
     {
      MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
      int now_mins = dt.hour*60+dt.min;
      int rollover_mins = (rollover_hour_server%24)*60;

      int diff = MathAbs(now_mins-rollover_mins);
      diff = MathMin(diff,1440-diff); // wrap around midnight
      return diff <= blackout_mins;
     }

   bool              VerifyPositionExists(const ulong ticket)
     {
      return PositionSelectByTicket(ticket);
     }
  };

#endif // AXF_BROKERADAPTER_MQH
