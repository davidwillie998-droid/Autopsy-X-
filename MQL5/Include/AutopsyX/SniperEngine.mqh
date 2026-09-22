//+------------------------------------------------------------------+
//|                                                   SniperEngine.mqh|
//|  Sniper Entry Engine - precision entry timing                    |
//|                                                                    |
//|  A confirmed signal alone no longer fires an order. Once armed,   |
//|  this engine waits for a genuine micro market-structure event -   |
//|  a pullback of a minimum size followed by a resumption in the     |
//|  original direction - before the entry actually commits capital.  |
//|  This buys a better entry price than chasing the initial thrust,  |
//|  and refuses to chase a move that never gives a re-entry point.   |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_SNIPERENGINE_MQH
#define AX_SNIPERENGINE_MQH
#include "Defs.mqh"

class CSniperEngine
  {
private:
   bool        m_armed;
   ENUM_AX_DIR m_dir;
   double      m_armPrice;
   datetime    m_armTime;
   double      m_extreme;          // best price in favor of m_dir seen since arm (or since re-qualifying)
   double      m_pullbackExtreme;  // worst point reached during the current pullback phase
   bool        m_pullbackSeen;

   //--- thresholds, all in raw PRICE units (caller converts from points using the symbol's Point()) ---
   double      m_pullbackDist;
   double      m_resumeDist;
   int         m_maxWaitSeconds;
   double      m_maxChaseDist;

public:
                     CSniperEngine(void)
     {
      m_pullbackDist=0; m_resumeDist=0; m_maxWaitSeconds=8; m_maxChaseDist=0;
      Reset();
     }

   //--- pullbackDist/resumeDist/maxChaseDist are PRICE distances, not points - convert once at the ---
   //--- call site using the symbol's Point() before configuring, since this class is symbol-agnostic ---
   void              Configure(const double pullbackDist,const double resumeDist,
                                const int maxWaitSeconds,const double maxChaseDist)
     {
      m_pullbackDist   = MathAbs(pullbackDist);
      m_resumeDist     = MathAbs(resumeDist);
      m_maxWaitSeconds = MathMax(1,maxWaitSeconds);
      m_maxChaseDist   = MathAbs(maxChaseDist);
     }

   void              Reset(void)
     {
      m_armed=false; m_dir=AX_DIR_NONE; m_armPrice=0; m_armTime=0;
      m_extreme=0; m_pullbackExtreme=0; m_pullbackSeen=false;
     }

   bool              IsArmed(void)      const { return(m_armed); }
   ENUM_AX_DIR       ArmedDir(void)     const { return(m_dir); }
   bool              PullbackSeen(void) const { return(m_pullbackSeen); }
   int               SecondsWaiting(void) const { return(m_armed ? (int)(TimeCurrent()-m_armTime) : 0); }

   //--- called once a fresh signal has cleared every other gate; starts the wait for the retest ---
   void              Arm(const ENUM_AX_DIR dir,const double referencePrice)
     {
      m_armed           = true;
      m_dir             = dir;
      m_armPrice        = referencePrice;
      m_armTime         = TimeCurrent();
      m_extreme         = referencePrice;
      m_pullbackExtreme = referencePrice;
      m_pullbackSeen    = false;
     }

   //--- call every tick while armed. Returns true exactly once, the moment the precision trigger  ---
   //--- fires (and resets to idle in the same call). expiredOut distinguishes "gave up" from       ---
   //--- "still waiting" purely for the caller's own logging - both leave the engine idle either way ---
   //--- only when expired; "still waiting" leaves it armed. ---
   //--- BUY/SELL are handled as one signed path (sign=+1/-1 on "favor" direction) rather than two   ---
   //--- mirrored branches, so a fix here can't accidentally apply to only one side.                 ---
   bool              OnTick(const double currentPrice,bool &expiredOut)
     {
      expiredOut = false;
      if(!m_armed) return(false);

      if((TimeCurrent()-m_armTime) > m_maxWaitSeconds) { expiredOut=true; Reset(); return(false); }

      double sign = (m_dir==AX_DIR_BUY) ? 1.0 : -1.0;

      double favorMove = sign*(currentPrice-m_armPrice);
      if(!m_pullbackSeen && favorMove>m_maxChaseDist) { expiredOut=true; Reset(); return(false); }

      if(m_pullbackSeen)
        {
         //--- check the resume trigger against the CURRENT extreme first: a fast single tick that ---
         //--- both clears resumeDist and beats the pre-pullback extreme must still fire the entry, ---
         //--- not get silently re-classified as "a new extreme, watching for a fresh pullback"      ---
         if(sign*currentPrice < sign*m_pullbackExtreme) m_pullbackExtreme = currentPrice;
         double resumeMove = sign*(currentPrice-m_pullbackExtreme);
         if(resumeMove>=m_resumeDist) { Reset(); return(true); }

         //--- only now, having ruled out an immediate trigger, let a bigger extreme invalidate the ---
         //--- current pullback and restart the watch for a fresh one from this new extreme         ---
         if(sign*currentPrice > sign*m_extreme) { m_extreme=currentPrice; m_pullbackSeen=false; }
        }
      else
        {
         if(sign*currentPrice > sign*m_extreme) m_extreme = currentPrice;
         double pullbackMove = sign*(m_extreme-currentPrice);
         if(pullbackMove>=m_pullbackDist) { m_pullbackSeen=true; m_pullbackExtreme=currentPrice; }
        }
      return(false);
     }
  };
#endif // AX_SNIPERENGINE_MQH
//+------------------------------------------------------------------+
