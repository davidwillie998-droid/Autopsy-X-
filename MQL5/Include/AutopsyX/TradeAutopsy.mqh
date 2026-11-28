//+------------------------------------------------------------------+
//|                                                  TradeAutopsy.mqh|
//|  Trade Autopsy (spec section 17) - every closed trade recorded,   |
//|  classified, and written to a CSV log for offline analysis.       |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_TRADEAUTOPSY_MQH
#define AX_TRADEAUTOPSY_MQH
#include "Defs.mqh"

class CTradeAutopsy
  {
private:
   int               m_fileHandle;
   string            m_fileName;
   string            m_legacyFileName;
   string            m_v4FileName;
   string            m_v5FileName;
   string            m_v6FileName;
   int               m_digits;
   ulong             m_magicNumber;
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
                "NewsState","Session","Provenance","PositionIdentifier",
                "VWAPPullbackBullBonus","VWAPPullbackBearBonus",
                "OvernightBiasBullBonus","OvernightBiasBearBonus",
                "TwinContinuationBullBonus","TwinContinuationBearBonus",
                "AccountLogin","MagicNumber","AccountServer","EntryModel");
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
      int fieldCount=ArraySize(fields);
      if(fieldCount!=44 && fieldCount!=50 && fieldCount!=53 && fieldCount!=54) return(false);
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
      rec.vwapPullbackBullBonus=(fieldCount>=50)?StringToDouble(fields[44]):0.0;
      rec.vwapPullbackBearBonus=(fieldCount>=50)?StringToDouble(fields[45]):0.0;
      rec.overnightBiasBullBonus=(fieldCount>=50)?StringToDouble(fields[46]):0.0;
      rec.overnightBiasBearBonus=(fieldCount>=50)?StringToDouble(fields[47]):0.0;
      rec.twinContinuationBullBonus=(fieldCount>=50)?StringToDouble(fields[48]):0.0;
      rec.twinContinuationBearBonus=(fieldCount>=50)?StringToDouble(fields[49]):0.0;
      rec.accountLogin=0;
      rec.magicNumber=0;
      rec.accountServer="";
      if(fieldCount>=53 &&
         (!ParseUnsigned(fields[50],rec.accountLogin) ||
          !ParseUnsigned(fields[51],rec.magicNumber))) return(false);
      if(fieldCount>=53) rec.accountServer=fields[52];
      rec.entryModel=(fieldCount>=54 && fields[53]!="")?fields[53]:"UNKNOWN";
      if(!MathIsValidNumber(rec.vwapPullbackBullBonus) || !MathIsValidNumber(rec.vwapPullbackBearBonus) ||
         !MathIsValidNumber(rec.overnightBiasBullBonus) || !MathIsValidNumber(rec.overnightBiasBearBonus) ||
         !MathIsValidNumber(rec.twinContinuationBullBonus) || !MathIsValidNumber(rec.twinContinuationBearBonus) ||
         rec.vwapPullbackBullBonus<0.0 || rec.vwapPullbackBullBonus>8.0 ||
         rec.vwapPullbackBearBonus<0.0 || rec.vwapPullbackBearBonus>8.0 ||
         rec.overnightBiasBullBonus<0.0 || rec.overnightBiasBullBonus>5.0 ||
         rec.overnightBiasBearBonus<0.0 || rec.overnightBiasBearBonus>5.0 ||
         rec.twinContinuationBullBonus<0.0 || rec.twinContinuationBullBonus>8.0 ||
         rec.twinContinuationBearBonus<0.0 || rec.twinContinuationBearBonus>8.0) return(false);

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
      string fields[];
      bool header=true;
      while(!FileIsEnding(handle))
        {
         bool rowRead=false;
         int expectedFields=(StringFind(sourceFile,"_v7")>=0)?54:
                            ((StringFind(sourceFile,"_v6")>=0)?53:
                            ((StringFind(sourceFile,"_v5")>=0)?50:44));
         if(ArrayResize(fields,expectedFields)!=expectedFields)
           {
            FileClose(handle);
            m_persistenceHealthy=false;
            Print("AUTOPSY JOURNAL ERROR: CSV recovery field allocation failed.");
            return(false);
           }
         for(int f=0;f<expectedFields;f++)
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

         // Retain every valid row from the durable journal. No rolling 5,000-row
         // window is permitted for lifetime performance statistics.
         if(ArrayResize(m_records,m_count+1,256)!=m_count+1)
           {
            FileClose(handle);
            m_persistenceHealthy=false;
            Print("AUTOPSY JOURNAL ERROR: full-history recovery allocation failed.");
            return(false);
           }
         m_records[m_count]=record;
         m_count++;
         loaded++;
        }
      FileClose(handle);
      return(true);
     }

   bool              LoadTradeRecords(void)
     {
      m_count=0;
      if(ArrayResize(m_records,0)!=0)
        {
         m_persistenceHealthy=false;
         Print("AUTOPSY JOURNAL ERROR: trade-record recovery buffer reset failed.");
         return(false);
        }
      int loaded=0,rejected=0;
      if(!LoadTradeRecordsFile(m_legacyFileName,true,loaded,rejected)) return(false);
      if(!LoadTradeRecordsFile(m_v4FileName,false,loaded,rejected)) return(false);
      if(!LoadTradeRecordsFile(m_v5FileName,false,loaded,rejected)) return(false);
      if(!LoadTradeRecordsFile(m_v6FileName,false,loaded,rejected)) return(false);
      if(!LoadTradeRecordsFile(m_fileName,false,loaded,rejected)) return(false);
      PrintFormat("FLIPDEMON AUTOPSY RECOVERY: restored=%d rejected=%d duplicate_deals_skipped; full_history=true.",
                  loaded,rejected);
      return(true);
     }

   bool              AddRiskHistory(const double netProfit,const double rMultiple,
                                    const bool isPartial,const string provenance)
     {
      // Keep the complete recovered risk sequence. The journal is the durable source;
      // dynamic arrays grow in reserved blocks to avoid a fixed historical cutoff.
      int requiredCount=m_riskCount+1;
      if(ArrayResize(m_riskNetProfit,requiredCount,256)!=requiredCount ||
         ArrayResize(m_riskMultiple,requiredCount,256)!=requiredCount ||
         ArrayResize(m_riskPartial,requiredCount,256)!=requiredCount ||
         ArrayResize(m_riskProvenance,requiredCount,256)!=requiredCount)
        {
         m_persistenceHealthy=false;
         Print("AUTOPSY JOURNAL ERROR: risk-history memory allocation failed; new entries must remain blocked.");
         return(false);
        }
      m_riskNetProfit[m_riskCount]=netProfit;
      m_riskMultiple[m_riskCount]=rMultiple;
      m_riskPartial[m_riskCount]=isPartial;
      m_riskProvenance[m_riskCount]=provenance;
      m_riskCount++;
      return(true);
     }

   bool              ReadRiskHistoryFile(const string sourceFile,const bool legacyV3)
     {
      int handle=FileOpen(sourceFile,FILE_READ|FILE_CSV|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE,',');
      if(handle==INVALID_HANDLE) return(true); // absent legacy file is not a startup failure
      int fieldCount=(StringFind(sourceFile,"_v7")>=0)?54:
                     ((StringFind(sourceFile,"_v6")>=0)?53:
                     ((StringFind(sourceFile,"_v5")>=0)?50:44));
      string fields[];
      if(ArrayResize(fields,fieldCount)!=fieldCount) return(false);
      bool header=true;
      while(!FileIsEnding(handle))
        {
         bool rowRead=false;
         for(int f=0;f<fieldCount;f++)
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
         if(!AddRiskHistory(StringToDouble(fields[24]),rMultiple,
                            (StringToInteger(fields[28])!=0),fields[42]))
           {
            FileClose(handle);
            return(false);
           }
        }
      FileClose(handle);
      return(true);
     }

   bool              LoadRiskHistory(void)
     {
      m_riskCount=0;
      if(ArrayResize(m_riskNetProfit,0)!=0 ||
         ArrayResize(m_riskMultiple,0)!=0 ||
         ArrayResize(m_riskPartial,0)!=0 ||
         ArrayResize(m_riskProvenance,0)!=0)
        {
         m_persistenceHealthy=false;
         Print("AUTOPSY JOURNAL ERROR: risk-history recovery buffer reset failed.");
         return(false);
        }
      if(!ReadRiskHistoryFile(m_legacyFileName,true)) return(false);
      if(!ReadRiskHistoryFile(m_v4FileName,false)) return(false);
      if(!ReadRiskHistoryFile(m_v5FileName,false)) return(false);
      if(!ReadRiskHistoryFile(m_v6FileName,false)) return(false);
      return(ReadRiskHistoryFile(m_fileName,false));
     }

