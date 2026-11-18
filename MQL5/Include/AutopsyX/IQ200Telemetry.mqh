//+------------------------------------------------------------------+
//|                                             IQ200Telemetry.mqh    |
//| Versioned, bounded, analysis-only execution telemetry.           |
//| No order, sizing, stop, or reservation authority.                 |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_IQ200_TELEMETRY_MQH
#define AX_IQ200_TELEMETRY_MQH

#define AX_IQ200_SCHEMA_VERSION 1
#define AX_IQ200_QUEUE_CAPACITY 256

enum ENUM_AX_IQ200_EVENT
  {
   AX_IQ200_DECISION=0,
   AX_IQ200_ROUTE_PLAN=1,
   AX_IQ200_ORDER_SUBMITTED=2,
   AX_IQ200_BROKER_ACK=3,
   AX_IQ200_DEAL_PARTIAL=4,
   AX_IQ200_DEAL_FILLED=5,
   AX_IQ200_ORDER_CANCEL_REQUESTED=6,
   AX_IQ200_ORDER_CANCELLED=7,
   AX_IQ200_ORDER_REJECTED=8,
   AX_IQ200_ORDER_EXPIRED=9,
   AX_IQ200_ORDER_AMBIGUOUS=10,
   AX_IQ200_POSITION_CLOSED=11,
   AX_IQ200_MARKOUT=12,
   AX_IQ200_QUEUE_OVERFLOW=13
  };

struct SAxIQ200Event
  {
   int      schemaVersion;
   ulong    eventId;
   int      eventType;
   long     eventTimeMsc;
   int      timeSource;       // 0=terminal, 1=broker, 2=estimated
   string   sessionId;
   string   decisionId;
   string   intentId;
   string   campaignId;
   ulong    orderTicket;
   ulong    dealTicket;
   ulong    positionIdentifier;
   string   symbol;
   ulong    magic;
   int      direction;        // -1 sell, 0 none, +1 buy
   int      orderType;
   double   requestedVolume;
   double   confirmedVolume;
   double   requestedPrice;
   double   fillPrice;
   double   bid;
   double   ask;
   double   pointSize;
   double   tickSize;
   double   atrPoints;
   double   spreadPercentile;
   double   slippagePoints;
   long     localElapsedUs;   // terminal-local elapsed time, not network latency
   uint     retcode;
   uint     retcodeExternal;
   int      reasonCode;
   uint     featureMask;
   string   modelVersion;
   double   reservedRiskAmount; // observation only
   int      markoutHorizonMs;
   double   markoutPoints;
   uint     missingMask;
  };

