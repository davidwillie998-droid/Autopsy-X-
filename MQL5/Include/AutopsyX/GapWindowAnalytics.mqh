//+------------------------------------------------------------------+
//|                                          GapWindowAnalytics.mqh  |
//| Time-of-week analytics for regular and market-reopening windows. |
//| Session-local aggregation. Raw observations remain in the journal.|
//+------------------------------------------------------------------+
#property strict
#ifndef AX_GAPWINDOWANALYTICS_MQH
#define AX_GAPWINDOWANALYTICS_MQH
#include "GapIntelligenceEngine.mqh"

#define AX_GAP_ANALYTIC_DAYS 7
#define AX_GAP_ANALYTIC_BUCKETS 96
#define AX_GAP_ANALYTIC_WINDOWS 2

struct SAxGapBucketStats
  {
   long samples;
   long freshQuotes;
   long zeroSpreadSamples;
   long unlimitedLeverageSamples;
   long bothConditionsSamples;
   long costEvidenceSamples;
   long acceptableCostSamples;
   long readySamples;
   double spreadSum;
   double spreadMin;
   double spreadMax;
   double commissionSum;
   double roundTripCostSum;
   double costToGrossRatioSum;
   double latencyP95SumUs;
  };

class CGapWindowAnalytics
  {
private:
   SAxGapBucketStats m_stats[AX_GAP_ANALYTIC_WINDOWS][AX_GAP_ANALYTIC_DAYS][AX_GAP_ANALYTIC_BUCKETS];
   string m_broker;
   string m_server;
   string m_accountType;
   string m_symbol;
   string m_filename;
   ulong m_magic;
   bool m_initialized;

   int WindowIndex(const ENUM_AX_GAP_WINDOW window) const
     {
      if(window==AX_GAP_WINDOW_REGULAR_SESSION) return(0);
      if(window==AX_GAP_WINDOW_MARKET_REOPEN) return(1);
      return(-1);
     }

   string WindowName(const int index) const
     {
      return(index==0 ? "REGULAR_SESSION" : "MARKET_REOPEN");
     }

   void ResetStats(void)
     {
      for(int w=0;w<AX_GAP_ANALYTIC_WINDOWS;w++)
         for(int d=0;d<AX_GAP_ANALYTIC_DAYS;d++)
            for(int b=0;b<AX_GAP_ANALYTIC_BUCKETS;b++)
              {
               m_stats[w][d][b].samples=0;
               m_stats[w][d][b].freshQuotes=0;
               m_stats[w][d][b].zeroSpreadSamples=0;
               m_stats[w][d][b].unlimitedLeverageSamples=0;
               m_stats[w][d][b].bothConditionsSamples=0;
               m_stats[w][d][b].costEvidenceSamples=0;
               m_stats[w][d][b].acceptableCostSamples=0;
               m_stats[w][d][b].readySamples=0;
               m_stats[w][d][b].spreadSum=0.0;
               m_stats[w][d][b].spreadMin=DBL_MAX;
               m_stats[w][d][b].spreadMax=0.0;
               m_stats[w][d][b].commissionSum=0.0;
               m_stats[w][d][b].roundTripCostSum=0.0;
               m_stats[w][d][b].costToGrossRatioSum=0.0;
               m_stats[w][d][b].latencyP95SumUs=0.0;
              }
     }

   string SafePart(string value) const
     {
      StringReplace(value,"/","_");
      StringReplace(value,"\\","_");
      StringReplace(value,":","_");
      StringReplace(value," ","_");
      return(value);
     }

public:
                     CGapWindowAnalytics(void)
     {
      m_broker="";
      m_server="";
      m_accountType="";
      m_symbol="";
      m_filename="";
      m_magic=0;
      m_initialized=false;
      ResetStats();
     }

   bool Init(const string broker,const string server,const string accountType,
             const string symbol,const ulong magic)
     {
      m_broker=broker;
      m_server=server;
      m_accountType=accountType;
      m_symbol=symbol;
      m_magic=magic;
      m_initialized=(m_symbol!="");
      return(m_initialized);
     }

   bool Record(const SAxGapObservation &o,const SAxGapSnapshot &s)
     {
      if(!m_initialized || o.serverTime<=0 || !o.quoteAvailable)
         return(false);

      int w=WindowIndex(o.window);
      if(w<0) return(false);

      MqlDateTime dt;
      if(!TimeToStruct(o.serverTime,dt)) return(false);
      if(dt.day_of_week<0 || dt.day_of_week>=AX_GAP_ANALYTIC_DAYS)
         return(false);

      int bucket=dt.hour*4+(dt.min/15);
      if(bucket<0 || bucket>=AX_GAP_ANALYTIC_BUCKETS)
         return(false);

      SAxGapBucketStats &v=m_stats[w][dt.day_of_week][bucket];
      v.samples++;
      if(s.quoteFresh) v.freshQuotes++;
      if(s.zeroSpread) v.zeroSpreadSamples++;
      if(s.unlimitedLeverage) v.unlimitedLeverageSamples++;
      if(s.zeroSpread && s.unlimitedLeverage) v.bothConditionsSamples++;
      if(o.executionCostAssessmentVerified) v.costEvidenceSamples++;
      if(o.executionCostAcceptable) v.acceptableCostSamples++;
      if(s.gapConditionsVerified) v.readySamples++;

      if(MathIsValidNumber(s.spreadPoints) && s.spreadPoints>=0.0)
        {
         v.spreadSum+=s.spreadPoints;
         if(s.spreadPoints<v.spreadMin) v.spreadMin=s.spreadPoints;
         if(s.spreadPoints>v.spreadMax) v.spreadMax=s.spreadPoints;
        }
      if(o.commissionVerified && MathIsValidNumber(o.commissionPerLotRoundTrip))
         v.commissionSum+=o.commissionPerLotRoundTrip;
      if(o.executionCostAssessmentVerified &&
         MathIsValidNumber(o.observedRoundTripCost) &&
         MathIsValidNumber(o.expectedGrossProfit) && o.expectedGrossProfit>0.0)
        {
         v.roundTripCostSum+=o.observedRoundTripCost;
         v.costToGrossRatioSum+=o.observedRoundTripCost/o.expectedGrossProfit;
        }
      if(o.executionTelemetryVerified)
         v.latencyP95SumUs+=(double)o.orderLatencyP95Us;
      return(true);
     }

   bool WriteSummary(const datetime serverTime)
     {
      if(!m_initialized || serverTime<=0) return(false);
      string day=TimeToString(serverTime,TIME_DATE);
      string dayKey=day;
      StringReplace(dayKey,".","");
      m_filename=StringFormat("AUTOPSYX_GapHour_Analytics_%s_%I64u_%s.csv",
                              SafePart(m_symbol),m_magic,dayKey);
      int h=FileOpen(m_filename,FILE_WRITE|FILE_CSV|FILE_ANSI|
                     FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_COMMON,',');
      if(h==INVALID_HANDLE)
        {
         PrintFormat("AUTOPSY X GAP ANALYTICS: summary open failed file=%s error=%d",
                     m_filename,GetLastError());
         return(false);
        }

      FileWrite(h,"generated_server_time","broker","server","account_type","symbol",
                "window","day_of_week","bucket_start","bucket_end","samples",
                "fresh_quote_rate","zero_spread_rate","unlimited_leverage_rate",
                "zero_spread_and_unlimited_rate","cost_evidence_rate",
                "acceptable_cost_rate","verified_gap_hour_rate",
                "average_spread_points","minimum_spread_points","maximum_spread_points",
                "average_round_trip_commission","average_round_trip_cost",
                "average_cost_to_gross_ratio","average_order_latency_p95_us");

      int rows=0;
      for(int w=0;w<AX_GAP_ANALYTIC_WINDOWS;w++)
         for(int d=0;d<AX_GAP_ANALYTIC_DAYS;d++)
            for(int b=0;b<AX_GAP_ANALYTIC_BUCKETS;b++)
              {
               SAxGapBucketStats v=m_stats[w][d][b];
               if(v.samples<=0) continue;
               double n=(double)v.samples;
               int startMinute=b*15;
               int endMinute=startMinute+15;
               string start=StringFormat("%02d:%02d",startMinute/60,startMinute%60);
               string finish=StringFormat("%02d:%02d",endMinute/60,endMinute%60);
               double avgSpread=v.spreadSum/n;
               double minSpread=(v.spreadMin==DBL_MAX ? 0.0 : v.spreadMin);
               double avgCommission=(v.commissionSum>0.0 ? v.commissionSum/n : 0.0);
               double avgRoundTrip=(v.costEvidenceSamples>0
                                    ? v.roundTripCostSum/(double)v.costEvidenceSamples : 0.0);
               double avgCostRatio=(v.costEvidenceSamples>0
                                    ? v.costToGrossRatioSum/(double)v.costEvidenceSamples : 0.0);
               double avgLatency=(v.freshQuotes>0
                                  ? v.latencyP95SumUs/n : 0.0);
               FileWrite(h,TimeToString(serverTime,TIME_DATE|TIME_SECONDS),
                         m_broker,m_server,m_accountType,m_symbol,
                         WindowName(w),d,start,finish,v.samples,
                         DoubleToString((double)v.freshQuotes/n,5),
                         DoubleToString((double)v.zeroSpreadSamples/n,5),
                         DoubleToString((double)v.unlimitedLeverageSamples/n,5),
                         DoubleToString((double)v.bothConditionsSamples/n,5),
                         DoubleToString((double)v.costEvidenceSamples/n,5),
                         DoubleToString((double)v.acceptableCostSamples/n,5),
                         DoubleToString((double)v.readySamples/n,5),
                         DoubleToString(avgSpread,6),DoubleToString(minSpread,6),
                         DoubleToString(v.spreadMax,6),
                         DoubleToString(avgCommission,6),
                         DoubleToString(avgRoundTrip,6),
                         DoubleToString(avgCostRatio,6),
                         DoubleToString(avgLatency,2));
               rows++;
              }
      FileFlush(h);
      FileClose(h);
      PrintFormat("AUTOPSY X GAP ANALYTICS: summary written rows=%d file=%s",
                  rows,m_filename);
      return(true);
     }

   string FileName(void) const { return(m_filename); }

   void Deinit(void)
     {
      m_initialized=false;
     }
  };

#endif // AX_GAPWINDOWANALYTICS_MQH
