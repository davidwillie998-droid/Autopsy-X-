//+------------------------------------------------------------------+
//|                                RegimeResearchJournalTest.mq5     |
//| Isolated persistence/recovery harness. Never sends broker orders. |
//+------------------------------------------------------------------+
#property strict
#property script_show_inputs

#include <AutopsyX/RegimeResearchJournal.mqh>

int g_assertions=0;
int g_failures=0;

void AssertTrue(const bool condition,const string label)
  {
   g_assertions++;
   if(condition) Print("PASS: ",label);
   else
     {
      g_failures++;
      Print("FAIL: ",label);
     }
  }

string JournalName(const string symbol,const ENUM_TIMEFRAMES timeframe)
  {
   string safe=symbol;
   StringReplace(safe,",","_");
   StringReplace(safe,";","_");
   StringReplace(safe," ","_");
   return(StringFormat("AX_RegimeResearch_%s_%d.csv",safe,(int)timeframe));
  }

string Header(void)
  {
   return("timestamp,symbol,timeframe,data_quality,regime_class,confidence,age_bars,transition,previous_class,base_regime,volatility_state,atr,volatility_percentile,atr_acceleration_pct,macro_available,macro_agreement,slope,vol_ratio");
  }

string ValidRow(const long stamp,const string symbol,const ENUM_TIMEFRAMES timeframe)
  {
   return(StringFormat("%I64d,%s,%d,1,1,75.0,4,0,1,3,1,0.001,55.0,10.0,0,0.0,2.0,1.2",
                       stamp,symbol,(int)timeframe));
  }

