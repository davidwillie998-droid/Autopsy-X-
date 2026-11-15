//+------------------------------------------------------------------+
//|                                         BrokerCompatibility.mqh  |
//|  Runtime broker/account capability snapshot for AUTOPSY X       |
//|  Metadata-driven: never guesses broker account labels or scaling. |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_BROKERCOMPATIBILITY_MQH
#define AX_BROKERCOMPATIBILITY_MQH

enum ENUM_AX_ACCOUNT_MODEL
  {
   AX_ACCOUNT_MODEL_UNKNOWN = 0,
   AX_ACCOUNT_MODEL_NETTING,
   AX_ACCOUNT_MODEL_EXCHANGE,
   AX_ACCOUNT_MODEL_HEDGING
  };

enum ENUM_AX_ACCOUNT_ENVIRONMENT
  {
   AX_ACCOUNT_ENV_UNKNOWN = 0,
   AX_ACCOUNT_ENV_DEMO,
   AX_ACCOUNT_ENV_REAL,
   AX_ACCOUNT_ENV_CONTEST
  };

enum ENUM_AX_CAPABILITY_STATE
  {
   AX_CAPABILITY_UNKNOWN = 0,
   AX_CAPABILITY_SUPPORTED,
   AX_CAPABILITY_UNSUPPORTED
  };

struct SAxBrokerCompatibilitySnapshot
  {
   string brokerCompany;
   string tradeServer;
   string accountCurrency;
   string symbol;
   string accountProfile;
   ENUM_AX_ACCOUNT_MODEL accountModel;
   ENUM_AX_ACCOUNT_ENVIRONMENT accountEnvironment;
   ENUM_AX_CAPABILITY_STATE marketOrderCapability;
   ENUM_AX_CAPABILITY_STATE positionManagementCapability;
   string positionManagementReason;
   long accountLeverage;
   long marginStopoutMode;
   double marginStopoutCall;
   double marginStopoutLevel;
   bool accountTradeAllowed;
   bool expertTradeAllowed;
   bool symbolSelected;
   bool symbolMetadataValid;
   bool quoteAvailable;
   long symbolTradeMode;
   long symbolExecutionMode;
   long symbolFillingFlags;
   long symbolOrderFlags;
   long symbolSwapMode;
   double point;
   double tickSize;
   double tickValue;
   double tickValueProfit;
   double tickValueLoss;
   double contractSize;
   double volumeMinimum;
   double volumeMaximum;
   double volumeStep;
   double volumeLimit;
   double bid;
   double ask;
   double spreadPoints;
   string accountProfileReason;
   string validationReason;
  };

