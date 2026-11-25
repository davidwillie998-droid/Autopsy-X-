//+------------------------------------------------------------------+
//|                                      HawkesEventIntensity.mqh    |
//|  Online bivariate Hawkes intensity from signed MT5 quote changes |
//|  IMPORTANT: event sides are inferred from mid-price tick moves.  |
//|  They are NOT exchange aggressor orders or a consolidated tape.  |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_HAWKES_EVENT_INTENSITY_MQH
#define AX_HAWKES_EVENT_INTENSITY_MQH
#include "Defs.mqh"
#include "MarketData.mqh"

enum ENUM_AX_HAWKES_STATUS
  {
   AX_HAWKES_WARMUP=0,
   AX_HAWKES_READY,
   AX_HAWKES_STALE,
   AX_HAWKES_INVALID
  };

struct SAxHawkesSnapshot
  {
   double buyIntensity;       // inferred upward-event intensity, events/second
   double sellIntensity;      // inferred downward-event intensity, events/second
   double imbalance;          // normalized intensity difference, -1..+1
   double clustering;         // bounded excitation contribution, 0..1
   double acceleration;       // change in total intensity since prior accepted event
   double confidence;         // sample sufficiency only, not predictive probability
   int    eventCount;
   long   timeMsc;
   ENUM_AX_HAWKES_STATUS status;
   bool   valid;
  };

