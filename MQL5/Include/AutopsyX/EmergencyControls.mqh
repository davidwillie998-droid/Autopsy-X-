//+------------------------------------------------------------------+
//|                                              EmergencyControls.mqh|
//|  Execution Modes (spec section 37) + Emergency Controls (spec     |
//|  section 38), FLIPDEMON EXTREME upgrade.                          |
//|                                                                    |
//|  Deliberately a thin, dependency-free gate class - it holds no     |
//|  reference to CExecutionEngine or CRiskEngine and sends no orders  |
//|  itself. CanEnterDirection()/OrdersAllowed() are checked BY the    |
//|  caller before it does anything broker-facing; CloseManagedPositions|
//|  is a one-shot action flag the main EA reads and acts on with its  ---
//|  own CExecutionEngine instance - kept out of this class so it      ---
//|  can't accidentally close a position on its own initiative.        ---
//+------------------------------------------------------------------+
#property strict
#ifndef AX_EMERGENCYCONTROLS_MQH
#define AX_EMERGENCYCONTROLS_MQH
#include "Defs.mqh"

class CEmergencyControls
  {
private:
   ENUM_AX_EXECUTION_MODE m_executionMode;
   bool                    m_enableTrading;
   bool                    m_enableLong;
   bool                    m_enableShort;
   bool                    m_emergencyStopActive;
   string                  m_emergencyStopReason;

public:
                     CEmergencyControls(void)
     {
      m_executionMode=AX_EXEC_ANALYSIS_ONLY; // fail-safe default (spec section 37)
      m_enableTrading=true; m_enableLong=true; m_enableShort=true;
      m_emergencyStopActive=false; m_emergencyStopReason="";
     }

   //--- read once at OnInit - this EA never switches execution mode mid-session on its own          ---
   //--- initiative (spec section 37: "Do not silently switch modes"). Changing it requires an EA     ---
   //--- restart with a different input, which is itself a visible, deliberate action by whoever runs ---
   //--- the EA, not something that happens quietly while it's running. ---
   void              Configure(const ENUM_AX_EXECUTION_MODE executionMode,const bool enableTrading,
                                const bool enableLong,const bool enableShort)
     {
      m_executionMode = executionMode;
      m_enableTrading = enableTrading;
      m_enableLong    = enableLong;
      m_enableShort   = enableShort;
     }

   ENUM_AX_EXECUTION_MODE ExecutionMode(void) const { return(m_executionMode); }
   bool              IsLiveExecution(void)    const { return(m_executionMode==AX_EXEC_LIVE); }
   bool              IsPaperExecution(void)   const { return(m_executionMode==AX_EXEC_PAPER); }
   bool              IsAnalysisOnly(void)     const { return(m_executionMode==AX_EXEC_ANALYSIS_ONLY); }

   //--- separate from CRiskEngine's kill switch on purpose - that one fires from a DETECTED risk      ---
   //--- condition (poor fill quality, etc.), this one is an explicit operator action. Keeping them    ---
   //--- distinct means logs/dashboard can say WHICH kind of stop is active rather than collapsing     ---
   //--- "the system decided" and "a human decided" into one flag. ---
   void              TriggerEmergencyStop(const string reason)
     {
      m_emergencyStopActive=true;
      m_emergencyStopReason=reason;
     }

   //--- deliberately named Reset, not Deactivate - clearing an emergency stop is a decision, not a   ---
   //--- routine state transition, and the naming should read that way at every call site. ---
   void              ResetEmergencyStop(void)
     {
      m_emergencyStopActive=false;
      m_emergencyStopReason="";
     }

   bool              IsEmergencyStopActive(void)  const { return(m_emergencyStopActive); }
   string            EmergencyStopReason(void)    const { return(m_emergencyStopReason); }

   //--- master direction-level entry gate - fails closed. Existing positions are NEVER touched by    ---
   //--- this function; it only ever blocks NEW entries. Management of anything already open must     ---
   //--- continue regardless of every flag here (spec section 18/38: emergency stop and disabled      ---
   //--- trading prevent NEW orders, they do not stop managing what is already on). ---
   bool              CanEnterDirection(const ENUM_AX_DIR dir,string &reasonOut) const
     {
      if(m_emergencyStopActive)
        { reasonOut="Emergency stop active: "+m_emergencyStopReason; return(false); }
      if(!m_enableTrading)
        { reasonOut="Trading disabled (EnableTrading=false)"; return(false); }
      if(dir==AX_DIR_BUY && !m_enableLong)
        { reasonOut="Long entries disabled (EnableLong=false)"; return(false); }
      if(dir==AX_DIR_SELL && !m_enableShort)
        { reasonOut="Short entries disabled (EnableShort=false)"; return(false); }
      //--- ONLY AX_EXEC_LIVE passes this gate. AX_EXEC_PAPER is treated the same as ANALYSIS_ONLY -   ---
      //--- blocked from reaching the real broker - because this codebase does not yet implement a    ---
      //--- simulated-fill/virtual-journal path (spec section 37's "simulate orders and journal the    ---
      //--- virtual lifecycle" for PAPER_EXECUTION). Letting PAPER fall through to CExecutionEngine     ---
      //--- would silently place REAL orders under a label that sounds safe - exactly the kind of       ---
      //--- overclaiming this rewrite has tried not to do anywhere else. Build the real paper-fill      ---
      //--- simulation before ever treating AX_EXEC_PAPER as anything other than "blocked, same as      ---
      //--- ANALYSIS_ONLY". ---
      if(m_executionMode!=AX_EXEC_LIVE)
        {
         reasonOut = (m_executionMode==AX_EXEC_PAPER)
                     ? "Execution mode is PAPER_EXECUTION - no simulated-fill engine exists yet in this build, real orders are blocked for safety"
                     : "Execution mode is ANALYSIS_ONLY - signal only, no order will be sent";
         return(false);
        }
      reasonOut="";
      return(true);
     }

   bool              EnableTrading(void) const { return(m_enableTrading); }
   bool              EnableLong(void)    const { return(m_enableLong); }
   bool              EnableShort(void)   const { return(m_enableShort); }
  };
//+------------------------------------------------------------------+
#endif // AX_EMERGENCYCONTROLS_MQH
