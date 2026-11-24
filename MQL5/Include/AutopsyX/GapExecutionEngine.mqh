//+------------------------------------------------------------------+
//|                                      GapExecutionEngine.mqh      |
//| Gap Hour event qualification. No direct order submission.        |
//| Signals must enter through the EA's existing risk and execution. |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_GAPEXECUTIONENGINE_MQH
#define AX_GAPEXECUTIONENGINE_MQH
#include "Defs.mqh"

enum ENUM_AX_GAP_EXEC_STATE
  {
   AX_GAP_EXEC_DISABLED = 0,
   AX_GAP_EXEC_IDLE,
   AX_GAP_EXEC_POST_GAP_WAIT,
   AX_GAP_EXEC_POST_GAP_SPREAD_WAIT,
   AX_GAP_EXEC_POST_GAP_CONFIRMATION_WAIT,
   AX_GAP_EXEC_POST_GAP_READY,
   AX_GAP_EXEC_POST_GAP_EXPIRED
  };

enum ENUM_AX_GAP_SETUP_TYPE
  {
   AX_GAP_SETUP_NONE = 0,
   AX_GAP_SETUP_CONTINUATION,
   AX_GAP_SETUP_SWEEP_REVERSAL
  };

struct SAxGapExecutionSignal
  {
   ENUM_AX_GAP_EXEC_STATE state;
   ENUM_AX_DIR direction;
   ENUM_AX_GAP_SETUP_TYPE setupType;
   datetime m1BarTime;
   double gapPoints;
   double gapOpenPrice;
   double priorClosePrice;
   double currentMidPrice;
   double confirmationDistancePoints;
   double currentSpreadPoints;
   double baselineSpreadPoints;
   ulong waitElapsedMs;
   bool rolloverSpikeObserved;
   bool postGapReady;
   string reason;
  };

