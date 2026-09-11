//+------------------------------------------------------------------+
//|                                                    Momentum.mqh |
//|  Tick-level intelligence: velocity, acceleration, displacement,  |
//|  volatility, persistence and exhaustion (spec section 3)         |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_MOMENTUM_MQH
#define AX_MOMENTUM_MQH
#include "Defs.mqh"
#include "MarketData.mqh"

#define AX_MOM_LOOKBACK      30     // ticks used for velocity/persistence window
#define AX_MOM_VEL_HISTORY   16     // stored velocity samples for acceleration/exhaustion

class CMomentumEngine
  {
private:
   int               m_consecBull;
   int               m_consecBear;
   double            m_velocity;         // ticks per second, most recent window
   double            m_velocityHistory[AX_MOM_VEL_HISTORY];
   int               m_velHead;
   int               m_velCount;
   double            m_acceleration;     // change in velocity, ticks/sec^2 (approx)
   double            m_displacementPts;  // signed, over lookback window, in points
   double            m_volatilityPts;    // stdev of tick-to-tick mid deltas, in points
   bool              m_persistBull;
   bool              m_persistBear;
   double            m_persistenceRatio; // 0..1, fraction of lookback ticks in dominant direction
   bool              m_exhaustion;       // true if momentum decelerating vs displacement direction

public:
                     CMomentumEngine(void) { Clear(); }

   void              Clear(void)
     {
      m_consecBull=0; m_consecBear=0;
      m_velocity=0; m_acceleration=0;
      m_displacementPts=0; m_volatilityPts=0;
      m_persistBull=false; m_persistBear=false; m_persistenceRatio=0;
      m_exhaustion=false;
      m_velHead=-1; m_velCount=0;
      ArrayInitialize(m_velocityHistory,0.0);
     }

   void              Update(const CMarketData &md)
     {
      int n = MathMin(md.Count(),AX_MOM_LOOKBACK);
      if(n<3) return;

      //--- consecutive same-direction ticks from most recent backwards ---
      m_consecBull = 0; m_consecBear = 0;
      SAxTick first;
      if(md.GetSample(0,first) && first.dir!=0)
        {
         int sign = first.dir;
         int streak = 1;
         for(int i=1;i<n;i++)
           {
            SAxTick t;
            if(!md.GetSample(i,t) || t.dir!=sign) break;
            streak++;
           }
         if(sign>0) m_consecBull = streak;
         else       m_consecBear = streak;
        }

      //--- tick velocity: ticks per second across lookback window ---
      SAxTick newest,oldest;
      md.GetSample(0,newest);
      md.GetSample(n-1,oldest);
      double dt = (double)(newest.time - oldest.time);
      if(dt<=0) dt = 1.0; // sub-second bursts: floor at 1s to avoid div-by-zero blowups
      double newVel = (double)n/dt;

      //--- push velocity into small ring history for acceleration/exhaustion ---
      m_velHead = (m_velHead+1) % AX_MOM_VEL_HISTORY;
      m_velocityHistory[m_velHead] = newVel;
      if(m_velCount<AX_MOM_VEL_HISTORY) m_velCount++;

      double prevVel = m_velocity;
      m_velocity = newVel;
      m_acceleration = m_velocity - prevVel;

      //--- displacement over lookback, in points ---
      double point = md.Point();
      if(point<=0) point = 0.00001;
      m_displacementPts = (newest.mid - oldest.mid)/point;

      //--- short-term volatility: stdev of tick-to-tick mid deltas (points) ---
      double sum=0,sumSq=0; int cnt=0;
      double prevMid = 0; bool havePrev=false;
      for(int i=n-1;i>=0;i--)
        {
         SAxTick t;
         if(!md.GetSample(i,t)) continue;
         if(havePrev)
           {
            double delta = (t.mid-prevMid)/point;
            sum+=delta; sumSq+=delta*delta; cnt++;
           }
         prevMid = t.mid; havePrev = true;
        }
      if(cnt>1)
        {
         double mean = sum/cnt;
         double variance = (sumSq/cnt) - (mean*mean);
         if(variance<0) variance=0;
         m_volatilityPts = MathSqrt(variance);
        }
      else
         m_volatilityPts = 0;

      //--- persistence ratio: fraction of lookback ticks matching dominant direction ---
      int upCount=0, downCount=0;
      for(int i=0;i<n;i++)
        {
         SAxTick t;
         if(!md.GetSample(i,t)) continue;
         if(t.dir>0) upCount++;
         else if(t.dir<0) downCount++;
        }
      int dominant = MathMax(upCount,downCount);
      m_persistenceRatio = (n>0) ? (double)dominant/(double)n : 0.0;
      m_persistBull = (upCount>downCount) && (m_persistenceRatio>=0.6);
      m_persistBear = (downCount>upCount) && (m_persistenceRatio>=0.6);

      //--- exhaustion: velocity/acceleration fading while displacement still extended ---
      m_exhaustion = false;
      if(m_velCount>=4)
        {
         double avgPrev=0; int c=0;
         for(int k=1;k<=3;k++)
           {
            int idx = m_velHead-k; if(idx<0) idx+=AX_MOM_VEL_HISTORY;
            avgPrev += m_velocityHistory[idx]; c++;
           }
         avgPrev = (c>0)? avgPrev/c : m_velocity;
         bool decelerating = (m_velocity < avgPrev*0.65);
         bool extended = MathAbs(m_displacementPts) > (m_volatilityPts*2.5);
         m_exhaustion = decelerating && extended;
        }
     }

   //--- accessors ---
   int               ConsecBull(void)      const { return(m_consecBull); }
   int               ConsecBear(void)      const { return(m_consecBear); }
   double            Velocity(void)        const { return(m_velocity); }
   double            Acceleration(void)    const { return(m_acceleration); }
   double            DisplacementPts(void) const { return(m_displacementPts); }
   double            VolatilityPts(void)   const { return(m_volatilityPts); }
   bool              PersistentBull(void)  const { return(m_persistBull); }
   bool              PersistentBear(void)  const { return(m_persistBear); }
   double            PersistenceRatio(void)const { return(m_persistenceRatio); }
   bool              IsExhausted(void)     const { return(m_exhaustion); }

   string            VelocityLabel(void) const
     {
      double v = MathAbs(m_velocity);
      if(v>=8)  return("EXTREME");
      if(v>=4)  return("HIGH");
      if(v>=1.5)return("MODERATE");
      return("LOW");
     }
  };
//+------------------------------------------------------------------+
#endif // AX_MOMENTUM_MQH
