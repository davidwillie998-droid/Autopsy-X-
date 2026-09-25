//+------------------------------------------------------------------+
//|                                          ExecutionEligibility.mqh|
//|  Execution Eligibility Gate (FLIPDEMON EXTREME upgrade, spec     |
//|  section 13) - the single funnel every proposed trade must pass  |
//|  through between "a thesis exists" and "an order gets built".    |
//|                                                                    |
//|  Deliberately thin: every hard risk/session/spread/margin check   |
//|  this function runs already lives in CRiskEngine or               |
//|  CEntryEngine - this class does NOT reimplement them (that would  |
//|  be the same double-maintenance risk the Phase 2 code-review      |
//|  caught with the composite-direction vote). It calls the real     |
//|  engines and adds only what's genuinely new: composite-direction  |
//|  interpretation and thesis-quality checks (R:R, EV, SL/TP sanity) |
//|  that no existing engine currently owns.                          |
//|                                                                    |
//|  FAIL CLOSED: any branch this function cannot positively confirm  |
//|  returns a non-eligible state. There is no default-to-eligible    |
//|  path anywhere below.                                             |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_EXECUTIONELIGIBILITY_MQH
#define AX_EXECUTIONELIGIBILITY_MQH
#include "Defs.mqh"
#include "RiskEngine.mqh"

