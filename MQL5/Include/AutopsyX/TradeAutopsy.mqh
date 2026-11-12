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
   bool              m_persistenceHealthy;

   bool              WriteHeaderIfNew(void)
     {
      if(FileSize(m_fileHandle)>0) return(true);
      uint headerWrite=FileWrite(m_fileHandle,
                "SetupId","Ticket","DealIdIn","DealIdOut","EntryTime","ExitTime","Direction","EntryPrice",
                "ExitPrice","Lots","SpreadAtEntry","SlippagePts","HoldSeconds","BuyScore","SellScore",
                "Confidence","Regime","EntryReason","ExitReason","MFE","MAE","GrossProfit","Commission","Swap",
                "NetProfit","RMultiple","Classification","FlipSeq","IsPartial",
                "AfeCapitalState","AfeRiskOfRuinPct","AfeExpectedValueR","AfeWinProbability","AfeRiskMultiplier",
                "ImpactCostPct","VWAPState","VPMACDState","OrderFlowState","StructureState","LiquidityState",
                "NewsState","Session","Provenance","PositionIdentifier");
      FileFlush(m_fileHandle);
      return(headerWrite>0 && FileSize(m_fileHandle)>0);
     }

   string            ParseCsvField(const string line,const int wantedField) const
     {
      int field=0;
      bool quoted=false;
      string value="";
      int length=StringLen(line);
      for(int i=0;i<length;i++)
        {
         ushort ch=StringGetCharacter(line,i);
         if(ch==34)
           {
            if(quoted && i+1<length && StringGetCharacter(line,i+1)==34)
              { i++; if(field==wantedField) value+=ShortToString(34); continue; }
            quoted=!quoted;
            continue;
           }
         if(ch==44 && !quoted) { field++; continue; }
         if(field==wantedField) value+=ShortToString(ch);
        }
      return(value);
     }

   bool              ParseCsvBoolean(const string value) const
     {
      string normalized=value;
      StringToLower(normalized);
      StringTrimLeft(normalized);
      StringTrimRight(normalized);
      return(normalized=="1" || normalized=="true" || normalized=="yes");
     }

   ulong             LastAccountedDealTicketInFile(const string sourceFile,
                                                       const ulong positionIdentifier) const
     {
      if(positionIdentifier==0) return(0);
      ulong lastDeal=0;
      int handle=FileOpen(sourceFile,FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
      if(handle==INVALID_HANDLE) return(0);
      bool firstLine=true;
      while(!FileIsEnding(handle))
        {
         string line=FileReadString(handle);
         if(firstLine) { firstLine=false; continue; }
         ulong rowPosition=(ulong)StringToInteger(ParseCsvField(line,43));
         if(rowPosition!=positionIdentifier) continue;
         ulong deal=(ulong)StringToInteger(ParseCsvField(line,3));
         if(deal>lastDeal) lastDeal=deal;
        }
      FileClose(handle);
      return(lastDeal);
     }

   bool              LastAccountedRecordInFile(const string sourceFile,
                                                const ulong positionIdentifier,
                                                ulong &dealTicket,bool &isPartial,
                                                double &lots,double &netProfit) const
     {
      dealTicket=0;
      isPartial=false;
      lots=0.0;
      netProfit=0.0;
      if(positionIdentifier==0) return(false);
      int handle=FileOpen(sourceFile,FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
      if(handle==INVALID_HANDLE) return(false);
      bool firstLine=true;
      while(!FileIsEnding(handle))
        {
         string line=FileReadString(handle);
         if(firstLine) { firstLine=false; continue; }
         if((ulong)StringToInteger(ParseCsvField(line,43))!=positionIdentifier)
            continue;
         ulong deal=(ulong)StringToInteger(ParseCsvField(line,3));
         if(deal<=dealTicket) continue;
         dealTicket=deal;
         lots=StringToDouble(ParseCsvField(line,9));
         netProfit=StringToDouble(ParseCsvField(line,24));
         isPartial=ParseCsvBoolean(ParseCsvField(line,28));
        }
      FileClose(handle);
      // The journal historically rounded Lots to two decimals. A valid broker
      // micro-volume can therefore be persisted as 0.00; the deal ticket, not
      // the rounded display volume, establishes whether the row exists.
      return(dealTicket>0 && MathIsValidNumber(lots) && MathIsValidNumber(netProfit));
     }


   bool              ParseFiniteNumber(const string source,double &value) const
     {
      string token=source;
      StringTrimLeft(token);
      StringTrimRight(token);
      int n=StringLen(token);
      if(n<=0) return(false);
      int i=0;
      if(StringGetCharacter(token,i)==43 || StringGetCharacter(token,i)==45) i++;
      int integerDigits=0;
      while(i<n)
        {
         ushort ch=StringGetCharacter(token,i);
         if(ch<48 || ch>57) break;
         integerDigits++;
         i++;
        }
      int fractionalDigits=0;
      if(i<n && StringGetCharacter(token,i)==46)
        {
         i++;
         while(i<n)
           {
            ushort ch=StringGetCharacter(token,i);
            if(ch<48 || ch>57) break;
            fractionalDigits++;
            i++;
           }
        }
      if(integerDigits==0 && fractionalDigits==0) return(false);
      if(i<n && (StringGetCharacter(token,i)==69 || StringGetCharacter(token,i)==101))
        {
         i++;
         if(i<n && (StringGetCharacter(token,i)==43 || StringGetCharacter(token,i)==45)) i++;
         int exponentDigits=0;
         while(i<n)
           {
            ushort ch=StringGetCharacter(token,i);
            if(ch<48 || ch>57) break;
            exponentDigits++;
            i++;
           }
         if(exponentDigits==0) return(false);
        }
      if(i!=n) return(false);
      value=StringToDouble(token);
      return(MathIsValidNumber(value));
     }

   bool              ParseUnsigned(const string source,ulong &value) const
     {
      string token=source;
      StringTrimLeft(token);
      StringTrimRight(token);
      if(StringLen(token)<=0) return(false);
      for(int i=0;i<StringLen(token);i++)
        {
         ushort ch=StringGetCharacter(token,i);
         if(ch<48 || ch>57) return(false);
        }
      long parsed=StringToInteger(token);
      if(parsed<0) return(false);
      value=(ulong)parsed;
      return(true);
     }

   bool              ParseBooleanField(const string value,bool &out) const
     {
      if(value=="1" || value=="true" || value=="TRUE" || value=="yes" || value=="YES")
        { out=true; return(true); }
      if(value=="0" || value=="false" || value=="FALSE" || value=="no" || value=="NO")
        { out=false; return(true); }
      return(false);
     }

   bool              ParseDirectionField(const string value,ENUM_AX_DIR &out) const
     {
      if(value=="BUY") { out=AX_DIR_BUY; return(true); }
      if(value=="SELL") { out=AX_DIR_SELL; return(true); }
      return(false);
     }

   bool              ParseRegimeField(const string value,ENUM_AX_REGIME &out) const
     {
      if(value=="TREND") out=AX_REGIME_TREND;
      else if(value=="STRONG TREND") out=AX_REGIME_STRONG_TREND;
      else if(value=="BREAKOUT") out=AX_REGIME_BREAKOUT;
      else if(value=="RANGE") out=AX_REGIME_RANGE;
      else if(value=="MEAN REVERSION") out=AX_REGIME_MEAN_REVERSION;
      else if(value=="HIGH VOLATILITY") out=AX_REGIME_HIGH_VOL;
      else if(value=="LOW VOLATILITY") out=AX_REGIME_LOW_VOL;
      else if(value=="CHAOTIC") out=AX_REGIME_CHAOTIC;
      else if(value=="UNSAFE") out=AX_REGIME_UNSAFE;
      else return(false);
      return(true);
     }

   bool              ParseExitReasonField(const string value,ENUM_AX_EXIT_REASON &out) const
     {
      if(value=="NONE") out=AX_EXIT_NONE;
      else if(value=="TAKE_PROFIT") out=AX_EXIT_TP;
      else if(value=="STOP_LOSS") out=AX_EXIT_SL;
      else if(value=="MOMENTUM_COLLAPSE") out=AX_EXIT_MOMENTUM_COLLAPSE;
      else if(value=="OPPOSITE_SIGNAL") out=AX_EXIT_OPPOSITE_SIGNAL;
      else if(value=="MICROSTRUCTURE_REVERSAL") out=AX_EXIT_MICROSTRUCTURE_REVERSAL;
      else if(value=="MAX_HOLD_TIME") out=AX_EXIT_MAX_HOLD_TIME;
      else if(value=="SPREAD_ABNORMAL") out=AX_EXIT_SPREAD_ABNORMAL;
      else if(value=="EXECUTION_QUALITY") out=AX_EXIT_EXECUTION_QUALITY;
      else if(value=="RISK_SHUTDOWN") out=AX_EXIT_RISK_SHUTDOWN;
      else if(value=="FLIP") out=AX_EXIT_FLIP;
      else if(value=="MANUAL_KILL") out=AX_EXIT_MANUAL_KILL;
      else if(value=="BREAKEVEN_STOP") out=AX_EXIT_BREAKEVEN_STOP;
      else if(value=="TRAIL_STOP") out=AX_EXIT_TRAIL_STOP;
      else if(value=="VWAP_TREND_FLIP") out=AX_EXIT_VWAP_TREND_FLIP;
      else return(false);
      return(true);
     }

   bool              ParseTradeClassField(const string value,ENUM_AX_TRADE_CLASS &out) const
     {
      if(value=="CORRECT_MOMENTUM") out=AX_CLASS_CORRECT_MOMENTUM;
      else if(value=="FALSE_BREAKOUT") out=AX_CLASS_FALSE_BREAKOUT;
      else if(value=="LIQUIDITY_TRAP") out=AX_CLASS_LIQUIDITY_TRAP;
      else if(value=="LATE_ENTRY") out=AX_CLASS_LATE_ENTRY;
      else if(value=="PREMATURE_EXIT") out=AX_CLASS_PREMATURE_EXIT;
      else if(value=="MOMENTUM_FAILURE") out=AX_CLASS_MOMENTUM_FAILURE;
      else if(value=="CORRECT_FLIP") out=AX_CLASS_CORRECT_FLIP;
      else if(value=="FALSE_FLIP") out=AX_CLASS_FALSE_FLIP;
      else if(value=="SPREAD_FAILURE") out=AX_CLASS_SPREAD_FAILURE;
      else if(value=="SLIPPAGE_FAILURE") out=AX_CLASS_SLIPPAGE_FAILURE;
      else if(value=="STOP_LOSS") out=AX_CLASS_STOP_LOSS;
      else if(value=="TAKE_PROFIT") out=AX_CLASS_TAKE_PROFIT;
      else if(value=="RISK_SHUTDOWN") out=AX_CLASS_RISK_SHUTDOWN;
      else return(false);
      return(true);
     }

   bool              ParseCapitalStateField(const string value,ENUM_AX_CAPITAL_STATE &out) const
     {
      if(value=="NORMAL") out=AX_CAPITAL_NORMAL;
      else if(value=="CAUTION") out=AX_CAPITAL_CAUTION;
      else if(value=="DEFENSIVE") out=AX_CAPITAL_DEFENSIVE;
      else if(value=="LOCKED") out=AX_CAPITAL_LOCKED;
      else return(false);
      return(true);
     }

   ENUM_AX_DATASET_PROVENANCE ParseProvenanceField(const string value) const
     {
      if(value=="BACKTEST") return(AX_PROVENANCE_BACKTEST);
      if(value=="FORWARD_DEMO") return(AX_PROVENANCE_FORWARD_DEMO);
      if(value=="LIVE") return(AX_PROVENANCE_LIVE);
      return(AX_PROVENANCE_UNKNOWN);
     }

   bool              ParseTradeRecordFields(string &fields[],const bool legacyV3,
                                              SAxTradeRecord &rec) const
     {
      if(ArraySize(fields)!=44) return(false);
      double values[19];
      int numericIndexes[19]={7,8,9,10,11,13,14,15,19,20,21,22,23,24,30,31,32,33,34};
      for(int i=0;i<19;i++)
         if(!ParseFiniteNumber(fields[numericIndexes[i]],values[i])) return(false);

      ulong ticket=0,dealIn=0,dealOut=0,positionId=0;
      if(!ParseUnsigned(fields[1],ticket) ||
         !ParseUnsigned(fields[2],dealIn) ||
         !ParseUnsigned(fields[3],dealOut) ||
         !ParseUnsigned(fields[43],positionId)) return(false);

      double flipValue=0.0,holdValue=0.0;
      if(!ParseFiniteNumber(fields[12],holdValue) ||
         !ParseFiniteNumber(fields[27],flipValue)) return(false);
      if(holdValue<0.0 || holdValue>2147483647.0 ||
         MathFloor(holdValue)!=holdValue || flipValue<0.0 ||
         flipValue>2147483647.0 || MathFloor(flipValue)!=flipValue) return(false);

      bool isPartial=false;
      if(!ParseBooleanField(fields[28],isPartial)) return(false);

      ENUM_AX_DIR direction;
      ENUM_AX_REGIME regime;
      ENUM_AX_EXIT_REASON exitReason;
      ENUM_AX_TRADE_CLASS tradeClass;
      ENUM_AX_CAPITAL_STATE capitalState;
      if(!ParseDirectionField(fields[6],direction) ||
         !ParseRegimeField(fields[16],regime) ||
         !ParseExitReasonField(fields[18],exitReason) ||
         !ParseTradeClassField(fields[26],tradeClass) ||
         !ParseCapitalStateField(fields[29],capitalState)) return(false);

      datetime entryTime=StringToTime(fields[4]);
      datetime exitTime=StringToTime(fields[5]);
      if(entryTime<=0 || exitTime<=0 || exitTime<entryTime) return(false);

      double rMultiple=EMPTY_VALUE;
      if(fields[25]!="NA")
        {
         if(!ParseFiniteNumber(fields[25],rMultiple)) return(false);
         if(legacyV3 && rMultiple==0.0) rMultiple=EMPTY_VALUE;
        }

      rec.setupId=fields[0];
      rec.ticket=ticket;
      rec.positionIdentifier=positionId;
      rec.dealIdIn=dealIn;
      rec.dealIdOut=dealOut;
      rec.entryTime=entryTime;
      rec.exitTime=exitTime;
      rec.direction=direction;
      rec.entryPrice=values[0];
      rec.exitPrice=values[1];
      rec.lots=values[2];
      rec.spreadAtEntry=values[3];
      rec.slippagePts=values[4];
      rec.holdSeconds=(int)holdValue;
      rec.buyScore=values[5];
      rec.sellScore=values[6];
      rec.confidence=values[7];
      rec.regime=regime;
      rec.entryReason=fields[17];
      rec.exitReason=exitReason;
      rec.mfe=values[8];
      rec.mae=values[9];
      rec.grossProfit=values[10];
      rec.commission=values[11];
      rec.swap=values[12];
      rec.netProfit=values[13];
      rec.rMultiple=rMultiple;
      rec.tradeClass=tradeClass;
      rec.flipSeq=(int)flipValue;
      rec.isPartial=isPartial;
      rec.afeCapitalState=capitalState;
      rec.afeRiskOfRuinPct=values[14];
      rec.afeExpectedValueR=values[15];
      rec.afeWinProbability=values[16];
      rec.afeRiskMultiplier=values[17];
      rec.impactCostPct=values[18];
      rec.vwapStateAtEntry=fields[35];
      rec.vpMacdStateAtEntry=fields[36];
      rec.orderFlowStateAtEntry=fields[37];
      rec.structureStateAtEntry=fields[38];
      rec.liquidityStateAtEntry=fields[39];
      rec.newsStateAtEntry=fields[40];
      rec.sessionAtEntry=fields[41];
      rec.provenance=ParseProvenanceField(fields[42]);

      if(rec.dealIdOut==0 || rec.positionIdentifier==0 ||
         rec.lots<=0.0 || rec.entryPrice<=0.0 || rec.exitPrice<=0.0 ||
         (rec.rMultiple!=EMPTY_VALUE && !MathIsValidNumber(rec.rMultiple)))
         return(false);
      return(true);
     }

   bool              HasLoadedDeal(const SAxTradeRecord &candidate) const
     {
      if(candidate.dealIdOut==0 || candidate.positionIdentifier==0) return(false);
      for(int i=0;i<m_count;i++)
         if(m_records[i].dealIdOut==candidate.dealIdOut &&
            m_records[i].positionIdentifier==candidate.positionIdentifier)
            return(true);
      return(false);
     }

   bool              LoadTradeRecordsFile(const string sourceFile,const bool legacyV3,
                                            int &loaded,int &rejected)
     {
      int handle=FileOpen(sourceFile,FILE_READ|FILE_CSV|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE,',');
      if(handle==INVALID_HANDLE) return(true); // absent legacy file is expected
      string fields[44];
      bool header=true;
      while(!FileIsEnding(handle))
        {
         bool rowRead=false;
         for(int f=0;f<44;f++)
           {
            if(FileIsEnding(handle) && f==0) { rowRead=false; break; }
            if(FileIsEnding(handle)) { rowRead=false; break; }
            fields[f]=FileReadString(handle);
            rowRead=true;
           }
         if(!rowRead) break;
         if(header) { header=false; continue; }

         SAxTradeRecord record;
         if(!ParseTradeRecordFields(fields,legacyV3,record))
           {
            rejected++;
            continue;
           }
         if(HasLoadedDeal(record)) continue;

         if(m_count<AX_AUTOPSY_MAX_MEMORY)
           {
            ArrayResize(m_records,m_count+1);
            m_records[m_count]=record;
            m_count++;
           }
         else
           {
            for(int i=1;i<AX_AUTOPSY_MAX_MEMORY;i++) m_records[i-1]=m_records[i];
            m_records[AX_AUTOPSY_MAX_MEMORY-1]=record;
           }
         loaded++;
        }
      FileClose(handle);
      return(true);
     }

   bool              LoadTradeRecords(void)
     {
      m_count=0;
      ArrayResize(m_records,0);
      int loaded=0,rejected=0;
      if(!LoadTradeRecordsFile(m_legacyFileName,true,loaded,rejected)) return(false);
      if(!LoadTradeRecordsFile(m_fileName,false,loaded,rejected)) return(false);
      PrintFormat("FLIPDEMON AUTOPSY RECOVERY: restored=%d rejected=%d duplicate_deals_skipped; memory_limit=%d.",
                  loaded,rejected,AX_AUTOPSY_MAX_MEMORY);
      return(true);
     }

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

         double rMultiple=(fields[25]=="NA") ? EMPTY_VALUE : StringToDouble(fields[25]);
         // v3 used zero for both unavailable R and true breakeven. Treat those
         // ambiguous legacy zeros as unavailable. v4 writes an explicit NA token.
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
                     CTradeAutopsy(void) { m_fileHandle=INVALID_HANDLE; m_count=0; m_riskCount=0; m_persistenceHealthy=false; }

   bool              Init(const string eaName,const string symbol)
     {
      m_persistenceHealthy=false;
      m_digits = (int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
      //--- v4 retains the 44-column schema and gives R-multiple an explicit EMPTY_VALUE sentinel.
      //--- v3 rows are read as legacy history, but ambiguous zero-R rows are excluded safely.
      m_fileName = StringFormat("%s_%s_TradeAutopsy_v4.csv",eaName,symbol);
      m_legacyFileName = StringFormat("%s_%s_TradeAutopsy_v3.csv",eaName,symbol);
      m_fileHandle = FileOpen(m_fileName,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_SHARE_READ,',');
      if(m_fileHandle==INVALID_HANDLE) return(false);
      FileSeek(m_fileHandle,0,SEEK_END);
      if(!WriteHeaderIfNew())
        {
         FileClose(m_fileHandle); m_fileHandle=INVALID_HANDLE;
         return(false);
        }
      ArrayResize(m_records,0);
      m_count=0;
      if(!LoadRiskHistory() || !LoadTradeRecords())
        {
         FileClose(m_fileHandle); m_fileHandle=INVALID_HANDLE;
         return(false);
        }
      m_persistenceHealthy=true;
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

      // Fail closed: a record is not admitted to memory or learning statistics until
      // the CSV append has succeeded and the terminal has flushed the file handle.
      if(!m_persistenceHealthy || m_fileHandle==INVALID_HANDLE)
        {
         m_persistenceHealthy=false;
         Print("AUTOPSY JOURNAL ERROR: persistence unavailable; trade record rejected from in-memory learning data.");
         return(rec.tradeClass);
        }

      if(!FileSeek(m_fileHandle,0,SEEK_END))
        {
         m_persistenceHealthy=false;
         PrintFormat("AUTOPSY JOURNAL ERROR: seek-to-end failed (%d); trade record not admitted.",GetLastError());
         return(rec.tradeClass);
        }
      ulong fileSizeBefore=FileSize(m_fileHandle);
      uint writeResult=FileWrite(m_fileHandle,
                   rec.setupId,rec.ticket,rec.dealIdIn,rec.dealIdOut,
                   TimeToString(rec.entryTime,TIME_DATE|TIME_SECONDS),
                   TimeToString(rec.exitTime,TIME_DATE|TIME_SECONDS),AxDirToString(rec.direction),
                   DoubleToString(rec.entryPrice,m_digits),DoubleToString(rec.exitPrice,m_digits),
                   DoubleToString(rec.lots,8),DoubleToString(rec.spreadAtEntry,1),
                   DoubleToString(rec.slippagePts,1),rec.holdSeconds,
                   DoubleToString(rec.buyScore,1),DoubleToString(rec.sellScore,1),
                   DoubleToString(rec.confidence,1),AxRegimeToString(rec.regime),rec.entryReason,
                   AxExitReasonToString(rec.exitReason),DoubleToString(rec.mfe,2),DoubleToString(rec.mae,2),
                   DoubleToString(rec.grossProfit,2),DoubleToString(rec.commission,2),
                   DoubleToString(rec.swap,2),DoubleToString(rec.netProfit,2),
                   (rec.rMultiple==EMPTY_VALUE ? "NA" : DoubleToString(rec.rMultiple,3)),
                   AxTradeClassToString(rec.tradeClass),rec.flipSeq,rec.isPartial,
                   AxCapitalStateToString(rec.afeCapitalState),DoubleToString(rec.afeRiskOfRuinPct,1),
                   DoubleToString(rec.afeExpectedValueR,2),DoubleToString(rec.afeWinProbability,3),
                   DoubleToString(rec.afeRiskMultiplier,2),DoubleToString(rec.impactCostPct,3),
                   rec.vwapStateAtEntry,rec.vpMacdStateAtEntry,rec.orderFlowStateAtEntry,
                   rec.structureStateAtEntry,rec.liquidityStateAtEntry,rec.newsStateAtEntry,
                   rec.sessionAtEntry,AxProvenanceToString(rec.provenance),rec.positionIdentifier);
      FileFlush(m_fileHandle);
      ulong fileSizeAfter=FileSize(m_fileHandle);
      if(writeResult==0 || fileSizeAfter<=fileSizeBefore)
        {
         m_persistenceHealthy=false;
         PrintFormat("AUTOPSY JOURNAL ERROR: CSV append/flush could not be verified (write=%u before=%I64u after=%I64u). New entries must remain blocked.",
                     writeResult,fileSizeBefore,fileSizeAfter);
         return(rec.tradeClass);
        }

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

      AddRiskHistory(rec.netProfit,rec.rMultiple,rec.isPartial,AxProvenanceToString(rec.provenance));
      return(rec.tradeClass);
     }

   ulong             LastAccountedDealTicket(const ulong positionIdentifier) const
     {
      ulong currentLast=LastAccountedDealTicketInFile(m_fileName,positionIdentifier);
      ulong legacyLast=LastAccountedDealTicketInFile(m_legacyFileName,positionIdentifier);
      return((currentLast>legacyLast) ? currentLast : legacyLast);
     }

   // Returns the newest durable row for a position, including whether it is
   // a partial slice and the volume that row accounted. Used only by restart
   // reconciliation to distinguish a journal-first partial commit from a
   // final close that was already written before a crash.
   bool              LastAccountedRecord(const ulong positionIdentifier,
                                         ulong &dealTicket,bool &isPartial,
                                         double &lots,double &netProfit) const
     {
      ulong currentTicket=0,legacyTicket=0;
      bool currentPartial=false,legacyPartial=false;
      double currentLots=0.0,legacyLots=0.0;
      double currentNetProfit=0.0,legacyNetProfit=0.0;
      bool currentFound=LastAccountedRecordInFile(m_fileName,positionIdentifier,
                                                   currentTicket,currentPartial,currentLots,currentNetProfit);
      bool legacyFound=LastAccountedRecordInFile(m_legacyFileName,positionIdentifier,
                                                  legacyTicket,legacyPartial,legacyLots,legacyNetProfit);
      if(!currentFound && !legacyFound) return(false);
      if(currentTicket>=legacyTicket)
        {
         dealTicket=currentTicket;
         isPartial=currentPartial;
         lots=currentLots;
         netProfit=currentNetProfit;
        }
      else
        {
         dealTicket=legacyTicket;
         isPartial=legacyPartial;
         lots=legacyLots;
         netProfit=legacyNetProfit;
        }
      return(true);
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
   bool              IsPersisting(void) const { return(m_persistenceHealthy && m_fileHandle!=INVALID_HANDLE); }

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
