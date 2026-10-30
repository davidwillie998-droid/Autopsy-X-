//+------------------------------------------------------------------+
//|                                                      Heatmap.mqh |
//|  Heatmap Engine - depth-of-market liquidity buildup/pull          |
//|                                                                    |
//|  Reads the broker's order book (MarketBookGet) near the touch     |
//|  price and tracks how resting size at each level changes between  |
//|  refreshes - a growing level is a "wall" forming, a shrinking one  |
//|  is being pulled. Most retail forex/CFD symbols on MT5 provide NO  |
//|  real depth at all (MarketBookAdd succeeds but the book stays      |
//|  empty, or the call fails outright) - this engine detects that and ---
//|  reports itself unavailable rather than fabricating a reading.     |
//|  Refreshed from OnTimer, not OnTick: MarketBookGet is materially   |
//|  heavier than a tick read and DOM structure doesn't need to be     |
//|  re-read on every price update to stay useful.                     |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_HEATMAP_MQH
#define AX_HEATMAP_MQH
#include "Defs.mqh"

#define AX_HM_MAX_LEVELS 40

class CHeatmapEngine
  {
private:
   string            m_symbol;
   bool              m_subscribed;
   bool              m_available;    // true once a non-empty book has been observed at least once

   double            m_prevPrice[AX_HM_MAX_LEVELS];
   double            m_prevVolume[AX_HM_MAX_LEVELS];
   bool              m_prevIsBuy[AX_HM_MAX_LEVELS];
   int               m_prevCount;

   double            m_buyWallPressure;   // 0..100
   double            m_sellWallPressure;  // 0..100

public:
                     CHeatmapEngine(void)
     {
      m_subscribed=false; m_available=false; m_prevCount=0;
      m_buyWallPressure=50.0; m_sellWallPressure=50.0;
     }

   //--- returns false when the broker/symbol simply doesn't offer depth - callers should treat ---
   //--- that as "feature unavailable", not an initialization error to fail EA startup over ---
   bool              Init(const string symbol)
     {
      m_symbol = symbol;
      m_subscribed = MarketBookAdd(symbol);
      return(m_subscribed);
     }

   void              Deinit(void)
     {
      if(m_subscribed) MarketBookRelease(m_symbol);
      m_subscribed=false;
     }

   bool              IsAvailable(void) const { return(m_available); }

   //--- call from OnTimer. rangePts bounds how far from the touch price levels are considered -   ---
   //--- deep book levels far from price add noise, not signal, for a scalping-horizon EA ---
   void              Update(const double refBid,const double refAsk,const double rangePts,const double point)
     {
      if(!m_subscribed) return;

      MqlBookInfo book[];
      if(!MarketBookGet(m_symbol,book) || ArraySize(book)==0) return;
      m_available = true;

      double p = (point>0) ? point : 0.00001;
      double rangePrice = rangePts*p;

      double buyPressure=0, sellPressure=0;
      int newCount=0;
      double newPrice[AX_HM_MAX_LEVELS]; double newVolume[AX_HM_MAX_LEVELS]; bool newIsBuy[AX_HM_MAX_LEVELS];

      int total = ArraySize(book);
      for(int i=0;i<total && newCount<AX_HM_MAX_LEVELS;i++)
        {
         bool isBuySide = (book[i].type==BOOK_TYPE_BUY || book[i].type==BOOK_TYPE_BUY_MARKET);
         bool isSellSide = (book[i].type==BOOK_TYPE_SELL || book[i].type==BOOK_TYPE_SELL_MARKET);
         if(!isBuySide && !isSellSide) continue;

         double vol  = (book[i].volume_real>0) ? book[i].volume_real : (double)book[i].volume;
         double dist = isBuySide ? (refBid-book[i].price) : (book[i].price-refAsk);
         if(dist<0 || dist>rangePrice) continue; // only levels within range of the current touch price

         //--- buildup/pull weighting against the previous snapshot at the same price/side ---
         double weight = vol;
         double prevVol = FindPrev(book[i].price,isBuySide);
         if(prevVol>=0 && vol>prevVol*1.15)      weight *= 1.5;  // growing size -> weight up (buildup)
         else if(prevVol>=0 && vol<prevVol*0.70) weight *= 0.5;  // shrinking size -> weight down (pulled)

         if(isBuySide) buyPressure += weight; else sellPressure += weight;

         newPrice[newCount]=book[i].price; newVolume[newCount]=vol; newIsBuy[newCount]=isBuySide;
         newCount++;
        }

      double sumPressure = buyPressure+sellPressure;
      m_buyWallPressure  = (sumPressure>0) ? AxClampD(buyPressure/sumPressure*100.0,0,100)  : 50.0;
      m_sellWallPressure = (sumPressure>0) ? AxClampD(sellPressure/sumPressure*100.0,0,100) : 50.0;

      for(int i=0;i<newCount;i++)
        {
         m_prevPrice[i]=newPrice[i]; m_prevVolume[i]=newVolume[i]; m_prevIsBuy[i]=newIsBuy[i];
        }
      m_prevCount = newCount;
     }

   double            BuyWallPressure(void)  const { return(m_buyWallPressure); }
   double            SellWallPressure(void) const { return(m_sellWallPressure); }

   //--- Patnaik & Thomas (2004), "Profitability of Trading Strategies on High-Frequency data,   ---
   //--- with Trading Costs": non-proportional trading costs (price/market impact) must be        ---
   //--- measured by walking the actual limit order book for the trade's own size, not inferred    ---
   //--- from spread - a fixed spread/slippage tolerance says nothing about what a LARGE order      ---
   //--- actually pays once it eats past the best price. This does a FRESH MarketBookGet (not the   ---
   //--- Update() timer's cached buildup/pull snapshot - sizing needs precision at the moment of    ---
   //--- the actual decision) and walks the opposite side of the book: a BUY consumes ask (SELL)    ---
   //--- liquidity ascending from the best price, a SELL consumes bid (BUY) liquidity descending    ---
   //--- from the best price - always walking away from the best available price, exactly the       ---
   //--- paper's Eq. 2-4 construction. impactCostPctOut is the cost of filling requestedLots in     ---
   //--- full (or of whatever the book could actually fill, if less); maxAffordableLotsOut is the   ---
   //--- largest size fillable while the running average cost stays within maxImpactCostPct -       ---
   //--- floored to the last fully-affordable level, never optimistically interpolated past it,     ---
   //--- matching this codebase's existing "round down, don't round up" sizing convention (see      ---
   //--- CAdaptiveFlipEngine's VolumeMin fix). Assumes the book's volume/volume_real field is in     ---
   //--- the same units as order volume (lots) - the standard MT5 convention for symbols that        ---
   //--- expose real depth (this engine's own buildup/pull tracking already makes the same           ---
   //--- assumption). Returns false when depth is unavailable - callers must not treat that as       ---
   //--- "zero cost", only as "this check cannot run right now". ---
   bool              EstimateExecution(const ENUM_AX_DIR dir,const double requestedLots,
                                        const double maxImpactCostPct,
                                        double &impactCostPctOut,double &maxAffordableLotsOut) const
     {
      impactCostPctOut   = 0.0;
      maxAffordableLotsOut = 0.0;
      if(!m_subscribed || requestedLots<=0) return(false);

      MqlBookInfo book[];
      if(!MarketBookGet(m_symbol,book) || ArraySize(book)==0) return(false);

      bool wantSellSide = (dir==AX_DIR_BUY); // BUY walks the ask/SELL side; SELL walks the bid/BUY side

      int total = ArraySize(book);
      int idx[]; int n=0;
      ArrayResize(idx,total);
      for(int i=0;i<total;i++)
        {
         bool isSell = (book[i].type==BOOK_TYPE_SELL || book[i].type==BOOK_TYPE_SELL_MARKET);
         bool isBuy  = (book[i].type==BOOK_TYPE_BUY  || book[i].type==BOOK_TYPE_BUY_MARKET);
         if((wantSellSide && isSell) || (!wantSellSide && isBuy)) { idx[n]=i; n++; }
        }
      if(n<=0) return(false);

      //--- sort the relevant side into best-price-first order: ascending price for asks, descending ---
      //--- for bids - insertion sort, n is small (a retail depth feed rarely exceeds a few dozen levels) ---
      for(int i=1;i<n;i++)
        {
         int key=idx[i]; double kp=book[key].price; int j=i-1;
         while(j>=0 && (wantSellSide ? (book[idx[j]].price>kp) : (book[idx[j]].price<kp)))
           { idx[j+1]=idx[j]; j--; }
         idx[j+1]=key;
        }

      double benchmarkPrice = book[idx[0]].price;
      if(benchmarkPrice<=0) return(false);

      double cumQty=0, cumCost=0;
      double affordableLots=0; bool budgetSet=false;
      for(int i=0;i<n && cumQty<requestedLots;i++)
        {
         double lvlVol = (book[idx[i]].volume_real>0) ? book[idx[i]].volume_real : (double)book[idx[i]].volume;
         if(lvlVol<=0) continue;
         double lvlPrice = book[idx[i]].price;

         double take = MathMin(lvlVol,requestedLots-cumQty);
         double newCumQty  = cumQty+take;
         double newCumCost = cumCost+take*lvlPrice;
         double avgPrice = newCumCost/newCumQty;
         double icPct = wantSellSide ? 100.0*(avgPrice/benchmarkPrice-1.0)
                                      : 100.0*(benchmarkPrice/avgPrice-1.0);

         if(!budgetSet && icPct>maxImpactCostPct)
           {
            // this level would push the running average over budget - the affordable size is
            // everything accumulated strictly BEFORE it, not an optimistic partial fill of it
            affordableLots = cumQty;
            budgetSet = true;
           }

         cumQty = newCumQty; cumCost = newCumCost;
        }

      if(!budgetSet) affordableLots = cumQty; // never breached budget, even filling the whole book/request

      impactCostPctOut = (cumQty>0) ? (wantSellSide ? 100.0*(cumCost/cumQty/benchmarkPrice-1.0)
                                                      : 100.0*(benchmarkPrice/(cumCost/cumQty)-1.0)) : 0.0;
      maxAffordableLotsOut = MathMax(0.0,affordableLots);
      return(true);
     }

   //--- 0..100 bias components - only meaningful once IsAvailable(); callers must check that first ---
   //--- (an unavailable heatmap reports a neutral 50/50 split, which BullishScoreComponent turns   ---
   //--- into a harmless 0 rather than a false signal) ---
   double            BullishScoreComponent(void) const
     {
      if(!m_available) return(0);
      return(AxClampD((m_buyWallPressure-50.0)*2.0,0,100));
     }

   double            BearishScoreComponent(void) const
     {
      if(!m_available) return(0);
      return(AxClampD((m_sellWallPressure-50.0)*2.0,0,100));
     }

private:
   double            FindPrev(const double price,const bool isBuy) const
     {
      for(int i=0;i<m_prevCount;i++)
         if(m_prevIsBuy[i]==isBuy && MathAbs(m_prevPrice[i]-price)<1e-9) return(m_prevVolume[i]);
      return(-1.0);
     }
  };
//+------------------------------------------------------------------+
#endif // AX_HEATMAP_MQH
