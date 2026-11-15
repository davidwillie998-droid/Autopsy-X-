//+------------------------------------------------------------------+
//|                                          ShadowRiverEngineTest.mq5|
//|  Deterministic in-terminal tests for ShadowRiverEngine.mqh        |
//+------------------------------------------------------------------+
#property strict
#property script_show_inputs

#include <AutopsyX/ShadowRiverEngine.mqh>

int g_passed=0;
int g_failed=0;

void Check(const bool condition,const string label)
  {
   if(condition)
     {
      g_passed++;
      Print("PASS: ",label);
     }
   else
     {
      g_failed++;
      Print("FAIL: ",label);
     }
  }

void CheckEvent(CShadowRiverEngine &engine,
                const double price,
                const datetime sampleTime,
                const ENUM_AX_SHADOW_EVENT expected,
                const string label)
  {
   ENUM_AX_SHADOW_EVENT actual=engine.Update(price,sampleTime);
   Check(actual==expected,label);
  }

void OnStart(void)
  {
   CShadowRiverEngine engine;

   Check(!engine.IsConfigured(),"new engine starts unconfigured");
   Check(!engine.ConfigurePriceDistance(0.0,2.0),"zero sensitivity rejected");
   Check(engine.ConfigurePriceDistance(10.0,2.0),"price-distance configuration accepted");
   Check(MathAbs(engine.ReversalDistance()-20.0)<1e-10,"reversal distance is twice sensitivity");

   CheckEvent(engine,100.0,1,AX_SHADOW_NONE,"first sample establishes anchor");
   CheckEvent(engine,109.99,2,AX_SHADOW_NONE,"sub-threshold initial movement ignored");
   CheckEvent(engine,110.0,3,AX_SHADOW_INITIAL_UP,"initial upward threshold emits event");
   CheckEvent(engine,115.0,4,AX_SHADOW_NONE,"in-leg movement below continuation threshold emits no event");
   CheckEvent(engine,120.0,5,AX_SHADOW_CONTINUATION_UP,"upward continuation threshold emits event");
   CheckEvent(engine,125.0,6,AX_SHADOW_NONE,"new high updates extreme without duplicate point");
   CheckEvent(engine,106.0,7,AX_SHADOW_NONE,"retrace below reversal threshold does not reverse");
   CheckEvent(engine,105.0,8,AX_SHADOW_REVERSAL_DOWN,"two-times retracement confirms downward reversal");
   CheckEvent(engine,95.0,9,AX_SHADOW_CONTINUATION_DOWN,"downward continuation threshold emits event");
   CheckEvent(engine,90.0,10,AX_SHADOW_NONE,"new low updates down-leg extreme");
   CheckEvent(engine,110.0,11,AX_SHADOW_REVERSAL_UP,"two-times rise from low confirms upward reversal");

   CheckEvent(engine,80.0,10,AX_SHADOW_NONE,"out-of-order timestamp is rejected");
   Check(engine.Direction()==1,"rejected stale sample cannot change direction");
   Check(engine.EventCount()==5,"event counter counts only emitted events");

   engine.Reset();
   Check(engine.IsConfigured(),"reset preserves valid configuration");
   Check(engine.Direction()==0 && engine.EventCount()==0,"reset clears directional state and event count");
   CheckEvent(engine,200.0,12,AX_SHADOW_NONE,"reset engine establishes a fresh anchor");

   Check(!engine.ConfigurePriceDistance(-1.0,2.0),"negative sensitivity rejected");
   Check(!engine.IsConfigured(),"invalid reconfiguration disables stale thresholds");
   CheckEvent(engine,220.0,13,AX_SHADOW_NONE,"unconfigured engine emits no events");

   CShadowRiverEngine pointEngine;
   Check(pointEngine.ConfigurePoints(10.0,0.01,2.0),"point-size configuration accepted");
   Check(MathAbs(pointEngine.SensitivityPrice()-0.10)<1e-10,"points converted to absolute price distance");
   Check(!pointEngine.ConfigurePoints(10.0,0.0,2.0),"invalid point size rejected");
   Check(!pointEngine.IsConfigured(),"invalid point-size reconfiguration fails closed");

   CShadowRiverEngine downEngine;
   Check(downEngine.ConfigurePriceDistance(10.0,2.0),"separate down-leg engine configured");
   CheckEvent(downEngine,100.0,20,AX_SHADOW_NONE,"down-leg engine establishes anchor");
   CheckEvent(downEngine,90.0,21,AX_SHADOW_INITIAL_DOWN,"initial downward threshold emits event");
   CheckEvent(downEngine,80.0,22,AX_SHADOW_CONTINUATION_DOWN,"downward continuation emits event");

   Print("SHADOW RIVER TESTS: ",g_passed," passed, ",g_failed," failed.");
   if(g_failed>0)
      Print("RESULT: FAIL");
   else
      Print("RESULT: PASS");
  }