class CBrokerCompatibility
  {
private:
   void ResetSnapshot(SAxBrokerCompatibilitySnapshot &out) const
     {
      out.brokerCompany="";
      out.tradeServer="";
      out.accountCurrency="";
      out.symbol="";
      out.accountProfile="UNKNOWN_BROKER_DEFINED";
      out.accountModel=AX_ACCOUNT_MODEL_UNKNOWN;
      out.accountEnvironment=AX_ACCOUNT_ENV_UNKNOWN;
      out.marketOrderCapability=AX_CAPABILITY_UNKNOWN;
      out.positionManagementCapability=AX_CAPABILITY_UNKNOWN;
      out.positionManagementReason="ACCOUNT_MARGIN_MODEL_NOT_VERIFIED";
      out.accountLeverage=0;
      out.marginStopoutMode=0;
      out.marginStopoutCall=0.0;
      out.marginStopoutLevel=0.0;
      out.accountTradeAllowed=false;
      out.expertTradeAllowed=false;
      out.symbolSelected=false;
      out.symbolMetadataValid=false;
      out.quoteAvailable=false;
      out.symbolTradeMode=-1;
      out.symbolExecutionMode=-1;
      out.symbolFillingFlags=0;
      out.symbolOrderFlags=0;
      out.symbolSwapMode=-1;
      out.point=0.0;
      out.tickSize=0.0;
      out.tickValue=0.0;
      out.tickValueProfit=0.0;
      out.tickValueLoss=0.0;
      out.contractSize=0.0;
      out.volumeMinimum=0.0;
      out.volumeMaximum=0.0;
      out.volumeStep=0.0;
      out.volumeLimit=0.0;
      out.bid=0.0;
      out.ask=0.0;
      out.spreadPoints=0.0;
      out.accountProfileReason="MT5 does not expose a reliable universal Pro/ECN/Raw/Cent account-type field";
      out.validationReason="";
     }

   void CaptureAccount(SAxBrokerCompatibilitySnapshot &out) const
     {
      out.brokerCompany=AccountInfoString(ACCOUNT_COMPANY);
      out.tradeServer=AccountInfoString(ACCOUNT_SERVER);
      out.accountCurrency=AccountInfoString(ACCOUNT_CURRENCY);
      out.accountLeverage=AccountInfoInteger(ACCOUNT_LEVERAGE);
      out.marginStopoutMode=AccountInfoInteger(ACCOUNT_MARGIN_SO_MODE);
      out.marginStopoutCall=AccountInfoDouble(ACCOUNT_MARGIN_SO_CALL);
      out.marginStopoutLevel=AccountInfoDouble(ACCOUNT_MARGIN_SO_SO);
      out.accountTradeAllowed=(AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)!=0);
      out.expertTradeAllowed=(AccountInfoInteger(ACCOUNT_TRADE_EXPERT)!=0);

      long marginMode=AccountInfoInteger(ACCOUNT_MARGIN_MODE);
      if(marginMode==ACCOUNT_MARGIN_MODE_RETAIL_NETTING)
        {
         out.accountModel=AX_ACCOUNT_MODEL_NETTING;
         out.positionManagementCapability=AX_CAPABILITY_SUPPORTED;
         out.positionManagementReason="NETTING_LIFECYCLE_SUPPORTED";
        }
      else if(marginMode==ACCOUNT_MARGIN_MODE_EXCHANGE)
        {
         out.accountModel=AX_ACCOUNT_MODEL_EXCHANGE;
         out.positionManagementCapability=AX_CAPABILITY_UNSUPPORTED;
         out.positionManagementReason="EXCHANGE_POSITION_LIFECYCLE_NOT_YET_VALIDATED";
        }
      else if(marginMode==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
        {
         out.accountModel=AX_ACCOUNT_MODEL_HEDGING;
         out.positionManagementCapability=AX_CAPABILITY_UNSUPPORTED;
         out.positionManagementReason="HEDGING_TICKET_LIFECYCLE_ADAPTER_NOT_YET_ACTIVE";
        }

      long tradeMode=AccountInfoInteger(ACCOUNT_TRADE_MODE);
      if(tradeMode==ACCOUNT_TRADE_MODE_DEMO)
         out.accountEnvironment=AX_ACCOUNT_ENV_DEMO;
      else if(tradeMode==ACCOUNT_TRADE_MODE_REAL)
         out.accountEnvironment=AX_ACCOUNT_ENV_REAL;
      else if(tradeMode==ACCOUNT_TRADE_MODE_CONTEST)
         out.accountEnvironment=AX_ACCOUNT_ENV_CONTEST;
     }

   bool CaptureSymbol(const string symbol,SAxBrokerCompatibilitySnapshot &out) const
     {
      out.symbol=symbol;
      out.symbolSelected=SymbolSelect(symbol,true);
      if(!out.symbolSelected)
        {
         out.validationReason="SYMBOL_SELECT_FAILED";
         return(false);
        }

      out.symbolTradeMode=SymbolInfoInteger(symbol,SYMBOL_TRADE_MODE);
      out.symbolExecutionMode=SymbolInfoInteger(symbol,SYMBOL_TRADE_EXEMODE);
      out.symbolFillingFlags=SymbolInfoInteger(symbol,SYMBOL_FILLING_MODE);
      out.symbolOrderFlags=SymbolInfoInteger(symbol,SYMBOL_ORDER_MODE);
      out.symbolSwapMode=SymbolInfoInteger(symbol,SYMBOL_SWAP_MODE);
      out.point=SymbolInfoDouble(symbol,SYMBOL_POINT);
      out.tickSize=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_SIZE);
      out.tickValue=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_VALUE);
      out.tickValueProfit=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_VALUE_PROFIT);
      out.tickValueLoss=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_VALUE_LOSS);
      out.contractSize=SymbolInfoDouble(symbol,SYMBOL_TRADE_CONTRACT_SIZE);
      out.volumeMinimum=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
      out.volumeMaximum=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX);
      out.volumeStep=SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
      out.volumeLimit=SymbolInfoDouble(symbol,SYMBOL_VOLUME_LIMIT);

      MqlTick quote;
      if(SymbolInfoTick(symbol,quote) && quote.bid>0.0 && quote.ask>=quote.bid)
        {
         out.quoteAvailable=true;
         out.bid=quote.bid;
         out.ask=quote.ask;
         if(out.point>0.0)
            out.spreadPoints=(quote.ask-quote.bid)/out.point;
        }

      if(out.symbolTradeMode==SYMBOL_TRADE_MODE_DISABLED ||
         out.symbolTradeMode==SYMBOL_TRADE_MODE_CLOSEONLY ||
         (out.symbolOrderFlags & SYMBOL_ORDER_MARKET)==0)
         out.marketOrderCapability=AX_CAPABILITY_UNSUPPORTED;
      else
         out.marketOrderCapability=AX_CAPABILITY_SUPPORTED;

      bool coreValid=
         MathIsValidNumber(out.point) && out.point>0.0 &&
         MathIsValidNumber(out.tickSize) && out.tickSize>0.0 &&
         MathIsValidNumber(out.contractSize) && out.contractSize>0.0 &&
         MathIsValidNumber(out.volumeMinimum) && out.volumeMinimum>0.0 &&
         MathIsValidNumber(out.volumeMaximum) && out.volumeMaximum>=out.volumeMinimum &&
         MathIsValidNumber(out.volumeStep) && out.volumeStep>0.0 &&
         MathIsValidNumber(out.volumeLimit) && out.volumeLimit>=0.0;
      out.symbolMetadataValid=coreValid;
      if(!coreValid)
        {
         out.validationReason="INVALID_OR_INCOMPLETE_SYMBOL_CONTRACT_METADATA";
         return(false);
        }
      return(true);
     }

