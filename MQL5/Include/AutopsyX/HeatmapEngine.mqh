//+------------------------------------------------------------------+
//| HeatmapEngine.mqh                                                 |
//| Real order-book liquidity heatmap via MarketBookGet, where the    |
//| broker/symbol actually exposes a DOM. Most OTC forex/CFD symbols  |
//| do not - this degrades to a clearly-flagged "unavailable" state   |
//| rather than fabricating a heatmap out of tick data.               |
//+------------------------------------------------------------------+
#pragma once
#include <AutopsyX/Defines.mqh>

#define AX_HEATMAP_LEVELS 5

class CAXHeatmap
{
private:
   string   m_symbol;
   bool     m_domAvailable;
   double   m_bidDepthNear;
   double   m_askDepthNear;
   double   m_imbalance;       // -1 (ask-heavy) .. +1 (bid-heavy)
   datetime m_lastUpdate;

public:
   CAXHeatmap(void) : m_domAvailable(false), m_bidDepthNear(0), m_askDepthNear(0),
      m_imbalance(0), m_lastUpdate(0) {}

   void Init(const string symbol)
   {
      m_symbol = symbol;
      m_domAvailable = MarketBookAdd(symbol);
      if(!m_domAvailable)
         PrintFormat("AutopsyX: DOM/order-book not available for %s on this broker - heatmap factor stays neutral", symbol);
   }

   void Deinit(void)
   {
      if(m_domAvailable) MarketBookRelease(m_symbol);
   }

   // cheap to call every tick - MarketBookGet just reads the last snapshot,
   // it does not itself request network I/O
   void Update(void)
   {
      if(!m_domAvailable) return;

      MqlBookInfo book[];
      if(!MarketBookGet(m_symbol, book))
      {
         m_imbalance = 0.0;
         return;
      }

      double bidVol = 0.0, askVol = 0.0;
      int bidLevelsSeen = 0, askLevelsSeen = 0;
      int n = ArraySize(book);
      for(int i = 0; i < n; i++)
      {
         if(book[i].type == BOOK_TYPE_BUY || book[i].type == BOOK_TYPE_BUY_MARKET)
         {
            if(bidLevelsSeen < AX_HEATMAP_LEVELS) { bidVol += book[i].volume_real > 0 ? book[i].volume_real : book[i].volume; bidLevelsSeen++; }
         }
         else if(book[i].type == BOOK_TYPE_SELL || book[i].type == BOOK_TYPE_SELL_MARKET)
         {
            if(askLevelsSeen < AX_HEATMAP_LEVELS) { askVol += book[i].volume_real > 0 ? book[i].volume_real : book[i].volume; askLevelsSeen++; }
         }
      }

      m_bidDepthNear = bidVol;
      m_askDepthNear = askVol;
      double total = bidVol + askVol;
      m_imbalance = (total > 0.0) ? AXClamp((bidVol - askVol) / total, -1.0, 1.0) : 0.0;
      m_lastUpdate = TimeTradeServer();
   }

   bool   DomAvailable(void)   const { return m_domAvailable; }
   double BidDepthNear(void)   const { return m_bidDepthNear; }
   double AskDepthNear(void)   const { return m_askDepthNear; }
   // +1 = bid-heavy (buy-side liquidity dominant), -1 = ask-heavy, 0 = balanced or unavailable
   double Imbalance(void)      const { return m_domAvailable ? m_imbalance : 0.0; }
};
