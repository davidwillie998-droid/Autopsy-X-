//+------------------------------------------------------------------+
//|                                                   EntryEngine.mqh|
//|  Entry Engine pre-trade validation checklist (spec section 8)    |
//|  Any deterioration between decision and execution cancels entry.  |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_ENTRYENGINE_MQH
#define AX_ENTRYENGINE_MQH
#include "Defs.mqh"
#include "MarketData.mqh"
#include "RiskEngine.mqh"
#include "AntiChop.mqh"

class CEntryEngine
  {
private:
   double            m_minConfidence;

public:
                     CEntryEngine(void) { m_minConfidence=65.0; }

   void              Configure(const double minConfidence) { m_minConfidence=minConfidence; }

   //--- terminal / account / symbol permission checks ---
   bool              TradingPermitted(const string symbol,string &reason) const
     {
      if(!TerminalInfoInteger(TERMINAL_CONNECTED)) { reason="Terminal not connected"; return(false); }
      if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) { reason="Algo trading disabled in terminal"; return(false); }
      if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) { reason="EA trade permission disabled"; return(false); }
      if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)) { reason="Account trading disabled"; return(false); }
      if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT)) { reason="Expert trading disabled on account"; return(false); }

      long tradeMode = SymbolInfoInteger(symbol,SYMBOL_TRADE_MODE);
      if(tradeMode==SYMBOL_TRADE_MODE_DISABLED) { reason="Symbol trading disabled"; return(false); }
      if(tradeMode==SYMBOL_TRADE_MODE_CLOSEONLY) { reason="Symbol is close-only"; return(false); }

      double bid = SymbolInfoDouble(symbol,SYMBOL_BID);
      double ask = SymbolInfoDouble(symbol,SYMBOL_ASK);
      if(bid<=0 || ask<=0) { reason="No valid quote"; return(false); }

      datetime lastQuote = (datetime)SymbolInfoInteger(symbol,SYMBOL_TIME);
      if((TimeCurrent()-lastQuote) > 60) { reason="Quotes are stale - market may be closed"; return(false); }

      reason="";
      return(true);
     }

   //--- stop distance vs broker stops/freeze level (section 8 + 14) ---
   bool              StopDistanceValid(const CMarketData &md,const double stopDistancePts,string &reason) const
     {
      int stopsLevel  = md.StopsLevelPts();
      int freezeLevel = md.FreezeLevelPts();
      double required = MathMax(stopsLevel,freezeLevel) + 2; // small safety buffer
      if(stopDistancePts < required)
        {
         reason = StringFormat("Stop distance %.1fpts below broker minimum %.1fpts",stopDistancePts,required);
         return(false);
        }
      reason="";
      return(true);
     }

   //--- broker-time trading-hours window + rollover-spread-spike avoidance (section 8) ---
   //--- pass startHour==endHour to mean "no session restriction, only rollover avoidance" ---
   bool              SessionAllowed(const int startHour,const int endHour,
                                     const int avoidRolloverMinutes,string &reason) const
     {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(),dt);

      if(startHour!=endHour)
        {
         bool inSession;
         if(startHour<endHour) inSession = (dt.hour>=startHour && dt.hour<endHour);
         else                  inSession = (dt.hour>=startHour || dt.hour<endHour); // wraps midnight
         if(!inSession)
           {
            reason = StringFormat("Outside configured trading session (%02d:00-%02d:00 broker time)",startHour,endHour);
            return(false);
           }
        }

      if(avoidRolloverMinutes>0)
        {
         int minutesFromMidnight = dt.hour*60+dt.min;
         int minutesToMidnight   = 1440-minutesFromMidnight;
         if(minutesFromMidnight<avoidRolloverMinutes || minutesToMidnight<avoidRolloverMinutes)
           {
            reason = "Within broker daily rollover window - spreads are typically abnormal here";
            return(false);
           }
        }

      reason="";
      return(true);
     }

   //--- signal quality gate, dampened by anti-chop aggression multiplier ---
   bool              SignalQualityOk(const SAxScore &score,const CAntiChopEngine &antiChop,string &reason) const
     {
      if(score.action==AX_DIR_NONE) { reason="No decisive signal"; return(false); }
      double mult = antiChop.AggressionMultiplier();
      if(mult<=0.0) { reason="Anti-chop cooldown active"; return(false); }
      double effectiveMin = m_minConfidence / MathMax(mult,0.01);
      effectiveMin = MathMin(effectiveMin,95.0);
      if(score.confidence < effectiveMin)
        {
         reason = StringFormat("Confidence %.1f below required %.1f (chop-adjusted)",score.confidence,effectiveMin);
         return(false);
        }
      reason="";
      return(true);
     }

   //--- full pre-flight prior to committing to an entry decision ---
   bool              PreFlightCheck(const string symbol,const CMarketData &md,const SAxScore &score,
                                     CRiskEngine &riskEngine,const CAntiChopEngine &antiChop,
                                     const double stopDistancePts,const int openPositions,
                                     const double exposureLots,const int sessionStartHour,
                                     const int sessionEndHour,const int avoidRolloverMinutes,
                                     string &reason)
     {
      if(!TradingPermitted(symbol,reason)) return(false);
      if(!SessionAllowed(sessionStartHour,sessionEndHour,avoidRolloverMinutes,reason)) return(false);
      if(!SignalQualityOk(score,antiChop,reason)) return(false);
      if(!StopDistanceValid(md,stopDistancePts,reason)) return(false);
      double spreadPts = md.CurrentSpreadPts();
      if(!riskEngine.PreTradeAllowed(openPositions,exposureLots,spreadPts,reason)) return(false);
      reason="";
      return(true);
     }

   //--- final re-check performed immediately before order transmission - "never chase a missed move" ---
   bool              FinalConfirm(const CMarketData &md,const SAxScore &originalScore,
                                   const SAxScore &freshScore,const double maxSpreadPts,string &reason) const
     {
      if(freshScore.action==AX_DIR_NONE || freshScore.action!=originalScore.action)
        {
         reason="Signal changed before execution";
         return(false);
        }
      if(md.CurrentSpreadPts()>maxSpreadPts)
        {
         reason="Spread deteriorated before execution";
         return(false);
        }
      if(freshScore.confidence < originalScore.confidence*0.85)
        {
         reason="Confidence deteriorated before execution";
         return(false);
        }
      reason="";
      return(true);
     }
  };
//+------------------------------------------------------------------+
#endif // AX_ENTRYENGINE_MQH
