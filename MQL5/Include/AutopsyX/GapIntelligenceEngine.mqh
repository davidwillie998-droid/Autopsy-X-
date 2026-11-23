//+------------------------------------------------------------------+
//|                                      GapIntelligenceEngine.mqh   |
//| Broker-neutral Gap Hour condition detector for AUTOPSY X        |
//| Detects verified zero-spread + unlimited-leverage overlap.       |
//| This module observes conditions only. It does not submit orders. |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_GAPINTELLIGENCEENGINE_MQH
#define AX_GAPINTELLIGENCEENGINE_MQH

enum ENUM_AX_GAP_WINDOW
  {
   AX_GAP_WINDOW_UNKNOWN = 0,
   AX_GAP_WINDOW_REGULAR_SESSION,
   AX_GAP_WINDOW_MARKET_REOPEN
  };

enum ENUM_AX_GAP_STATE
  {
   AX_GAP_STATE_UNVERIFIED = 0,
   AX_GAP_STATE_INACTIVE,
   AX_GAP_STATE_ZERO_SPREAD_ONLY,
   AX_GAP_STATE_UNLIMITED_LEVERAGE_ONLY,
   AX_GAP_STATE_READY
  };

struct SAxGapObservation
  {
   datetime serverTime;
   long     quoteTimeMsc;
   double   bid;
   double   ask;
   double   point;
   long     accountLeverage;
   double   requiredMargin;
   double   freeMargin;
   bool     quoteAvailable;
   bool     symbolTradingAllowed;
   bool     accountTradingAllowed;
   bool     expertTradingAllowed;
   bool     unlimitedLeverageVerified;
   bool     brokerWindowVerified;
   ENUM_AX_GAP_WINDOW window;
  };

struct SAxGapSnapshot
  {
   ENUM_AX_GAP_STATE state;
   ENUM_AX_GAP_WINDOW window;
   datetime serverTime;
   double   spreadPoints;
   long     accountLeverage;
   double   requiredMargin;
   double   freeMargin;
   bool     zeroSpread;
   bool     unlimitedLeverage;
   bool     quoteFresh;
   bool     executionAllowed;
   string   reason;
  };

class CGapIntelligenceEngine
  {
private:
   long   m_maxQuoteAgeMs;
   ulong  m_lastEvaluationMsc;
   ENUM_AX_GAP_STATE m_lastState;

   void ResetSnapshot(SAxGapSnapshot &out) const
     {
      out.state=AX_GAP_STATE_UNVERIFIED;
      out.window=AX_GAP_WINDOW_UNKNOWN;
      out.serverTime=0;
      out.spreadPoints=0.0;
      out.accountLeverage=0;
      out.requiredMargin=0.0;
      out.freeMargin=0.0;
      out.zeroSpread=false;
      out.unlimitedLeverage=false;
      out.quoteFresh=false;
      out.executionAllowed=false;
      out.reason="OBSERVATION_NOT_EVALUATED";
     }

public:
   CGapIntelligenceEngine(void)
     {
      m_maxQuoteAgeMs=2000;
      m_lastEvaluationMsc=0;
      m_lastState=AX_GAP_STATE_UNVERIFIED;
     }

   void Configure(const long maxQuoteAgeMs=2000)
     {
      m_maxQuoteAgeMs=(maxQuoteAgeMs>0 ? maxQuoteAgeMs : 2000);
     }

   // The caller supplies broker-window and unlimited-leverage verification.
   // MT5's numeric ACCOUNT_LEVERAGE value alone is not proof of unlimited leverage.
   bool Evaluate(const SAxGapObservation &observation,
                 const ulong nowMsc,
                 SAxGapSnapshot &out)
     {
      ResetSnapshot(out);
      out.serverTime=observation.serverTime;
      out.window=observation.window;
      out.accountLeverage=observation.accountLeverage;
      out.requiredMargin=observation.requiredMargin;
      out.freeMargin=observation.freeMargin;

      if(!observation.brokerWindowVerified ||
         observation.window==AX_GAP_WINDOW_UNKNOWN)
        {
         out.reason="BROKER_WINDOW_NOT_VERIFIED";
         out.state=AX_GAP_STATE_UNVERIFIED;
         m_lastState=out.state;
         return(false);
        }

      if(!observation.quoteAvailable || observation.bid<=0.0 ||
         observation.ask<observation.bid || observation.point<=0.0 ||
         observation.quoteTimeMsc<=0 || nowMsc<(ulong)observation.quoteTimeMsc)
        {
         out.reason="QUOTE_INVALID_OR_UNAVAILABLE";
         out.state=AX_GAP_STATE_UNVERIFIED;
         m_lastState=out.state;
         return(false);
        }

      long quoteAgeMs=(long)(nowMsc-(ulong)observation.quoteTimeMsc);
      out.quoteFresh=(quoteAgeMs<=m_maxQuoteAgeMs);
      out.spreadPoints=(observation.ask-observation.bid)/observation.point;
      out.zeroSpread=(observation.ask==observation.bid);
      out.unlimitedLeverage=observation.unlimitedLeverageVerified;

      if(!out.quoteFresh)
        {
         out.reason="QUOTE_STALE";
         out.state=AX_GAP_STATE_INACTIVE;
        }
      else if(!observation.accountTradingAllowed ||
              !observation.expertTradingAllowed ||
              !observation.symbolTradingAllowed)
        {
         out.reason="TRADING_PERMISSION_NOT_AVAILABLE";
         out.state=AX_GAP_STATE_INACTIVE;
        }
      else if(out.zeroSpread && out.unlimitedLeverage)
        {
         out.reason="GAP_HOUR_CONDITIONS_VERIFIED";
         out.state=AX_GAP_STATE_READY;
         out.executionAllowed=true;
        }
      else if(out.zeroSpread)
        {
         out.reason="ZERO_SPREAD_ONLY_LEVERAGE_NOT_VERIFIED";
         out.state=AX_GAP_STATE_ZERO_SPREAD_ONLY;
        }
      else if(out.unlimitedLeverage)
        {
         out.reason="UNLIMITED_LEVERAGE_ONLY_SPREAD_NOT_ZERO";
         out.state=AX_GAP_STATE_UNLIMITED_LEVERAGE_ONLY;
        }
      else
        {
         out.reason="GAP_HOUR_CONDITIONS_NOT_ACTIVE";
         out.state=AX_GAP_STATE_INACTIVE;
        }

      m_lastEvaluationMsc=nowMsc;
      m_lastState=out.state;
      return(out.state==AX_GAP_STATE_READY);
     }

   ENUM_AX_GAP_STATE LastState(void) const
     {
      return(m_lastState);
     }

   ulong LastEvaluationMsc(void) const
     {
      return(m_lastEvaluationMsc);
     }
  };

#endif // AX_GAPINTELLIGENCEENGINE_MQH
