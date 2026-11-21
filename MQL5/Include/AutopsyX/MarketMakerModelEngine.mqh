//+------------------------------------------------------------------+
//| MarketMakerModelEngine.mqh                                       |
//| Closed-bar ICT Market Maker Buy/Sell Model state machine.        |
//| Observational model; no order, position or risk-control calls.   |
//|                                                                  |
//| Operational definition used here (not claimed as a canonical ICT |
//| definition): original H4 consolidation -> directional curve ->  |
//| external liquidity raid + H4 premium/discount terminal location  |
//| -> M15 displacement/MSS confirmation -> delivery back to origin. |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_MARKETMAKERMODELENGINE_MQH
#define AX_MARKETMAKERMODELENGINE_MQH

#include "PremiumDiscountEngine.mqh"

enum ENUM_AX_MMXM_MODEL
  {
   AX_MMXM_NONE=0,
   AX_MMXM_BUY_MODEL,
   AX_MMXM_SELL_MODEL
  };

enum ENUM_AX_MMXM_STAGE
  {
   AX_MMXM_UNAVAILABLE=0,
   AX_MMXM_ORIGIN_IDENTIFIED,
   AX_MMXM_BUY_SIDE_CURVE,
   AX_MMXM_SELL_SIDE_CURVE,
   AX_MMXM_TERMINAL_ZONE_REACHED,
   AX_MMXM_REVERSAL_CONFIRMED,
   AX_MMXM_RETURN_TO_ORIGIN,
   AX_MMXM_INVALIDATED
  };

struct SAxMarketMakerModelSnapshot
  {
   bool available;
   ENUM_AX_MMXM_MODEL model;
   ENUM_AX_MMXM_STAGE stage;
   ENUM_AX_DIR direction;             // Final delivery direction, only set after confirmation.
   bool originRetestObserved;         // Informational; a retest is not required by this model.
   bool externalLiquiditySwept;
   bool terminalZoneReached;
   bool reversalConfirmed;
   bool returnedToOrigin;
   double originHigh;
   double originLow;
   double originMidpoint;
   double priorExternalLiquidity;
   double curveExtreme;
   double terminalPositionPercent;    // Position of curve extreme in the supplied H4 dealing range.
   double targetNear;                  // First edge of the original consolidation on return.
   double targetFar;                   // Opposite edge of the original consolidation.
   datetime originEndTime;
   datetime curveExtremeTime;
   datetime reversalTime;
   int curveBars;
   string reason;
  };