class CAxIQ200Telemetry
  {
private:
   SAxIQ200Event m_queue[AX_IQ200_QUEUE_CAPACITY];
   int      m_head;
   int      m_tail;
   int      m_count;
   int      m_handle;
   string   m_fileName;
   string   m_sessionId;
   ulong    m_nextEventId;
   ulong    m_droppedEvents;
   ulong    m_rowsWritten;
   bool     m_healthy;
   bool     m_overflowPending;
   ulong    m_seenDealTickets[512];
   int      m_seenDealCount;
   int      m_seenDealNext;
   ulong    m_orderTickets[256];
   string   m_orderDecisionIds[256];
   int      m_orderMapCount;
   SAxIQ200Event m_markoutEvents[128];
   ulong    m_markoutDueMs[128];
   int      m_markoutHorizons[128];
   int      m_markoutCount;
   ulong    m_markoutDropped;
   int      m_orderMapNext;

   string Quote(const string value) const
     {
      string escaped=value;
      StringReplace(escaped,"\"","\"\"");
      return("\""+escaped+"\"");
     }

   string EventName(const int eventType) const
     {
      switch(eventType)
        {
         case AX_IQ200_DECISION: return("DECISION");
         case AX_IQ200_ROUTE_PLAN: return("ROUTE_PLAN");
         case AX_IQ200_ORDER_SUBMITTED: return("ORDER_SUBMITTED");
         case AX_IQ200_BROKER_ACK: return("BROKER_ACK");
         case AX_IQ200_DEAL_PARTIAL: return("DEAL_PARTIAL");
         case AX_IQ200_DEAL_FILLED: return("DEAL_FILLED");
         case AX_IQ200_ORDER_CANCEL_REQUESTED: return("ORDER_CANCEL_REQUESTED");
         case AX_IQ200_ORDER_CANCELLED: return("ORDER_CANCELLED");
         case AX_IQ200_ORDER_REJECTED: return("ORDER_REJECTED");
         case AX_IQ200_ORDER_EXPIRED: return("ORDER_EXPIRED");
         case AX_IQ200_ORDER_AMBIGUOUS: return("ORDER_AMBIGUOUS");
         case AX_IQ200_POSITION_CLOSED: return("POSITION_CLOSED");
         case AX_IQ200_MARKOUT: return("MARKOUT");
         case AX_IQ200_QUEUE_OVERFLOW: return("QUEUE_OVERFLOW");
        }
      return("UNKNOWN");
     }

   string Header(void) const
     {
      return("schema_version,event_id,event_type,event_time_msc,time_source,session_id,decision_id,intent_id,campaign_id,order_ticket,deal_ticket,position_identifier,symbol,magic,direction,order_type,requested_volume,confirmed_volume,requested_price,fill_price,bid,ask,point_size,tick_size,atr_points,spread_percentile,slippage_points,local_elapsed_us,retcode,retcode_external,reason_code,feature_mask,model_version,reserved_risk_amount,markout_horizon_ms,markout_points,missing_mask");
     }

   string Serialize(const SAxIQ200Event &e) const
     {
      return(StringFormat("%d,%I64u,%s,%I64d,%d,%s,%s,%s,%s,%I64u,%I64u,%I64u,%s,%I64u,%d,%d,%.8f,%.8f,%.10f,%.10f,%.10f,%.10f,%.10f,%.10f,%.3f,%.3f,%.3f,%I64d,%u,%u,%d,%u,%s,%.2f,%d,%.3f,%u\r\n",
                          e.schemaVersion,e.eventId,EventName(e.eventType),e.eventTimeMsc,e.timeSource,
                          Quote(e.sessionId),Quote(e.decisionId),Quote(e.intentId),Quote(e.campaignId),
                          e.orderTicket,e.dealTicket,e.positionIdentifier,Quote(e.symbol),e.magic,
                          e.direction,e.orderType,e.requestedVolume,e.confirmedVolume,e.requestedPrice,
                          e.fillPrice,e.bid,e.ask,e.pointSize,e.tickSize,e.atrPoints,e.spreadPercentile,
                          e.slippagePoints,e.localElapsedUs,e.retcode,e.retcodeExternal,e.reasonCode,
                          e.featureMask,Quote(e.modelVersion),e.reservedRiskAmount,e.markoutHorizonMs,
                          e.markoutPoints,e.missingMask));
     }

   void ResetEvent(SAxIQ200Event &e)
     {
      e.schemaVersion=AX_IQ200_SCHEMA_VERSION;
      e.eventId=0;
      e.eventType=AX_IQ200_DECISION;
      e.eventTimeMsc=0;
      e.timeSource=0;
      e.sessionId="";
      e.decisionId="";
      e.intentId="";
      e.campaignId="";
      e.orderTicket=0;
      e.dealTicket=0;
      e.positionIdentifier=0;
      e.symbol="";
      e.magic=0;
      e.direction=0;
      e.orderType=0;
      e.requestedVolume=0.0;
      e.confirmedVolume=0.0;
      e.requestedPrice=0.0;
      e.fillPrice=0.0;
      e.bid=0.0;
      e.ask=0.0;
      e.pointSize=0.0;
      e.tickSize=0.0;
      e.atrPoints=0.0;
      e.spreadPercentile=0.0;
      e.slippagePoints=0.0;
      e.localElapsedUs=0;
      e.retcode=0;
      e.retcodeExternal=0;
      e.reasonCode=0;
      e.featureMask=0;
      e.modelVersion="";
      e.reservedRiskAmount=0.0;
      e.markoutHorizonMs=0;
      e.markoutPoints=0.0;
      e.missingMask=0;
     }

   bool WriteLine(const string line)
     {
      if(m_handle==INVALID_HANDLE || !m_healthy) return(false);
      if(!FileSeek(m_handle,0,SEEK_END)) return(false);
      ulong before=FileSize(m_handle);
      uint expected=(uint)StringLen(line);
      uint written=FileWriteString(m_handle,line);
      FileFlush(m_handle);
      ulong after=FileSize(m_handle);
      return(written==expected && after>before);
     }

   void LatchFailure(const string reason)
     {
      m_healthy=false;
      PrintFormat("AX IQ200 TELEMETRY: persistence latched unhealthy (%s). Trading authority is unchanged.",reason);
     }

public:
                     CAxIQ200Telemetry(void)
     {
      m_head=0;
      m_tail=0;
      m_count=0;
      m_handle=INVALID_HANDLE;
      m_fileName="";
      m_sessionId="";
      m_nextEventId=1;
      m_droppedEvents=0;
      m_rowsWritten=0;
      m_healthy=false;
      m_overflowPending=false;
      m_seenDealCount=0;
      m_seenDealNext=0;
      for(int i=0;i<512;i++) m_seenDealTickets[i]=0;
      m_orderMapCount=0;
      m_orderMapNext=0;
      m_markoutCount=0;
      m_markoutDropped=0;
      for(int i=0;i<256;i++)
        {
         m_orderTickets[i]=0;
         m_orderDecisionIds[i]="";
        }
     }

   bool Init(const string symbol,const ulong magic)
     {
      Deinit();
      m_seenDealCount=0;
      m_seenDealNext=0;
      for(int i=0;i<512;i++) m_seenDealTickets[i]=0;
      m_orderMapCount=0;
      m_orderMapNext=0;
      m_markoutCount=0;
      m_markoutDropped=0;
      for(int i=0;i<256;i++)
        {
         m_orderTickets[i]=0;
         m_orderDecisionIds[i]="";
        }
      if(StringLen(symbol)==0 || magic==0) return(false);
      m_sessionId=StringFormat("%I64u_%I64d_%I64u",(ulong)ChartID(),(long)TimeLocal(),(ulong)GetTickCount());
      m_fileName=StringFormat("AX_IQ200_%s_%I64u.csv",symbol,magic);
      m_handle=FileOpen(m_fileName,FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
      if(m_handle==INVALID_HANDLE) return(false);
      if(FileSize(m_handle)==0)
        {
         string header=Header()+"\r\n";
         uint expected=(uint)StringLen(header);
         uint written=FileWriteString(m_handle,header);
         FileFlush(m_handle);
         if(written!=expected || FileSize(m_handle)!=written)
           {
            FileClose(m_handle);
            m_handle=INVALID_HANDLE;
            return(false);
           }
        }
      else
        {
         if(!FileSeek(m_handle,0,SEEK_SET))
           {
            FileClose(m_handle);
            m_handle=INVALID_HANDLE;
            return(false);
           }
         string existing=FileReadString(m_handle);
         if(existing!=Header())
           {
            FileClose(m_handle);
            m_handle=INVALID_HANDLE;
            return(false);
           }
        }
      if(!FileSeek(m_handle,0,SEEK_END))
        {
         FileClose(m_handle);
         m_handle=INVALID_HANDLE;
         return(false);
        }
      m_healthy=true;
      return(true);
     }

   void NewEvent(SAxIQ200Event &event,const int eventType,const string symbol,const ulong magic)
     {
      ResetEvent(event);
      event.eventType=eventType;
      event.symbol=symbol;
      event.magic=magic;
      event.eventTimeMsc=(long)TimeLocal()*1000;
      event.timeSource=0;
      event.sessionId=m_sessionId;
     }

   bool Enqueue(const SAxIQ200Event &source)
     {
      if(!m_healthy || m_count>=AX_IQ200_QUEUE_CAPACITY)
        {
         m_droppedEvents++;
         m_overflowPending=true;
         return(false);
        }
      SAxIQ200Event event=source;
      event.schemaVersion=AX_IQ200_SCHEMA_VERSION;
      event.eventId=m_nextEventId++;
      if(event.eventTimeMsc<=0)
         event.eventTimeMsc=(long)TimeLocal()*1000;
      if(StringLen(event.sessionId)==0) event.sessionId=m_sessionId;
      if(event.direction< -1 || event.direction>1 ||
         event.eventType<AX_IQ200_DECISION || event.eventType>AX_IQ200_QUEUE_OVERFLOW ||
         !MathIsValidNumber(event.requestedVolume) || event.requestedVolume<0.0 ||
         !MathIsValidNumber(event.confirmedVolume) || event.confirmedVolume<0.0 ||
         !MathIsValidNumber(event.bid) || !MathIsValidNumber(event.ask) ||
         !MathIsValidNumber(event.pointSize) || !MathIsValidNumber(event.tickSize))
        {
         m_droppedEvents++;
         return(false);
        }
      m_queue[m_tail]=event;
      m_tail=(m_tail+1)%AX_IQ200_QUEUE_CAPACITY;
      m_count++;
      return(true);
     }

   // Schedule three executable-side markout observations from a confirmed entry fill.
   // The scheduler is bounded and uses a monotonic terminal clock. It never sleeps or polls.
   bool ScheduleMarkouts(const SAxIQ200Event &fill)
     {
      if((fill.eventType!=AX_IQ200_DEAL_PARTIAL && fill.eventType!=AX_IQ200_DEAL_FILLED) ||
         fill.direction==0)
         return(false);
      int horizons[3];
      horizons[0]=1000;
      horizons[1]=5000;
      horizons[2]=30000;
      bool allScheduled=true;
      for(int h=0;h<3;h++)
        {
         if(m_markoutCount>=128)
           {
            m_markoutDropped++;
            allScheduled=false;
            continue;
           }
         int slot=m_markoutCount++;
         m_markoutEvents[slot]=fill;
         m_markoutHorizons[slot]=horizons[h];
         m_markoutDueMs[slot]=GetTickCount64()+(ulong)horizons[h];
        }
      return(allScheduled);
     }

   // Called from OnTimer. Markout is executable-side price movement, not realized P/L:
   // BUY is valued at bid; SELL is valued at ask. Missing quotes are retained as missing.
   int ProcessDueMarkouts(double &markoutPoints[],bool &markoutValid[])
     {
      ArrayResize(markoutPoints,0);
      ArrayResize(markoutValid,0);
      ulong now=GetTickCount64();
      int processed=0;
      for(int i=m_markoutCount-1;i>=0;i--)
        {
         if(now<m_markoutDueMs[i]) continue;
         SAxIQ200Event sample=m_markoutEvents[i];
         MqlTick tick;
         bool quoteReady=SymbolInfoTick(sample.symbol,tick) &&
                         tick.bid>0.0 && tick.ask>=tick.bid &&
                         sample.fillPrice>0.0 && sample.pointSize>0.0 &&
                         MathIsValidNumber(tick.bid) && MathIsValidNumber(tick.ask) &&
                         MathIsValidNumber(sample.fillPrice) && MathIsValidNumber(sample.pointSize);
         sample.eventType=AX_IQ200_MARKOUT;
         sample.markoutHorizonMs=m_markoutHorizons[i];
         sample.eventTimeMsc=(quoteReady && tick.time_msc>0)
                             ?(long)tick.time_msc:(long)TimeLocal()*1000;
         sample.timeSource=quoteReady?1:0;
         if(quoteReady)
           {
            sample.bid=tick.bid;
            sample.ask=tick.ask;
            double exitQuote=(sample.direction>0)?tick.bid:tick.ask;
            sample.markoutPoints=(double)sample.direction*
                                 (exitQuote-sample.fillPrice)/sample.pointSize;
           }
         else
           {
            sample.markoutPoints=0.0;
            sample.missingMask|=2;
           }
         int outputIndex=ArraySize(markoutPoints);
         ArrayResize(markoutPoints,outputIndex+1);
         ArrayResize(markoutValid,outputIndex+1);
         markoutPoints[outputIndex]=sample.markoutPoints;
         markoutValid[outputIndex]=quoteReady;
         Enqueue(sample);
         m_markoutEvents[i]=m_markoutEvents[m_markoutCount-1];
         m_markoutDueMs[i]=m_markoutDueMs[m_markoutCount-1];
         m_markoutHorizons[i]=m_markoutHorizons[m_markoutCount-1];
         m_markoutCount--;
         processed++;
        }
      return(processed);
     }

   int ProcessDueMarkouts(void)
     {
      double values[];
      bool valid[];
      return(ProcessDueMarkouts(values,valid));
     }

   // Call only from OnTimer or another controlled non-hot-path callback.
   // Never call this from OnTick or OnTradeTransaction.
   int Flush(const int maxRows=64)
     {
      if(!m_healthy || m_handle==INVALID_HANDLE || maxRows<=0) return(0);
      int writtenRows=0;
      while(m_count>0 && writtenRows<maxRows)
        {
         string line=Serialize(m_queue[m_head]);
         if(!WriteLine(line))
           {
            LatchFailure("append/flush verification failed");
            return(writtenRows);
           }
         m_head=(m_head+1)%AX_IQ200_QUEUE_CAPACITY;
         m_count--;
         m_rowsWritten++;
         writtenRows++;
        }
      if(m_overflowPending && m_count<AX_IQ200_QUEUE_CAPACITY)
        {
         SAxIQ200Event overflow;
         ResetEvent(overflow);
         overflow.eventType=AX_IQ200_QUEUE_OVERFLOW;
         overflow.reasonCode=(int)MathMin((double)m_droppedEvents,2147483647.0);
         overflow.missingMask=1;
         if(Enqueue(overflow)) m_overflowPending=false;
        }
      return(writtenRows);
     }

   // Bind broker order identifiers to the strategy-approved setup identifier.
   // This is called after CTrade returns; MT5 transaction callbacks are then correlated
   // by exact order ticket, never by symbol alone.
   void BindOrderDecision(const ulong orderTicket,const string decisionId)
     {
      if(orderTicket==0 || StringLen(decisionId)==0) return;
      for(int i=0;i<m_orderMapCount;i++)
        {
         if(m_orderTickets[i]==orderTicket)
           {
            m_orderDecisionIds[i]=decisionId;
            return;
           }
        }
      m_orderTickets[m_orderMapNext]=orderTicket;
      m_orderDecisionIds[m_orderMapNext]=decisionId;
      m_orderMapNext=(m_orderMapNext+1)%256;
      if(m_orderMapCount<256) m_orderMapCount++;
     }

   string DecisionIdForOrder(const ulong orderTicket) const
     {
      if(orderTicket==0) return("");
      for(int i=0;i<m_orderMapCount;i++)
         if(m_orderTickets[i]==orderTicket) return(m_orderDecisionIds[i]);
      return("");
     }

   // Transaction callbacks can be repeated while the terminal reconciles broker state.
   // Suppress duplicate deal tickets within this terminal session.
   bool MarkDealTicketSeen(const ulong dealTicket)
     {
      if(dealTicket==0) return(false);
      for(int i=0;i<m_seenDealCount;i++)
         if(m_seenDealTickets[i]==dealTicket) return(false);
      m_seenDealTickets[m_seenDealNext]=dealTicket;
      m_seenDealNext=(m_seenDealNext+1)%512;
      if(m_seenDealCount<512) m_seenDealCount++;
      return(true);
     }

   bool IsHealthy(void) const { return(m_healthy); }
   int PendingCount(void) const { return(m_count); }
   ulong DroppedEvents(void) const { return(m_droppedEvents); }
   int PendingMarkouts(void) const { return(m_markoutCount); }
   ulong MarkoutDropped(void) const { return(m_markoutDropped); }
   ulong RowsWritten(void) const { return(m_rowsWritten); }
   string FileName(void) const { return(m_fileName); }
   string SessionId(void) const { return(m_sessionId); }

   void Deinit(void)
     {
      if(m_handle!=INVALID_HANDLE)
        {
         FileFlush(m_handle);
         FileClose(m_handle);
        }
      m_handle=INVALID_HANDLE;
      m_healthy=false;
      m_head=0;
      m_tail=0;
      m_count=0;
      m_markoutCount=0;
     }
  };

#endif // AX_IQ200_TELEMETRY_MQH