class CGapExecutionEngine
  {
private:
   datetime m_lastM1BarTime;
   datetime m_pendingM1BarTime;
   ulong m_gapDetectedAtMs;
   ENUM_AX_DIR m_pendingDirection;
   double m_pendingGapPoints;
   double m_gapOpenPrice;
   double m_priorClosePrice;
   ENUM_AX_GAP_SETUP_TYPE m_setupType;
   bool m_pending;
   bool m_ready;
   bool m_expired;
   bool m_rolloverSpikeLatched;

   bool InMinuteWindow(const datetime serverTime,const int startMinute,
                       const int endMinute) const
     {
      if(serverTime<=0 || startMinute<0 || startMinute>1439 ||
         endMinute<0 || endMinute>1439 || startMinute==endMinute)
         return(false);
      MqlDateTime parts;
      if(!TimeToStruct(serverTime,parts)) return(false);
      int minuteOfDay=parts.hour*60+parts.min;
      if(startMinute<endMinute)
         return(minuteOfDay>=startMinute && minuteOfDay<endMinute);
      return(minuteOfDay>=startMinute || minuteOfDay<endMinute);
     }

   void ResetOutput(SAxGapExecutionSignal &out) const
     {
      ZeroMemory(out);
      out.state=AX_GAP_EXEC_IDLE;
      out.direction=AX_DIR_NONE;
      out.reason="NO_GAP_SETUP";
     }

public:
                     CGapExecutionEngine(void)
     {
      Reset();
     }

   void Reset(void)
     {
      m_lastM1BarTime=0;
      m_pendingM1BarTime=0;
      m_gapDetectedAtMs=0;
      m_pendingDirection=AX_DIR_NONE;
      m_pendingGapPoints=0.0;
      m_gapOpenPrice=0.0;
      m_priorClosePrice=0.0;
      m_setupType=AX_GAP_SETUP_NONE;
      m_pending=false;
      m_ready=false;
      m_expired=false;
      m_rolloverSpikeLatched=false;
     }

   // A post-gap continuation candidate follows the M1 opening gap direction.
   // It is only qualified after the monotonic wait and spread normalization.
   // Rollover spread spikes are recorded separately because spread alone has
   // no directional information and must never manufacture a BUY or SELL.
   bool Update(const string symbol,const datetime serverTime,
               const double bid,const double ask,const double point,
               const bool postGapEnabled,const double minGapPoints,
               const int waitSeconds,const int maxSignalAgeSeconds,
               const double maxSpreadPoints,const double spreadNormalizationMultiple,
               const double minFollowThroughPoints,const double minSweepPenetrationPoints,
               const bool allowSweepReversal,const bool rolloverEnabled,const int rolloverStartMinute,
               const int rolloverEndMinute,const double rolloverSpikeMultiple,
               const double rollingSpreadAverage,const int rollingSpreadSamples,
               SAxGapExecutionSignal &out)
     {
      ResetOutput(out);
      if(symbol=="" || point<=0.0 || bid<=0.0 || ask<bid ||
         !MathIsValidNumber(point) || !MathIsValidNumber(bid) ||
         !MathIsValidNumber(ask))
        {
         out.state=AX_GAP_EXEC_DISABLED;
         out.reason="INVALID_SYMBOL_OR_QUOTE";
         return(false);
        }

      out.currentSpreadPoints=(ask-bid)/point;
      out.baselineSpreadPoints=rollingSpreadAverage;
      ulong nowMs=GetTickCount64();

      if(rolloverEnabled && rollingSpreadSamples>=100 &&
         rollingSpreadAverage>0.0 && rolloverSpikeMultiple>1.0 &&
         InMinuteWindow(serverTime,rolloverStartMinute,rolloverEndMinute) &&
         out.currentSpreadPoints>rollingSpreadAverage*rolloverSpikeMultiple)
        {
         out.rolloverSpikeObserved=true;
         m_rolloverSpikeLatched=true;
        }
      else if(!InMinuteWindow(serverTime,rolloverStartMinute,rolloverEndMinute))
         m_rolloverSpikeLatched=false;

      if(!postGapEnabled || minGapPoints<=0.0 || waitSeconds<0 ||
         maxSignalAgeSeconds<=0 || maxSpreadPoints<0.0 ||
         spreadNormalizationMultiple<=0.0 || minFollowThroughPoints<0.0 ||
         minSweepPenetrationPoints<0.0)
        {
         out.state=(postGapEnabled ? AX_GAP_EXEC_DISABLED : AX_GAP_EXEC_IDLE);
         out.reason=(postGapEnabled ? "POST_GAP_PARAMETERS_NOT_VALIDATED" : "POST_GAP_MODE_DISABLED");
         out.rolloverSpikeObserved=out.rolloverSpikeObserved || m_rolloverSpikeLatched;
         return(false);
        }

      datetime currentBar=iTime(symbol,PERIOD_M1,0);
      if(currentBar>0 && currentBar!=m_lastM1BarTime)
        {
         bool firstObservation=(m_lastM1BarTime==0);
         m_lastM1BarTime=currentBar;
         m_pending=false;
         m_ready=false;
         m_expired=false;
         m_pendingDirection=AX_DIR_NONE;
         m_pendingGapPoints=0.0;
         m_gapOpenPrice=0.0;
         m_priorClosePrice=0.0;
         m_setupType=AX_GAP_SETUP_NONE;
         // Recover the current bar age on attach/restart, but reject stale gaps.
         double currentOpen=iOpen(symbol,PERIOD_M1,0);
         double previousClose=iClose(symbol,PERIOD_M1,1);
         long barAgeSeconds=(long)(serverTime-currentBar);
         bool ageKnown=(serverTime>0 && barAgeSeconds>=0);
         bool ageAcceptable=(!firstObservation || (ageKnown && barAgeSeconds<=maxSignalAgeSeconds));
         if(currentOpen>0.0 && previousClose>0.0 && ageAcceptable)
           {
            double signedGap=(currentOpen-previousClose)/point;
            if(MathAbs(signedGap)>=minGapPoints)
              {
               m_pending=true;
               m_pendingM1BarTime=currentBar;
               ulong ageMs=(firstObservation ? (ulong)barAgeSeconds*1000 : 0);
               m_gapDetectedAtMs=(nowMs>=ageMs ? nowMs-ageMs : 0);
               m_pendingDirection=(signedGap>0.0 ? AX_DIR_BUY : AX_DIR_SELL);
               m_pendingGapPoints=signedGap;
               m_gapOpenPrice=currentOpen;
               m_priorClosePrice=previousClose;
              }
           }
        }
      out.m1BarTime=m_pendingM1BarTime;
      out.gapPoints=m_pendingGapPoints;
      out.gapOpenPrice=m_gapOpenPrice;
      out.priorClosePrice=m_priorClosePrice;
      out.currentMidPrice=(bid+ask)*0.5;
      out.direction=m_pendingDirection;
      out.setupType=m_setupType;

      if(m_ready)
        {
         out.state=AX_GAP_EXEC_POST_GAP_READY;
         out.postGapReady=true;
         out.reason=(m_setupType==AX_GAP_SETUP_CONTINUATION ? "POST_GAP_CONTINUATION_CONFIRMED" : "POST_GAP_SWEEP_REVERSAL_CONFIRMED");
         out.rolloverSpikeObserved=out.rolloverSpikeObserved || m_rolloverSpikeLatched;
         return(true);
        }
      if(m_expired)
        {
         out.state=AX_GAP_EXEC_POST_GAP_EXPIRED;
         out.reason="POST_GAP_SIGNAL_EXPIRED";
         out.rolloverSpikeObserved=out.rolloverSpikeObserved || m_rolloverSpikeLatched;
         return(false);
        }
      if(!m_pending)
        {
         out.state=AX_GAP_EXEC_IDLE;
         out.reason="NO_QUALIFYING_M1_OPEN_GAP";
         out.rolloverSpikeObserved=out.rolloverSpikeObserved || m_rolloverSpikeLatched;
         return(false);
        }

      ulong elapsed=(nowMs>=m_gapDetectedAtMs ? nowMs-m_gapDetectedAtMs : 0);
      out.waitElapsedMs=elapsed;
      if(elapsed>(ulong)maxSignalAgeSeconds*1000)
        {
         m_pending=false;
         m_expired=true;
         out.state=AX_GAP_EXEC_POST_GAP_EXPIRED;
         out.reason="POST_GAP_SIGNAL_EXPIRED_BEFORE_NORMALIZATION";
         out.rolloverSpikeObserved=out.rolloverSpikeObserved || m_rolloverSpikeLatched;
         return(false);
        }
      if(elapsed<(ulong)waitSeconds*1000)
        {
         out.state=AX_GAP_EXEC_POST_GAP_WAIT;
         out.reason="POST_GAP_WAIT_TIMER_ACTIVE";
         out.rolloverSpikeObserved=out.rolloverSpikeObserved || m_rolloverSpikeLatched;
         return(false);
        }

      // A true zero-spread feed is a valid baseline, not missing history.
      // With a zero baseline, only an exactly zero current spread is normalized;
      // any positive spread must wait for a measurable baseline or fail the cap.
      bool spreadBaselineValid=(MathIsValidNumber(rollingSpreadAverage) &&
                                rollingSpreadAverage>=0.0);
      bool enoughSpreadHistory=(rollingSpreadSamples>=100 && spreadBaselineValid);
      bool spreadWithinAbsoluteCap=(out.currentSpreadPoints<=maxSpreadPoints);
      bool spreadNormalized=(enoughSpreadHistory &&
                             (rollingSpreadAverage==0.0
                              ? out.currentSpreadPoints==0.0
                              : out.currentSpreadPoints<=rollingSpreadAverage*spreadNormalizationMultiple));
      if(!spreadWithinAbsoluteCap || !spreadNormalized)
        {
         out.state=AX_GAP_EXEC_POST_GAP_SPREAD_WAIT;
         out.reason=(!enoughSpreadHistory ? "ROLLING_SPREAD_BASELINE_NOT_READY" :
                     !spreadWithinAbsoluteCap ? "CURRENT_SPREAD_ABOVE_ABSOLUTE_CAP" :
                     (rollingSpreadAverage==0.0
                      ? "ZERO_SPREAD_BASELINE_REQUIRES_ZERO_CURRENT_SPREAD"
                      : "CURRENT_SPREAD_NOT_NORMALIZED"));
         out.rolloverSpikeObserved=out.rolloverSpikeObserved || m_rolloverSpikeLatched;
         return(false);
        }

      // Confirm continuation or a failed gap auction before exposing a signal.
      double mid=(bid+ask)*0.5;
      double continuationDistance=(m_pendingDirection==AX_DIR_BUY ? (mid-m_priorClosePrice)/point : (m_priorClosePrice-mid)/point);
      double sweepDistance=(m_pendingDirection==AX_DIR_BUY ? (m_priorClosePrice-mid)/point : (mid-m_priorClosePrice)/point);
      out.confirmationDistancePoints=MathMax(continuationDistance,sweepDistance);
      if(continuationDistance>=minFollowThroughPoints)
        {
         m_setupType=AX_GAP_SETUP_CONTINUATION;
         m_pendingDirection=(m_pendingGapPoints>0.0 ? AX_DIR_BUY : AX_DIR_SELL);
        }
      else if(allowSweepReversal && sweepDistance>=minSweepPenetrationPoints)
        {
         m_setupType=AX_GAP_SETUP_SWEEP_REVERSAL;
         m_pendingDirection=(m_pendingGapPoints>0.0 ? AX_DIR_SELL : AX_DIR_BUY);
        }
      else
        {
         out.state=AX_GAP_EXEC_POST_GAP_CONFIRMATION_WAIT;
         out.reason="WAITING_FOR_CONTINUATION_OR_SWEEP_CONFIRMATION";
         out.direction=m_pendingDirection;
         out.rolloverSpikeObserved=out.rolloverSpikeObserved || m_rolloverSpikeLatched;
         return(false);
        }
      m_ready=true;
      out.direction=m_pendingDirection;
      out.setupType=m_setupType;
      out.state=AX_GAP_EXEC_POST_GAP_READY;
      out.postGapReady=true;
      out.reason=(m_setupType==AX_GAP_SETUP_CONTINUATION ? "POST_GAP_CONTINUATION_CONFIRMED" : "POST_GAP_SWEEP_REVERSAL_CONFIRMED");
      out.rolloverSpikeObserved=out.rolloverSpikeObserved || m_rolloverSpikeLatched;
      return(true);
     }

   // The caller must consume only after routing the setup through all existing
   // entry gates. This prevents the same M1 gap from being submitted repeatedly.
   bool ConsumePostGapSignal(void)
     {
      if(!m_ready) return(false);
      m_ready=false;
      m_pending=false;
      return(true);
     }
  };

#endif // AX_GAPEXECUTIONENGINE_MQH