class CHawkesEventIntensityEngine
  {
private:
   double m_muBuy;
   double m_muSell;
   double m_alphaBB;
   double m_alphaBS;
   double m_alphaSB;
   double m_alphaSS;
   double m_beta;

   double m_buyState;
   double m_sellState;
   double m_lastBuyIntensity;
   double m_lastSellIntensity;
   double m_acceleration;
   long   m_lastTimeMsc;
   ulong  m_lastSequence;
   int    m_eventCount;
   int    m_minEvents;
   long   m_maxAgeMsc;
   double m_minMovePoints;
   double m_lastMid;
   bool   m_haveMid;
   bool   m_configValid;
   bool   m_requireBaseline;
   SAxHawkesSnapshot m_snapshot;

   void ClearSnapshot(void)
     {
      ZeroMemory(m_snapshot);
      m_snapshot.status=AX_HAWKES_WARMUP;
      m_snapshot.valid=false;
     }

   bool StableParameters(void) const
     {
      // Reject NaN/INF explicitly. Ordinary comparisons do not reject NaN.
      if(!MathIsValidNumber(m_beta) ||
         !MathIsValidNumber(m_muBuy) || !MathIsValidNumber(m_muSell) ||
         !MathIsValidNumber(m_alphaBB) || !MathIsValidNumber(m_alphaBS) ||
         !MathIsValidNumber(m_alphaSB) || !MathIsValidNumber(m_alphaSS) ||
         !MathIsValidNumber(m_minMovePoints))
         return(false);
      if(m_beta<=0.0 || m_muBuy<0.0 || m_muSell<0.0 ||
         m_alphaBB<0.0 || m_alphaBS<0.0 ||
         m_alphaSB<0.0 || m_alphaSS<0.0 || m_minMovePoints<0.0)
         return(false);
      // Conservative sufficient stability bound for a non-negative
      // two-type branching matrix: maximum row sum divided by beta < 1.
      double rowBuy=(m_alphaBB+m_alphaBS)/m_beta;
      double rowSell=(m_alphaSB+m_alphaSS)/m_beta;
      return(MathMax(rowBuy,rowSell)<0.95);
     }

public:
                     CHawkesEventIntensityEngine(void)
     {
      Configure(0.05,0.05,0.12,0.04,0.04,0.12,1.0,30,10000,0.0);
      Reset();
     }

   bool Configure(const double muBuy,const double muSell,
                  const double alphaBB,const double alphaBS,
                  const double alphaSB,const double alphaSS,
                  const double beta,const int minEvents=30,
                  const long maxAgeMsc=10000,
                  const double minMovePoints=0.0)
     {
      m_muBuy=muBuy; m_muSell=muSell;
      m_alphaBB=alphaBB; m_alphaBS=alphaBS;
      m_alphaSB=alphaSB; m_alphaSS=alphaSS;
      m_beta=beta;
      m_minEvents=(minEvents<5)?5:minEvents;
      m_maxAgeMsc=(maxAgeMsc<100)?100:maxAgeMsc;
      m_minMovePoints=minMovePoints;
      m_configValid=false;
      if(!StableParameters())
        {
         Reset();
         m_snapshot.status=AX_HAWKES_INVALID;
         return(false);
        }
      m_configValid=true;
      Reset();
      return(true);
     }

   void Reset(void)
     {
      m_buyState=0.0; m_sellState=0.0;
      m_lastBuyIntensity=0.0; m_lastSellIntensity=0.0;
      m_acceleration=0.0;
      m_lastTimeMsc=0; m_lastSequence=0;
      m_eventCount=0; m_lastMid=0.0; m_haveMid=false;
      m_requireBaseline=false;
      ClearSnapshot();
     }

   // Deterministic sample entry point. Production calls Update(md); the
   // script harness can inject synthetic accepted samples without a broker feed.
   bool UpdateSample(const SAxTick &tick,const double point)
     {
      if(!m_configValid)
        {
         m_snapshot.status=AX_HAWKES_INVALID;
         m_snapshot.valid=false;
         return(false);
        }
      if(tick.timeMsc<=0 || tick.sequence==0 || !MathIsValidNumber(tick.mid) ||
         !MathIsValidNumber(point) || point<=0.0 ||
         tick.dir<-1 || tick.dir>1)
        {
         Reset();
         m_snapshot.status=AX_HAWKES_INVALID;
         return(false);
        }
      if(tick.sequence<=m_lastSequence) return(false);
      if(m_lastTimeMsc>0 && tick.timeMsc<m_lastTimeMsc)
        {
         // Keep the chronology watermark. A delayed tick must not erase it
         // and allow an older sample to seed a fresh model after the reset.
         m_buyState=0.0; m_sellState=0.0;
         m_lastBuyIntensity=0.0; m_lastSellIntensity=0.0;
         m_acceleration=0.0; m_eventCount=0;
         m_lastMid=0.0; m_haveMid=false;
         m_requireBaseline=true;
         ClearSnapshot();
         m_snapshot.status=AX_HAWKES_INVALID;
         return(false);
        }

      if(m_requireBaseline || m_lastTimeMsc==0)
        {
         m_requireBaseline=false;
        {
         m_lastTimeMsc=tick.timeMsc;
         m_lastSequence=tick.sequence;
         m_lastMid=tick.mid;
         m_haveMid=true;
         m_snapshot.timeMsc=tick.timeMsc;
         m_snapshot.status=AX_HAWKES_WARMUP;
         return(true);
        }

      long elapsedMsc=tick.timeMsc-m_lastTimeMsc;
      double elapsedSeconds=(double)elapsedMsc/1000.0;
      double decay=MathExp(-m_beta*elapsedSeconds);
      m_buyState*=decay;
      m_sellState*=decay;

      int direction=tick.dir;
      if(m_haveMid && m_minMovePoints>0.0)
        {
         // Threshold is measured from the last classified event reference.
         double displacementPoints=(tick.mid-m_lastMid)/point;
         if(MathAbs(displacementPoints)<m_minMovePoints)
            direction=0;
         else
            direction=(displacementPoints>0.0)?1:-1;
        }

      double buyBefore=m_muBuy+m_alphaBB*m_buyState+m_alphaBS*m_sellState;
      double sellBefore=m_muSell+m_alphaSB*m_buyState+m_alphaSS*m_sellState;

      if(direction>0)
        {
         m_buyState+=1.0;
         m_eventCount++;
        }
      else if(direction<0)
        {
         m_sellState+=1.0;
         m_eventCount++;
        }

      double buyNow=m_muBuy+m_alphaBB*m_buyState+m_alphaBS*m_sellState;
      double sellNow=m_muSell+m_alphaSB*m_buyState+m_alphaSS*m_sellState;
      double totalBefore=buyBefore+sellBefore;
      double totalNow=buyNow+sellNow;
      if(!MathIsValidNumber(buyNow) || !MathIsValidNumber(sellNow) ||
         !MathIsValidNumber(totalBefore) || !MathIsValidNumber(totalNow))
        {
         Reset();
         m_snapshot.status=AX_HAWKES_INVALID;
         return(false);
        }
      m_acceleration=totalNow-(m_lastBuyIntensity+m_lastSellIntensity);
      m_lastBuyIntensity=buyNow;
      m_lastSellIntensity=sellNow;
      m_lastTimeMsc=tick.timeMsc;
      m_lastSequence=tick.sequence;
      if(m_minMovePoints<=0.0 || direction!=0)
         m_lastMid=tick.mid;
      m_haveMid=true;

      m_snapshot.buyIntensity=buyNow;
      m_snapshot.sellIntensity=sellNow;
      double total=buyNow+sellNow;
      m_snapshot.imbalance=(total>0.0)?(buyNow-sellNow)/total:0.0;
      double excitation=MathMax(0.0,total-(m_muBuy+m_muSell));
      m_snapshot.clustering=(total>0.0)?AxClampD(excitation/total,0.0,1.0):0.0;
      m_snapshot.acceleration=m_acceleration;
      m_snapshot.eventCount=m_eventCount;
      m_snapshot.timeMsc=tick.timeMsc;
      m_snapshot.confidence=AxClampD((double)m_eventCount/(double)m_minEvents,0.0,1.0);
      m_snapshot.valid=(m_eventCount>=m_minEvents);
      m_snapshot.status=m_snapshot.valid?AX_HAWKES_READY:AX_HAWKES_WARMUP;
      return(true);
     }

   // Call once after CMarketData::OnTickUpdate() accepts a new sample.
   bool Update(const CMarketData &md)
     {
      SAxTick tick;
      if(!md.GetSample(0,tick)) return(false);
      return(UpdateSample(tick,md.Point()));
     }

   bool Evaluate(const long nowMsc,SAxHawkesSnapshot &out) const
     {
      out=m_snapshot;
      if(m_lastTimeMsc<=0 || nowMsc<m_lastTimeMsc)
        {
         out.valid=false;
         out.status=AX_HAWKES_INVALID;
         return(false);
        }
      if(nowMsc-m_lastTimeMsc>m_maxAgeMsc)
        {
         out.valid=false;
         out.status=AX_HAWKES_STALE;
         return(false);
        }
      return(out.valid);
     }

   bool Snapshot(SAxHawkesSnapshot &out) const
     {
      out=m_snapshot;
      return(out.valid);
     }

   bool IsReady(void) const { return(m_snapshot.valid); }
   int  EventCount(void) const { return(m_eventCount); }
  };
//+------------------------------------------------------------------+
#endif // AX_HAWKES_EVENT_INTENSITY_MQH
