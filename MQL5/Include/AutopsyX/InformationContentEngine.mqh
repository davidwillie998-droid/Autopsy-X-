//+------------------------------------------------------------------+
//|                                        InformationContentEngine.mqh|
//|  Order-Flow / Information-Content Model (institutional engine     |
//|  upgrade) - ENGINEERING DESIGN combining paper-adjacent concepts.  |
//|                                                                    |
//|  Deliberately thin: COrderFlowEngine (OrderFlow.mqh) already        |
//|  computes a windowed buy/sell imbalance from inferred tick          |
//|  direction - this class does not recompute that. It exposes it     |
//|  under the vocabulary spec section 6 asks for (SIGNAL PRESSURE)     |
//|  and adds one genuinely new check: whether the CURRENT tick's       |
//|  more rigorous Lee & Ready classification (CTickDirectionEngine,    |
//|  paper-sourced) agrees with the windowed pressure reading, as a     |
//|  same-tick confirmation signal.                                     |
//|                                                                    |
//|  HARD DISTINCTION (spec section 6's own requirement): everything    |
//|  here is SIGNAL PRESSURE - an inference from price/quote/tick        |
//|  behavior on a feed with no real trade-aggressor flag. It is NEVER  |
//|  EXECUTABLE ORDER FLOW (a real, visible order book / trade tape),   |
//|  which no retail MT5 feed exposes. Every accessor name and          |
//|  docstring below says "signal", never "order flow" alone, to keep   |
//|  that distinction impossible to miss at the call site.              |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_INFORMATIONCONTENTENGINE_MQH
#define AX_INFORMATIONCONTENTENGINE_MQH
#include "Defs.mqh"
#include "OrderFlow.mqh"
#include "TickDirectionEngine.mqh"

class CInformationContentEngine
  {
public:
   //--- -100 (all SELL signal pressure) .. +100 (all BUY signal pressure), directly rescaled from  ---
   //--- COrderFlowEngine's own -1..+1 windowed imbalance ratio - not recomputed, just relabeled     ---
   //--- under this engine's vocabulary. ---
   double            SignalPressure(const COrderFlowEngine &oflow) const
     {
      return(AxClampD(oflow.ImbalanceRatio()*100.0,-100.0,100.0));
     }

   string            PressureLabel(const double signalPressure) const
     {
      if(signalPressure>=20.0)  return("BUY_PRESSURE");
      if(signalPressure<=-20.0) return("SELL_PRESSURE");
      return("BALANCED");
     }

   //--- true if the Lee & Ready-classified direction of the MOST RECENT tick agrees with the sign  ---
   //--- of the windowed signal pressure - a same-tick cross-check between the two independent        ---
   //--- classification methods this codebase now carries (OrderFlow.mqh's own simpler mid-move dir,  ---
   //--- and TickDirectionEngine's more rigorous T+Q test). Disagreement isn't itself an error - it's ---
   //--- normal for a single tick to run against a windowed average - but persistent disagreement is  ---
   //--- worth surfacing rather than silently averaged away. ---
   bool              CurrentTickConfirms(const double signalPressure,const CTickDirectionEngine &tickDir) const
     {
      ENUM_AX_TICK_DIRECTION dir = tickDir.LastDirection();
      if(dir==AX_TICKDIR_UNCLASSIFIED) return(false);
      if(signalPressure>=20.0)  return(dir==AX_TICKDIR_BUY);
      if(signalPressure<=-20.0) return(dir==AX_TICKDIR_SELL);
      return(true); // BALANCED pressure has no directional claim for a single tick to confirm/deny
     }
  };
//+------------------------------------------------------------------+
#endif // AX_INFORMATIONCONTENTENGINE_MQH
