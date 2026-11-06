//+------------------------------------------------------------------+
//|                                                     OrderFlow.mqh |
//|  Order Flow Engine - tick-classified buy/sell pressure            |
//|                                                                    |
//|  Retail MT5 feeds rarely carry a real trade-aggressor flag, so    |
//|  direction is inferred the same way the rest of this EA already   |
//|  does it: which way mid moved tick-to-tick (CMarketData.dir).     |
//|  Volume is the feed's real traded size when available, else a     |
//|  per-tick count proxy - either way every tick contributes a       |
//|  consistent, non-zero weight rather than being silently dropped.  |
//|  This is an approximation, not a substitute for a real trade tape |
//|  - see README for the honest caveat on what this can and can't    |
//|  see on a quote-only forex/CFD feed.                              |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_ORDERFLOW_MQH
#define AX_ORDERFLOW_MQH
#include "Defs.mqh"
#include "MarketData.mqh"

#define AX_OF_WINDOW 50

class COrderFlowEngine
  {
private:
   double            m_sessionCvd;      // cumulative signed volume since the trading day started
   datetime          m_sessionDay;

   double            m_windowDelta;     // signed buy-sell volume over the rolling lookback window
   double            m_windowVolume;    // total (buy+sell) volume over the same window
   double            m_imbalanceRatio;  // windowDelta/windowVolume, -1 (all selling) .. +1 (all buying)
   double            m_priceRangePts;   // high-low of the same window, in points

   double            m_lastTickBuyVol;  // this tick's classified volume, for Footprint to reuse
   double            m_lastTickSellVol; // without re-deriving direction/volume classification itself

   bool              m_bullAbsorption;  // heavy one-sided SELLING failed to move price down - hidden buyers
   bool              m_bearAbsorption;  // heavy one-sided BUYING failed to move price up - hidden sellers
   bool              m_bullCvdDivergence; // price makes a lower low while normalized signed flow improves
   bool              m_bearCvdDivergence; // price makes a higher high while normalized signed flow weakens

public:
                     COrderFlowEngine(void) { Clear(); }

   void              Clear(void)
     {
      m_sessionCvd=0; m_sessionDay=0;
      m_windowDelta=0; m_windowVolume=0; m_imbalanceRatio=0; m_priceRangePts=0;
      m_lastTickBuyVol=0; m_lastTickSellVol=0;
      m_bullAbsorption=false; m_bearAbsorption=false;
      m_bullCvdDivergence=false; m_bearCvdDivergence=false;
     }

   //--- call once per genuine tick (i.e. from inside OnTick, after CMarketData::OnTickUpdate() has ---
   //--- already confirmed a new sample landed - OnTick returns early otherwise, so every call here ---
   //--- corresponds to exactly one new tick, never a re-poll of a stale one) ---
   void              Update(const CMarketData &md)
     {
      MqlDateTime dtNow;
      TimeToStruct(TimeCurrent(),dtNow);
      datetime dayStart = TimeCurrent() - (dtNow.hour*3600 + dtNow.min*60 + dtNow.sec);
      if(dayStart!=m_sessionDay) { m_sessionDay=dayStart; m_sessionCvd=0; }

      m_lastTickBuyVol=0; m_lastTickSellVol=0;
      m_bullCvdDivergence=false; m_bearCvdDivergence=false;

      SAxTick newest;
      if(!md.GetSample(0,newest)) return;

      double newestVol = (double)MathMax((long)1,newest.volume);
      if(newest.dir>0)      { m_sessionCvd += newestVol; m_lastTickBuyVol  = newestVol; }
      else if(newest.dir<0) { m_sessionCvd -= newestVol; m_lastTickSellVol = newestVol; }
      // dir==0 (flat tick): no aggressor can be inferred from a mid that didn't move - contributes
      // to neither side, matching how CMicrostructureEngine's tick imbalance already treats flats

      int n = MathMin(md.Count(),AX_OF_WINDOW);
      if(n<5) return;

      double buyVol=0, sellVol=0;
      double hi=-DBL_MAX, lo=DBL_MAX;
      for(int i=0;i<n;i++)
        {
         SAxTick t;
         if(!md.GetSample(i,t)) continue;
         double vol = (double)MathMax((long)1,t.volume);
         if(t.dir>0)      buyVol  += vol;
         else if(t.dir<0) sellVol += vol;
         if(t.mid>hi) hi=t.mid;
         if(t.mid<lo) lo=t.mid;
        }
      m_windowVolume    = buyVol+sellVol;
      m_windowDelta     = buyVol-sellVol;
      m_imbalanceRatio  = (m_windowVolume>0) ? m_windowDelta/m_windowVolume : 0.0;

      double point = md.Point();
      if(point<=0) point = 0.00001;
      m_priceRangePts = (hi>lo) ? (hi-lo)/point : 0.0;

      //--- absorption: one-sided pressure strong enough that it "should" have moved price, but the ---
      //--- window's own price range stayed inside roughly a spread's worth - the move was absorbed ---
      bool heavyOneSided = MathAbs(m_imbalanceRatio)>=0.55 && m_windowVolume>=(double)n*0.5;
      bool rangeStalled  = m_priceRangePts < (md.CurrentSpreadPts()*1.5 + 2.0);
      m_bullAbsorption = heavyOneSided && rangeStalled && m_imbalanceRatio<0; // sellers pressed, price held -> bullish
      m_bearAbsorption = heavyOneSided && rangeStalled && m_imbalanceRatio>0; // buyers pressed, price held -> bearish

      //--- short-horizon CVD divergence: compare two adjacent halves of the same rolling tick
      //--- window. The older half is the reference; the newer half must extend price beyond the
      //--- older extreme while its normalized signed-volume delta fails to confirm. This uses
      //--- per-half delta ratios, not raw contract/lot counts, so it remains scale-independent
      //--- across feeds. It is still a tick-direction proxy, not exchange aggressor data.
      if(n>=20)
        {
         int split=n/2;
         double oldDelta=0, oldVolume=0, oldHigh=-DBL_MAX, oldLow=DBL_MAX;
         double newDelta=0, newVolume=0, newHigh=-DBL_MAX, newLow=DBL_MAX;
         int oldDirectional=0, newDirectional=0;

         for(int i=split;i<n;i++)
           {
            SAxTick t;
            if(!md.GetSample(i,t)) continue;
            if(t.mid>oldHigh) oldHigh=t.mid;
            if(t.mid<oldLow)  oldLow=t.mid;
            double vol=(double)MathMax((long)1,t.volume);
            if(t.dir>0) { oldDelta+=vol; oldVolume+=vol; oldDirectional++; }
            else if(t.dir<0) { oldDelta-=vol; oldVolume+=vol; oldDirectional++; }
           }

         for(int i=0;i<split;i++)
           {
            SAxTick t;
            if(!md.GetSample(i,t)) continue;
            if(t.mid>newHigh) newHigh=t.mid;
            if(t.mid<newLow)  newLow=t.mid;
            double vol=(double)MathMax((long)1,t.volume);
            if(t.dir>0) { newDelta+=vol; newVolume+=vol; newDirectional++; }
            else if(t.dir<0) { newDelta-=vol; newVolume+=vol; newDirectional++; }
           }

         if(oldDirectional>=5 && newDirectional>=5 && oldVolume>0 && newVolume>0 &&
            oldHigh>-DBL_MAX && oldLow<DBL_MAX && newHigh>-DBL_MAX && newLow<DBL_MAX)
           {
            double oldRatio=oldDelta/oldVolume;
            double newRatio=newDelta/newVolume;
            double minExtensionPts=MathMax(md.CurrentSpreadPts()*1.5,2.0);
            double extension=(hi-lo); // retain the already-validated full-window price span
            if(point>0 && extension>=0)
              {
               bool lowerLow=(newLow<oldLow-minExtensionPts*point);
               bool higherHigh=(newHigh>oldHigh+minExtensionPts*point);
               m_bullCvdDivergence=lowerLow && newRatio>=oldRatio+0.15;
               m_bearCvdDivergence=higherHigh && newRatio<=oldRatio-0.15;
              }
           }
        }
     }

   double            SessionCvd(void)        const { return(m_sessionCvd); }
   double            WindowDelta(void)       const { return(m_windowDelta); }
   double            WindowVolume(void)      const { return(m_windowVolume); }
   double            ImbalanceRatio(void)    const { return(m_imbalanceRatio); }
   bool              BullishAbsorption(void) const { return(m_bullAbsorption); }
   bool              BearishAbsorption(void) const { return(m_bearAbsorption); }
   bool              BullishCvdDivergence(void) const { return(m_bullCvdDivergence); }
   bool              BearishCvdDivergence(void) const { return(m_bearCvdDivergence); }

   //--- this tick's classified volume, for CFootprintEngine to bin without re-deriving direction ---
   double            LastTickBuyVol(void)  const { return(m_lastTickBuyVol); }
   double            LastTickSellVol(void) const { return(m_lastTickSellVol); }

   //--- 0..100 bias components, same pattern as Microstructure/Liquidity for SignalScore blending ---
   double            BullishScoreComponent(const bool includeCvdDivergence=true) const
     {
      double score=0;
      if(m_imbalanceRatio>0) score += m_imbalanceRatio*60.0;
      if(m_bullAbsorption)   score += 40.0;
      if(includeCvdDivergence && m_bullCvdDivergence) score += 25.0;
      return(AxClampD(score,0,100));
     }

   double            BearishScoreComponent(const bool includeCvdDivergence=true) const
     {
      double score=0;
      if(m_imbalanceRatio<0) score += (-m_imbalanceRatio)*60.0;
      if(m_bearAbsorption)   score += 40.0;
      if(includeCvdDivergence && m_bearCvdDivergence) score += 25.0;
      return(AxClampD(score,0,100));
     }
  };
//+------------------------------------------------------------------+
#endif // AX_ORDERFLOW_MQH
