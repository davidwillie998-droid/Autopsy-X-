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
     }

   bool Init(const string symbol,const ulong magic)
     {
      Deinit();
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
     }
  };

#endif // AX_IQ200_TELEMETRY_MQH
