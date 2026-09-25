//+------------------------------------------------------------------+
//|                                                  DrawdownEngine.mqh|
//|  Dynamic Drawdown Engine + Liquidity-Adjusted Drawdown (spec       |
//|  sections 10-12), institutional engine upgrade - ENGINEERING       |
//|  DESIGN, not paper-sourced. The source paper (Malhotra SSRN         |
//|  3306817) warns that traditional return-based risk methods miss     |
//|  hidden liquidity risk and that risk must factor loss probability   |
//|  and magnitude, not just volatility (findings items v, x) - it       |
//|  does not specify a drawdown state machine or an LADD formula.       |
//|  Every threshold, weight, and the LADD formula itself are this       |
//|  codebase's own design.                                              |
//|                                                                    |
//|  Distinct from AdaptiveFlipEngine's ENUM_AX_CAPITAL_STATE ladder:   |
//|  that one reacts to peak-equity drawdown alone. This engine          |
//|  combines drawdown MAGNITUDE, VELOCITY, current volatility regime,   |
//|  current liquidity score, execution quality, and consecutive         |
//|  losses into one severity read - deliberately not reducible to "if   |
//|  drawdown > X" (spec section 10's own explicit instruction).         |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_DRAWDOWNENGINE_MQH
#define AX_DRAWDOWNENGINE_MQH
#include "Defs.mqh"
#include "VolatilityEngine.mqh"

#define AX_DD_EQUITY_HISTORY 200  // ring buffer for rolling-window drawdown + velocity

struct SAxEquitySample
  {
   datetime time;
   double   equity;
  };

struct SAxDrawdownState
  {
   double   currentEquity;
   double   peakEquity;
   double   absoluteDrawdown;          // currency
   double   percentDrawdown;           // %
   double   dailyDrawdownPct;
   double   weeklyDrawdownPct;
   double   rollingDrawdownPct;        // over the configured rolling window
   int      consecutiveLosses;
   double   lossVelocityPctPerHour;    // rate of drawdown % increase - 0 or negative when recovering
   int      timeUnderwaterSeconds;     // 0 if currently at/above peak
   int      lastRecoverySeconds;       // time taken to recover from the most recently CLOSED
                                         // underwater period - 0 if never recovered yet
   double   volatilityAdjustedDrawdownPct;
   double   liquidityAdjustedDrawdownPct; // LADD
   ENUM_AX_DRAWDOWN_STATE state;
   string   reason;
  };

