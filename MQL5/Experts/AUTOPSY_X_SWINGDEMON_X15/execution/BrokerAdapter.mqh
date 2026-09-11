//+------------------------------------------------------------------+
//| BrokerAdapter.mqh                                                 |
//| Reads real broker/symbol specifications and normalizes orders.    |
//| Nothing in this file is assumed - every spec is queried live.     |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_EXECUTION_BROKERADAPTER_MQH
#define AX_EXECUTION_BROKERADAPTER_MQH
#include "../core/Types.mqh"

class CBrokerAdapter
  {
private:
   string   m_symbol;

public:
   int      digits;
   double   point;
   double   tickSize;
   double   tickValue;
   double   contractSize;
   double   volumeMin;
   double   volumeMax;
   double   volumeStep;
   long     stopLevelPoints;
   long     freezeLevelPoints;
   int      filling; // ENUM_SYMBOL_TRADE_EXECUTION-derived filling mode to use
   bool     tradeAllowed;

   void Init(const string symbol)
     {
      m_symbol = symbol;
      Refresh();
     }

   void Refresh()
     {
      digits            = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
      point             = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      tickSize          = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_SIZE);
      tickValue         = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_VALUE);
      contractSize      = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_CONTRACT_SIZE);
      volumeMin         = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
      volumeMax         = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MAX);
      volumeStep        = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);
      stopLevelPoints   = SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL);
      freezeLevelPoints = SymbolInfoInteger(m_symbol, SYMBOL_TRADE_FREEZE_LEVEL);
      tradeAllowed      = (SymbolInfoInteger(m_symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_FULL);
      filling           = ResolveFillingMode();
     }

   double Bid() const { return SymbolInfoDouble(m_symbol, SYMBOL_BID); }
   double Ask() const { return SymbolInfoDouble(m_symbol, SYMBOL_ASK); }
   double SpreadPoints() const
     {
      double bid = Bid(), ask = Ask();
      if(point <= 0.0) return 0.0;
      return (ask - bid) / point;
     }

   //--- round price to the symbol's tick size
   double NormalizePrice(double price) const
     {
      if(tickSize <= 0.0) return NormalizeDouble(price, digits);
      double steps = MathRound(price / tickSize);
      return NormalizeDouble(steps * tickSize, digits);
     }

   //--- round volume to the symbol's lot step and clamp to broker limits
   double NormalizeVolume(double volume) const
     {
      if(volumeStep <= 0.0) return volumeMin;
      double steps = MathFloor(volume / volumeStep + 1e-8);
      double vol = steps * volumeStep;
      vol = MathMax(vol, volumeMin);
      vol = MathMin(vol, volumeMax);
      return NormalizeDouble(vol, 8);
     }

   //--- minimum distance (in price) that SL/TP must sit from current price
   double MinStopDistance() const
     {
      long lvl = MathMax(stopLevelPoints, freezeLevelPoints);
      return lvl * point;
     }

   //--- money value of one point move for one lot
   double PointValuePerLot() const
     {
      if(tickSize <= 0.0) return 0.0;
      return tickValue * (point / tickSize);
     }

   //--- convert a stop distance in price units to money risk for a given volume
   double RiskMoneyForStop(double stopDistancePrice, double volume) const
     {
      double pointValue = PointValuePerLot();
      if(point <= 0.0) return 0.0;
      double pointsInStop = stopDistancePrice / point;
      return pointsInStop * pointValue * volume;
     }

   //--- solve for volume that risks exactly riskMoney given a stop distance
   double VolumeForRisk(double riskMoney, double stopDistancePrice) const
     {
      double pointValue = PointValuePerLot();
      if(point <= 0.0 || pointValue <= 0.0 || stopDistancePrice <= 0.0) return 0.0;
      double pointsInStop = stopDistancePrice / point;
      if(pointsInStop <= 0.0) return 0.0;
      double rawVolume = riskMoney / (pointsInStop * pointValue);
      return NormalizeVolume(rawVolume);
     }

   bool MarketOpen() const
     {
      datetime from, to;
      MqlDateTime dt; TimeToStruct(TimeTradeServer(), dt);
      return SymbolInfoSessionTrade(m_symbol, (ENUM_DAY_OF_WEEK)dt.day_of_week, 0, from, to);
     }

private:
   int ResolveFillingMode() const
     {
      long modeFlags = SymbolInfoInteger(m_symbol, SYMBOL_FILLING_MODE);
      if((modeFlags & SYMBOL_FILLING_FOK) != 0)  return ORDER_FILLING_FOK;
      if((modeFlags & SYMBOL_FILLING_IOC) != 0)  return ORDER_FILLING_IOC;
      return ORDER_FILLING_RETURN;
     }
  };
#endif // AX_EXECUTION_BROKERADAPTER_MQH
