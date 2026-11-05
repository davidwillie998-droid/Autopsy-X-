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
   string            m_legacyFileName;
   int               m_digits;
   SAxTradeRecord    m_records[];
   int               m_count;
   double            m_riskNetProfit[];
   double            m_riskMultiple[];
   bool              m_riskPartial[];
   string            m_riskProvenance[];
   int               m_riskCount;

   void              AddRiskHistory(const double netProfit,const double rMultiple,
                                    const bool isPartial,const string provenance)
     {
      if(m_riskCount>=AX_AUTOPSY_MAX_MEMORY)
        {
         for(int i=1;i<AX_AUTOPSY_MAX_MEMORY;i++)
           {
            m_riskNetProfit[i-1]=m_riskNetProfit[i];
            m_riskMultiple[i-1]=m_riskMultiple[i];
            m_riskPartial[i-1]=m_riskPartial[i];
            m_riskProvenance[i-1]=m_riskProvenance[i];
           }
         m_riskCount=AX_AUTOPSY_MAX_MEMORY-1;
        }
      ArrayResize(m_riskNetProfit,m_riskCount+1);
      ArrayResize(m_riskMultiple,m_riskCount+1);
      ArrayResize(m_riskPartial,m_riskCount+1);
      ArrayResize(m_riskProvenance,m_riskCount+1);
      m_riskNetProfit[m_riskCount]=netProfit;
      m_riskMultiple[m_riskCount]=rMultiple;
      m_riskPartial[m_riskCount]=isPartial;
      m_riskProvenance[m_riskCount]=provenance;
      m_riskCount++;
     }

   bool              ReadRiskHistoryFile(const string sourceFile,const bool legacyV3)
     {
      int handle=FileOpen(sourceFile,FILE_READ|FILE_CSV|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE,',');
      if(handle==INVALID_HANDLE) return(true); // absent legacy file is not a startup failure
      string fields[44];
      bool header=true;
      while(!FileIsEnding(handle))
        {
         bool rowRead=false;
         for(int f=0;f<44;f++)
           {
            if(FileIsEnding(handle) && f==0) { rowRead=false; break; }
            fields[f]=FileReadString(handle);
            rowRead=true;
           }
         if(!rowRead) break;
         if(header) { header=false; continue; }

         double rMultiple=StringToDouble(fields[25]);
         // v3 used zero for both unavailable R and true breakeven. Treat those
         // ambiguous legacy zeros as unavailable. v4 has an explicit sentinel.
         if(legacyV3 && rMultiple==0.0) rMultiple=EMPTY_VALUE;
         AddRiskHistory(StringToDouble(fields[24]),rMultiple,
                        (StringToInteger(fields[28])!=0),fields[42]);
        }
      FileClose(handle);
      return(true);
     }

   bool              LoadRiskHistory(void)
     {
      m_riskCount=0;
      ArrayResize(m_riskNetProfit,0);
      ArrayResize(m_riskMultiple,0);
      ArrayResize(m_riskPartial,0);
      ArrayResize(m_riskProvenance,0);
      if(!ReadRiskHistoryFile(m_legacyFileName,true)) return(false);
      return(ReadRiskHistoryFile(m_fileName,false));
     }

