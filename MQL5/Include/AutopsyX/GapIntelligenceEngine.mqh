//+------------------------------------------------------------------+
//|                                      GapIntelligenceEngine.mqh   |
//| Broker-neutral Gap Hour observation contract for AUTOPSY X      |
//| Records regular-session and market-reopening conditions.        |
//| Observation only. No order submission or risk-policy override.  |
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

enum ENUM_AX_GAP_MARKET_STATUS
  {
   AX_GAP_MARKET_UNKNOWN = 0,
   AX_GAP_MARKET_CLOSED,
   AX_GAP_MARKET_PRE_OPEN,
   AX_GAP_MARKET_REOPENING,
   AX_GAP_MARKET_OPEN
  };

enum ENUM_AX_GAP_LEVERAGE_POLICY
  {
   AX_GAP_LEVERAGE_UNKNOWN = 0,
   AX_GAP_LEVERAGE_FIXED,
   AX_GAP_LEVERAGE_DYNAMIC,
   AX_GAP_LEVERAGE_UNLIMITED_VERIFIED
  };

enum ENUM_AX_GAP_STATE
  {
   AX_GAP_STATE_UNVERIFIED = 0,
   AX_GAP_STATE_INACTIVE,
   AX_GAP_STATE_ZERO_SPREAD_ONLY,
   AX_GAP_STATE_LEVERAGE_ONLY,
   AX_GAP_STATE_COSTS_UNVERIFIED,
   AX_GAP_STATE_COSTS_UNACCEPTABLE,
   AX_GAP_STATE_READY
  };

// One timestamped observation. Values that MT5 cannot expose universally
// (commission schedules, unlimited-leverage eligibility, broker order caps)
// must be supplied from broker documentation or measured broker responses.
// Never infer them from ACCOUNT_LEVERAGE or from a zero spread quote.
struct SAxGapObservation
  {
   string brokerCompany;
   string tradeServer;
   string accountCurrency;
   string accountTypeLabel;
   string symbol;
   datetime serverTime;
   long quoteTimeMsc;
   ENUM_AX_GAP_WINDOW window;
   ENUM_AX_GAP_MARKET_STATUS marketStatus;

   double bid;
   double ask;
   double point;
   long accountLeverage;
   ENUM_AX_GAP_LEVERAGE_POLICY leveragePolicy;
   bool unlimitedLeverageVerified;
   bool leverageEligibilityVerified;

   double referenceVolumeLots;
   double grossNotional;
   double requiredMargin;
   double freeMargin;
   double effectiveLeverage;
   bool marginCalculationVerified;

   double commissionPerLotRoundTrip;
   bool commissionVerified;
   double observedRoundTripCost;
   double expectedGrossProfit;
   bool executionCostAssessmentVerified;
   bool executionCostAcceptable;

   ulong orderCallLatencyUs;
   ulong orderLatencyP50Us;
   ulong orderLatencyP95Us;
   ulong orderLatencyP99Us;
   double entrySlippagePoints;
   double exitSlippagePoints;
   int confirmedFillSamples;
   bool executionTelemetryVerified;

   double brokerMaxOrderVolume;
   double brokerMinOrderVolume;
   double brokerVolumeStep;
   double brokerVolumeLimit;
   int brokerMaxOpenPositions;
   int brokerMaxPendingOrders;
   int brokerMaxRequestsPerSecond;
   bool brokerOrderLimitsVerified;

   bool quoteAvailable;
   bool symbolTradingAllowed;
   bool accountTradingAllowed;
   bool expertTradingAllowed;
   bool brokerWindowVerified;
  };

struct SAxGapSnapshot
  {
   ENUM_AX_GAP_STATE state;
   ENUM_AX_GAP_WINDOW window;
   ENUM_AX_GAP_MARKET_STATUS marketStatus;
   datetime serverTime;
   string brokerCompany;
   string tradeServer;
   string accountTypeLabel;
   string symbol;
   double spreadPoints;
   long accountLeverage;
   ENUM_AX_GAP_LEVERAGE_POLICY leveragePolicy;
   double effectiveLeverage;
   double requiredMargin;
   double freeMargin;
   double commissionPerLotRoundTrip;
   double observedRoundTripCost;
   double expectedGrossProfit;
   ulong orderLatencyP50Us;
   ulong orderLatencyP95Us;
   ulong orderLatencyP99Us;
   double entrySlippagePoints;
   double exitSlippagePoints;
   int confirmedFillSamples;
   int brokerMaxOpenPositions;
   int brokerMaxPendingOrders;
   int brokerMaxRequestsPerSecond;
   bool zeroSpread;
   bool unlimitedLeverage;
   bool quoteFresh;
   bool commissionVerified;
   bool executionTelemetryVerified;
   bool orderLimitsVerified;
   bool executionCostAcceptable;
   bool executionAllowed;
   string reason;
  };

