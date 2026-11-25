//+------------------------------------------------------------------+
//|                                  HawkesEventIntensityReplay.mq5  |
//| Deterministic synthetic-sample tests for the actual Hawkes class |
//| Run from MetaEditor on a demo terminal. No orders are submitted. |
//+------------------------------------------------------------------+
#property strict
#include <AutopsyX/HawkesEventIntensity.mqh>

int g_passed=0;
int g_failed=0;

void Check(const bool condition,const string name)
  {
   if(condition)
     {
      g_passed++;
      Print("PASS | ",name);
     }
   else
     {
      g_failed++;
      Print("FAIL | ",name);
     }
  }

void MakeSample(SAxTick &tick,const ulong sequence,const long timeMsc,
                const double mid,const int direction)
  {
   ZeroMemory(tick);
   tick.time=(datetime)(timeMsc/1000);
   tick.timeMsc=timeMsc;
   tick.sequence=sequence;
   tick.mid=mid;
   tick.dir=direction;
   tick.bid=mid-0.5;
   tick.ask=mid+0.5;
  }

void TestDirectionalIntensity(void)
  {
   CHawkesEventIntensityEngine engine;
   Check(engine.Configure(0.05,0.05,0.12,0.04,0.04,0.12,1.0,5,10000,0.0),
         "configure directional test");
   SAxTick tick;
   MakeSample(tick,1,1000,100.0,0);
   engine.UpdateSample(tick,1.0);
   for(ulong i=2;i<=7;i++)
     {
      MakeSample(tick,i,1000+(long)i*100,100.0+(double)(i-1),1);
      engine.UpdateSample(tick,1.0);
     }
   SAxHawkesSnapshot snap;
   Check(engine.Snapshot(snap),"upward events reach warm-up threshold");
   Check(snap.buyIntensity>snap.sellIntensity,"upward events lift buy intensity");

   engine.Reset();
   MakeSample(tick,1,1000,100.0,0);
   engine.UpdateSample(tick,1.0);
   for(ulong j=2;j<=7;j++)
     {
      MakeSample(tick,j,1000+(long)j*100,100.0-(double)(j-1),-1);
      engine.UpdateSample(tick,1.0);
     }
   Check(engine.Snapshot(snap),"downward events reach warm-up threshold");
   Check(snap.sellIntensity>snap.buyIntensity,"downward events lift sell intensity");
  }

void TestThresholdAccumulation(void)
  {
   CHawkesEventIntensityEngine engine;
   engine.Configure(0.05,0.05,0.12,0.04,0.04,0.12,1.0,5,10000,3.0);
   SAxTick tick;
   MakeSample(tick,1,1000,100.0,0);
   engine.UpdateSample(tick,1.0);
   MakeSample(tick,2,1100,101.0,1); engine.UpdateSample(tick,1.0);
   MakeSample(tick,3,1200,102.0,1); engine.UpdateSample(tick,1.0);
   MakeSample(tick,4,1300,103.0,1); engine.UpdateSample(tick,1.0);
   Check(engine.EventCount()==1,"sub-threshold movements accumulate into one event");
  }

void TestOrderingAndInvalidTimestamp(void)
  {
   CHawkesEventIntensityEngine engine;
   engine.Configure(0.05,0.05,0.12,0.04,0.04,0.12,1.0,5,10000,0.0);
   SAxTick tick;
   MakeSample(tick,1,1000,100.0,0); engine.UpdateSample(tick,1.0);
   MakeSample(tick,1,1100,101.0,1);
   Check(!engine.UpdateSample(tick,1.0),"duplicate sequence rejected");
   MakeSample(tick,2,900,101.0,1);
   Check(!engine.UpdateSample(tick,1.0),"out-of-order timestamp rejected");
   MakeSample(tick,3,0,101.0,1);
   Check(!engine.UpdateSample(tick,1.0),"zero timestamp rejected");
  }

void TestStalenessAndConfigurationGuard(void)
  {
   CHawkesEventIntensityEngine engine;
   Check(engine.Configure(0.05,0.05,0.12,0.04,0.04,0.12,1.0,5,100,0.0),
         "valid bounded configuration accepted");
   SAxTick tick;
   MakeSample(tick,1,1000,100.0,0);
   engine.UpdateSample(tick,1.0);
   SAxHawkesSnapshot snap;
   Check(!engine.Evaluate(1200,snap) && snap.status==AX_HAWKES_STALE,
         "stale snapshot is rejected");

   CHawkesEventIntensityEngine invalid;
   Check(!invalid.Configure(0.05,0.05,0.90,0.90,0.04,0.12,1.0,5,10000,0.0),
         "unstable excitation configuration rejected");
  }

void TestDeterministicReplay(void)
  {
   CHawkesEventIntensityEngine first;
   CHawkesEventIntensityEngine second;
   first.Configure(0.05,0.05,0.12,0.04,0.04,0.12,1.0,5,10000,0.0);
   second.Configure(0.05,0.05,0.12,0.04,0.04,0.12,1.0,5,10000,0.0);
   SAxTick tick;
   for(ulong i=1;i<=12;i++)
     {
      int direction=(i%3==0)?-1:1;
      double mid=100.0+(double)i*direction*0.25;
      MakeSample(tick,i,1000+(long)i*125,mid,direction);
      first.UpdateSample(tick,0.01);
      second.UpdateSample(tick,0.01);
     }
   SAxHawkesSnapshot a,b;
   bool aReady=first.Snapshot(a);
   bool bReady=second.Snapshot(b);
   Check(aReady && bReady,"both deterministic replays become ready");
   Check(a.eventCount==b.eventCount,"replay event counts are identical");
   Check(MathAbs(a.buyIntensity-b.buyIntensity)<1e-12 &&
         MathAbs(a.sellIntensity-b.sellIntensity)<1e-12,
         "replay intensities are identical");
  }

void OnStart(void)
  {
   TestDirectionalIntensity();
   TestThresholdAccumulation();
   TestOrderingAndInvalidTimestamp();
   TestStalenessAndConfigurationGuard();
   TestDeterministicReplay();
   PrintFormat("HAWKES REPLAY COMPLETE | passed=%d failed=%d | no trade requests issued",
               g_passed,g_failed);
   if(g_failed>0)
      Print("RESULT: FAILED. Inspect the individual assertions above.");
   else
      Print("RESULT: ALL ASSERTIONS PASSED. MetaEditor compilation is still required.");
  }
//+------------------------------------------------------------------+
