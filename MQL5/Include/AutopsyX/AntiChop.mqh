//+------------------------------------------------------------------+
//|                                                     AntiChop.mqh |
//|  Anti-Chop Engine (spec section 11)                              |
//|  Detects hostile, noisy, back-and-forth conditions and imposes    |
//|  an adaptive cooldown / aggression reduction.                     |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_ANTICHOP_MQH
#define AX_ANTICHOP_MQH
#include "Defs.mqh"

#define AX_CHOP_EVENT_BUFFER 64
#define AX_CHOP_WINDOW_SEC   900   // 15 minute rolling window

class CAntiChopEngine
  {
private:
   datetime          m_flipTimes[AX_CHOP_EVENT_BUFFER];
   int               m_flipCount;
   datetime          m_stopOutTimes[AX_CHOP_EVENT_BUFFER];
   int               m_stopOutCount;
   datetime          m_failedBreakoutTimes[AX_CHOP_EVENT_BUFFER];
   int               m_failedBreakoutCount;

   datetime          m_cooldownUntil;
   int               m_baseCooldownSec;
   int               m_maxCooldownSec;

   void              PushEvent(datetime &arr[],int &count,const datetime t)
     {
      if(count<AX_CHOP_EVENT_BUFFER)
        {
         arr[count]=t; count++;
        }
      else
        {
         for(int i=1;i<AX_CHOP_EVENT_BUFFER;i++) arr[i-1]=arr[i];
         arr[AX_CHOP_EVENT_BUFFER-1]=t;
        }
     }

   int               CountWithinWindow(const datetime &arr[],const int count,const datetime now) const
     {
      int c=0;
      for(int i=0;i<count;i++)
         if((now-arr[i])<=AX_CHOP_WINDOW_SEC) c++;
      return(c);
     }

public:
                     CAntiChopEngine(void)
     {
      m_flipCount=0; m_stopOutCount=0; m_failedBreakoutCount=0;
      m_cooldownUntil=0; m_baseCooldownSec=20; m_maxCooldownSec=1800;
     }

   void              Configure(const int baseCooldownSec,const int maxCooldownSec)
     {
      m_baseCooldownSec = baseCooldownSec;
      m_maxCooldownSec  = maxCooldownSec;
     }

   void              RegisterFlip(void)       { PushEvent(m_flipTimes,m_flipCount,TimeCurrent()); ApplyCooldown(); }
   void              RegisterStopOut(void)    { PushEvent(m_stopOutTimes,m_stopOutCount,TimeCurrent()); ApplyCooldown(); }
   void              RegisterFailedBreakout(void) { PushEvent(m_failedBreakoutTimes,m_failedBreakoutCount,TimeCurrent()); ApplyCooldown(); }

   int               FlipsInWindow(void)  const { return(CountWithinWindow(m_flipTimes,m_flipCount,TimeCurrent())); }
   int               StopOutsInWindow(void) const { return(CountWithinWindow(m_stopOutTimes,m_stopOutCount,TimeCurrent())); }
   int               FailedBreakoutsInWindow(void) const { return(CountWithinWindow(m_failedBreakoutTimes,m_failedBreakoutCount,TimeCurrent())); }

   //--- hostile-conditions detector: excessive flips/stop-outs/failed breakouts in the window ---
   bool              IsHostile(void) const
     {
      int score = FlipsInWindow()*2 + StopOutsInWindow()*2 + FailedBreakoutsInWindow();
      return(score>=6);
     }

   void              ApplyCooldown(void)
     {
      int events = FlipsInWindow()+StopOutsInWindow()+FailedBreakoutsInWindow();
      int cooldown = (int)MathMin((double)m_maxCooldownSec, (double)m_baseCooldownSec*MathPow(1.6,(double)events));
      datetime candidate = TimeCurrent()+cooldown;
      if(candidate>m_cooldownUntil) m_cooldownUntil = candidate;
     }

   bool              IsInCooldown(void) const { return(TimeCurrent()<m_cooldownUntil); }
   int               CooldownRemainingSec(void) const
     {
      int r = (int)(m_cooldownUntil-TimeCurrent());
      return(MathMax(0,r));
     }

   //--- multiplies EntryEngine's willingness to act; 1.0 = full aggression ---
   double            AggressionMultiplier(void) const
     {
      if(IsInCooldown()) return(0.0);
      if(IsHostile())    return(0.35);
      int events = FlipsInWindow()+StopOutsInWindow()+FailedBreakoutsInWindow();
      if(events>=3) return(0.65);
      return(1.0);
     }
  };
//+------------------------------------------------------------------+
#endif // AX_ANTICHOP_MQH