class CGapIntelligenceEngine
  {
private:
   long m_maxQuoteAgeMs;
   ENUM_AX_GAP_STATE m_lastState;
   ulong m_lastEvaluationMsc;

   void ResetSnapshot(SAxGapSnapshot &out) const
     {
      out.state=AX_GAP_STATE_UNVERIFIED;
      out.window=AX_GAP_WINDOW_UNKNOWN;
      out.marketStatus=AX_GAP_MARKET_UNKNOWN;
      out.serverTime=0;
      out.brokerCompany="";
      out.tradeServer="";
      out.accountTypeLabel="";
      out.symbol="";
      out.spreadPoints=0.0;
      out.accountLeverage=0;
      out.leveragePolicy=AX_GAP_LEVERAGE_UNKNOWN;
      out.effectiveLeverage=0.0;
      out.requiredMargin=0.0;
      out.freeMargin=0.0;
      out.commissionPerLotRoundTrip=0.0;
      out.observedRoundTripCost=0.0;
      out.expectedGrossProfit=0.0;
      out.orderLatencyP50Us=0;
      out.orderLatencyP95Us=0;
      out.orderLatencyP99Us=0;
      out.entrySlippagePoints=0.0;
      out.exitSlippagePoints=0.0;
      out.confirmedFillSamples=0;
      out.brokerMaxOpenPositions=0;
      out.brokerMaxPendingOrders=0;
      out.brokerMaxRequestsPerSecond=0;
      out.zeroSpread=false;
      out.unlimitedLeverage=false;
      out.quoteFresh=false;
      out.commissionVerified=false;
      out.executionTelemetryVerified=false;
      out.orderLimitsVerified=false;
      out.executionCostAcceptable=false;
      out.executionAllowed=false;
      out.reason="OBSERVATION_NOT_EVALUATED";
     }

   bool IsFiniteNonNegative(const double value) const
     {
      return(MathIsValidNumber(value) && value>=0.0);
     }

public:
   CGapIntelligenceEngine(void)
     {
      m_maxQuoteAgeMs=2000;
      m_lastState=AX_GAP_STATE_UNVERIFIED;
      m_lastEvaluationMsc=0;
     }

   void Configure(const long maxQuoteAgeMs=2000)
     {
      m_maxQuoteAgeMs=(maxQuoteAgeMs>0 ? maxQuoteAgeMs : 2000);
     }

   // "Unlimited" is an explicit broker-policy verification, not a numeric
   // leverage threshold. Both windows are preserved as separate observations.
   bool Evaluate(const SAxGapObservation &observation,
                 const ulong nowMsc,
                 SAxGapSnapshot &out)
     {
      ResetSnapshot(out);
      out.serverTime=observation.serverTime;
      out.window=observation.window;
      out.marketStatus=observation.marketStatus;
      out.brokerCompany=observation.brokerCompany;
      out.tradeServer=observation.tradeServer;
      out.accountTypeLabel=observation.accountTypeLabel;
      out.symbol=observation.symbol;
      out.accountLeverage=observation.accountLeverage;
      out.leveragePolicy=observation.leveragePolicy;
      out.effectiveLeverage=observation.effectiveLeverage;
      out.requiredMargin=observation.requiredMargin;
      out.freeMargin=observation.freeMargin;
      out.commissionPerLotRoundTrip=observation.commissionPerLotRoundTrip;
      out.observedRoundTripCost=observation.observedRoundTripCost;
      out.expectedGrossProfit=observation.expectedGrossProfit;
      out.orderLatencyP50Us=observation.orderLatencyP50Us;
      out.orderLatencyP95Us=observation.orderLatencyP95Us;
      out.orderLatencyP99Us=observation.orderLatencyP99Us;
      out.entrySlippagePoints=observation.entrySlippagePoints;
      out.exitSlippagePoints=observation.exitSlippagePoints;
      out.confirmedFillSamples=observation.confirmedFillSamples;
      out.brokerMaxOpenPositions=observation.brokerMaxOpenPositions;
      out.brokerMaxPendingOrders=observation.brokerMaxPendingOrders;
      out.brokerMaxRequestsPerSecond=observation.brokerMaxRequestsPerSecond;
      out.commissionVerified=observation.commissionVerified;
      out.executionTelemetryVerified=observation.executionTelemetryVerified;
      out.orderLimitsVerified=observation.brokerOrderLimitsVerified;

      if(!observation.brokerWindowVerified ||
         observation.window==AX_GAP_WINDOW_UNKNOWN ||
         observation.brokerCompany=="" || observation.tradeServer=="" ||
         observation.symbol=="")
        {
         out.reason="BROKER_IDENTITY_OR_WINDOW_NOT_VERIFIED";
         return(SetState(AX_GAP_STATE_UNVERIFIED));
        }

      if(!observation.quoteAvailable ||
         !MathIsValidNumber(observation.bid) ||
         !MathIsValidNumber(observation.ask) ||
         !MathIsValidNumber(observation.point) ||
         observation.bid<=0.0 || observation.ask<observation.bid ||
         observation.point<=0.0 || observation.quoteTimeMsc<=0 ||
         nowMsc<(ulong)observation.quoteTimeMsc)
        {
         out.reason="QUOTE_INVALID_OR_UNAVAILABLE";
         return(SetState(AX_GAP_STATE_UNVERIFIED));
        }

      long quoteAgeMs=(long)(nowMsc-(ulong)observation.quoteTimeMsc);
      out.quoteFresh=(quoteAgeMs<=m_maxQuoteAgeMs);
      out.spreadPoints=(observation.ask-observation.bid)/observation.point;
      out.zeroSpread=(out.spreadPoints<=0.0000001);
      out.unlimitedLeverage=
         observation.unlimitedLeverageVerified &&
         observation.leverageEligibilityVerified &&
         observation.leveragePolicy==AX_GAP_LEVERAGE_UNLIMITED_VERIFIED;

      if(!out.quoteFresh)
        {
         out.reason="QUOTE_STALE";
         return(SetState(AX_GAP_STATE_INACTIVE));
        }

      if(observation.marketStatus!=AX_GAP_MARKET_OPEN &&
         observation.marketStatus!=AX_GAP_MARKET_REOPENING)
        {
         out.reason="MARKET_NOT_IN_EXECUTABLE_OPEN_OR_REOPEN_STATE";
         return(SetState(AX_GAP_STATE_INACTIVE));
        }

      if(!observation.accountTradingAllowed ||
         !observation.expertTradingAllowed ||
         !observation.symbolTradingAllowed)
        {
         out.reason="TRADING_PERMISSION_NOT_AVAILABLE";
         return(SetState(AX_GAP_STATE_INACTIVE));
        }

      if(!IsFiniteNonNegative(observation.requiredMargin) ||
         !IsFiniteNonNegative(observation.freeMargin) ||
         !IsFiniteNonNegative(observation.effectiveLeverage))
        {
         out.reason="MARGIN_OR_EFFECTIVE_LEVERAGE_DATA_INVALID";
         return(SetState(AX_GAP_STATE_UNVERIFIED));
        }

      if(!out.zeroSpread && !out.unlimitedLeverage)
        {
         out.reason="ZERO_SPREAD_AND_UNLIMITED_LEVERAGE_NOT_ACTIVE";
         return(SetState(AX_GAP_STATE_INACTIVE));
        }
      if(!out.zeroSpread)
        {
         out.reason="UNLIMITED_LEVERAGE_ONLY_SPREAD_NOT_ZERO";
         return(SetState(AX_GAP_STATE_LEVERAGE_ONLY));
        }
      if(!out.unlimitedLeverage)
        {
         out.reason="ZERO_SPREAD_ONLY_UNLIMITED_LEVERAGE_NOT_VERIFIED";
         return(SetState(AX_GAP_STATE_ZERO_SPREAD_ONLY));
        }

      if(!observation.commissionVerified ||
         !observation.executionCostAssessmentVerified ||
         !observation.executionTelemetryVerified ||
         observation.confirmedFillSamples<=0)
        {
         out.reason="COMMISSION_OR_EXECUTION_COST_EVIDENCE_INCOMPLETE";
         return(SetState(AX_GAP_STATE_COSTS_UNVERIFIED));
        }

      if(!IsFiniteNonNegative(observation.commissionPerLotRoundTrip) ||
         !IsFiniteNonNegative(observation.observedRoundTripCost) ||
         !MathIsValidNumber(observation.expectedGrossProfit) ||
         observation.expectedGrossProfit<=0.0)
        {
         out.reason="ROUND_TRIP_COST_INPUT_INVALID";
         return(SetState(AX_GAP_STATE_COSTS_UNVERIFIED));
        }

      if(!observation.executionCostAcceptable)
        {
         out.reason="EXECUTION_COSTS_NOT_ACCEPTABLE";
         return(SetState(AX_GAP_STATE_COSTS_UNACCEPTABLE));
        }

      out.executionCostAcceptable=true;
      out.executionAllowed=true;
      out.reason="GAP_HOUR_CONDITIONS_AND_COST_EVIDENCE_VERIFIED";
      return(SetState(AX_GAP_STATE_READY));
     }

   ENUM_AX_GAP_STATE LastState(void) const
     {
      return(m_lastState);
     }

   ulong LastEvaluationMsc(void) const
     {
      return(m_lastEvaluationMsc);
     }

private:
   bool SetState(const ENUM_AX_GAP_STATE state)
     {
      m_lastState=state;
      return(state==AX_GAP_STATE_READY);
     }
  };

#endif // AX_GAPINTELLIGENCEENGINE_MQH