bool WriteFixture(const string fileName,const string &rows[])
  {
   int h=FileOpen(fileName,FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(h==INVALID_HANDLE) return(false);
   bool ok=(FileWriteString(h,Header()+"\r\n")>0);
   for(int i=0;i<ArraySize(rows) && ok;i++)
      ok=(FileWriteString(h,rows[i]+"\r\n")>0);
   FileFlush(h);
   FileClose(h);
   return(ok);
  }

ulong ReadFileSize(const string fileName)
  {
   int h=FileOpen(fileName,FILE_READ|FILE_TXT|FILE_ANSI);
   if(h==INVALID_HANDLE) return(0);
   ulong size=FileSize(h);
   FileClose(h);
   return(size);
  }

void OnStart(void)
  {
   string symbol=_Symbol;
   ENUM_TIMEFRAMES timeframe=PERIOD_M1;
   string fileName=JournalName(symbol,timeframe);
   long t1=1790000000;
   long t2=t1+60;
   long t3=t2+60;
   long t4=t3+60;

   FileDelete(fileName);

   // Scenario 1: valid row followed by a truncated final row.
   string rows1[];
   ArrayResize(rows1,2);
   rows1[0]=ValidRow(t1,symbol,timeframe);
   rows1[1]=StringFormat("%I64d,%s,%d,1,1,75.0,4,0,1",t2,symbol,(int)timeframe);
   AssertTrue(WriteFixture(fileName,rows1),"truncated-tail fixture created");

   CRegimeResearchJournal journal;
   bool initialized=journal.Init(symbol,timeframe);
   AssertTrue(initialized && journal.IsPersisting(),"journal initializes with recoverable truncated tail");
   AssertTrue(journal.LastTimestamp()==(datetime)t1,"truncated row is rejected and last complete timestamp is recovered");

   CRegimeEngine baseRegime;
   CVolatilityEngine volatility;
   baseRegime.Init(symbol,timeframe);
   baseRegime.Update();
   volatility.Configure(20.0,80.0,95.0,60.0);
   volatility.Init(symbol,timeframe,AX_VOL_ATR_PERIOD_DEFAULT,100);
   volatility.Update();

   SAxRegimeClassification classification;
   classification.timestamp=(datetime)t2;
   classification.dataQualityOk=true;
   classification.dataQualityReason="";
   classification.regime=AX_RC_PERSISTENT_BULLISH_TREND;
   classification.regimeConfidence=75.0;
   classification.regimeAgeBars=4;
   classification.hasPreviousRegime=true;
   classification.previousRegime=AX_RC_BULLISH_UNSTABLE;
   classification.transitionDetected=false;
   classification.transitionDescription="";

   SAxRegimeIntelligence intelligence;
   intelligence.timestamp=(datetime)t2;
   intelligence.currentRegime=AX_REGIME_TREND;
   intelligence.previousRegime=AX_REGIME_RANGE;
   intelligence.hasPreviousRegime=true;
   intelligence.regimeChanged=false;
   intelligence.regimeAgeBars=4;
   intelligence.regimeStability=80.0;
   intelligence.regimeConfidence=75.0;
   intelligence.macroDataAvailable=false;
   intelligence.macroAgreementScore=0.0;

   bool appended=initialized && journal.Record(classification,intelligence,baseRegime,volatility);
   AssertTrue(appended,"valid new bar appends after truncated tail with a line boundary");
   journal.Deinit();
   baseRegime.Deinit();
   volatility.Deinit();

   CRegimeResearchJournal recovered;
   bool recoveredOk=recovered.Init(symbol,timeframe);
   AssertTrue(recoveredOk && recovered.LastTimestamp()==(datetime)t2,
              "restart recovers the newly appended complete row");
   ulong beforeDuplicate=ReadFileSize(fileName);
   bool duplicateAccepted=recovered.Record(classification,intelligence,baseRegime,volatility);
   recovered.Deinit();
   ulong afterDuplicate=ReadFileSize(fileName);
   AssertTrue(duplicateAccepted && beforeDuplicate==afterDuplicate,
              "replayed bar is idempotent and does not append a duplicate");

   // Scenario 2: malformed numeric row between two valid rows must not hide the later valid row.
   FileDelete(fileName);
   string rows2[];
   ArrayResize(rows2,3);
   rows2[0]=ValidRow(t1,symbol,timeframe);
   rows2[1]=StringFormat("%I64d,%s,%d,1,1,BROKEN,4,0,1,3,1,0.001,55.0,10.0,0,0.0,2.0,1.2",
                         t2,symbol,(int)timeframe);
   rows2[2]=ValidRow(t3,symbol,timeframe);
   AssertTrue(WriteFixture(fileName,rows2),"malformed-middle-row fixture created");

   CRegimeResearchJournal middleRecovery;
   bool middleOk=middleRecovery.Init(symbol,timeframe);
   AssertTrue(middleOk && middleRecovery.LastTimestamp()==(datetime)t3,
              "malformed numeric row is rejected while later complete row is recovered");
   middleRecovery.Deinit();

   // Scenario 3: malformed numeric value in the final row is never treated as durable.
   FileDelete(fileName);
   string rows3[];
   ArrayResize(rows3,2);
   rows3[0]=ValidRow(t1,symbol,timeframe);
   rows3[1]=StringFormat("%I64d,%s,%d,1,1,NOT_A_NUMBER,4,0,1,3,1,0.001,55.0,10.0,0,0.0,2.0,1.2",
                         t4,symbol,(int)timeframe);
   AssertTrue(WriteFixture(fileName,rows3),"malformed-final-row fixture created");

   CRegimeResearchJournal finalRecovery;
   bool finalOk=finalRecovery.Init(symbol,timeframe);
   AssertTrue(finalOk && finalRecovery.LastTimestamp()==(datetime)t1,
              "malformed final numeric row is excluded from recovered timestamp");
   finalRecovery.Deinit();

   FileDelete(fileName);
   PrintFormat("REGIME JOURNAL HARNESS: %d assertions, %d failures.",g_assertions,g_failures);
   if(g_failures>0)
      Print("RESULT: FAIL. Do not promote regime journal persistence.");
   else
      Print("RESULT: PASS. Local MT5 file persistence only; no broker execution or strategy performance is tested.");
  }
//+------------------------------------------------------------------+
