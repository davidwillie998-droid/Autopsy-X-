//+------------------------------------------------------------------+
//|                                                  MarketData.mqh |
//|  Broker-agnostic symbol properties + lightweight tick ring buffer|
//+------------------------------------------------------------------+
#property strict
#ifndef AX_MARKETDATA_MQH
#define AX_MARKETDATA_MQH
#include "Defs.mqh"

#define AX_TICK_BUFFER_SIZE 512

//+------------------------------------------------------------------+
//| CMarketData - symbol adaptation + rolling tick window             |
//+------------------------------------------------------------------+
class CMarketData
  {
private:
   string            m_symbol;

   //--- broker-adapted symbol properties (section 14) ---
   int               m_digits;
   double            m_point;
   double            m_tickSize;
   double            m_tickValue;
   double            m_contractSize;
   double            m_volMin;
   double            m_volMax;
   double            m_volStep;
   int               m_stopsLevelPts;
   int               m_freezeLevelPts;
   int               m_execMode;

   //--- rolling tick ring buffer ---
   SAxTick           m_ticks[AX_TICK_BUFFER_SIZE];
   int               m_count;      // number of valid samples (<=buffer size)
   int               m_head;       // index of most recent sample

   double            m_lastMid;
   bool              m_haveLast;

public:
                     CMarketData(void) { Reset(); }

   bool              Init(const string symbol)
     {
      m_symbol = symbol;
      if(!SymbolSelect(m_symbol,true))
         return(false);
      RefreshSymbolProperties();
      Reset();
      return(true);
     }

   void              Reset(void)
     {
      m_count   = 0;
      m_head    = -1;
      m_haveLast= false;
      m_lastMid = 0.0;
     }

   void              RefreshSymbolProperties(void)
     {
      m_digits         = (int)SymbolInfoInteger(m_symbol,SYMBOL_DIGITS);
      m_point          = SymbolInfoDouble(m_symbol,SYMBOL_POINT);
      m_tickSize       = SymbolInfoDouble(m_symbol,SYMBOL_TRADE_TICK_SIZE);
      m_tickValue      = SymbolInfoDouble(m_symbol,SYMBOL_TRADE_TICK_VALUE);
      m_contractSize   = SymbolInfoDouble(m_symbol,SYMBOL_TRADE_CONTRACT_SIZE);
      m_volMin         = SymbolInfoDouble(m_symbol,SYMBOL_VOLUME_MIN);
      m_volMax         = SymbolInfoDouble(m_symbol,SYMBOL_VOLUME_MAX);
      m_volStep        = SymbolInfoDouble(m_symbol,SYMBOL_VOLUME_STEP);
      m_stopsLevelPts  = (int)SymbolInfoInteger(m_symbol,SYMBOL_TRADE_STOPS_LEVEL);
      m_freezeLevelPts = (int)SymbolInfoInteger(m_symbol,SYMBOL_TRADE_FREEZE_LEVEL);
      m_execMode       = (int)SymbolInfoInteger(m_symbol,SYMBOL_TRADE_EXEMODE);
      if(m_tickSize<=0) m_tickSize = m_point;
     }

   //--- feed a new tick, returns true if a genuinely new sample was stored ---
   bool              OnTickUpdate(void)
     {
      MqlTick tick;
      if(!SymbolInfoTick(m_symbol,tick))
         return(false);
      if(tick.bid<=0 || tick.ask<=0)
         return(false);

      double mid = (tick.bid+tick.ask)/2.0;
      int dir = 0;
      if(m_haveLast)
        {
         if(mid>m_lastMid) dir = 1;
         else if(mid<m_lastMid) dir = -1;
        }

      m_head = (m_head+1) % AX_TICK_BUFFER_SIZE;
      m_ticks[m_head].time      = tick.time;
      m_ticks[m_head].bid       = tick.bid;
      m_ticks[m_head].ask       = tick.ask;
      m_ticks[m_head].mid       = mid;
      m_ticks[m_head].spreadPts = (m_point>0) ? (tick.ask-tick.bid)/m_point : 0.0;
      m_ticks[m_head].dir       = dir;

      if(m_count<AX_TICK_BUFFER_SIZE) m_count++;
      m_lastMid  = mid;
      m_haveLast = true;
      return(true);
     }

   //--- accessors ---
   string            Symbol(void)          const { return(m_symbol); }
   int               Digits(void)          const { return(m_digits); }
   double            Point(void)           const { return(m_point); }
   double            TickSize(void)        const { return(m_tickSize); }
   double            TickValue(void)       const { return(m_tickValue); }
   double            ContractSize(void)    const { return(m_contractSize); }
   double            VolumeMin(void)       const { return(m_volMin); }
   double            VolumeMax(void)       const { return(m_volMax); }
   double            VolumeStep(void)      const { return(m_volStep); }
   int               StopsLevelPts(void)   const { return(m_stopsLevelPts); }
   int               FreezeLevelPts(void)  const { return(m_freezeLevelPts); }
   int               ExecMode(void)        const { return(m_execMode); }
   int               Count(void)           const { return(m_count); }

   double            CurrentBid(void) const { return(SymbolInfoDouble(m_symbol,SYMBOL_BID)); }
   double            CurrentAsk(void) const { return(SymbolInfoDouble(m_symbol,SYMBOL_ASK)); }
   double            CurrentMid(void) const { return((CurrentBid()+CurrentAsk())/2.0); }
   double            CurrentSpreadPts(void) const
     {
      if(m_point<=0) return(0.0);
      return((CurrentAsk()-CurrentBid())/m_point);
     }

   //--- sample lookup: 0 = most recent, 1 = one before, ... ---
   bool              GetSample(const int back,SAxTick &out) const
     {
      if(back<0 || back>=m_count) return(false);
      int idx = m_head - back;
      if(idx<0) idx += AX_TICK_BUFFER_SIZE;
      out = m_ticks[idx];
      return(true);
     }

   //--- normalize a lot size to the broker's volume step/min/max ---
   double            NormalizeVolume(const double rawLots) const
     {
      double step = (m_volStep>0)? m_volStep : 0.01;
      double vol  = MathFloor(rawLots/step)*step;
      vol = AxClampD(vol,m_volMin,m_volMax);
      int stepDigits = 0;
      double s = step;
      while(MathAbs(s-MathRound(s))>1e-8 && stepDigits<8) { s*=10; stepDigits++; }
      return(NormalizeDouble(vol,stepDigits));
     }

   double            NormalizePrice(const double price) const
     {
      return(NormalizeDouble(price,m_digits));
     }
  };
//+------------------------------------------------------------------+
#endif // AX_MARKETDATA_MQH
