//+------------------------------------------------------------------+
//|                                      MarketSnapshotRecorder.mqh  |
//|  Buffered, timestamped market/decision snapshots for MT5 replay. |
//|  Observational only: never participates in entry or risk gates.   |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_MARKETSNAPSHOTRECORDER_MQH
#define AX_MARKETSNAPSHOTRECORDER_MQH
#include "Defs.mqh"

#define AX_MARKET_SNAPSHOT_CAPACITY 4096

struct SAxMarketSnapshotRow
  {
   ulong       sequence;
   MqlTick     tick;
   SAxScore    score;
   int         engineState;
   bool        pending;
   bool        hasPosition;
   int         positionDirection;
   double      equity;
   double      balance;
   double      freeMargin;
   double      marginLevel;
   ulong       droppedBefore;
  };

class CMarketSnapshotRecorder
  {
private:
   int                  m_file;
   bool                 m_enabled;
   bool                 m_ready;
   string               m_symbol;
   string               m_fileName;
   long                 m_magic;
   ulong                m_sequence;
   ulong                m_dropped;
   int                  m_head;
   int                  m_count;
   int                  m_digits;
   double               m_point;
   double               m_tickSize;
   double               m_tickValue;
   double               m_volumeMin;
   double               m_volumeMax;
   double               m_volumeStep;
   SAxMarketSnapshotRow m_rows[AX_MARKET_SNAPSHOT_CAPACITY];

   bool WriteHeader(void)
     {
      uint written=FileWrite(m_file,
         "schema_version","sequence","symbol","magic","time_msc",
         "bid","ask","last","tick_volume","real_volume","flags",
         "digits","point","tick_size","tick_value",
         "volume_min","volume_max","volume_step","spread_points",
         "buy_score","sell_score","confidence","action","regime","score_time",
         "engine_state","pending_entry","has_position","position_direction",
         "equity","balance","free_margin","margin_level","dropped_before");
      return(written>0);
     }

public:
                     CMarketSnapshotRecorder(void)
     {
      m_file=INVALID_HANDLE;
      m_enabled=false;
      m_ready=false;
      m_magic=0;
      m_sequence=0;
      m_dropped=0;
      m_head=0;
      m_count=0;
      m_digits=0;
      m_point=0.0;
      m_tickSize=0.0;
      m_tickValue=0.0;
      m_volumeMin=0.0;
      m_volumeMax=0.0;
      m_volumeStep=0.0;
     }

   bool Init(const string symbol,const long magic,const bool enabled)
     {
      m_symbol=symbol;
      m_magic=magic;
      m_enabled=enabled;
      if(!m_enabled) return(true);

      m_digits=(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
      m_point=SymbolInfoDouble(symbol,SYMBOL_POINT);
      m_tickSize=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_SIZE);
      m_tickValue=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_VALUE);
      m_volumeMin=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
      m_volumeMax=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX);
      m_volumeStep=SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
      m_fileName=StringFormat("AutopsyX_MarketSnapshots_%s_%I64d.csv",symbol,magic);

      m_file=FileOpen(m_fileName,FILE_READ|FILE_WRITE|FILE_CSV|FILE_SHARE_READ|FILE_ANSI,',');
      if(m_file==INVALID_HANDLE)
        {
         PrintFormat("AUTOPSY X SNAPSHOT: cannot open %s (error %d). Snapshot export disabled; trading logic unchanged.",
                     m_fileName,GetLastError());
         m_enabled=false;
         return(false);
        }

      if(FileSize(m_file)==0 && !WriteHeader())
        {
         PrintFormat("AUTOPSY X SNAPSHOT: header write failed for %s (error %d).",m_fileName,GetLastError());
         FileClose(m_file);
         m_file=INVALID_HANDLE;
         m_enabled=false;
         return(false);
        }
      FileSeek(m_file,0,SEEK_END);
      m_ready=true;
      PrintFormat("AUTOPSY X SNAPSHOT: recording enabled, file=MQL5/Files/%s, capacity=%d rows.",
                  m_fileName,AX_MARKET_SNAPSHOT_CAPACITY);
      return(true);
     }

   bool Record(const MqlTick &tick,const SAxScore &score,const int engineState,
               const bool pending,const bool hasPosition,const int positionDirection,
               const double equity,const double balance,const double freeMargin,
               const double marginLevel)
     {
      if(!m_enabled || !m_ready) return(false);
      if(m_count>=AX_MARKET_SNAPSHOT_CAPACITY)
        {
         m_dropped++;
         return(false);
        }

      int tail=(m_head+m_count)%AX_MARKET_SNAPSHOT_CAPACITY;
      m_rows[tail].sequence=m_sequence++;
      m_rows[tail].tick=tick;
      m_rows[tail].score=score;
      m_rows[tail].engineState=engineState;
      m_rows[tail].pending=pending;
      m_rows[tail].hasPosition=hasPosition;
      m_rows[tail].positionDirection=positionDirection;
      m_rows[tail].equity=equity;
      m_rows[tail].balance=balance;
      m_rows[tail].freeMargin=freeMargin;
      m_rows[tail].marginLevel=marginLevel;
      m_rows[tail].droppedBefore=m_dropped;
      m_count++;
      return(true);
     }

   int Flush(const int maxRows=0)
     {
      if(!m_ready || m_file==INVALID_HANDLE) return(0);
      int limit=(maxRows<=0)?m_count:MathMin(maxRows,m_count);
      int written=0;
      while(written<limit && m_count>0)
        {
         SAxMarketSnapshotRow row=m_rows[m_head];
         double spreadPts=(m_point>0.0)?(row.tick.ask-row.tick.bid)/m_point:0.0;
         uint result=FileWrite(m_file,
            1,row.sequence,m_symbol,m_magic,row.tick.time_msc,
            row.tick.bid,row.tick.ask,row.tick.last,row.tick.volume,row.tick.volume_real,row.tick.flags,
            m_digits,m_point,m_tickSize,m_tickValue,
            m_volumeMin,m_volumeMax,m_volumeStep,spreadPts,
            row.score.buyScore,row.score.sellScore,row.score.confidence,
            (int)row.score.action,(int)row.score.regime,(long)row.score.time,
            row.engineState,(int)row.pending,(int)row.hasPosition,row.positionDirection,
            row.equity,row.balance,row.freeMargin,row.marginLevel,row.droppedBefore);
         if(result==0)
           {
            PrintFormat("AUTOPSY X SNAPSHOT: write failed (error %d); %d buffered rows retained for retry.",
                        GetLastError(),m_count);
            break;
           }
         m_head=(m_head+1)%AX_MARKET_SNAPSHOT_CAPACITY;
         m_count--;
         written++;
        }
      if(written>0) FileFlush(m_file);
      return(written);
     }

   void Deinit(void)
     {
      if(m_ready && m_file!=INVALID_HANDLE)
        {
         Flush(0);
         FileClose(m_file);
        }
      m_file=INVALID_HANDLE;
      m_ready=false;
     }

   ulong DroppedRows(void) const { return(m_dropped); }
   int BufferedRows(void) const { return(m_count); }
   string FileName(void) const { return(m_fileName); }
  };

#endif // AX_MARKETSNAPSHOTRECORDER_MQH
