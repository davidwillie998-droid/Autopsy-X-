//+------------------------------------------------------------------+
//|                                                  TradeAutopsy.mqh|
//|  Trade Autopsy (spec section 17) - every closed trade recorded,   |
//|  classified, and written to a CSV log for offline analysis.       |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_TRADEAUTOPSY_MQH
#define AX_TRADEAUTOPSY_MQH
#include "Defs.mqh"

#define AX_AUTOPSY_MAX_MEMORY 5000

class CTradeAutopsy
  {
private:
   int               m_fileHandle;
   string            m_fileName;
   int               m_digits;
   SAxTradeRecord    m_records[];
   int               m_count;

   void              WriteHeaderIfNew(void)
     {
      if(FileSize(m_fileHandle)>0) return;
      FileWrite(m_fileHandle,
                "Ticket","EntryTime","ExitTime","Direction","EntryPrice","ExitPrice","Lots",
                "SpreadAtEntry","SlippagePts","HoldSeconds","BuyScore","SellScore","Confidence",
                "Regime","EntryReason","ExitReason","MFE","MAE","GrossProfit","Commission","Swap",
                "NetProfit","Classification","FlipSeq","IsPartial");
     }

public:
                     CTradeAutopsy(void) { m_fileHandle=INVALID_HANDLE; m_count=0; }

   bool              Init(const string eaName,const string symbol)
     {
      m_digits = (int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
      m_fileName = StringFormat("%s_%s_TradeAutopsy.csv",eaName,symbol);
      m_fileHandle = FileOpen(m_fileName,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_SHARE_READ,',');
      if(m_fileHandle==INVALID_HANDLE) return(false);
      FileSeek(m_fileHandle,0,SEEK_END);
      WriteHeaderIfNew();
      ArrayResize(m_records,0);
      m_count=0;
      return(true);
     }

   void              Deinit(void)
     {
      if(m_fileHandle!=INVALID_HANDLE) { FileClose(m_fileHandle); m_fileHandle=INVALID_HANDLE; }
     }

   //--- rule-based post-trade classification (spec section 17) ---
   ENUM_AX_TRADE_CLASS Classify(const SAxTradeRecord &rec) const
     {
      if(rec.exitReason==AX_EXIT_RISK_SHUTDOWN) return(AX_CLASS_RISK_SHUTDOWN);
      if(rec.exitReason==AX_EXIT_SPREAD_ABNORMAL) return(AX_CLASS_SPREAD_FAILURE);
      if(MathAbs(rec.slippagePts) > 25) return(AX_CLASS_SLIPPAGE_FAILURE);

      if(rec.flipSeq>0)
         return((rec.netProfit>0) ? AX_CLASS_CORRECT_FLIP : AX_CLASS_FALSE_FLIP);

      if(rec.exitReason==AX_EXIT_TP) return(AX_CLASS_TAKE_PROFIT);
      if(rec.exitReason==AX_EXIT_SL)
        {
         // stopped out almost immediately with negligible favorable excursion -> late/bad entry
         if(rec.mfe < MathAbs(rec.mae)*0.15 && rec.holdSeconds < 60) return(AX_CLASS_LATE_ENTRY);
         return(AX_CLASS_STOP_LOSS);
        }

      if(rec.exitReason==AX_EXIT_MOMENTUM_COLLAPSE || rec.exitReason==AX_EXIT_MICROSTRUCTURE_REVERSAL)
        {
         if(rec.netProfit>0 && rec.mfe>0 && rec.netProfit < rec.mfe*0.35) return(AX_CLASS_PREMATURE_EXIT);
         if(rec.netProfit<=0 && rec.mfe<=0) return(AX_CLASS_MOMENTUM_FAILURE);
         if(StringFind(rec.entryReason,"BREAKOUT")>=0 && rec.netProfit<=0) return(AX_CLASS_FALSE_BREAKOUT);
         if(StringFind(rec.entryReason,"LIQUIDITY")>=0 && rec.netProfit<=0) return(AX_CLASS_LIQUIDITY_TRAP);
         return(rec.netProfit>0 ? AX_CLASS_CORRECT_MOMENTUM : AX_CLASS_MOMENTUM_FAILURE);
        }

      if(rec.exitReason==AX_EXIT_OPPOSITE_SIGNAL)
        {
         if(StringFind(rec.entryReason,"LIQUIDITY")>=0 && rec.netProfit<=0) return(AX_CLASS_LIQUIDITY_TRAP);
         return(rec.netProfit>0 ? AX_CLASS_CORRECT_MOMENTUM : AX_CLASS_MOMENTUM_FAILURE);
        }

      return(rec.netProfit>=0 ? AX_CLASS_CORRECT_MOMENTUM : AX_CLASS_MOMENTUM_FAILURE);
     }

   //--- record + persist a completed trade; returns the assigned classification ---
   ENUM_AX_TRADE_CLASS RecordTrade(SAxTradeRecord &rec)
     {
      rec.tradeClass = Classify(rec);

      if(m_count<AX_AUTOPSY_MAX_MEMORY)
        {
         ArrayResize(m_records,m_count+1);
         m_records[m_count] = rec;
         m_count++;
        }
      else
        {
         // ring-shift memory buffer once capacity is reached; file remains the full record
         for(int i=1;i<AX_AUTOPSY_MAX_MEMORY;i++) m_records[i-1]=m_records[i];
         m_records[AX_AUTOPSY_MAX_MEMORY-1]=rec;
        }

      if(m_fileHandle!=INVALID_HANDLE)
        {
         FileWrite(m_fileHandle,
                   rec.ticket,TimeToString(rec.entryTime,TIME_DATE|TIME_SECONDS),
                   TimeToString(rec.exitTime,TIME_DATE|TIME_SECONDS),AxDirToString(rec.direction),
                   DoubleToString(rec.entryPrice,m_digits),DoubleToString(rec.exitPrice,m_digits),
                   DoubleToString(rec.lots,2),DoubleToString(rec.spreadAtEntry,1),
                   DoubleToString(rec.slippagePts,1),rec.holdSeconds,
                   DoubleToString(rec.buyScore,1),DoubleToString(rec.sellScore,1),
                   DoubleToString(rec.confidence,1),AxRegimeToString(rec.regime),rec.entryReason,
                   AxExitReasonToString(rec.exitReason),DoubleToString(rec.mfe,2),DoubleToString(rec.mae,2),
                   DoubleToString(rec.grossProfit,2),DoubleToString(rec.commission,2),
                   DoubleToString(rec.swap,2),DoubleToString(rec.netProfit,2),
                   AxTradeClassToString(rec.tradeClass),rec.flipSeq,rec.isPartial);
         FileFlush(m_fileHandle);
        }

      return(rec.tradeClass);
     }

   int               Count(void) const { return(m_count); }
   bool              GetRecord(const int i,SAxTradeRecord &out) const
     {
      if(i<0 || i>=m_count) return(false);
      out = m_records[i];
      return(true);
     }
   string            FileName(void) const { return(m_fileName); }
  };
//+------------------------------------------------------------------+
#endif // AX_TRADEAUTOPSY_MQH