public:
   bool Capture(const string symbol,SAxBrokerCompatibilitySnapshot &out) const
     {
      ResetSnapshot(out);
      CaptureAccount(out);
      if(out.accountCurrency=="")
        {
         out.validationReason="ACCOUNT_CURRENCY_UNAVAILABLE";
         return(false);
        }
      if(out.accountLeverage<=0 || out.accountModel==AX_ACCOUNT_MODEL_UNKNOWN)
        {
         out.validationReason="ACCOUNT_LEVERAGE_OR_MARGIN_MODEL_UNKNOWN";
         return(false);
        }
      return(CaptureSymbol(symbol,out));
     }

   void Log(const SAxBrokerCompatibilitySnapshot &s) const
     {
      string model="UNKNOWN";
      if(s.accountModel==AX_ACCOUNT_MODEL_NETTING) model="NETTING";
      else if(s.accountModel==AX_ACCOUNT_MODEL_EXCHANGE) model="EXCHANGE";
      else if(s.accountModel==AX_ACCOUNT_MODEL_HEDGING) model="HEDGING";

      string environment="UNKNOWN";
      if(s.accountEnvironment==AX_ACCOUNT_ENV_DEMO) environment="DEMO";
      else if(s.accountEnvironment==AX_ACCOUNT_ENV_REAL) environment="REAL";
      else if(s.accountEnvironment==AX_ACCOUNT_ENV_CONTEST) environment="CONTEST";

      string marketOrders="UNKNOWN";
      if(s.marketOrderCapability==AX_CAPABILITY_SUPPORTED) marketOrders="SUPPORTED";
      else if(s.marketOrderCapability==AX_CAPABILITY_UNSUPPORTED) marketOrders="UNSUPPORTED";

      PrintFormat("FLIPDEMON UBCE ACCOUNT: broker='%s' server='%s' environment=%s margin_model=%s currency='%s' leverage=1:%I64d trade_allowed=%s expert_allowed=%s profile=%s",
                  s.brokerCompany,s.tradeServer,environment,model,s.accountCurrency,
                  s.accountLeverage,s.accountTradeAllowed?"true":"false",
                  s.expertTradeAllowed?"true":"false",s.accountProfile);
      PrintFormat("FLIPDEMON UBCE SYMBOL: symbol='%s' market_orders=%s execution=%I64d filling_flags=%I64d order_flags=%I64d point=%.10g tick_size=%.10g tick_value=%.10g tick_value_profit=%.10g tick_value_loss=%.10g contract_size=%.10g volume_min=%.8g volume_max=%.8g volume_step=%.8g volume_limit=%.8g spread_points=%.2f quote_available=%s",
                  s.symbol,marketOrders,s.symbolExecutionMode,s.symbolFillingFlags,
                  s.symbolOrderFlags,s.point,s.tickSize,s.tickValue,s.tickValueProfit,
                  s.tickValueLoss,s.contractSize,s.volumeMinimum,s.volumeMaximum,
                  s.volumeStep,s.volumeLimit,s.spreadPoints,
                  s.quoteAvailable?"true":"false");
      string positionLifecycle="UNKNOWN";
      if(s.positionManagementCapability==AX_CAPABILITY_SUPPORTED) positionLifecycle="SUPPORTED";
      else if(s.positionManagementCapability==AX_CAPABILITY_UNSUPPORTED) positionLifecycle="UNSUPPORTED";
      PrintFormat("FLIPDEMON UBCE POSITION LIFECYCLE: %s (%s).",
                  positionLifecycle,s.positionManagementReason);
      PrintFormat("FLIPDEMON UBCE ACCOUNT PROFILE: %s; account-label classification and cent scaling require a verified broker profile, never inference.",
                  s.accountProfileReason);
     }
  };

#endif // AX_BROKERCOMPATIBILITY_MQH