class CExecutionEligibility
  {
private:
   double            m_minRR;
   double            m_minExpectedValueR;
   double            m_minFreeMarginBufferPercent; // required free margin AFTER the trade, as a
                                                     // percent of what the trade itself would use

public:
                     CExecutionEligibility(void)
     {
      m_minRR=1.2; m_minExpectedValueR=0.0; m_minFreeMarginBufferPercent=50.0;
     }

   void              Configure(const double minRR,const double minExpectedValueR,
                                const double minFreeMarginBufferPercent)
     {
      m_minRR                      = MathMax(0.0,minRR);
      m_minExpectedValueR          = minExpectedValueR;
      m_minFreeMarginBufferPercent = MathMax(0.0,minFreeMarginBufferPercent);
     }

   //--- thesis and composite direction must already be built by the caller (CompositeDirection.mqh, ---
   //--- the thesis-construction step) - this function only judges what's handed to it, it does not  ---
   //--- compute any of those inputs itself. ---
   ENUM_AX_ELIGIBILITY Check(const SAxTradeThesis &thesis,
                              const ENUM_AX_COMPOSITE_DIRECTION compositeDirection,
                              CRiskEngine &risk,
                              const int openPositions,const double currentExposureLots,
                              const double spreadPts,const double marginRequiredForOrder,
                              string &reasonOut) const
     {
      //--- 1. composite direction's own verdict is authoritative for BLOCKED/DATA_UNAVAILABLE/ ---
      //--- INSUFFICIENT_EVIDENCE - this gate does not second-guess those, only NEUTRAL/BULLISH/BEARISH ---
      if(compositeDirection==AX_COMPOSITE_BLOCKED)
        { reasonOut="Composite direction: hard defensive block active"; return(AX_ELIGIBILITY_BLOCKED); }
      if(compositeDirection==AX_COMPOSITE_DATA_UNAVAILABLE)
        { reasonOut="Composite direction: required data unavailable"; return(AX_ELIGIBILITY_DATA_UNAVAILABLE); }
      if(compositeDirection==AX_COMPOSITE_INSUFFICIENT_EVIDENCE)
        { reasonOut="Composite direction: insufficient evidence to act"; return(AX_ELIGIBILITY_INSUFFICIENT_EVIDENCE); }
      if(compositeDirection==AX_COMPOSITE_NEUTRAL)
        { reasonOut="Composite direction: neutral, no edge"; return(AX_NOT_ELIGIBLE); }

      //--- the thesis and the composite direction are two independently-passed parameters - a       ---
      //--- caller-side bug (stale thesis, wrong engine wired up, executionBias/htfBias mixed up)     ---
      //--- could hand this function a SELL thesis alongside a BULLISH composite read. Without this   ---
      //--- check the function would still return AX_ELIGIBLE_LONG at the bottom - directionally      ---
      //--- wrong despite every other gate passing. Fail closed rather than trust the two agree. ---
      ENUM_AX_DIR impliedDir = (compositeDirection==AX_COMPOSITE_BULLISH) ? AX_DIR_BUY : AX_DIR_SELL;
      if(thesis.direction!=impliedDir)
        {
         reasonOut=StringFormat("Thesis direction (%s) does not match composite direction (%s)",
                                 AxDirToString(thesis.direction),AxCompositeDirectionToString(compositeDirection));
         return(AX_NOT_ELIGIBLE);
        }

      //--- 2. hard risk/session/exposure gates - real engine, not reimplemented here ---
      string riskReason;
      if(!risk.PreTradeAllowed(openPositions,currentExposureLots,spreadPts,riskReason))
        { reasonOut=riskReason; return(AX_ELIGIBILITY_BLOCKED); }

      //--- 3. margin: real broker figures, checked fresh, never assumed ---
      double marginFree = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(marginRequiredForOrder<=0)
        { reasonOut="Margin requirement could not be computed"; return(AX_ELIGIBILITY_DATA_UNAVAILABLE); }
      double marginBufferPct = ((marginFree-marginRequiredForOrder)/marginRequiredForOrder)*100.0;
      if(marginFree<marginRequiredForOrder || marginBufferPct<m_minFreeMarginBufferPercent)
        {
         reasonOut=StringFormat("Insufficient margin buffer: free=%.2f required=%.2f (buffer %.1f%% < min %.1f%%)",
                                 marginFree,marginRequiredForOrder,marginBufferPct,m_minFreeMarginBufferPercent);
         return(AX_ELIGIBILITY_BLOCKED);
        }

      //--- 4. thesis-quality checks: SL/TP validity, structural sanity ---
      if(thesis.direction==AX_DIR_BUY)
        {
         if(thesis.stopLoss<=0 || thesis.stopLoss>=thesis.expectedEntry)
           { reasonOut="Invalid stop loss for BUY (must be below entry)"; return(AX_NOT_ELIGIBLE); }
         if(thesis.takeProfit>0 && thesis.takeProfit<=thesis.expectedEntry)
           { reasonOut="Invalid take profit for BUY (must be above entry)"; return(AX_NOT_ELIGIBLE); }
        }
      else if(thesis.direction==AX_DIR_SELL)
        {
         if(thesis.stopLoss<=thesis.expectedEntry)
           { reasonOut="Invalid stop loss for SELL (must be above entry)"; return(AX_NOT_ELIGIBLE); }
         if(thesis.takeProfit>0 && thesis.takeProfit>=thesis.expectedEntry)
           { reasonOut="Invalid take profit for SELL (must be below entry)"; return(AX_NOT_ELIGIBLE); }
        }
      else
        { reasonOut="Thesis has no direction"; return(AX_NOT_ELIGIBLE); }

      //--- 5. R:R and EV thresholds - the two numeric bars a thesis must clear regardless of how ---
      //--- strong the directional read was ---
      if(thesis.initialRR<m_minRR)
        {
         reasonOut=StringFormat("R:R %.2f below minimum %.2f",thesis.initialRR,m_minRR);
         return(AX_NOT_ELIGIBLE);
        }
      if(thesis.expectedValueR<m_minExpectedValueR)
        {
         reasonOut=StringFormat("Expected value %.3fR below minimum %.3fR",
                                 thesis.expectedValueR,m_minExpectedValueR);
         return(AX_NOT_ELIGIBLE);
        }

      //--- 6. news defense: BLOCK is already funneled through compositeDirection==BLOCKED above -  ---
      //--- this only catches the case where the composite engine wasn't configured to require news ---
      //--- data but this gate's caller wants to be stricter for live execution specifically ---
      if(thesis.newsState=="BLOCK")
        { reasonOut="News Defense: high-impact event window"; return(AX_ELIGIBILITY_BLOCKED); }

      //--- everything cleared - direction comes from the composite read, already validated above ---
      reasonOut=StringFormat("Eligible: R:R=%.2f EV=%.3fR composite=%s",
                              thesis.initialRR,thesis.expectedValueR,
                              AxCompositeDirectionToString(compositeDirection));
      return((compositeDirection==AX_COMPOSITE_BULLISH) ? AX_ELIGIBLE_LONG : AX_ELIGIBLE_SHORT);
     }
  };
//+------------------------------------------------------------------+
#endif // AX_EXECUTIONELIGIBILITY_MQH
