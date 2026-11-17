//+------------------------------------------------------------------+
//|                                      ExecutionLatencyProfiler.mqh |
//|  Low-overhead local latency telemetry. No trading decisions.      |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_EXECUTION_LATENCY_PROFILER_MQH
#define AX_EXECUTION_LATENCY_PROFILER_MQH

#define AX_LATENCY_SAMPLE_CAPACITY 256

class CExecutionLatencyProfiler
  {
private:
   ulong m_tickSamples[AX_LATENCY_SAMPLE_CAPACITY];
   ulong m_orderSamples[AX_LATENCY_SAMPLE_CAPACITY];
   int   m_tickHead;
   int   m_tickCount;
   int   m_orderHead;
   int   m_orderCount;
   ulong m_tickTotal;
   ulong m_orderTotal;

   ulong Percentile(const ulong &source[],const int count,const double percentile) const
     {
      if(count<=0) return(0);
      double sorted[];
      if(ArrayResize(sorted,count)!=count) return(0);
      for(int i=0;i<count;i++) sorted[i]=(double)source[i];
      ArraySort(sorted,WHOLE_ARRAY,0,MODE_ASCEND);
      int index=(int)MathCeil((count-1)*percentile);
      index=(int)MathMax(0,MathMin(count-1,index));
      return((ulong)sorted[index]);
     }

   ulong Minimum(const ulong &source[],const int count) const
     {
      if(count<=0) return(0);
      ulong value=source[0];
      for(int i=1;i<count;i++) if(source[i]<value) value=source[i];
      return(value);
     }

   ulong Maximum(const ulong &source[],const int count) const
     {
      if(count<=0) return(0);
      ulong value=source[0];
      for(int i=1;i<count;i++) if(source[i]>value) value=source[i];
      return(value);
     }

public:
                     CExecutionLatencyProfiler(void)
     {
      m_tickHead=0;
      m_tickCount=0;
      m_orderHead=0;
      m_orderCount=0;
      m_tickTotal=0;
      m_orderTotal=0;
     }

   // Called once by the OnTick wrapper, including all early-return paths.
   // GetMicrosecondCount measures local terminal elapsed time, not network one-way latency.
   void RecordTick(const ulong elapsedUs)
     {
      m_tickSamples[m_tickHead]=elapsedUs;
      m_tickHead=(m_tickHead+1)%AX_LATENCY_SAMPLE_CAPACITY;
      if(m_tickCount<AX_LATENCY_SAMPLE_CAPACITY) m_tickCount++;
      m_tickTotal++;
     }

   // Measures the complete synchronous CExecutionEngine call, including broker wait/retries.
   void RecordOrderCall(const ulong elapsedUs)
     {
      m_orderSamples[m_orderHead]=elapsedUs;
      m_orderHead=(m_orderHead+1)%AX_LATENCY_SAMPLE_CAPACITY;
      if(m_orderCount<AX_LATENCY_SAMPLE_CAPACITY) m_orderCount++;
      m_orderTotal++;
     }

   // Reporting is intentionally outside OnTick and OnTradeTransaction.
   void Report(void) const
     {
      if(m_tickCount>0)
         PrintFormat("AX LATENCY | OnTick samples=%I64u window=%d min=%I64u us p50=%I64u us p95=%I64u us p99=%I64u us max=%I64u us",
                     m_tickTotal,m_tickCount,Minimum(m_tickSamples,m_tickCount),
                     Percentile(m_tickSamples,m_tickCount,0.50),
                     Percentile(m_tickSamples,m_tickCount,0.95),
                     Percentile(m_tickSamples,m_tickCount,0.99),
                     Maximum(m_tickSamples,m_tickCount));
      else
         Print("AX LATENCY | OnTick: no samples recorded.");

      if(m_orderCount>0)
         PrintFormat("AX LATENCY | CExecutionEngine call samples=%I64u window=%d min=%I64u us p50=%I64u us p95=%I64u us p99=%I64u us max=%I64u us",
                     m_orderTotal,m_orderCount,Minimum(m_orderSamples,m_orderCount),
                     Percentile(m_orderSamples,m_orderCount,0.50),
                     Percentile(m_orderSamples,m_orderCount,0.95),
                     Percentile(m_orderSamples,m_orderCount,0.99),
                     Maximum(m_orderSamples,m_orderCount));
      else
         Print("AX LATENCY | CExecutionEngine call: no samples recorded.");

      Print("AX LATENCY | Percentiles cover the most recent 256 samples per stream. Values are local terminal elapsed time, not exchange or one-way network latency.");
     }
  };

#endif // AX_EXECUTION_LATENCY_PROFILER_MQH
