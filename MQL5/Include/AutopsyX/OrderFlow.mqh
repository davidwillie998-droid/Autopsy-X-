//+------------------------------------------------------------------+
//|                                                     OrderFlow.mqh |
//|  Order-flow and institutional-execution behaviour proxies        |
//|                                                                    |
//|  Direction is inferred from accepted mid-price changes because    |
//|  ordinary MT5 OTC/CFD feeds usually do not expose a trade-aggressor|
//|  flag. Volume provenance is retained separately. Persistence and  |
//|  absorption describe observable price/quote behaviour; they do not|
//|  identify a bank, fund, parent order or hidden institutional book. |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_ORDERFLOW_MQH
#define AX_ORDERFLOW_MQH
#include "Defs.mqh"
#include "MarketData.mqh"

#define AX_OF_WINDOW 50
#define AX_OF_PERSISTENCE_BUCKETS 5

class COrderFlowEngine
  {
private:
   double            m_sessionCvd;
   datetime          m_sessionDay;

   double            m_windowDelta;
   double            m_windowVolume;
   double            m_imbalanceRatio;
   double            m_priceRangePts;
   double            m_windowNetMovePts;
   double            m_windowPathPts;
   double            m_pricePathEfficiency;
   double            m_priceImpactPtsPerVolume;

   double            m_flowPersistence;       // 0..100, share of usable subwindows aligned with dominant flow
   double            m_absorptionStrength;    // 0..100, pressure not matched by directional price progress
   double            m_directionalCoveragePct;
   double            m_realVolumeSharePct;
   double            m_tickVolumeSharePct;
   double            m_tickCountProxySharePct;
   int               m_validWindowSamples;
   int               m_validPersistenceBuckets;
   bool              m_parentOrderPersistenceProxy;

   double            m_lastTickBuyVol;
   double            m_lastTickSellVol;

   bool              m_bullAbsorption;
   bool              m_bearAbsorption;
   bool              m_bullCvdDivergence;
   bool              m_bearCvdDivergence;

public:
                     COrderFlowEngine(void) { Clear(); }

   void              Clear(void)
     {
      m_sessionCvd=0; m_sessionDay=0;
      m_windowDelta=0; m_windowVolume=0; m_imbalanceRatio=0; m_priceRangePts=0;
      m_windowNetMovePts=0; m_windowPathPts=0; m_pricePathEfficiency=0;
      m_priceImpactPtsPerVolume=0;
      m_flowPersistence=0; m_absorptionStrength=0; m_directionalCoveragePct=0;
      m_realVolumeSharePct=0; m_tickVolumeSharePct=0;
      m_tickCountProxySharePct=0; m_validWindowSamples=0; m_validPersistenceBuckets=0;
      m_parentOrderPersistenceProxy=false;
      m_lastTickBuyVol=0; m_lastTickSellVol=0;
      m_bullAbsorption=false; m_bearAbsorption=false;
      m_bullCvdDivergence=false; m_bearCvdDivergence=false;
     }

   // Call exactly once for each accepted CMarketData sample, after OnTickUpdate().
   // The session CVD is an inferred quote-direction series, not signed exchange volume.
   void              Update(const CMarketData &md)
     {
      MqlDateTime dtNow;
      TimeToStruct(TimeCurrent(),dtNow);
      datetime dayStart=TimeCurrent()-(dtNow.hour*3600+dtNow.min*60+dtNow.sec);
      if(dayStart!=m_sessionDay) { m_sessionDay=dayStart; m_sessionCvd=0; }

      m_windowDelta=0; m_windowVolume=0; m_imbalanceRatio=0; m_priceRangePts=0;
      m_windowNetMovePts=0; m_windowPathPts=0; m_pricePathEfficiency=0;
      m_priceImpactPtsPerVolume=0;
      m_flowPersistence=0; m_absorptionStrength=0; m_directionalCoveragePct=0;
      m_realVolumeSharePct=0; m_tickVolumeSharePct=0;
      m_tickCountProxySharePct=0; m_validWindowSamples=0; m_validPersistenceBuckets=0;
      m_parentOrderPersistenceProxy=false;
      m_bullAbsorption=false; m_bearAbsorption=false;
      m_bullCvdDivergence=false; m_bearCvdDivergence=false;
      m_lastTickBuyVol=0; m_lastTickSellVol=0;

      SAxTick newest;
      if(!md.GetSample(0,newest)) return;

      // Session CVD and the footprint's per-tick input use unit tick weights.
      // This prevents a broker changing volume fields mid-session from mixing units.
      if(newest.dir>0)      { m_sessionCvd+=1.0; m_lastTickBuyVol=1.0; }
      else if(newest.dir<0) { m_sessionCvd-=1.0; m_lastTickSellVol=1.0; }

      int n=MathMin(md.Count(),AX_OF_WINDOW);
      if(n<5) return;

      // Determine source homogeneity before calculating the window. Real volume,
      // broker tick volume and one-tick fallback counts are not interchangeable.
      int sourceClasses=0;
      int realSamples=0, tickVolumeSamples=0, proxySamples=0;
      for(int i=0;i<n;i++)
        {
         SAxTick t;
         if(!md.GetSample(i,t)) return;
         if(t.volumeSource==AX_VOLUME_SOURCE_REAL) realSamples++;
         else if(t.volumeSource==AX_VOLUME_SOURCE_TICK_VOLUME) tickVolumeSamples++;
         else if(t.volumeSource==AX_VOLUME_SOURCE_TICK_COUNT) proxySamples++;
        }
      if(realSamples>0) sourceClasses++;
      if(tickVolumeSamples>0) sourceClasses++;
      if(proxySamples>0) sourceClasses++;
      bool mixedVolumeSource=(sourceClasses>1);

      double buyVol=0.0, sellVol=0.0;
      double hi=-DBL_MAX, lo=DBL_MAX;
      double previousMid=0.0;
      int directionalSamples=0;
      double bucketDelta[AX_OF_PERSISTENCE_BUCKETS];
      double bucketVolume[AX_OF_PERSISTENCE_BUCKETS];
      ArrayInitialize(bucketDelta,0.0);
      ArrayInitialize(bucketVolume,0.0);

      for(int i=0;i<n;i++)
        {
         SAxTick t;
         if(!md.GetSample(i,t)) return; // incomplete windows are not scored

         m_validWindowSamples++;
         // Mixed-source windows are normalized to one observation per tick.
         // Homogeneous windows retain their native feed-volume weighting.
         double vol=(mixedVolumeSource ? 1.0 : (double)MathMax((long)1,t.volume));
         if(t.dir>0)
           {
            buyVol+=vol;
            directionalSamples++;
           }
         else if(t.dir<0)
           {
            sellVol+=vol;
            directionalSamples++;
           }

         if(t.dir!=0)
           {
            int bucket=(int)(((n-1-i)*AX_OF_PERSISTENCE_BUCKETS)/n);
            bucket=(int)MathMax(0,MathMin(AX_OF_PERSISTENCE_BUCKETS-1,bucket));
            bucketDelta[bucket]+=(t.dir>0 ? vol : -vol);
            bucketVolume[bucket]+=vol;
           }

         if(t.mid>hi) hi=t.mid;
         if(t.mid<lo) lo=t.mid;
         if(i>0) m_windowPathPts+=MathAbs(t.mid-previousMid);
         previousMid=t.mid;
        }

      if(m_validWindowSamples!=n || hi<=-DBL_MAX || lo>=DBL_MAX) return;

      double point=md.Point();
      if(point<=0.0) return;

      SAxTick oldest;
      if(!md.GetSample(n-1,oldest)) return;

      m_windowVolume=buyVol+sellVol;
      m_windowDelta=buyVol-sellVol;
      m_imbalanceRatio=(m_windowVolume>0.0 ? m_windowDelta/m_windowVolume : 0.0);
      m_priceRangePts=(hi>lo ? (hi-lo)/point : 0.0);
      m_windowNetMovePts=(newest.mid-oldest.mid)/point;
      m_windowPathPts/=point;
      m_pricePathEfficiency=(m_windowPathPts>0.0 ?
                             AxClampD(MathAbs(m_windowNetMovePts)/m_windowPathPts,0.0,1.0) : 0.0);
      m_priceImpactPtsPerVolume=(m_windowVolume>0.0 ?
                                 m_windowNetMovePts/m_windowVolume : 0.0);

      m_directionalCoveragePct=100.0*(double)directionalSamples/(double)n;
      m_realVolumeSharePct=100.0*(double)realSamples/(double)n;
      m_tickVolumeSharePct=100.0*(double)tickVolumeSamples/(double)n;
      m_tickCountProxySharePct=100.0*(double)proxySamples/(double)n;
      // These shares describe feed composition, not data quality,
      // reliability, institutional origin or predictive value.

      // Persistence is measured across five chronological subwindows. A valid bucket must
      // contain directional volume and at least 5% absolute imbalance; flat/noisy buckets
      // are excluded rather than counted as neutral confirmation.
      int alignedBuckets=0;
      double dominantSign=(m_imbalanceRatio>0.0 ? 1.0 : (m_imbalanceRatio<0.0 ? -1.0 : 0.0));
      if(dominantSign!=0.0)
        {
         for(int b=0;b<AX_OF_PERSISTENCE_BUCKETS;b++)
           {
            if(bucketVolume[b]<=0.0) continue;
            double ratio=bucketDelta[b]/bucketVolume[b];
            if(MathAbs(ratio)<0.05) continue;
            m_validPersistenceBuckets++;
            if(ratio*dominantSign>0.0) alignedBuckets++;
           }
         if(m_validPersistenceBuckets>=3)
            m_flowPersistence=100.0*(double)alignedBuckets/(double)m_validPersistenceBuckets;
        }

      // A persistent-execution pattern is only a proxy for parent-order behaviour. It does
      // not prove that one institution or one parent order generated the observed sequence.
      m_parentOrderPersistenceProxy=(m_validPersistenceBuckets>=4 &&
                                     alignedBuckets>=4 &&
                                     m_flowPersistence>=80.0 &&
                                     MathAbs(m_imbalanceRatio)>=0.20 &&
                                     m_directionalCoveragePct>=60.0);

      // Absorption is evaluated against directional progress, not merely a narrow high-low
      // range. Strong inferred pressure with little movement in its own direction is a
      // candidate; feed direction remains a quote-mid proxy.
      if(m_windowVolume>0.0 && directionalSamples>=10 &&
         MathAbs(m_imbalanceRatio)>=0.45)
        {
         double alignedProgressPts=dominantSign*m_windowNetMovePts;
         double stallThresholdPts=MathMax(md.CurrentSpreadPts()*1.5,2.0);
         double progressFraction=AxClampD(MathMax(alignedProgressPts,0.0)/
                                          MathMax(stallThresholdPts,0.1),0.0,1.0);
         m_absorptionStrength=AxClampD(MathAbs(m_imbalanceRatio)*100.0*
                                       (1.0-progressFraction),0.0,100.0);
         m_bullAbsorption=(m_imbalanceRatio<0.0 && m_absorptionStrength>=35.0);
         m_bearAbsorption=(m_imbalanceRatio>0.0 && m_absorptionStrength>=35.0);
        }

      // Short-horizon normalized CVD divergence: compare two adjacent halves of the same
      // complete rolling window. This remains an inferred quote-direction signal.
      if(n>=20)
        {
         int split=n/2;
         double oldDelta=0.0, oldVolume=0.0, oldHigh=-DBL_MAX, oldLow=DBL_MAX;
         double newDelta=0.0, newVolume=0.0, newHigh=-DBL_MAX, newLow=DBL_MAX;
         int oldDirectional=0, newDirectional=0;

         for(int i=split;i<n;i++)
           {
            SAxTick t;
            if(!md.GetSample(i,t)) return;
            if(t.mid>oldHigh) oldHigh=t.mid;
            if(t.mid<oldLow) oldLow=t.mid;
            double vol=(mixedVolumeSource ? 1.0 : (double)MathMax((long)1,t.volume));
            if(t.dir>0) { oldDelta+=vol; oldVolume+=vol; oldDirectional++; }
            else if(t.dir<0) { oldDelta-=vol; oldVolume+=vol; oldDirectional++; }
           }

         for(int i=0;i<split;i++)
           {
            SAxTick t;
            if(!md.GetSample(i,t)) return;
            if(t.mid>newHigh) newHigh=t.mid;
            if(t.mid<newLow) newLow=t.mid;
            double vol=(mixedVolumeSource ? 1.0 : (double)MathMax((long)1,t.volume));
            if(t.dir>0) { newDelta+=vol; newVolume+=vol; newDirectional++; }
            else if(t.dir<0) { newDelta-=vol; newVolume+=vol; newDirectional++; }
           }

         if(oldDirectional>=5 && newDirectional>=5 && oldVolume>0.0 && newVolume>0.0 &&
            oldHigh>-DBL_MAX && oldLow<DBL_MAX && newHigh>-DBL_MAX && newLow<DBL_MAX)
           {
            double oldRatio=oldDelta/oldVolume;
            double newRatio=newDelta/newVolume;
            double minExtensionPts=MathMax(md.CurrentSpreadPts()*1.5,2.0);
            bool lowerLow=(newLow<oldLow-minExtensionPts*point);
            bool higherHigh=(newHigh>oldHigh+minExtensionPts*point);
            m_bullCvdDivergence=lowerLow && newRatio>=oldRatio+0.15;
            m_bearCvdDivergence=higherHigh && newRatio<=oldRatio-0.15;
           }
        }
     }

   double SessionCvd(void) const { return(m_sessionCvd); }
   double WindowDelta(void) const { return(m_windowDelta); }
   double WindowVolume(void) const { return(m_windowVolume); }
   double ImbalanceRatio(void) const { return(m_imbalanceRatio); }
   double WindowNetMovePts(void) const { return(m_windowNetMovePts); }
   double WindowPathPts(void) const { return(m_windowPathPts); }
   double PricePathEfficiency(void) const { return(m_pricePathEfficiency); }
   double PriceImpactPointsPerVolume(void) const { return(m_priceImpactPtsPerVolume); }
   double FlowPersistence(void) const { return(m_flowPersistence); }
   double AbsorptionStrength(void) const { return(m_absorptionStrength); }
   double DirectionalCoveragePct(void) const { return(m_directionalCoveragePct); }
   double RealVolumeSharePct(void) const { return(m_realVolumeSharePct); }
   double TickVolumeSharePct(void) const { return(m_tickVolumeSharePct); }
   double TickCountProxySharePct(void) const { return(m_tickCountProxySharePct); }
   int ValidPersistenceBuckets(void) const { return(m_validPersistenceBuckets); }
   bool ParentOrderPersistenceProxy(void) const { return(m_parentOrderPersistenceProxy); }

   string VolumeEvidenceLabel(void) const
     {
      if(m_validWindowSamples<5) return("INSUFFICIENT_DATA");
      if(m_realVolumeSharePct>=99.9) return("REAL_VOLUME_QUOTE_DIRECTION");
      if(m_tickVolumeSharePct>=99.9) return("BROKER_VOLUME_QUOTE_DIRECTION");
      if(m_tickCountProxySharePct>=99.9) return("TICK_COUNT_QUOTE_DIRECTION");
      return("MIXED_VOLUME_QUOTE_DIRECTION");
     }

   bool BullishAbsorption(void) const { return(m_bullAbsorption); }
   bool BearishAbsorption(void) const { return(m_bearAbsorption); }
   bool BullishCvdDivergence(void) const { return(m_bullCvdDivergence); }
   bool BearishCvdDivergence(void) const { return(m_bearCvdDivergence); }
   double LastTickBuyVol(void) const { return(m_lastTickBuyVol); }
   double LastTickSellVol(void) const { return(m_lastTickSellVol); }

   // Directional components are deliberately coverage-adjusted. The same inferred
   // tick stream feeds footprint and CVD, so this remains one advisory evidence family.
   double BullishScoreComponent(const bool includeCvdDivergence=true) const
     {
      double coverage=AxClampD(m_directionalCoveragePct/100.0,0.0,1.0);
      double score=0.0;
      if(m_imbalanceRatio>0.0)
        {
         score+=m_imbalanceRatio*40.0*coverage;
         score+=m_flowPersistence*0.25*coverage;
        }
      if(m_bullAbsorption) score+=m_absorptionStrength*0.20*coverage;
      if(includeCvdDivergence && m_bullCvdDivergence) score+=15.0*coverage;
      return(AxClampD(score,0.0,100.0));
     }

   double BearishScoreComponent(const bool includeCvdDivergence=true) const
     {
      double coverage=AxClampD(m_directionalCoveragePct/100.0,0.0,1.0);
      double score=0.0;
      if(m_imbalanceRatio<0.0)
        {
         score+=(-m_imbalanceRatio)*40.0*coverage;
         score+=m_flowPersistence*0.25*coverage;
        }
      if(m_bearAbsorption) score+=m_absorptionStrength*0.20*coverage;
      if(includeCvdDivergence && m_bearCvdDivergence) score+=15.0*coverage;
      return(AxClampD(score,0.0,100.0));
     }
  };
//+------------------------------------------------------------------+
#endif // AX_ORDERFLOW_MQH
