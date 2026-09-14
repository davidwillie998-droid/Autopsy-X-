//+------------------------------------------------------------------+
//| HeatmapEngine.mqh                                                  |
//| Level-2 order book (Depth of Market) via the real MT5 API:        |
//| MarketBookAdd/MarketBookGet/OnBookEvent. Most retail FX/CFD        |
//| symbols simply do not offer DOM - MarketBookAdd can report        |
//| success while the book itself never actually populates, so this   |
//| tracks genuine staleness on top of the subscription flag rather   |
//| than trusting "subscribed" to mean "has real data."                |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_CORE_HEATMAPENGINE_MQH
#define AX_CORE_HEATMAPENGINE_MQH
#include "Types.mqh"

struct AXBookLevel
  {
   double price;
   double volume;
   bool   isBuy; // true = bid-side (resting buyers), false = ask-side (resting sellers)
  };

class CHeatmapEngine
  {
private:
   string      m_symbol;
   bool        m_subscribed;
   MqlBookInfo m_lastBook[];
   datetime    m_lastUpdate;
   int         m_updateCount;

public:
   bool Init(const string symbol)
     {
      m_symbol = symbol;
      m_lastUpdate = 0;
      m_updateCount = 0;
      m_subscribed = MarketBookAdd(symbol);
      return m_subscribed;
     }

   void Deinit()
     {
      if(m_subscribed) MarketBookRelease(m_symbol);
      m_subscribed=false;
     }

   //--- call from the EA's global OnBookEvent() when it fires for this symbol
   void OnBook()
     {
      MqlBookInfo book[];
      if(!MarketBookGet(m_symbol, book)) return;
      ArrayCopy(m_lastBook, book);
      m_lastUpdate = TimeCurrent();
      m_updateCount++;
     }

   //--- MarketBookAdd succeeding is not proof of real data - many brokers accept the subscription and then
   //--- never actually deliver a populated book for spot FX/CFD symbols. Both conditions must hold.
   bool Available() const
     {
      return m_subscribed && ArraySize(m_lastBook)>0 && (TimeCurrent()-m_lastUpdate) < 30;
     }

   int UpdateCount() const { return m_updateCount; }

   bool GetBestBidAsk(double &bidPrice, double &bidVol, double &askPrice, double &askVol) const
     {
      bidPrice=0.0; bidVol=0.0; askPrice=0.0; askVol=0.0;
      if(!Available()) return false;
      double bestBid=-1.0, bestAsk=DBL_MAX;
      for(int i=0;i<ArraySize(m_lastBook);i++)
        {
         if(m_lastBook[i].type==BOOK_TYPE_BUY && m_lastBook[i].price>bestBid)
           { bestBid=m_lastBook[i].price; bidPrice=m_lastBook[i].price; bidVol=m_lastBook[i].volume_real>0.0?m_lastBook[i].volume_real:(double)m_lastBook[i].volume; }
         if(m_lastBook[i].type==BOOK_TYPE_SELL && m_lastBook[i].price<bestAsk)
           { bestAsk=m_lastBook[i].price; askPrice=m_lastBook[i].price; askVol=m_lastBook[i].volume_real>0.0?m_lastBook[i].volume_real:(double)m_lastBook[i].volume; }
        }
      return bidPrice>0.0 && askPrice>0.0;
     }

   //--- is there an unusually large resting order ("wall") within `tolerance` of a price, on a given side?
   //--- direction>0 looks for a buy-side wall (support), direction<0 looks for a sell-side wall (resistance)
   bool FindWall(int direction, double nearPrice, double tolerance, double &wallPrice, double &wallVolume) const
     {
      wallPrice=0.0; wallVolume=0.0;
      if(!Available()) return false;
      int n=ArraySize(m_lastBook);
      double avgVol=0.0; int counted=0;
      for(int i=0;i<n;i++)
        {
         double v=m_lastBook[i].volume_real>0.0?m_lastBook[i].volume_real:(double)m_lastBook[i].volume;
         if(v>0.0) { avgVol+=v; counted++; }
        }
      if(counted==0) return false;
      avgVol/=counted;

      bool wantBuySide = direction>0;
      double bestVol=-1.0;
      for(int i=0;i<n;i++)
        {
         bool isBuySide = (m_lastBook[i].type==BOOK_TYPE_BUY);
         if(isBuySide!=wantBuySide) continue;
         if(MathAbs(m_lastBook[i].price-nearPrice)>tolerance) continue;
         double v=m_lastBook[i].volume_real>0.0?m_lastBook[i].volume_real:(double)m_lastBook[i].volume;
         if(v > avgVol*2.5 && v>bestVol) { bestVol=v; wallPrice=m_lastBook[i].price; wallVolume=v; }
        }
      return bestVol>0.0;
     }

   //--- top N resting levels on one side, for the dashboard heatmap strip
   int GetTopLevels(bool buySide, AXBookLevel &out[], int maxLevels=10) const
     {
      ArrayResize(out,0);
      if(!Available()) return 0;
      int n=ArraySize(m_lastBook);
      for(int i=0;i<n && ArraySize(out)<maxLevels;i++)
        {
         bool isBuySide=(m_lastBook[i].type==BOOK_TYPE_BUY);
         if(isBuySide!=buySide) continue;
         AXBookLevel lvl;
         lvl.price=m_lastBook[i].price;
         lvl.volume=m_lastBook[i].volume_real>0.0?m_lastBook[i].volume_real:(double)m_lastBook[i].volume;
         lvl.isBuy=isBuySide;
         int k=ArraySize(out); ArrayResize(out,k+1); out[k]=lvl;
        }
      return ArraySize(out);
     }
  };
#endif // AX_CORE_HEATMAPENGINE_MQH
