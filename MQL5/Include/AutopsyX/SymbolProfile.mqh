//+------------------------------------------------------------------+
//| SymbolProfile.mqh                                                 |
//| Auto-detects broker/symbol execution properties. No hard-coded    |
//| pip assumptions anywhere - everything is derived at runtime.      |
//+------------------------------------------------------------------+
#pragma once
#include <AutopsyX/Defines.mqh>

class CAXSymbolProfile
{
public:
   string   symbol;
   int      digits;
   double   point;
   double   tick_size;
   double   tick_value;
   double   contract_size;
   double   volume_min;
   double   volume_max;
   double   volume_step;
   int      stops_level_points;
   int      freeze_level_points;
   // a "point" here means SymbolInfoDouble point; we express distances
   // in "price points" (multiples of `point`) throughout the engines.

   bool Init(const string sym)
   {
      symbol = sym;
      digits        = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      point          = SymbolInfoDouble(symbol, SYMBOL_POINT);
      tick_size      = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
      tick_value     = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
      contract_size  = SymbolInfoDouble(symbol, SYMBOL_TRADE_CONTRACT_SIZE);
      volume_min     = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
      volume_max     = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
      volume_step    = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
      stops_level_points  = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
      freeze_level_points = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);

      if(point <= 0.0 || tick_size <= 0.0 || contract_size <= 0.0)
         return false;
      return true;
   }

   // price distance (in raw price units) -> points
   double PriceToPoints(const double priceDelta) const
   {
      if(point <= 0.0) return 0.0;
      return priceDelta / point;
   }

   double PointsToPrice(const double points) const
   {
      return points * point;
   }

   double NormalizePrice(const double price) const
   {
      if(tick_size <= 0.0) return NormalizeDouble(price, digits);
      double n = MathRound(price / tick_size) * tick_size;
      return NormalizeDouble(n, digits);
   }

   double NormalizeVolume(const double vol) const
   {
      double v = vol;
      if(volume_step > 0.0)
         v = MathRound(v / volume_step) * volume_step;
      v = AXClamp(v, volume_min, volume_max);
      return NormalizeDouble(v, 8);
   }

   bool IsTradingAllowed() const
   {
      long mode = SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE);
      return (mode == SYMBOL_TRADE_MODE_FULL);
   }

   bool IsMarketOpen() const
   {
      datetime from, to;
      MqlDateTime dt;
      TimeToStruct(TimeTradeServer(), dt);
      ENUM_DAY_OF_WEEK dow = (ENUM_DAY_OF_WEEK)dt.day_of_week;
      // if there is at least one active session "now", market is open
      for(uint i = 0; i < 8; i++)
      {
         if(!SymbolInfoSessionTrade(symbol, dow, i, from, to))
            break;
         if(from == 0 && to == 0) continue;
         int nowSec = dt.hour * 3600 + dt.min * 60 + dt.sec;
         MqlDateTime f, t;
         TimeToStruct(from, f);
         TimeToStruct(to, t);
         int fromSec = f.hour * 3600 + f.min * 60 + f.sec;
         int toSec   = t.hour * 3600 + t.min * 60 + t.sec;
         if(nowSec >= fromSec && nowSec <= toSec)
            return true;
      }
      return false;
   }

   // minimum stop distance in price units, respecting broker stops level
   double MinStopDistancePrice() const
   {
      return stops_level_points * point;
   }

   double FreezeDistancePrice() const
   {
      return freeze_level_points * point;
   }
};
