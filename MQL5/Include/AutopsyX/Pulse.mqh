//+------------------------------------------------------------------+
//|                                                        Pulse.mqh |
//|  Pulse Engine - one composite "is the market alive right now"    |
//|  gauge, blending tick velocity, order-flow imbalance, volatility |
//|  expansion and spread quality into a single 0..100 reading with  |
//|  a direction lean. Purely a read of already-computed engine      |
//|  outputs - no state of its own, so it's cheap enough to refresh  |
//|  every tick and safe to call before those engines' own Update()  |
//|  has ever produced a meaningful non-zero reading (everything     |
//|  degrades to 0 cleanly at startup).                               |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_PULSE_MQH
#define AX_PULSE_MQH
#include "Defs.mqh"
#include "Momentum.mqh"
#include "Microstructure.mqh"
#include "Regime.mqh"
#include "OrderFlow.mqh"

class CPulseEngine
  {
private:
   double            m_pulse;      // 0..100 overall activity/opportunity gauge
   int               m_direction;  // +1/-1/0 lean implied by the blended inputs

public:
                     CPulseEngine(void) { m_pulse=0; m_direction=0; }

   void              Update(const CMomentumEngine &mom,const CMicrostructureEngine &micro,
                             const CRegimeEngine &regime,const COrderFlowEngine &of)
     {
      double velComponent    = AxClampD(MathAbs(mom.Velocity())/6.0,0,1)*30.0;   // 0..30
      double flowComponent   = AxClampD(MathAbs(of.ImbalanceRatio()),0,1)*30.0;  // 0..30
      double volComponent    = AxClampD((regime.VolRatio()-0.5)/1.5,0,1)*25.0;   // 0..25
      double spreadPenalty   = micro.SpreadExpanding() ? 15.0 : 0.0;

      // +15 base so a quiet-but-clean market reads as something above a flat zero, and an
      // unfavorable spread can only pull the gauge down, never push it negative
      m_pulse = AxClampD(velComponent+flowComponent+volComponent-spreadPenalty+15.0,0,100);

      m_direction = 0;
      if(mom.DisplacementPts()>0 && of.ImbalanceRatio()>=0)      m_direction = 1;
      else if(mom.DisplacementPts()<0 && of.ImbalanceRatio()<=0) m_direction = -1;
     }

   double            Value(void)     const { return(m_pulse); }
   int               Direction(void) const { return(m_direction); }

   string            Label(void) const
     {
      if(m_pulse>=80) return("EXTREME");
      if(m_pulse>=55) return("HOT");
      if(m_pulse>=30) return("WARM");
      return("COLD");
     }
  };
//+------------------------------------------------------------------+
#endif // AX_PULSE_MQH
