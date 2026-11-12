//+------------------------------------------------------------------+
//|                                      JournalRecoveryTest.mq5     |
//| Isolated restart-recovery harness. Creates synthetic CSV fixtures|
//| and never submits, modifies, or closes broker orders.             |
//+------------------------------------------------------------------+
#property strict
#property script_show_inputs

#include <AutopsyX/TradeAutopsy.mqh>

#define AX_TEST_FIELD_COUNT 44

int g_assertions=0;
int g_failures=0;

void AssertTrue(const bool condition,const string label)
  {
   g_assertions++;
   if(condition)
      Print("PASS: ",label);
   else
     {
      g_failures++;
      Print("FAIL: ",label);
     }
  }

string MakeHeader(void)
  {
   string line="";
   for(int i=0;i<AX_TEST_FIELD_COUNT;i++)
     {
      if(i>0) line+=",";
      line+="F"+IntegerToString(i);
     }
   return(line);
  }

string MakeTradeRow(const ulong dealOut,const ulong positionId,
                    const string provenance,const bool partial,
                    const string rMultiple,const string entryPrice)
  {
   string fields[AX_TEST_FIELD_COUNT];
   for(int i=0;i<AX_TEST_FIELD_COUNT;i++) fields[i]="";

   fields[0]="TEST_SETUP";
   fields[1]="9001";
   fields[2]="8001";
   fields[3]=IntegerToString((long)dealOut);
   fields[4]="2026.11.10 10:00:00";
   fields[5]="2026.11.10 10:05:00";
   fields[6]="BUY";
   fields[7]=entryPrice;
   fields[8]="101.25";
   fields[9]="0.10";
   fields[10]="12.0";
   fields[11]="0.5";
   fields[12]="300";
   fields[13]="75.0";
   fields[14]="20.0";
   fields[15]="80.0";
   fields[16]="TREND";
   fields[17]="TEST_ENTRY";
   fields[18]="TAKE_PROFIT";
   fields[19]="1.5";
   fields[20]="-0.5";
   fields[21]="15.0";
   fields[22]="-1.0";
   fields[23]="0.0";
   fields[24]="14.0";
   fields[25]=rMultiple;
   fields[26]="TAKE_PROFIT";
   fields[27]="0";
   fields[28]=(partial ? "1" : "0");
   fields[29]="NORMAL";
   fields[30]="0.0";
   fields[31]="0.25";
   fields[32]="0.55";
   fields[33]="1.0";
   fields[34]="0.0";
   fields[35]="VWAP_BULLISH";
   fields[36]="VP_NEUTRAL";
   fields[37]="UNAVAILABLE";
   fields[38]="BOS_BULLISH";
   fields[39]="SWEEP_LOW";
   fields[40]="ALLOW";
   fields[41]="LONDON";
   fields[42]=provenance;
   fields[43]=IntegerToString((long)positionId);

   string row="";
   for(int i=0;i<AX_TEST_FIELD_COUNT;i++)
     {
      if(i>0) row+=",";
      row+=fields[i];
     }
   return(row);
  }

bool WriteFixture(const string fileName,const string rowOne,
                  const string rowTwo="",const string rowThree="",
                  const string rowFour="")
  {
   int handle=FileOpen(fileName,FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(handle==INVALID_HANDLE)
     {
      PrintFormat("FIXTURE ERROR: FileOpen(%s) failed, error=%d",fileName,GetLastError());
      return(false);
     }

   bool ok=(FileWriteString(handle,MakeHeader()+"\r\n")>0);
   if(ok && rowOne!="") ok=(FileWriteString(handle,rowOne+"\r\n")>0);
   if(ok && rowTwo!="") ok=(FileWriteString(handle,rowTwo+"\r\n")>0);
   if(ok && rowThree!="") ok=(FileWriteString(handle,rowThree+"\r\n")>0);
   if(ok && rowFour!="") ok=(FileWriteString(handle,rowFour+"\r\n")>0);
   FileFlush(handle);
   FileClose(handle);
   return(ok);
  }

void OnStart(void)
  {
   string eaName="AXJournalRecoveryHarness";
   string symbol=_Symbol;
   string v3=StringFormat("%s_%s_TradeAutopsy_v3.csv",eaName,symbol);
   string v4=StringFormat("%s_%s_TradeAutopsy_v4.csv",eaName,symbol);

   FileDelete(v3);
   FileDelete(v4);

   // The same deal appears in both versions. v3's zero-R value is ambiguous
   // and must be restored as unavailable, not as a measured breakeven.
   string legacy=MakeTradeRow(1001,7001,"FORWARD_DEMO",false,"0.000","100.25");
   string duplicate=MakeTradeRow(1001,7001,"FORWARD_DEMO",false,"1.400","100.25");
   string partial=MakeTradeRow(1002,7001,"FORWARD_DEMO",true,"0.500","100.25");
   string unknown=MakeTradeRow(1003,7002,"UNKNOWN",false,"1.000","100.25");
   string malformed=MakeTradeRow(1004,7003,"FORWARD_DEMO",false,"1.000","BROKEN");

   bool v3Written=WriteFixture(v3,legacy);
   bool v4Written=WriteFixture(v4,duplicate,partial,unknown,malformed);
   AssertTrue(v3Written,"v3 journal fixture written");
   AssertTrue(v4Written,"v4 journal fixture written");
   if(!v3Written || !v4Written)
     {
      FileDelete(v3);
      FileDelete(v4);
      return;
     }

   CTradeAutopsy autopsy;
   bool initialized=autopsy.Init(eaName,symbol);
   AssertTrue(initialized,"journal recovery initializes from both versions");
   if(!initialized)
     {
      autopsy.Deinit();
      FileDelete(v3);
      FileDelete(v4);
      return;
     }

   AssertTrue(autopsy.Count()==3,
              "restores valid unique records and rejects malformed row");
   SAxTradeRecord record;
   bool gotLegacy=autopsy.GetRecord(0,record);
   AssertTrue(gotLegacy && record.dealIdOut==1001 &&
              record.rMultiple==EMPTY_VALUE,
              "legacy v3 zero-R is restored as unavailable");
   bool gotPartial=autopsy.GetRecord(1,record);
   AssertTrue(gotPartial && record.dealIdOut==1002 && record.isPartial,
              "partial exit is retained as a partial record");
   bool gotUnknown=autopsy.GetRecord(2,record);
   AssertTrue(gotUnknown && record.dealIdOut==1003 &&
              record.provenance==AX_PROVENANCE_UNKNOWN,
              "unknown provenance is retained but not relabelled");

   SAxTradeRecord forwardRecords[];
   int forwardCount=autopsy.GetDatasetRecords(AX_PROVENANCE_FORWARD_DEMO,
                                               forwardRecords);
   AssertTrue(forwardCount==1,
              "learning dataset excludes partial exits and unknown provenance");
   AssertTrue(forwardCount==1 && forwardRecords[0].dealIdOut==1001,
              "duplicate broker deal across v3/v4 is counted once");

   autopsy.Deinit();
   FileDelete(v3);
   FileDelete(v4);

   PrintFormat("JOURNAL RECOVERY HARNESS: %d assertions, %d failures.",
               g_assertions,g_failures);
   if(g_failures>0)
      Print("RESULT: FAIL. Do not promote this recovery implementation.");
   else
      Print("RESULT: PASS. This script validates local journal parsing only, not MetaEditor compilation or broker execution.");
  }
//+------------------------------------------------------------------+