public:
                     CTradeAutopsy(void) { m_fileHandle=INVALID_HANDLE; m_count=0; m_riskCount=0; }

   bool              Init(const string eaName,const string symbol)
     {
      m_digits = (int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
      //--- v4 retains the 44-column schema and gives R-multiple an explicit EMPTY_VALUE sentinel.
      //--- v3 rows are read as legacy history, but ambiguous zero-R rows are excluded safely.
      m_fileName = StringFormat("%s_%s_TradeAutopsy_v4.csv",eaName,symbol);
      m_legacyFileName = StringFormat("%s_%s_TradeAutopsy_v3.csv",eaName,symbol);
      m_fileHandle = FileOpen(m_fileName,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_SHARE_READ,',');
      if(m_fileHandle==INVALID_HANDLE) return(false);
      FileSeek(m_fileHandle,0,SEEK_END);
      WriteHeaderIfNew();
      ArrayResize(m_records,0);
      m_count=0;
      if(!LoadRiskHistory())
        {
         FileClose(m_fileHandle); m_fileHandle=INVALID_HANDLE;
         return(false);
        }
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

   //--- record + persist a completed trade; returns the assigned classification. Provenance is    ---
   //--- ALWAYS (re)detected here from real account/terminal state at the moment of journaling,     ---
   //--- regardless of what the caller may or may not have already set - this is the authoritative   ---
   //--- point a record's dataset membership is decided, never left to caller diligence. ---
   ENUM_AX_TRADE_CLASS RecordTrade(SAxTradeRecord &rec)
     {
      rec.tradeClass = Classify(rec);
      rec.provenance = AxDetectProvenance();
      if(rec.dealIdOut>0 && rec.positionIdentifier>0 && rec.dealIdOut<=LastAccountedDealTicket(rec.positionIdentifier))
         return(rec.tradeClass);

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
         uint writeResult=FileWrite(m_fileHandle,
                   rec.setupId,rec.ticket,rec.dealIdIn,rec.dealIdOut,
                   TimeToString(rec.entryTime,TIME_DATE|TIME_SECONDS),
                   TimeToString(rec.exitTime,TIME_DATE|TIME_SECONDS),AxDirToString(rec.direction),
                   DoubleToString(rec.entryPrice,m_digits),DoubleToString(rec.exitPrice,m_digits),
                   DoubleToString(rec.lots,2),DoubleToString(rec.spreadAtEntry,1),
                   DoubleToString(rec.slippagePts,1),rec.holdSeconds,
                   DoubleToString(rec.buyScore,1),DoubleToString(rec.sellScore,1),
                   DoubleToString(rec.confidence,1),AxRegimeToString(rec.regime),rec.entryReason,
                   AxExitReasonToString(rec.exitReason),DoubleToString(rec.mfe,2),DoubleToString(rec.mae,2),
                   DoubleToString(rec.grossProfit,2),DoubleToString(rec.commission,2),
                   DoubleToString(rec.swap,2),DoubleToString(rec.netProfit,2),DoubleToString(rec.rMultiple,3),
                   AxTradeClassToString(rec.tradeClass),rec.flipSeq,rec.isPartial,
                   AxCapitalStateToString(rec.afeCapitalState),DoubleToString(rec.afeRiskOfRuinPct,1),
                   DoubleToString(rec.afeExpectedValueR,2),DoubleToString(rec.afeWinProbability,3),
                   DoubleToString(rec.afeRiskMultiplier,2),DoubleToString(rec.impactCostPct,3),
                   rec.vwapStateAtEntry,rec.vpMacdStateAtEntry,rec.orderFlowStateAtEntry,
                   rec.structureStateAtEntry,rec.liquidityStateAtEntry,rec.newsStateAtEntry,
                   rec.sessionAtEntry,AxProvenanceToString(rec.provenance),rec.positionIdentifier);
         FileFlush(m_fileHandle);
        }

      AddRiskHistory(rec.netProfit,rec.rMultiple,rec.isPartial,AxProvenanceToString(rec.provenance));
      return(rec.tradeClass);
     }

   int               RiskHistoryCount(void) const { return(m_riskCount); }
   bool              GetRiskHistoryRecord(const int i,double &netProfit,double &rMultiple,
                                           bool &isPartial,string &provenance) const
     {
      if(i<0 || i>=m_riskCount) return(false);
      netProfit=m_riskNetProfit[i];
      rMultiple=m_riskMultiple[i];
      isPartial=m_riskPartial[i];
      provenance=m_riskProvenance[i];
      return(true);
     }

   int               Count(void) const { return(m_count); }
   bool              GetRecord(const int i,SAxTradeRecord &out) const
     {
      if(i<0 || i>=m_count) return(false);
      out = m_records[i];
      return(true);
     }
   string            FileName(void) const { return(m_fileName); }

   //--- adaptive learning dataset access (spec section 29). Callers doing adaptive tuning/learning ---
   //--- go through this rather than reading records directly, so historical/forward-demo/live data ---
   //--- is never silently mixed, and partial (scale-out) slices - which are not standalone trade    ---
   //--- outcomes - are never included in a learning sample. ---
   int               GetDatasetRecords(const ENUM_AX_DATASET_PROVENANCE provenance,SAxTradeRecord &out[]) const
     {
      int found=0;
      ArrayResize(out,0);
      for(int i=0;i<m_count;i++)
        {
         if(m_records[i].isPartial) continue;
         if(m_records[i].provenance!=provenance) continue;
         ArrayResize(out,found+1);
         out[found]=m_records[i];
         found++;
        }
      return(found);
     }
  };
//+------------------------------------------------------------------+
#endif // AX_TRADEAUTOPSY_MQH