class CDynamicDrawdownEngine
  {
private:
   double            m_peakEquity;
   double            m_dayStartEquity;
   datetime          m_dayStartTime;
   double            m_weekStartEquity;
   datetime          m_weekStartTime;

   datetime          m_underwaterStartTime; // 0 when not currently underwater
   int               m_lastRecoverySeconds;

   int               m_rollingWindowSeconds;
   int               m_minSampleIntervalSeconds; // derived from m_rollingWindowSeconds so the fixed-size
                                                   // ring buffer always spans the full configured window
                                                   // regardless of tick rate (code-review finding: sampling
                                                   // every tick on a liquid symbol overwrote a 24h window
                                                   // in under a minute)
   datetime          m_lastSampleTime;            // 0 = no sample taken yet
   SAxEquitySample   m_history[AX_DD_EQUITY_HISTORY];
   int               m_historyCount;
   int               m_historyHead;

   //--- state-machine thresholds (severity score 0..100 -> 5 states) - configurable ---
   double            m_cautionThreshold;
   double            m_defensiveThreshold;
   double            m_severeThreshold;
   double            m_haltThreshold;

   //--- component weights for the severity score ---
   double            m_wMagnitude, m_wVelocity, m_wVolatility, m_wLiquidity, m_wExecution, m_wConsecLosses;

   int               m_maxConsecutiveLossesForFullPenalty;

   void              PushEquitySample(const datetime t,const double equity)
     {
      m_history[m_historyHead].time=t; m_history[m_historyHead].equity=equity;
      m_historyHead=(m_historyHead+1)%AX_DD_EQUITY_HISTORY;
      if(m_historyCount<AX_DD_EQUITY_HISTORY) m_historyCount++;
     }

   double            RollingDrawdownPct(const datetime now,const double currentEquity) const
     {
      double windowPeak=currentEquity;
      for(int i=0;i<m_historyCount;i++)
        {
         if((double)(now-m_history[i].time)>m_rollingWindowSeconds) continue;
         if(m_history[i].equity>windowPeak) windowPeak=m_history[i].equity;
        }
      if(windowPeak<=0) return(0.0);
      return(MathMax(0.0,(windowPeak-currentEquity)/windowPeak*100.0));
     }

   //--- linear-regression-free velocity: percent-drawdown now minus percent-drawdown at the oldest  ---
   //--- sample still inside the rolling window, divided by elapsed hours - a simple, robust rate      ---
   //--- rather than a full regression (this is a live tick-loop read, kept deliberately cheap) ---
   double            LossVelocityPctPerHour(const datetime now,const double currentPercentDrawdown) const
     {
      if(m_historyCount<2) return(0.0);
      // find the oldest sample within the rolling window
      datetime oldestTimeInWindow=now; double oldestEquity=0; bool found=false;
      for(int i=0;i<m_historyCount;i++)
        {
         if((double)(now-m_history[i].time)>m_rollingWindowSeconds) continue;
         if(!found || m_history[i].time<oldestTimeInWindow)
           { oldestTimeInWindow=m_history[i].time; oldestEquity=m_history[i].equity; found=true; }
        }
      if(!found || oldestEquity<=0) return(0.0);
      double elapsedHours = (double)(now-oldestTimeInWindow)/3600.0;
      if(elapsedHours<=0.001) return(0.0);
      double oldestPctDrawdown = MathMax(0.0,(m_peakEquity-oldestEquity)/m_peakEquity*100.0);
      return((currentPercentDrawdown-oldestPctDrawdown)/elapsedHours);
     }

public:
                     CDynamicDrawdownEngine(void)
     {
      m_peakEquity=0; m_dayStartEquity=0; m_dayStartTime=0; m_weekStartEquity=0; m_weekStartTime=0;
      m_underwaterStartTime=0; m_lastRecoverySeconds=0;
      m_rollingWindowSeconds=3600*24; m_historyCount=0; m_historyHead=0;
      m_minSampleIntervalSeconds=MathMax(1,m_rollingWindowSeconds/AX_DD_EQUITY_HISTORY); m_lastSampleTime=0;
      m_cautionThreshold=20.0; m_defensiveThreshold=40.0; m_severeThreshold=60.0; m_haltThreshold=80.0;
      m_wMagnitude=30; m_wVelocity=20; m_wVolatility=15; m_wLiquidity=15; m_wExecution=10; m_wConsecLosses=10;
      m_maxConsecutiveLossesForFullPenalty=6;
     }

   void              Configure(const int rollingWindowSeconds,const double cautionThreshold,
                                const double defensiveThreshold,const double severeThreshold,
                                const double haltThreshold,const double wMagnitude,const double wVelocity,
                                const double wVolatility,const double wLiquidity,const double wExecution,
                                const double wConsecLosses,const int maxConsecutiveLossesForFullPenalty)
     {
      m_rollingWindowSeconds = MathMax(60,rollingWindowSeconds);
      m_minSampleIntervalSeconds = MathMax(1,m_rollingWindowSeconds/AX_DD_EQUITY_HISTORY);
      //--- guard against a transposed-argument call silently inverting the state ladder (code-review    ---
      //--- finding, same as HiddenRiskDetector.mqh's Configure()): MQL5 has no named parameters, so four ---
      //--- adjacent same-typed doubles are an easy swap - each threshold is floored at the previous one  ---
      //--- so the ladder stays monotonic regardless of call-site argument order ---
      m_cautionThreshold=cautionThreshold;
      m_defensiveThreshold=MathMax(m_cautionThreshold,defensiveThreshold);
      m_severeThreshold=MathMax(m_defensiveThreshold,severeThreshold);
      m_haltThreshold=MathMax(m_severeThreshold,haltThreshold);
      m_wMagnitude=MathMax(0,wMagnitude); m_wVelocity=MathMax(0,wVelocity);
      m_wVolatility=MathMax(0,wVolatility); m_wLiquidity=MathMax(0,wLiquidity);
      m_wExecution=MathMax(0,wExecution); m_wConsecLosses=MathMax(0,wConsecLosses);
      m_maxConsecutiveLossesForFullPenalty=MathMax(1,maxConsecutiveLossesForFullPenalty);
     }

   //--- call every tick (or every few seconds - this is cheap enough for either cadence) ---
   SAxDrawdownState  Update(const double currentEquity,const int consecutiveLosses,
                             const ENUM_AX_VOLATILITY_STATE volState,const double liquidityScore,
                             const double executionQualityScore,const datetime now)
     {
      SAxDrawdownState s;

      if(m_peakEquity<=0) m_peakEquity=currentEquity; // first call - seed, never a fabricated prior peak

      //--- day/week rollover, tracked independently here (same reasoning as VolatilityEngine owning ---
      //--- its own ATR handle rather than sharing CRegimeEngine's - each engine's read is            ---
      //--- independently reviewable without cross-engine state coupling) ---
      MqlDateTime dtNow; TimeToStruct(now,dtNow);
      datetime dayStart = now-(dtNow.hour*3600+dtNow.min*60+dtNow.sec);
      if(dayStart!=m_dayStartTime) { m_dayStartTime=dayStart; m_dayStartEquity=currentEquity; }
      if(m_dayStartEquity<=0) m_dayStartEquity=currentEquity;

      int daysSinceMonday=(dtNow.day_of_week+6)%7;
      datetime weekStart=dayStart-daysSinceMonday*86400;
      if(weekStart!=m_weekStartTime) { m_weekStartTime=weekStart; m_weekStartEquity=currentEquity; }
      if(m_weekStartEquity<=0) m_weekStartEquity=currentEquity;

      //--- peak tracking + underwater/recovery timing ---
      if(currentEquity>=m_peakEquity)
        {
         if(m_underwaterStartTime>0) m_lastRecoverySeconds=(int)(now-m_underwaterStartTime);
         m_underwaterStartTime=0;
         m_peakEquity=currentEquity;
        }
      else if(m_underwaterStartTime==0)
         m_underwaterStartTime=now;

      //--- sample at intervals derived from the configured rolling window rather than every call, so   ---
      //--- the fixed-size ring buffer actually spans the full window instead of being overwritten in   ---
      //--- seconds on a liquid symbol ticking many times per second (code-review finding) ---
      if(m_lastSampleTime==0 || (double)(now-m_lastSampleTime)>=m_minSampleIntervalSeconds)
        {
         PushEquitySample(now,currentEquity);
         m_lastSampleTime=now;
        }

      s.currentEquity=currentEquity;
      s.peakEquity=m_peakEquity;
      s.absoluteDrawdown=MathMax(0.0,m_peakEquity-currentEquity);
      s.percentDrawdown=(m_peakEquity>0)?s.absoluteDrawdown/m_peakEquity*100.0:0.0;
      s.dailyDrawdownPct=(m_dayStartEquity>0)?MathMax(0.0,(m_dayStartEquity-currentEquity)/m_dayStartEquity*100.0):0.0;
      s.weeklyDrawdownPct=(m_weekStartEquity>0)?MathMax(0.0,(m_weekStartEquity-currentEquity)/m_weekStartEquity*100.0):0.0;
      s.rollingDrawdownPct=RollingDrawdownPct(now,currentEquity);
      s.consecutiveLosses=consecutiveLosses;
      s.lossVelocityPctPerHour=LossVelocityPctPerHour(now,s.percentDrawdown);
      s.timeUnderwaterSeconds=(m_underwaterStartTime>0)?(int)(now-m_underwaterStartTime):0;
      s.lastRecoverySeconds=m_lastRecoverySeconds;

      //--- volatility-adjusted / liquidity-adjusted drawdown - ENGINEERING DESIGN multipliers,        ---
      //--- documented as such, not derived from the source paper ---
      double volMultiplier;
      switch(volState)
        {
         case AX_VOL_NORMAL:  volMultiplier=1.0; break;
         case AX_VOL_LOW:     volMultiplier=0.9; break;
         case AX_VOL_HIGH:    volMultiplier=1.3; break;
         case AX_VOL_EXTREME: volMultiplier=1.8; break;
         case AX_VOL_SHOCK:   volMultiplier=2.5; break;
         default:              volMultiplier=1.0; break; // any future enum member not yet mapped above
                                                            // falls back to NORMAL rather than being silently
                                                            // absorbed into it (code-review finding: every
                                                            // current member now has its own explicit case)
        }
      s.volatilityAdjustedDrawdownPct = s.percentDrawdown*volMultiplier;

      //--- LADD = Drawdown x LiquidityRiskMultiplier (spec section 12) - multiplier scales from 1.0  ---
      //--- (liquidityScore=100, perfect conditions) to 2.5 (liquidityScore=0, worst conditions) ---
      double liqMultiplier = 1.0+(100.0-AxClampD(liquidityScore,0.0,100.0))/100.0*1.5;
      s.liquidityAdjustedDrawdownPct = s.percentDrawdown*liqMultiplier;

      //--- severity score: each component normalized to 0..100 "how bad", weighted-averaged ---
      double magnitudeSeverity = AxClampD(s.percentDrawdown*2.0,0.0,100.0); // 50% DD = max severity
      double velocitySeverity  = AxClampD(s.lossVelocityPctPerHour*10.0,0.0,100.0); // 10%/hr = max
      double volSeverity       = AxClampD((volMultiplier-1.0)/1.5*100.0,0.0,100.0);
      //--- algebraically liqMultiplier's round trip reduces to exactly (100-liquidityScore), so computed ---
      //--- directly from liquidityScore rather than back out of liqMultiplier - keeps this severity term  ---
      //--- independent of the LADD multiplier's own 1.0..2.5 range constant (code-review finding) ---
      double liqSeverity       = AxClampD(100.0-AxClampD(liquidityScore,0.0,100.0),0.0,100.0);
      double execSeverity      = AxClampD(100.0-executionQualityScore,0.0,100.0);
      double consecSeverity    = AxClampD(100.0*consecutiveLosses/(double)m_maxConsecutiveLossesForFullPenalty,0.0,100.0);

      double totalWeight = m_wMagnitude+m_wVelocity+m_wVolatility+m_wLiquidity+m_wExecution+m_wConsecLosses;
      double severity = (totalWeight>0) ?
         (magnitudeSeverity*m_wMagnitude+velocitySeverity*m_wVelocity+volSeverity*m_wVolatility+
          liqSeverity*m_wLiquidity+execSeverity*m_wExecution+consecSeverity*m_wConsecLosses)/totalWeight
         : 0.0;

      if(severity>=m_haltThreshold)           { s.state=AX_DD_STATE_HALT; }
      else if(severity>=m_severeThreshold)     { s.state=AX_DD_STATE_SEVERE; }
      else if(severity>=m_defensiveThreshold)  { s.state=AX_DD_STATE_DEFENSIVE; }
      else if(severity>=m_cautionThreshold)    { s.state=AX_DD_STATE_CAUTION; }
      else                                      { s.state=AX_DD_STATE_NORMAL; }

      s.reason=StringFormat(
         "severity=%.1f (mag=%.0f vel=%.0f vol=%.0f liq=%.0f exec=%.0f consec=%.0f) dd=%.2f%% ladd=%.2f%%",
         severity,magnitudeSeverity,velocitySeverity,volSeverity,liqSeverity,execSeverity,consecSeverity,
         s.percentDrawdown,s.liquidityAdjustedDrawdownPct);

      return(s);
     }

   double            PeakEquity(void) const { return(m_peakEquity); }
  };
//+------------------------------------------------------------------+
#endif // AX_DRAWDOWNENGINE_MQH
