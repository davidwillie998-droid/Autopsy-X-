//+------------------------------------------------------------------+
//|                                      GapObservationJournal.mqh   |
//| Daily CSV journal for measured Gap Hour broker conditions.       |
//| Research telemetry only. Journal failure never authorizes trades. |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_GAPOBSERVATIONJOURNAL_MQH
#define AX_GAPOBSERVATIONJOURNAL_MQH
#include "GapIntelligenceEngine.mqh"

class CGapObservationJournal
  {
private:
   int      m_handle;
   string   m_symbol;
   string   m_filename;
   ulong    m_magic;
   string   m_dayKey;
   bool     m_ready;

   string BoolText(const bool value) const
     {
      return(value ? "true" : "false");
     }

   string SafeFilePart(string value) const
     {
      StringReplace(value,"/","_");
      StringReplace(value,"\\","_");
      StringReplace(value,":","_");
      StringReplace(value," ","_");
      return(value);
     }

   bool OpenForDay(const datetime serverTime)
     {
      string day=TimeToString(serverTime,TIME_DATE);
      string key=day;
      StringReplace(key,".","");
      string filename=StringFormat("AUTOPSYX_GapHour_%s_%I64u_%s.csv",
                                   SafeFilePart(m_symbol),m_magic,key);
      if(m_handle!=INVALID_HANDLE)
        {
         FileFlush(m_handle);
         FileClose(m_handle);
         m_handle=INVALID_HANDLE;
        }
      m_filename=filename;
      m_dayKey=key;
      m_handle=FileOpen(m_filename,
                        FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|
                        FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_COMMON,',');
      if(m_handle==INVALID_HANDLE)
        {
         m_ready=false;
         PrintFormat("AUTOPSY X GAP JOURNAL: open failed file=%s error=%d",
                     m_filename,GetLastError());
         return(false);
        }
      if(FileSize(m_handle)==0)
        {
         FileWrite(m_handle,
                   "server_time","broker","server","account_type","symbol",
                   "window","market_status","gap_state","reason",
                   "bid","ask","point","spread_points",
                   "account_leverage","leverage_policy","unlimited_leverage_verified",
                   "required_margin","free_margin","margin_calculation_verified",
                   "gross_notional","effective_leverage","effective_leverage_verified",
                   "commission_round_trip_per_lot","commission_verified",
                   "observed_round_trip_cost","expected_gross_profit",
                   "cost_assessment_verified","cost_acceptable",
                   "latency_p50_us","latency_p95_us","latency_p99_us",
                   "entry_slippage_points","exit_slippage_points","confirmed_fill_samples",
                   "broker_min_volume","broker_max_volume","broker_volume_step","broker_volume_limit",
                   "broker_max_positions","broker_max_pending_orders","broker_max_requests_per_second",
                   "order_limits_verified","quote_fresh","gap_conditions_verified");
         FileFlush(m_handle);
        }
      FileSeek(m_handle,0,SEEK_END);
      m_ready=true;
      return(true);
     }

public:
                     CGapObservationJournal(void)
     {
      m_handle=INVALID_HANDLE;
      m_symbol="";
      m_filename="";
      m_magic=0;
      m_dayKey="";
      m_ready=false;
     }

   bool Init(const string symbol,const ulong magic)
     {
      m_symbol=symbol;
      m_magic=magic;
      datetime now=TimeTradeServer();
      if(now<=0) now=TimeCurrent();
      return(OpenForDay(now));
     }

   bool IsReady(void) const { return(m_ready && m_handle!=INVALID_HANDLE); }
   string FileName(void) const { return(m_filename); }

   bool Record(const SAxGapObservation &o,const SAxGapSnapshot &s)
     {
      if(!m_ready || m_handle==INVALID_HANDLE) return(false);
      datetime timestamp=o.serverTime;
      string key=TimeToString(timestamp,TIME_DATE);
      StringReplace(key,".","");
      if(key!=m_dayKey && !OpenForDay(timestamp)) return(false);

      bool written=(FileWrite(m_handle,
         TimeToString(o.serverTime,TIME_DATE|TIME_SECONDS),
         o.brokerCompany,o.tradeServer,o.accountTypeLabel,o.symbol,
         EnumToString(o.window),EnumToString(o.marketStatus),
         EnumToString(s.state),s.reason,
         DoubleToString(o.bid,10),DoubleToString(o.ask,10),
         DoubleToString(o.point,10),DoubleToString(s.spreadPoints,5),
         (string)o.accountLeverage,EnumToString(o.leveragePolicy),
         BoolText(o.unlimitedLeverageVerified),
         DoubleToString(o.requiredMargin,8),DoubleToString(o.freeMargin,2),
         BoolText(o.marginCalculationVerified),
         DoubleToString(o.grossNotional,2),DoubleToString(o.effectiveLeverage,4),
         BoolText(s.effectiveLeverageVerified),
         DoubleToString(o.commissionPerLotRoundTrip,4),
         BoolText(o.commissionVerified),
         DoubleToString(o.observedRoundTripCost,4),
         DoubleToString(o.expectedGrossProfit,4),
         BoolText(o.executionCostAssessmentVerified),
         BoolText(o.executionCostAcceptable),
         (string)o.orderLatencyP50Us,(string)o.orderLatencyP95Us,
         (string)o.orderLatencyP99Us,
         DoubleToString(o.entrySlippagePoints,4),
         DoubleToString(o.exitSlippagePoints,4),
         (string)o.confirmedFillSamples,
         DoubleToString(o.brokerMinOrderVolume,8),
         DoubleToString(o.brokerMaxOrderVolume,8),
         DoubleToString(o.brokerVolumeStep,8),
         DoubleToString(o.brokerVolumeLimit,8),
         (string)o.brokerMaxOpenPositions,
         (string)o.brokerMaxPendingOrders,
         (string)o.brokerMaxRequestsPerSecond,
         BoolText(o.brokerOrderLimitsVerified),
         BoolText(s.quoteFresh),
         BoolText(s.gapConditionsVerified))>0);
      if(!written)
        {
         m_ready=false;
         PrintFormat("AUTOPSY X GAP JOURNAL: write failed file=%s error=%d",
                     m_filename,GetLastError());
         return(false);
        }
      FileFlush(m_handle);
      return(true);
     }

   void Deinit(void)
     {
      if(m_handle!=INVALID_HANDLE)
        {
         FileFlush(m_handle);
         FileClose(m_handle);
         m_handle=INVALID_HANDLE;
        }
      m_ready=false;
     }
  };

#endif // AX_GAPOBSERVATIONJOURNAL_MQH
