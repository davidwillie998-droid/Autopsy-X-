//+------------------------------------------------------------------+
//| MarketDataEngine.mqh                                              |
//| Single entry point for tick + bar ingestion. Feeds the tick ring  |
//| buffer every tick and refreshes the bar cache only on a new bar,  |
//| so downstream engines never recompute more than necessary.        |
//+------------------------------------------------------------------+
#pragma once
#include <AutopsyX/Defines.mqh>
#include <AutopsyX/SymbolProfile.mqh>
#include <AutopsyX/TickBuffer.mqh>

class CAXMarketData
{
private:
   string        m_symbol;
   ENUM_TIMEFRAMES m_tf;
   MqlTick       m_lastTick;
   MqlRates      m_rates[];
   datetime      m_lastBarTime;
   bool          m_newBar;

public:
   CAXTickBuffer ticks;

   CAXMarketData(void) : m_lastBarTime(0), m_newBar(false) {}

   bool Init(const string symbol, const ENUM_TIMEFRAMES tf, const int tickCapacity)
   {
      m_symbol = symbol;
      m_tf     = tf;
      ticks.Init(tickCapacity);
      ArraySetAsSeries(m_rates, true);
      return RefreshBars();
   }

   bool RefreshBars(void)
   {
      int copied = CopyRates(m_symbol, m_tf, 0, AX_BAR_STRUCT_LOOKBACK, m_rates);
      return (copied > 0);
   }

   // call once per OnTick(); returns false if tick fetch failed
   bool OnTick(void)
   {
      if(!SymbolInfoTick(m_symbol, m_lastTick))
         return false;

      ticks.Push(m_lastTick.time, m_lastTick.time_msc, m_lastTick.bid, m_lastTick.ask);

      m_newBar = false;
      datetime curBarTime = iTime(m_symbol, m_tf, 0);
      if(curBarTime != m_lastBarTime && curBarTime != 0)
      {
         m_lastBarTime = curBarTime;
         m_newBar = true;
         RefreshBars();
      }
      return true;
   }

   bool IsNewBar(void) const { return m_newBar; }
   const MqlTick LastTick(void) const { return m_lastTick; }
   double Bid(void) const { return m_lastTick.bid; }
   double Ask(void) const { return m_lastTick.ask; }
   double Mid(void) const { return (m_lastTick.bid + m_lastTick.ask) * 0.5; }

   int RatesCount(void) const { return ArraySize(m_rates); }
   // idx = 0 -> current (forming) bar, idx = 1 -> last closed bar, series order
   bool GetRate(const int idx, MqlRates &out) const
   {
      if(idx < 0 || idx >= ArraySize(m_rates)) return false;
      out = m_rates[idx];
      return true;
   }

   int CopyRatesOut(MqlRates &dst[]) const
   {
      ArraySetAsSeries(dst, true);
      return ArrayCopy(dst, m_rates);
   }
};
