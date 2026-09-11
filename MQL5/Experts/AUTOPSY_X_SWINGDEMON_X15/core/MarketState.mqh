//+------------------------------------------------------------------+
//| MarketState.mqh                                                   |
//| Single source of truth for multi-timeframe price/ATR data.        |
//| Every engine reads through this instead of calling CopyRates      |
//| directly, so the whole EA shares one consistent view of the tape. |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_CORE_MARKETSTATE_MQH
#define AX_CORE_MARKETSTATE_MQH
#include "Types.mqh"

#define AX_TF_COUNT 8

class CMarketState
  {
private:
   string          m_symbol;
   ENUM_TIMEFRAMES m_tfs[AX_TF_COUNT];
   int             m_atrHandle[AX_TF_COUNT];
   MqlRates        m_rates[AX_TF_COUNT][];
   datetime        m_lastBarTime[AX_TF_COUNT];

   int IndexOf(ENUM_TIMEFRAMES tf) const
     {
      for(int i=0;i<AX_TF_COUNT;i++)
         if(m_tfs[i]==tf) return i;
      return -1;
     }

public:
   void Init(const string symbol)
     {
      m_symbol = symbol;
      m_tfs[0]=PERIOD_MN1; m_tfs[1]=PERIOD_W1; m_tfs[2]=PERIOD_D1; m_tfs[3]=PERIOD_H4;
      m_tfs[4]=PERIOD_H1;  m_tfs[5]=PERIOD_M15; m_tfs[6]=PERIOD_M5; m_tfs[7]=PERIOD_M1;
      for(int i=0;i<AX_TF_COUNT;i++)
        {
         m_atrHandle[i] = iATR(m_symbol, m_tfs[i], 14);
         m_lastBarTime[i] = 0;
        }
     }

   void Deinit()
     {
      for(int i=0;i<AX_TF_COUNT;i++)
         if(m_atrHandle[i]!=INVALID_HANDLE) IndicatorRelease(m_atrHandle[i]);
     }

   //--- refresh cached rate arrays for every tracked timeframe; call once per tick
   void Update()
     {
      for(int i=0;i<AX_TF_COUNT;i++)
        {
         int copied = CopyRates(m_symbol, m_tfs[i], 0, 300, m_rates[i]);
         if(copied>0) ArraySetAsSeries(m_rates[i], true);
        }
     }

   bool IsNewBar(ENUM_TIMEFRAMES tf)
     {
      int idx = IndexOf(tf);
      if(idx<0) return false;
      datetime t = iTime(m_symbol, tf, 0);
      if(t!=m_lastBarTime[idx])
        {
         m_lastBarTime[idx]=t;
         return true;
        }
      return false;
     }

   int Bars(ENUM_TIMEFRAMES tf) const
     {
      int idx = IndexOf(tf);
      if(idx<0) return 0;
      return ArraySize(m_rates[idx]);
     }

   double High(ENUM_TIMEFRAMES tf, int shift) const
     {
      int idx = IndexOf(tf);
      if(idx<0 || shift>=ArraySize(m_rates[idx])) return 0.0;
      return m_rates[idx][shift].high;
     }

   double Low(ENUM_TIMEFRAMES tf, int shift) const
     {
      int idx = IndexOf(tf);
      if(idx<0 || shift>=ArraySize(m_rates[idx])) return 0.0;
      return m_rates[idx][shift].low;
     }

   double Close(ENUM_TIMEFRAMES tf, int shift) const
     {
      int idx = IndexOf(tf);
      if(idx<0 || shift>=ArraySize(m_rates[idx])) return 0.0;
      return m_rates[idx][shift].close;
     }

   double Open(ENUM_TIMEFRAMES tf, int shift) const
     {
      int idx = IndexOf(tf);
      if(idx<0 || shift>=ArraySize(m_rates[idx])) return 0.0;
      return m_rates[idx][shift].open;
     }

   datetime Time(ENUM_TIMEFRAMES tf, int shift) const
     {
      int idx = IndexOf(tf);
      if(idx<0 || shift>=ArraySize(m_rates[idx])) return 0;
      return m_rates[idx][shift].time;
     }

   long Volume(ENUM_TIMEFRAMES tf, int shift) const
     {
      int idx = IndexOf(tf);
      if(idx<0 || shift>=ArraySize(m_rates[idx])) return 0;
      return m_rates[idx][shift].tick_volume;
     }

   double ATR(ENUM_TIMEFRAMES tf, int shift=0) const
     {
      int idx = IndexOf(tf);
      if(idx<0 || m_atrHandle[idx]==INVALID_HANDLE) return 0.0;
      double buf[];
      ArraySetAsSeries(buf, true);
      if(CopyBuffer(m_atrHandle[idx], 0, shift, 1, buf)<=0) return 0.0;
      return buf[0];
     }

   double Bid() const { return SymbolInfoDouble(m_symbol, SYMBOL_BID); }
   double Ask() const { return SymbolInfoDouble(m_symbol, SYMBOL_ASK); }
   double Mid() const { return (Bid()+Ask())/2.0; }

   string Symbol() const { return m_symbol; }
  };
#endif // AX_CORE_MARKETSTATE_MQH
