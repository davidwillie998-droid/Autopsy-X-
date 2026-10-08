//+------------------------------------------------------------------+
//|                                                TradeLifecycle.mqh|
//|  Trade Execution State Machine (FLIPDEMON EXTREME upgrade,       |
//|  spec section 21) - one instance tracks ONE setup from signal to |
//|  autopsy. Strictly forward-only: TransitionTo() rejects any jump |
//|  that isn't the next legal state and returns false rather than   |
//|  silently accepting it - "handle errors explicitly" means the    |
//|  caller finds out immediately, not later when state is already   |
//|  wrong. Never treat an order as filled just because it was       |
//|  submitted - ORDER_FILLED is reachable only from ORDER_SUBMITTED,|
//|  and the caller is expected to have a real broker confirmation   |
//|  (see ExecutionEngine.mqh's ConfirmPosition) in hand before       |
//|  calling TransitionTo(AX_LIFECYCLE_ORDER_FILLED).                 |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_TRADELIFECYCLE_MQH
#define AX_TRADELIFECYCLE_MQH
#include "Defs.mqh"

class CTradeLifecycle
  {
private:
   ENUM_AX_LIFECYCLE_STATE m_state;
   string                  m_setupId;
   datetime                m_stateChangedTime;
   string                  m_lastError;

   //--- CANCELLED = the setup never reached the market at all (failed validation/risk/data quality). ---
   //--- FAILED = an order was actually attempted and something went wrong at or after that point     ---
   //--- (broker rejection, execution failure, a position that had to be abandoned mid-management).    ---
   //--- Keeping these distinct means the journal/statistics can tell "we correctly declined to trade" ---
   //--- apart from "we tried and it went wrong" - which are very different things to learn from. ---
   bool IsLegalTransition(const ENUM_AX_LIFECYCLE_STATE from,const ENUM_AX_LIFECYCLE_STATE to) const
     {
      if(from==AX_LIFECYCLE_AUTOPSIED || from==AX_LIFECYCLE_CANCELLED || from==AX_LIFECYCLE_FAILED)
         return(false); // terminal - nothing transitions out of a terminal state

      if(to==AX_LIFECYCLE_CANCELLED)
         return(from==AX_LIFECYCLE_SIGNAL_DETECTED || from==AX_LIFECYCLE_THESIS_CREATED ||
                from==AX_LIFECYCLE_VALIDATING || from==AX_LIFECYCLE_RISK_CHECK || from==AX_LIFECYCLE_ORDER_READY);

      if(to==AX_LIFECYCLE_FAILED)
         return(from==AX_LIFECYCLE_ORDER_SUBMITTED || from==AX_LIFECYCLE_ORDER_FILLED ||
                from==AX_LIFECYCLE_POSITION_ACTIVE || from==AX_LIFECYCLE_POSITION_MANAGED ||
                from==AX_LIFECYCLE_EXIT_TRIGGERED); // a triggered close that never gets a confirmed
                                                      // fill (rejected/requoted/connection drop) must
                                                      // have an escape too, same as ORDER_SUBMITTED -
                                                      // code-review finding: this was missing and left
                                                      // the setup permanently stuck in a non-terminal state

      switch(from)
        {
         case AX_LIFECYCLE_SIGNAL_DETECTED:  return(to==AX_LIFECYCLE_THESIS_CREATED);
         case AX_LIFECYCLE_THESIS_CREATED:   return(to==AX_LIFECYCLE_VALIDATING);
         case AX_LIFECYCLE_VALIDATING:       return(to==AX_LIFECYCLE_RISK_CHECK);
         case AX_LIFECYCLE_RISK_CHECK:       return(to==AX_LIFECYCLE_ORDER_READY);
         case AX_LIFECYCLE_ORDER_READY:      return(to==AX_LIFECYCLE_ORDER_SUBMITTED);
         case AX_LIFECYCLE_ORDER_SUBMITTED:  return(to==AX_LIFECYCLE_ORDER_FILLED);
         case AX_LIFECYCLE_ORDER_FILLED:     return(to==AX_LIFECYCLE_POSITION_ACTIVE);
         case AX_LIFECYCLE_POSITION_ACTIVE:  return(to==AX_LIFECYCLE_POSITION_MANAGED || to==AX_LIFECYCLE_EXIT_TRIGGERED);
         case AX_LIFECYCLE_POSITION_MANAGED: return(to==AX_LIFECYCLE_EXIT_TRIGGERED);
         case AX_LIFECYCLE_EXIT_TRIGGERED:   return(to==AX_LIFECYCLE_POSITION_CLOSED);
         case AX_LIFECYCLE_POSITION_CLOSED:  return(to==AX_LIFECYCLE_JOURNALED);
         case AX_LIFECYCLE_JOURNALED:        return(to==AX_LIFECYCLE_AUTOPSIED);
        }
      return(false);
     }

public:
                     CTradeLifecycle(void)
     {
      m_state=AX_LIFECYCLE_SIGNAL_DETECTED; m_setupId=""; m_stateChangedTime=0; m_lastError="";
     }

   void              Begin(const string setupId)
     {
      m_setupId=setupId;
      m_state=AX_LIFECYCLE_SIGNAL_DETECTED;
      m_stateChangedTime=TimeCurrent();
      m_lastError="";
     }

   //--- returns false and sets LastError() on an illegal jump - caller must NOT proceed as if the ---
   //--- transition happened. This is the state machine's whole point: it is impossible to silently ---
   //--- treat, say, ORDER_READY as if it were ORDER_FILLED. ---
   bool              TransitionTo(const ENUM_AX_LIFECYCLE_STATE to)
     {
      if(!IsLegalTransition(m_state,to))
        {
         m_lastError=StringFormat("Illegal lifecycle transition: %s -> %s",
                                   AxLifecycleStateToString(m_state),AxLifecycleStateToString(to));
         return(false);
        }
      m_state=to;
      m_stateChangedTime=TimeCurrent();
      m_lastError="";
      return(true);
     }

   ENUM_AX_LIFECYCLE_STATE State(void)            const { return(m_state); }
   string                  SetupId(void)          const { return(m_setupId); }
   datetime                StateChangedTime(void) const { return(m_stateChangedTime); }
   string                  LastError(void)        const { return(m_lastError); }
   bool                    IsTerminal(void)        const
     {
      return(m_state==AX_LIFECYCLE_AUTOPSIED || m_state==AX_LIFECYCLE_CANCELLED || m_state==AX_LIFECYCLE_FAILED);
     }
   int                     SecondsInState(void)    const
     {
      if(m_stateChangedTime<=0) return(0);
      return((int)(TimeCurrent()-m_stateChangedTime));
     }
  };
//+------------------------------------------------------------------+
#endif // AX_TRADELIFECYCLE_MQH
