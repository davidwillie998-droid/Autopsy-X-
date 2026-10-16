//+------------------------------------------------------------------+
//| MarketEngine.mqh                                                   |
//| Layer 01 — MARKET DATA ENGINE.                                     |
//| Owns raw data access: symbol specs, ticks, spread, bar caches.     |
//| Every other engine reads market data through this, never directly |
//| via bare SymbolInfo/CopyRates calls, so data-quality checks live   |
//| in exactly one place.                                              |
//+------------------------------------------------------------------+
#ifndef AXF_MARKETENGINE_MQH
#define AXF_MARKETENGINE_MQH

#include "../Common/Defines.mqh"

class CAxfMarketEngine
  {
private:
   string            m_symbol;
   double            m_point;
   int               m_digits;
   double            m_tick_size;
   double            m_tick_value;
   double            m_contract_size;
   double            m_volume_min, m_volume_max, m_volume_step;
   int               m_stops_level, m_freeze_level;
   datetime          m_last_tick_time;
   bool              m_data_ok;

   //--- Live execution realism: this account's OWN rolling spread history for
   //--- this symbol, so "wide spread" is judged relative to what is actually
   //--- normal here (demo servers routinely show tighter/steadier spreads than
   //--- the live server this EA is actually trading on).
   double            m_spread_history[];
   int               m_spread_head;
   int               m_spread_count;
   int               m_spread_capacity;

public:
                     CAxfMarketEngine(void) { Reset(); }

   void              Reset(void)
     {
      m_symbol=_Symbol; m_point=0; m_digits=0; m_tick_size=0; m_tick_value=0;
      m_contract_size=0; m_volume_min=0; m_volume_max=0; m_volume_step=0;
      m_stops_level=0; m_freeze_level=0; m_last_tick_time=0; m_data_ok=false;
      m_spread_head=0; m_spread_count=0; m_spread_capacity=0;
      ArrayResize(m_spread_history,0);
     }

   void              InitSpreadHistory(const int capacity)
     {
      m_spread_capacity = MathMax(10,capacity);
      ArrayResize(m_spread_history,m_spread_capacity);
      ArrayInitialize(m_spread_history,0.0);
      m_spread_head=0; m_spread_count=0;
     }

   //--- call once per timer cycle (not per tick — this is a slow, structural
   //--- read of "what is normal here", not a high-frequency signal).
   void              RecordSpreadSample(void)
     {
      if(m_spread_capacity<=0) return;
      double sp = SpreadPoints();
      if(sp<0) return;
      m_spread_history[m_spread_head] = sp;
      m_spread_head = (m_spread_head+1) % m_spread_capacity;
      if(m_spread_count<m_spread_capacity) m_spread_count++;
     }

   //--- median is deliberately used over mean — a handful of spike samples
   //--- (news, rollover) must not drag the "normal" baseline up with them.
   double            MedianSpreadPoints(void) const
     {
      if(m_spread_count<=0) return -1;
      double tmp[]; ArrayResize(tmp,m_spread_count);
      for(int i=0;i<m_spread_count;i++) tmp[i]=m_spread_history[i];
      ArraySort(tmp);
      int mid = m_spread_count/2;
      if(m_spread_count%2==1) return tmp[mid];
      return (tmp[mid-1]+tmp[mid])/2.0;
     }

   int               SpreadSampleCount(void) const { return m_spread_count; }

   bool              Init(const string symbol)
     {
      m_symbol = symbol;
      if(!SymbolSelect(m_symbol,true))
        {
         Print("AXF MarketEngine: cannot select symbol ",m_symbol);
         return false;
        }
      RefreshSpecs();
      return m_data_ok;
     }

   void              RefreshSpecs(void)
     {
      m_point         = SymbolInfoDouble(m_symbol,SYMBOL_POINT);
      m_digits        = (int)SymbolInfoInteger(m_symbol,SYMBOL_DIGITS);
      m_tick_size     = SymbolInfoDouble(m_symbol,SYMBOL_TRADE_TICK_SIZE);
      m_tick_value    = SymbolInfoDouble(m_symbol,SYMBOL_TRADE_TICK_VALUE);
      m_contract_size = SymbolInfoDouble(m_symbol,SYMBOL_TRADE_CONTRACT_SIZE);
      m_volume_min    = SymbolInfoDouble(m_symbol,SYMBOL_VOLUME_MIN);
      m_volume_max    = SymbolInfoDouble(m_symbol,SYMBOL_VOLUME_MAX);
      m_volume_step   = SymbolInfoDouble(m_symbol,SYMBOL_VOLUME_STEP);
      m_stops_level   = (int)SymbolInfoInteger(m_symbol,SYMBOL_TRADE_STOPS_LEVEL);
      m_freeze_level  = (int)SymbolInfoInteger(m_symbol,SYMBOL_TRADE_FREEZE_LEVEL);

      m_data_ok = (m_point>0 && m_tick_size>0 && m_tick_value>0 && m_contract_size>0 && m_volume_step>0);
     }

   //--- freshness / sanity check. Stale or zero data must never feed decisions.
   bool              IsDataFresh(const int max_seconds=120)
     {
      MqlTick tick;
      if(!SymbolInfoTick(m_symbol,tick)) return false;
      if(tick.bid<=0 || tick.ask<=0) return false;
      if(tick.ask<tick.bid) return false;
      m_last_tick_time = tick.time;
      long server_now = TimeCurrent();
      if(server_now - tick.time > max_seconds) return false;
      return true;
     }

   double            Bid(void) { return SymbolInfoDouble(m_symbol,SYMBOL_BID); }
   double            Ask(void) { return SymbolInfoDouble(m_symbol,SYMBOL_ASK); }
   double            Mid(void) { return (Bid()+Ask())/2.0; }
   double            SpreadPoints(void)
     {
      if(m_point<=0) return -1;
      return (Ask()-Bid())/m_point;
     }

   string            Symbol(void)   const { return m_symbol; }
   double            Point(void)    const { return m_point; }
   int               Digits(void)   const { return m_digits; }
   double            TickSize(void) const { return m_tick_size; }
   double            TickValue(void)const { return m_tick_value; }
   double            ContractSize(void) const { return m_contract_size; }
   double            VolumeMin(void)  const { return m_volume_min; }
   double            VolumeMax(void)  const { return m_volume_max; }
   double            VolumeStep(void) const { return m_volume_step; }
   int               StopsLevelPoints(void)  const { return m_stops_level; }
   int               FreezeLevelPoints(void)const { return m_freeze_level; }
   bool              SpecsValid(void) const { return m_data_ok; }

   //--- money value of a 1-point move on 'lots' lots, using tick value/size.
   double            PointValue(const double lots) const
     {
      if(m_tick_size<=0) return 0;
      return (m_point/m_tick_size)*m_tick_value*lots;
     }

   //--- pulls 'count' bars (0 = current forming bar included) into caller arrays.
   int               CopyBars(const ENUM_TIMEFRAMES tf,const int start,const int count,
                               MqlRates &rates[])
     {
      ArraySetAsSeries(rates,true);
      int copied = CopyRates(m_symbol,tf,start,count,rates);
      return copied;
     }

   bool              NormalizeVolume(double &lots) const
     {
      if(m_volume_step<=0) return false;
      lots = MathFloor(lots/m_volume_step)*m_volume_step;
      lots = AxfClamp(lots,m_volume_min,m_volume_max);
      return (lots>=m_volume_min);
     }

   double            NormalizePrice(const double price) const
     {
      if(m_tick_size<=0) return NormalizeDouble(price,m_digits);
      return NormalizeDouble(MathRound(price/m_tick_size)*m_tick_size,m_digits);
     }
  };

#endif // AXF_MARKETENGINE_MQH