public:
                     CTradeAutopsy(void) { m_fileHandle=INVALID_HANDLE; m_count=0; m_riskCount=0; m_persistenceHealthy=false; }

   bool              Init(const string eaName,const string symbol,const ulong magicNumber)
     {
      m_persistenceHealthy=false;
      m_digits = (int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
      //--- v7 adds a structured entry-model identifier. v3-v6 journals remain read-only.
      //--- Symbol files are durable shards; a later account-wide reader can safely consolidate by identity.
      string serverKey=AccountInfoString(ACCOUNT_SERVER);
      StringReplace(serverKey,"/","_"); StringReplace(serverKey,"\\","_");
      StringReplace(serverKey,":","_"); StringReplace(serverKey,".","_");
      StringReplace(serverKey," ","_");
      ulong login=(ulong)AccountInfoInteger(ACCOUNT_LOGIN);
      m_magicNumber=magicNumber;
      // ChartID isolates simultaneous writers using the same account, server,
      // magic number and symbol. A new chart session may create a new shard;
      // the account-wide reader must discover all matching shards.
      long writerChartId=ChartID();
      m_fileName = StringFormat("%s_%I64u_%s_%I64u_%I64d_%s_TradeAutopsy_v7.csv",
                                eaName,login,serverKey,m_magicNumber,writerChartId,symbol);
      m_v6FileName = StringFormat("%s_%I64u_%s_%I64u_%I64d_%s_TradeAutopsy_v6.csv",
                                  eaName,login,serverKey,m_magicNumber,writerChartId,symbol);
      m_v4FileName = StringFormat("%s_%s_TradeAutopsy_v4.csv",eaName,symbol);
      m_legacyFileName = StringFormat("%s_%s_TradeAutopsy_v3.csv",eaName,symbol);
      m_fileHandle = FileOpen(m_fileName,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_SHARE_READ,',');
      if(m_fileHandle==INVALID_HANDLE) return(false);
      FileSeek(m_fileHandle,0,SEEK_END);
      if(!WriteHeaderIfNew())
        {
         FileClose(m_fileHandle); m_fileHandle=INVALID_HANDLE;
         return(false);
        }
      if(ArrayResize(m_records,0)!=0)
        {
         FileClose(m_fileHandle); m_fileHandle=INVALID_HANDLE;
         Print("AUTOPSY JOURNAL ERROR: trade-record buffer initialization failed.");
         return(false);
        }
      m_count=0;
      m_v5FileName = StringFormat("%s_%s_TradeAutopsy_v5.csv",eaName,symbol);
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
      rec.accountLogin=(ulong)AccountInfoInteger(ACCOUNT_LOGIN);
      rec.magicNumber=m_magicNumber;
      rec.accountServer=AccountInfoString(ACCOUNT_SERVER);
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
                   rec.sessionAtEntry,AxProvenanceToString(rec.provenance),rec.positionIdentifier,
                   DoubleToString(rec.vwapPullbackBullBonus,3),DoubleToString(rec.vwapPullbackBearBonus,3),
                   DoubleToString(rec.overnightBiasBullBonus,3),DoubleToString(rec.overnightBiasBearBonus,3),
                   DoubleToString(rec.twinContinuationBullBonus,3),DoubleToString(rec.twinContinuationBearBonus,3),
                   rec.accountLogin,rec.magicNumber,rec.accountServer,rec.entryModel);
      FileFlush(m_fileHandle);
      ulong fileSizeAfter=FileSize(m_fileHandle);
      if(writeResult==0 || fileSizeAfter<=fileSizeBefore)
        {
         m_persistenceHealthy=false;
         PrintFormat("AUTOPSY JOURNAL ERROR: CSV append/flush could not be verified (write=%u before=%I64u after=%I64u). New entries must remain blocked.",
                     writeResult,fileSizeBefore,fileSizeAfter);
         return(rec.tradeClass);
        }

      // Keep the in-memory learning/statistics view aligned with the complete CSV.
      if(ArrayResize(m_records,m_count+1,256)!=m_count+1)
        {
         m_persistenceHealthy=false;
         Print("AUTOPSY JOURNAL ERROR: durable trade was written but full-history memory allocation failed; new entries must remain blocked.");
         return(rec.tradeClass);
        }
      m_records[m_count]=rec;
      m_count++;

      if(!AddRiskHistory(rec.netProfit,rec.rMultiple,rec.isPartial,AxProvenanceToString(rec.provenance)))
         return(rec.tradeClass);
      return(rec.tradeClass);
     }

   // Research-only campaign report. Partial exit rows are aggregated with the final
   // close by stable POSITION_IDENTIFIER, so one campaign contributes one outcome.
   // BUY+BULLISH and SELL+BEARISH are aligned; the reverse combinations are opposed.
   // Neutral/unavailable states are kept out of both cohorts. Dataset provenance is
   // segmented so tester, forward-demo and live results are never blended.
   void              ReportVWAPAlignment(const int minimumSamples) const
     {
      int minCount=minimumSamples;
      if(minCount<1) minCount=1;

      // Build compact keys and sort once. The previous nested campaign search
      // and insertion ordering became quadratic as the durable journal grew.
      SAxCampaignKey keys[];
      if(ArrayResize(keys,m_count)!=m_count)
        {
         Print("FLIPDEMON VWAP RESEARCH WARNING: campaign-key allocation failed; no cohort report produced.");
         return;
        }

      int keyCount=0;
      for(int i=0;i<m_count;i++)
        {
         SAxTradeRecord rec=m_records[i];
         if(rec.positionIdentifier==0) continue;
         keys[keyCount].positionIdentifier=rec.positionIdentifier;
         keys[keyCount].recordIndex=i;
         keyCount++;
        }
      if(keyCount>1) AxSortCampaignKeys(keys,keyCount);

      SAxCampaignAggregate campaigns[];
      if(ArrayResize(campaigns,keyCount)!=keyCount)
        {
         Print("FLIPDEMON VWAP RESEARCH WARNING: campaign allocation failed; no cohort report produced.");
         return;
        }

      int campaignCount=0;
      for(int k=0;k<keyCount;k++)
        {
         SAxTradeRecord rec=m_records[keys[k].recordIndex];
         if(campaignCount==0 ||
            campaigns[campaignCount-1].positionIdentifier!=keys[k].positionIdentifier)
           {
            campaigns[campaignCount].positionIdentifier=keys[k].positionIdentifier;
            campaigns[campaignCount].net=0.0;
            campaigns[campaignCount].gross=0.0; // commission accumulator for this report
            campaigns[campaignCount].finalRecordIndex=-1;
            campaigns[campaignCount].firstRecordIndex=keys[k].recordIndex;
            campaigns[campaignCount].finalExitTime=0;
            campaignCount++;
           }

         int group=campaignCount-1;
         campaigns[group].net+=rec.netProfit;
         campaigns[group].gross+=rec.commission;
         if(!rec.isPartial &&
            (campaigns[group].finalRecordIndex<0 ||
             rec.exitTime>=campaigns[group].finalExitTime))
           {
            campaigns[group].finalRecordIndex=keys[k].recordIndex;
            campaigns[group].finalExitTime=rec.exitTime;
           }
        }

      SAxCampaignAggregate completed[];
      int completedCount=0;
      for(int i=0;i<campaignCount;i++)
         if(campaigns[i].finalRecordIndex>=0) completedCount++;
      if(ArrayResize(completed,completedCount)!=completedCount)
        {
         Print("FLIPDEMON VWAP RESEARCH WARNING: completed-campaign allocation failed; no cohort report produced.");
         return;
        }

      int completedIndex=0;
      for(int i=0;i<campaignCount;i++)
         if(campaigns[i].finalRecordIndex>=0)
            completed[completedIndex++]=campaigns[i];
      if(completedCount>1) AxSortCampaignAggregates(completed,completedCount);

      int samples[12],wins[12],losses[12],rSamples[12];
      double net[12],grossWins[12],grossLosses[12],rTotal[12];
      double mfeTotal[12],maeTotal[12],spreadTotal[12],slippageTotal[12],commissionTotal[12];
      double runningPnl[12],peakPnl[12],maxClosedPnlDd[12];
      ArrayInitialize(samples,0);
      ArrayInitialize(wins,0);
      ArrayInitialize(losses,0);
      ArrayInitialize(rSamples,0);
      ArrayInitialize(net,0.0);
      ArrayInitialize(grossWins,0.0);
      ArrayInitialize(grossLosses,0.0);
      ArrayInitialize(rTotal,0.0);
      ArrayInitialize(mfeTotal,0.0);
      ArrayInitialize(maeTotal,0.0);
      ArrayInitialize(spreadTotal,0.0);
      ArrayInitialize(slippageTotal,0.0);
      ArrayInitialize(commissionTotal,0.0);
      ArrayInitialize(runningPnl,0.0);
      ArrayInitialize(peakPnl,0.0);
      ArrayInitialize(maxClosedPnlDd,0.0);

      for(int orderIndex=0;orderIndex<completedCount;orderIndex++)
        {
         int finalIndex=completed[orderIndex].finalRecordIndex;
         SAxTradeRecord finalRec=m_records[finalIndex];

         int provenance=3;
         if(finalRec.provenance==AX_PROVENANCE_BACKTEST) provenance=0;
         else if(finalRec.provenance==AX_PROVENANCE_FORWARD_DEMO) provenance=1;
         else if(finalRec.provenance==AX_PROVENANCE_LIVE) provenance=2;

         int cohort=2;
         if(finalRec.vwapStateAtEntry=="BULLISH" || finalRec.vwapStateAtEntry=="BEARISH")
           {
            bool aligned=(finalRec.direction==AX_DIR_BUY && finalRec.vwapStateAtEntry=="BULLISH") ||
                         (finalRec.direction==AX_DIR_SELL && finalRec.vwapStateAtEntry=="BEARISH");
            cohort=aligned ? 0 : 1;
           }

         int slot=provenance*3+cohort;
         double campaignResult=completed[orderIndex].net;
         samples[slot]++;
         net[slot]+=campaignResult;
         runningPnl[slot]+=campaignResult;
         if(runningPnl[slot]>peakPnl[slot]) peakPnl[slot]=runningPnl[slot];
         double currentDd=peakPnl[slot]-runningPnl[slot];
         if(currentDd>maxClosedPnlDd[slot]) maxClosedPnlDd[slot]=currentDd;

         if(campaignResult>0.0)
           {
            wins[slot]++;
            grossWins[slot]+=campaignResult;
           }
         else if(campaignResult<0.0)
           {
            losses[slot]++;
            grossLosses[slot]+=MathAbs(campaignResult);
           }

         mfeTotal[slot]+=finalRec.mfe;
         maeTotal[slot]+=finalRec.mae;
         spreadTotal[slot]+=finalRec.spreadAtEntry;
         slippageTotal[slot]+=finalRec.slippagePts;
         commissionTotal[slot]+=completed[orderIndex].gross;

         // The final-slice R value shares the original campaign-risk denominator.
         // Recover that denominator to express aggregated campaign P/L in R.
         // If the final slice is exactly breakeven or R is unavailable, report no R
         // observation rather than manufacturing a denominator.
         if(finalRec.rMultiple!=EMPTY_VALUE && MathIsValidNumber(finalRec.rMultiple) &&
            MathAbs(finalRec.rMultiple)>0.0000001 && MathAbs(finalRec.netProfit)>0.0000001)
           {
            double originalRiskMoney=finalRec.netProfit/finalRec.rMultiple;
            if(MathIsValidNumber(originalRiskMoney) && originalRiskMoney>0.0)
              {
               double campaignR=campaignResult/originalRiskMoney;
               if(MathIsValidNumber(campaignR))
                 {
                  rSamples[slot]++;
                  rTotal[slot]+=campaignR;
                 }
              }
           }
        }

      string provenanceNames[4]={"BACKTEST","FORWARD_DEMO","LIVE","UNKNOWN_PROVENANCE"};
      string cohortNames[3]={"ALIGNED","OPPOSED","NEUTRAL_OR_UNAVAILABLE"};
      PrintFormat("FLIPDEMON VWAP RESEARCH | symbol-scoped closed campaigns | minimum sample threshold=%d | partial exits aggregated | closed-PnL drawdown is account-currency, not percent",
                  minCount);
      for(int p=0;p<4;p++)
        {
         for(int c=0;c<3;c++)
           {
            int slot=p*3+c;
            if(samples[slot]<=0) continue;
            int decided=wins[slot]+losses[slot];
            double winRate=(decided>0) ? 100.0*wins[slot]/decided : 0.0;
            string pfText=(grossLosses[slot]>0.0)
                          ? DoubleToString(grossWins[slot]/grossLosses[slot],3)
                          : (grossWins[slot]>0.0 ? "INF" : "N/A");
            string avgRText=(rSamples[slot]>0)
                            ? DoubleToString(rTotal[slot]/rSamples[slot],3)
                            : "N/A";
            string sampleState=(samples[slot]>=minCount)
                               ? "SAMPLE_THRESHOLD_MET" : "INSUFFICIENT_SAMPLE";
            double divisor=(double)samples[slot];
            PrintFormat("FLIPDEMON VWAP COHORT | provenance=%s cohort=%s campaigns=%d wins=%d losses=%d winRate=%.1f%% net=%.2f PF=%s meanR=%s validR=%d/%d maxClosedPnlDD=%.2f avgMFE=%.2f avgMAE=%.2f avgSpreadPts=%.1f avgEntrySlipPts=%.1f avgCommission=%.2f status=%s",
                        provenanceNames[p],cohortNames[c],samples[slot],wins[slot],
                        losses[slot],winRate,net[slot],pfText,avgRText,
                        rSamples[slot],samples[slot],maxClosedPnlDd[slot],
                        mfeTotal[slot]/divisor,maeTotal[slot]/divisor,
                        spreadTotal[slot]/divisor,slippageTotal[slot]/divisor,
                        commissionTotal[slot]/divisor,sampleState);
           }
        }
     }

   ulong             LastAccountedDealTicket(const ulong positionIdentifier) const
     {
      ulong currentLast=LastAccountedDealTicketInFile(m_fileName,positionIdentifier);
      ulong v4Last=LastAccountedDealTicketInFile(m_v4FileName,positionIdentifier);
      ulong v5Last=LastAccountedDealTicketInFile(m_v5FileName,positionIdentifier);
      ulong legacyLast=LastAccountedDealTicketInFile(m_legacyFileName,positionIdentifier);
      return(MathMax(currentLast,MathMax(v5Last,MathMax(v4Last,legacyLast))));
     }

   bool              LastAccountedRecord(const ulong positionIdentifier,
                                          ulong &dealTicket,bool &isPartial,
                                          double &lots,double &netProfit) const
     {
      ulong currentTicket=0,v4Ticket=0,v5Ticket=0,legacyTicket=0;
      bool currentPartial=false,v4Partial=false,v5Partial=false,legacyPartial=false;
      double currentLots=0.0,v4Lots=0.0,v5Lots=0.0,legacyLots=0.0;
      double currentNet=0.0,v4Net=0.0,v5Net=0.0,legacyNet=0.0;
      bool currentFound=LastAccountedRecordInFile(m_fileName,positionIdentifier,
                                                   currentTicket,currentPartial,currentLots,currentNet);
      bool v4Found=LastAccountedRecordInFile(m_v4FileName,positionIdentifier,
                                              v4Ticket,v4Partial,v4Lots,v4Net);
      bool v5Found=LastAccountedRecordInFile(m_v5FileName,positionIdentifier,
                                              v5Ticket,v5Partial,v5Lots,v5Net);
      bool legacyFound=LastAccountedRecordInFile(m_legacyFileName,positionIdentifier,
                                                  legacyTicket,legacyPartial,legacyLots,legacyNet);
      if(!currentFound && !v4Found && !v5Found && !legacyFound) return(false);
      if(currentFound && currentTicket>=v4Ticket && currentTicket>=v5Ticket && currentTicket>=legacyTicket)
        { dealTicket=currentTicket; isPartial=currentPartial; lots=currentLots; netProfit=currentNet; }
      else if(v5Found && v5Ticket>=v4Ticket && v5Ticket>=legacyTicket)
        { dealTicket=v5Ticket; isPartial=v5Partial; lots=v5Lots; netProfit=v5Net; }
      else if(v4Found && v4Ticket>=legacyTicket)
        { dealTicket=v4Ticket; isPartial=v4Partial; lots=v4Lots; netProfit=v4Net; }
      else
        { dealTicket=legacyTicket; isPartial=legacyPartial; lots=legacyLots; netProfit=legacyNet; }
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
   bool              GetCampaignNetProfit(const ulong positionIdentifier,double &netProfit,bool &closed) const
     {
      netProfit=0.0;
      closed=false;
      if(positionIdentifier==0) return(false);
      bool found=false;
      for(int i=0;i<m_count;i++)
        {
         if(m_records[i].positionIdentifier!=positionIdentifier) continue;
         found=true;
         netProfit+=m_records[i].netProfit;
         if(!m_records[i].isPartial) closed=true;
        }
      return(found && MathIsValidNumber(netProfit));
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
      if(ArrayResize(out,0)!=0) return(-1);
      for(int i=0;i<m_count;i++)
        {
         if(m_records[i].isPartial) continue;
         if(m_records[i].provenance!=provenance) continue;
         if(ArrayResize(out,found+1)!=found+1) return(-1);
         out[found]=m_records[i];
         found++;
        }
      return(found);
     }
  };
//+------------------------------------------------------------------+
#endif // AX_TRADEAUTOPSY_MQH
