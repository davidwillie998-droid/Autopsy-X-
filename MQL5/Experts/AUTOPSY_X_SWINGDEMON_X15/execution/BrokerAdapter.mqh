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
   double   m_spreadHistory[]; // rolling window - live spread varies tick to tick, demo often doesn't
   int      m_fillingModes[3]; // broker-supported filling modes, in try-order
   int      m_fillingModeCount;

public:
   int      digits;
   double   point;
   double   tickSize;
   double   tickValue;
   double   contractSize;
   double   volumeMin;
   double   volumeMax;
   double   volumeStep;
   double   volumeLimit;   // 0 = no aggregate cap; otherwise max combined open+pending volume on this symbol
   long     stopLevelPoints;
   long     freezeLevelPoints;
   int      filling; // preferred ENUM_ORDER_TYPE_FILLING to try first
   bool     tradeAllowed;

   void Init(const string symbol)
     {
      m_symbol = symbol;
      ArrayResize(m_spreadHistory, 0);
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
      volumeLimit       = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_LIMIT);
      stopLevelPoints   = SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL);
      freezeLevelPoints = SymbolInfoInteger(m_symbol, SYMBOL_TRADE_FREEZE_LEVEL);
      tradeAllowed      = (SymbolInfoInteger(m_symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_FULL);
      ResolveFillingModes();
      filling           = m_fillingModeCount>0 ? m_fillingModes[0] : ORDER_FILLING_FOK;
      LogSpread(SpreadPoints());
     }

   double Bid() const { return SymbolInfoDouble(m_symbol, SYMBOL_BID); }
   double Ask() const { return SymbolInfoDouble(m_symbol, SYMBOL_ASK); }
   double Mid() const { return (Bid()+Ask())/2.0; }
   double SpreadPoints() const
     {
      double bid = Bid(), ask = Ask();
      if(point <= 0.0) return 0.0;
      return (ask - bid) / point;
     }

   //--- rolling average spread this account has actually seen recently (not a broker-quoted "typical" figure)
   double AverageSpreadPoints() const
     {
      int n = ArraySize(m_spreadHistory);
      if(n==0) return SpreadPoints();
      double sum=0.0;
      for(int i=0;i<n;i++) sum+=m_spreadHistory[i];
      return sum/n;
     }

   //--- true when the CURRENT spread is blowing out relative to this account's own recent norm -
   //--- catches news/rollover/thin-liquidity spikes that a single static point cap can't tell apart
   //--- from a broker that just always quotes wide (e.g. some brokers run 300+ pt on gold routinely)
   bool IsSpreadSpiking(double multiple=2.5) const
     {
      int n = ArraySize(m_spreadHistory);
      if(n < 20) return false; // not enough live history yet to know what "normal" is for this account
      double avg = AverageSpreadPoints();
      if(avg<=0.0) return false;
      return SpreadPoints() > avg*multiple;
     }

   int FillingModeCount() const { return m_fillingModeCount; }
   int FillingModeAt(int i) const { return (i>=0 && i<m_fillingModeCount) ? m_fillingModes[i] : ORDER_FILLING_FOK; }

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
   //--- broker-advertised filling modes are sometimes wrong or incomplete on live servers, so this
   //--- builds a try-order rather than committing to one mode; ExecutionEngine falls back through it
   //--- on TRADE_RETCODE_INVALID_FILL instead of just retrying the same rejected request
   void ResolveFillingModes()
     {
      m_fillingModeCount = 0;
      long modeFlags = SymbolInfoInteger(m_symbol, SYMBOL_FILLING_MODE);
      if((modeFlags & SYMBOL_FILLING_FOK) != 0)  m_fillingModes[m_fillingModeCount++] = ORDER_FILLING_FOK;
      if((modeFlags & SYMBOL_FILLING_IOC) != 0)  m_fillingModes[m_fillingModeCount++] = ORDER_FILLING_IOC;
      m_fillingModes[m_fillingModeCount++] = ORDER_FILLING_RETURN; // always a valid last resort to try
     }

   void LogSpread(double points)
     {
      int n = ArraySize(m_spreadHistory);
      if(n>=100) ArrayRemove(m_spreadHistory,0,1);
      n = ArraySize(m_spreadHistory);
      ArrayResize(m_spreadHistory,n+1);
      m_spreadHistory[n]=points;
     }
  };
#endif // AX_EXECUTION_BROKERADAPTER_MQH