class CMarketMakerModelEngine
  {
private:
   string m_symbol;
   ENUM_TIMEFRAMES m_curveTimeframe;
   ENUM_TIMEFRAMES m_confirmationTimeframe;
   int m_maxOriginAgeBars;
   int m_minConsolidationBars;
   int m_maxConsolidationBars;
   double m_maxConsolidationAtr;
   double m_breakoutBufferAtr;
   int m_reversalLookbackBars;
   double m_minDisplacementAtr;
   double m_minBodyRatio;
   double m_terminalZonePercent;
   datetime m_lastCurveBar;
   datetime m_lastConfirmationBar;
   bool m_initialized;
   SAxMarketMakerModelSnapshot m_state;

   void Reset(const string reason)
     {
      ZeroMemory(m_state);
      m_state.available=false;
      m_state.model=AX_MMXM_NONE;
      m_state.stage=AX_MMXM_UNAVAILABLE;
      m_state.direction=AX_DIR_NONE;
      m_state.reason=reason;
     }

   double AverageTrueRange(const MqlRates &rates[],const int count,
                           const int firstIndex,const int period) const
     {
      if(firstIndex<0 || firstIndex+period>=count) return(0.0);
      double sum=0.0;
      for(int i=firstIndex;i<firstIndex+period;i++)
        {
         double tr=rates[i].high-rates[i].low;
         tr=MathMax(tr,MathAbs(rates[i].high-rates[i+1].close));
         tr=MathMax(tr,MathAbs(rates[i].low-rates[i+1].close));
         if(tr<=0.0 || !MathIsValidNumber(tr)) return(0.0);
         sum+=tr;
        }
      return(sum/(double)period);
     }

   bool FindOrigin(const MqlRates &rates[],const int count,const double atr,
                   const double point,SAxMarketMakerModelSnapshot &out) const
     {
      if(count<m_maxConsolidationBars+20 || atr<=0.0 || point<=0.0)
         return(false);

      double bestScore=DBL_MAX;
      bool found=false;
      int maxEnd=(int)MathMin((double)m_maxOriginAgeBars,
                              (double)(count-m_maxConsolidationBars-22));
      double breakoutBuffer=MathMax(point*2.0,atr*m_breakoutBufferAtr);

      // Series arrays: index 0 is the latest CLOSED H4 bar. A candidate
      // origin occupies [end .. end+length-1]; lower indexes are later bars.
      for(int end=1;end<=maxEnd;end++)
        {
         for(int length=m_minConsolidationBars;
             length<=m_maxConsolidationBars;length++)
           {
            if(end+length+20>=count) continue;
            double rangeHigh=-DBL_MAX;
            double rangeLow=DBL_MAX;
            for(int j=end;j<end+length;j++)
              {
               rangeHigh=MathMax(rangeHigh,rates[j].high);
               rangeLow=MathMin(rangeLow,rates[j].low);
              }
            double width=rangeHigh-rangeLow;
            if(width<=point*2.0 || width>atr*m_maxConsolidationAtr)
               continue;

            ENUM_AX_DIR firstBreak=AX_DIR_NONE;
            int breakoutIndex=-1;
            for(int k=end-1;k>=0;k--)
              {
               if(rates[k].close>rangeHigh+breakoutBuffer)
                 { firstBreak=AX_DIR_BUY; breakoutIndex=k; break; }
               if(rates[k].close<rangeLow-breakoutBuffer)
                 { firstBreak=AX_DIR_SELL; breakoutIndex=k; break; }
              }
            if(firstBreak==AX_DIR_NONE) continue;

            double extreme=(firstBreak==AX_DIR_BUY ? -DBL_MAX : DBL_MAX);
            datetime extremeTime=0;
            for(int k=0;k<end;k++)
              {
               if(firstBreak==AX_DIR_BUY && rates[k].high>extreme)
                 { extreme=rates[k].high; extremeTime=rates[k].time; }
               if(firstBreak==AX_DIR_SELL && rates[k].low<extreme)
                 { extreme=rates[k].low; extremeTime=rates[k].time; }
              }
            if(extremeTime<=0) continue;

            // Liquidity reference is the most extreme opposing-side level
            // in the completed H4 history immediately preceding the origin.
            double external=(firstBreak==AX_DIR_BUY ? -DBL_MAX : DBL_MAX);
            int externalEnd=(int)MathMin((double)count,(double)(end+length+25));
            for(int k=end+length;k<externalEnd;k++)
              {
               if(firstBreak==AX_DIR_BUY) external=MathMax(external,rates[k].high);
               else external=MathMin(external,rates[k].low);
              }
            if(external==-DBL_MAX || external==DBL_MAX)
               external=(firstBreak==AX_DIR_BUY ? rangeHigh : rangeLow);

            double extension=(firstBreak==AX_DIR_BUY ?
                              extreme-rangeHigh : rangeLow-extreme);
            if(extension<atr*0.35) continue;

            // Prefer a compact, multi-bar origin followed by meaningful
            // expansion. Penalize stale origins so old unrelated ranges
            // cannot dominate a newer, cleaner model.
            double compactness=width/atr;
            double extensionCredit=MathMin(4.0,extension/atr)*0.08;
            double score=compactness-(double)length*0.012+
                         (double)end*0.012-extensionCredit;
            if(score>=bestScore) continue;

            bestScore=score;
            found=true;
            ZeroMemory(out);
            out.available=true;
            out.model=(firstBreak==AX_DIR_SELL ? AX_MMXM_BUY_MODEL :
                                                    AX_MMXM_SELL_MODEL);
            out.stage=(firstBreak==AX_DIR_BUY ? AX_MMXM_BUY_SIDE_CURVE :
                                                 AX_MMXM_SELL_SIDE_CURVE);
            out.direction=AX_DIR_NONE;
            out.originHigh=rangeHigh;
            out.originLow=rangeLow;
            out.originMidpoint=(rangeHigh+rangeLow)*0.5;
            out.priorExternalLiquidity=external;
            out.curveExtreme=extreme;
            out.curveExtremeTime=extremeTime;
            out.originEndTime=rates[end].time;
            out.curveBars=end;
            out.targetNear=(firstBreak==AX_DIR_BUY ? rangeHigh : rangeLow);
            out.targetFar=(firstBreak==AX_DIR_BUY ? rangeLow : rangeHigh);
            out.reason=(firstBreak==AX_DIR_BUY ?
                        "ORIGIN_FOUND_BUY_SIDE_CURVE_FORMING" :
                        "ORIGIN_FOUND_SELL_SIDE_CURVE_FORMING");

            // Only count a retest that occurs AFTER the first closed-bar
            // breakout. The breakout candle itself is not a pullback.
            for(int k=0;k<breakoutIndex;k++)
               if(rates[k].low<=rangeHigh && rates[k].high>=rangeLow)
                 { out.originRetestObserved=true; break; }
           }
        }
      return(found);
     }

   bool FindReversal(const MqlRates &rates[],const int count,
                     const datetime afterTime,const bool bearish,
                     datetime &signalTime) const
     {
      signalTime=0;
      if(count<m_reversalLookbackBars+18 || afterTime<=0) return(false);

      // Search only completed M15 bars strictly after the H4 terminal
      // extreme. Older bars provide the structure reference, so there is
      // no forward-looking swing confirmation.
      for(int i=0;i+m_reversalLookbackBars+15<count;i++)
        {
         if(rates[i].time<=afterTime) continue;
         double priorHigh=-DBL_MAX;
         double priorLow=DBL_MAX;
         for(int j=i+1;j<=i+m_reversalLookbackBars;j++)
           {
            priorHigh=MathMax(priorHigh,rates[j].high);
            priorLow=MathMin(priorLow,rates[j].low);
           }
         double candleRange=rates[i].high-rates[i].low;
         if(candleRange<=0.0) continue;
         double bodyRatio=MathAbs(rates[i].close-rates[i].open)/candleRange;
         double atr=AverageTrueRange(rates,count,i+1,14);
         if(atr<=0.0 || bodyRatio<m_minBodyRatio ||
            candleRange<atr*m_minDisplacementAtr)
            continue;

         if(bearish)
           {
            double closeLocation=(rates[i].close-rates[i].low)/candleRange;
            if(rates[i].close<rates[i].open &&
               rates[i].close<priorLow && closeLocation<=0.25)
              { signalTime=rates[i].time; return(true); }
           }
         else
           {
            double closeLocation=(rates[i].close-rates[i].low)/candleRange;
            if(rates[i].close>rates[i].open &&
               rates[i].close>priorHigh && closeLocation>=0.75)
              { signalTime=rates[i].time; return(true); }
           }
        }
      return(false);
     }

   bool IsInvalidated(const MqlRates &rates[],const int count,
                      const datetime reversalTime,const double terminalExtreme,
                      const bool bullish,const double point) const
     {
      if(reversalTime<=0 || point<=0.0) return(true);
      for(int i=0;i<count;i++)
        {
         if(rates[i].time<=reversalTime) continue;
         // A completed H4 close through the terminal extreme invalidates
         // the reversal thesis. A wick alone does not.
         if(bullish && rates[i].close<terminalExtreme-point*2.0) return(true);
         if(!bullish && rates[i].close>terminalExtreme+point*2.0) return(true);
        }
      return(false);
     }

public:
                     CMarketMakerModelEngine(void)
     {
      m_symbol="";
      m_curveTimeframe=PERIOD_H4;
      m_confirmationTimeframe=PERIOD_M15;
      m_maxOriginAgeBars=36;
      m_minConsolidationBars=3;
      m_maxConsolidationBars=8;
      m_maxConsolidationAtr=1.75;
      m_breakoutBufferAtr=0.10;
      m_reversalLookbackBars=5;
      m_minDisplacementAtr=0.75;
      m_minBodyRatio=0.55;
      m_terminalZonePercent=61.8;
      m_lastCurveBar=0;
      m_lastConfirmationBar=0;
      m_initialized=false;
      Reset("NOT_INITIALIZED");
     }

   bool Init(const string symbol,const ENUM_TIMEFRAMES curveTimeframe=PERIOD_H4,
             const ENUM_TIMEFRAMES confirmationTimeframe=PERIOD_M15,
             const int maxOriginAgeBars=36,const int minConsolidationBars=3,
             const int maxConsolidationBars=8,const double maxConsolidationAtr=1.75,
             const double breakoutBufferAtr=0.10,const int reversalLookbackBars=5,
             const double minDisplacementAtr=0.75,const double minBodyRatio=0.55,
             const double terminalZonePercent=61.8)
     {
      if(StringLen(symbol)==0 || curveTimeframe<=PERIOD_CURRENT ||
         confirmationTimeframe<=PERIOD_CURRENT || maxOriginAgeBars<5 ||
         minConsolidationBars<3 || maxConsolidationBars<minConsolidationBars ||
         maxConsolidationBars>20 || maxConsolidationAtr<=0.0 ||
         maxConsolidationAtr>5.0 || breakoutBufferAtr<0.0 ||
         breakoutBufferAtr>1.0 || reversalLookbackBars<2 ||
         reversalLookbackBars>20 || minDisplacementAtr<0.0 ||
         minDisplacementAtr>3.0 || minBodyRatio<0.0 || minBodyRatio>1.0 ||
         terminalZonePercent<50.0 || terminalZonePercent>90.0)
        {
         Reset("INVALID_CONFIGURATION");
         return(false);
        }
      m_symbol=symbol;
      m_curveTimeframe=curveTimeframe;
      m_confirmationTimeframe=confirmationTimeframe;
      m_maxOriginAgeBars=maxOriginAgeBars;
      m_minConsolidationBars=minConsolidationBars;
      m_maxConsolidationBars=maxConsolidationBars;
      m_maxConsolidationAtr=maxConsolidationAtr;
      m_breakoutBufferAtr=breakoutBufferAtr;
      m_reversalLookbackBars=reversalLookbackBars;
      m_minDisplacementAtr=minDisplacementAtr;
      m_minBodyRatio=minBodyRatio;
      m_terminalZonePercent=terminalZonePercent;
      m_initialized=true;
      return(true);
     }

   bool Update(const SAxPremiumDiscountSnapshot &h4Range,const bool force=false)
     {
      if(!m_initialized) { Reset("NOT_INITIALIZED"); return(false); }
      datetime curveBar=iTime(m_symbol,m_curveTimeframe,1);
      datetime confirmBar=iTime(m_symbol,m_confirmationTimeframe,1);
      if(curveBar<=0 || confirmBar<=0)
        { Reset("CLOSED_BAR_TIME_UNAVAILABLE"); return(false); }
      if(!force && curveBar==m_lastCurveBar &&
         confirmBar==m_lastConfirmationBar) return(false);
      m_lastCurveBar=curveBar;
      m_lastConfirmationBar=confirmBar;

      MqlTick tick;
      if(!SymbolInfoTick(m_symbol,tick) || tick.bid<=0.0 ||
         tick.ask<tick.bid || tick.ask<=0.0)
        { Reset("VALID_QUOTE_UNAVAILABLE"); return(false); }
      double price=(tick.bid+tick.ask)*0.5;
      double point=SymbolInfoDouble(m_symbol,SYMBOL_POINT);
      if(point<=0.0) { Reset("SYMBOL_POINT_UNAVAILABLE"); return(false); }

      MqlRates curveRates[];
      ArraySetAsSeries(curveRates,true);
      int curveCount=CopyRates(m_symbol,m_curveTimeframe,1,160,curveRates);
      if(curveCount<m_maxConsolidationBars+30)
        { Reset("H4_HISTORY_UNAVAILABLE"); return(false); }
      double curveAtr=AverageTrueRange(curveRates,curveCount,1,14);
      if(curveAtr<=0.0) { Reset("H4_ATR_UNAVAILABLE"); return(false); }

      SAxMarketMakerModelSnapshot s;
      ZeroMemory(s);
      if(!FindOrigin(curveRates,curveCount,curveAtr,point,s))
        { Reset("NO_QUALIFIED_ORIGIN_CONSOLIDATION_AND_EXPANSION"); return(false); }

      bool firstCurveUp=(s.stage==AX_MMXM_BUY_SIDE_CURVE);
      bool bearishModel=firstCurveUp;
      bool swept=(firstCurveUp ?
                  s.curveExtreme>s.priorExternalLiquidity+point*2.0 :
                  s.curveExtreme<s.priorExternalLiquidity-point*2.0);
      s.externalLiquiditySwept=swept;

      double h4Width=h4Range.rangeHigh-h4Range.rangeLow;
      if(h4Range.available && h4Width>point*2.0)
        {
         s.terminalPositionPercent=
            (s.curveExtreme-h4Range.rangeLow)/h4Width*100.0;
         s.terminalZoneReached=(firstCurveUp ?
            s.terminalPositionPercent>=m_terminalZonePercent :
            s.terminalPositionPercent<=(100.0-m_terminalZonePercent));
        }
      else
        {
         s.terminalPositionPercent=-1.0;
         s.terminalZoneReached=false;
        }

      bool terminalReady=(swept && s.terminalZoneReached);
      if(terminalReady)
         s.stage=AX_MMXM_TERMINAL_ZONE_REACHED;

      MqlRates confirmRates[];
      ArraySetAsSeries(confirmRates,true);
      int confirmCount=CopyRates(m_symbol,m_confirmationTimeframe,1,240,confirmRates);
      if(confirmCount<m_reversalLookbackBars+18)
        {
         s.reason="ORIGIN_AND_CURVE_FOUND_BUT_CONFIRMATION_HISTORY_UNAVAILABLE";
         m_state=s;
         return(true);
        }

      datetime reversalTime=0;
      bool reversal=(terminalReady &&
         FindReversal(confirmRates,confirmCount,s.curveExtremeTime,
                      bearishModel,reversalTime));
      if(reversal)
        {
         bool bullishFinal=!bearishModel;
         if(IsInvalidated(curveRates,curveCount,reversalTime,
                          s.curveExtreme,bullishFinal,point))
           {
            s.stage=AX_MMXM_INVALIDATED;
            s.direction=AX_DIR_NONE;
            s.reason="H4_CLOSE_INVALIDATED_TERMINAL_REVERSAL_EXTREME";
           }
         else
           {
            s.reversalConfirmed=true;
            s.reversalTime=reversalTime;
            s.direction=(bullishFinal ? AX_DIR_BUY : AX_DIR_SELL);
            bool returned=(bullishFinal ? price>=s.originLow :
                                          price<=s.originHigh);
            s.returnedToOrigin=returned;
            s.stage=(returned ? AX_MMXM_RETURN_TO_ORIGIN :
                                AX_MMXM_REVERSAL_CONFIRMED);
            s.reason=(bullishFinal ?
               (returned ? "MMBM_CONFIRMED_RETURNED_TO_ORIGIN" :
                           "MMBM_CONFIRMED_BULLISH_DELIVERY_TO_ORIGIN") :
               (returned ? "MMSM_CONFIRMED_RETURNED_TO_ORIGIN" :
                           "MMSM_CONFIRMED_BEARISH_DELIVERY_TO_ORIGIN"));
           }
        }
      else if(terminalReady)
         s.reason=(bearishModel ?
                   "MMSM_PREMIUM_AND_BUY_SIDE_LIQUIDITY_SWEPT_WAITING_FOR_BEARISH_MSS" :
                   "MMBM_DISCOUNT_AND_SELL_SIDE_LIQUIDITY_SWEPT_WAITING_FOR_BULLISH_MSS");
      else
         s.reason=(firstCurveUp ?
                   "MMSM_BUY_SIDE_CURVE_FORMING_TERMINAL_NOT_CONFIRMED" :
                   "MMBM_SELL_SIDE_CURVE_FORMING_TERMINAL_NOT_CONFIRMED");

      m_state=s;
      return(true);
     }

   SAxMarketMakerModelSnapshot Read(void) const { return(m_state); }

   double DirectionalScoreComponent(void) const
     {
      if(!m_state.available || !m_state.reversalConfirmed ||
         m_state.stage!=AX_MMXM_REVERSAL_CONFIRMED ||
         m_state.direction==AX_DIR_NONE) return(0.0);
      return(100.0);
     }

   string Summary(void) const
     {
      if(!m_state.available) return("MMXM "+m_state.reason);
      string model=(m_state.model==AX_MMXM_BUY_MODEL ? "MMBM" :
                    (m_state.model==AX_MMXM_SELL_MODEL ? "MMSM" : "NONE"));
      string stage=EnumToString(m_state.stage);
      string direction=(m_state.direction==AX_DIR_BUY ? "BUY" :
                        (m_state.direction==AX_DIR_SELL ? "SELL" : "WAIT"));
      return(StringFormat("MMXM %s %s dir=%s origin=[%.5f..%.5f] external=%.5f swept=%s curveExtreme=%.5f H4Position=%.1f%% terminal=%s retest=%s reversal=%s target=[%.5f..%.5f] reason=%s",
         model,stage,direction,
         m_state.originLow,m_state.originHigh,m_state.priorExternalLiquidity,
         m_state.externalLiquiditySwept?"YES":"NO",m_state.curveExtreme,
         m_state.terminalPositionPercent,m_state.terminalZoneReached?"YES":"NO",
         m_state.originRetestObserved?"YES":"NO",
         m_state.reversalConfirmed?"YES":"NO",
         MathMin(m_state.targetNear,m_state.targetFar),
         MathMax(m_state.targetNear,m_state.targetFar),m_state.reason);
     }
  };

#endif // AX_MARKETMAKERMODELENGINE_MQH
