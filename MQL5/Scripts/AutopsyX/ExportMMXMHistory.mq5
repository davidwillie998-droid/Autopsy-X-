//+------------------------------------------------------------------+
//| ExportMMXMHistory.mq5                                            |
//| Export aligned H4 and M15 OHLC history for MMXM chronological    |
//| replay. Data is written in broker-server time to MQL5/Files.     |
//+------------------------------------------------------------------+
#property strict
#property script_show_inputs

input string InpSymbol = "";          // Empty uses the chart symbol
input int    InpHistoryDays = 730;     // Two years by default
input string InpFilePrefix = "MMXM";  // Output: PREFIX_SYMBOL_H4/M15.csv

bool ExportTimeframe(const string symbol,
                     const ENUM_TIMEFRAMES timeframe,
                     const datetime fromTime,
                     const datetime toTime,
                     const string fileName)
  {
   MqlRates rates[];
   ArraySetAsSeries(rates,false); // Oldest to newest for deterministic replay.
   ResetLastError();
   int copied=CopyRates(symbol,timeframe,fromTime,toTime,rates);
   if(copied<=0)
     {
      PrintFormat("MMXM EXPORT FAILED: %s %s CopyRates=%d error=%d",
                  symbol,EnumToString(timeframe),copied,GetLastError());
      return(false);
     }

   int handle=FileOpen(fileName,FILE_WRITE|FILE_CSV|FILE_ANSI,',');
   if(handle==INVALID_HANDLE)
     {
      PrintFormat("MMXM EXPORT FAILED: cannot open %s error=%d",
                  fileName,GetLastError());
      return(false);
     }

   FileWrite(handle,"time_server","open","high","low","close",
             "tick_volume","real_volume","spread_points");
   int digits=(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
   for(int i=0;i<copied;i++)
     {
      FileWrite(handle,
                TimeToString(rates[i].time,TIME_DATE|TIME_MINUTES),
                DoubleToString(rates[i].open,digits),
                DoubleToString(rates[i].high,digits),
                DoubleToString(rates[i].low,digits),
                DoubleToString(rates[i].close,digits),
                (long)rates[i].tick_volume,
                (long)rates[i].real_volume,
                rates[i].spread);
     }
   FileClose(handle);

   PrintFormat("MMXM EXPORT OK: %s %s rows=%d from=%s to=%s file=MQL5/Files/%s",
               symbol,EnumToString(timeframe),copied,
               TimeToString(rates[0].time,TIME_DATE|TIME_MINUTES),
               TimeToString(rates[copied-1].time,TIME_DATE|TIME_MINUTES),
               fileName);
   return(true);
  }

void OnStart()
  {
   string symbol=(StringLen(InpSymbol)>0 ? InpSymbol : _Symbol);
   if(!SymbolSelect(symbol,true))
     {
      PrintFormat("MMXM EXPORT FAILED: symbol unavailable: %s",symbol);
      return;
     }
   if(InpHistoryDays<30 || InpHistoryDays>3650)
     {
      Print("MMXM EXPORT FAILED: InpHistoryDays must be between 30 and 3650.");
      return;
     }

   datetime toTime=TimeTradeServer();
   if(toTime<=0) toTime=TimeCurrent();
   datetime fromTime=toTime-(datetime)InpHistoryDays*86400;
   string safeSymbol=symbol;
   StringReplace(safeSymbol,".","_");
   StringReplace(safeSymbol,"/","_");
   string prefix=InpFilePrefix;
   if(StringLen(prefix)==0) prefix="MMXM";

   string h4File=prefix+"_"+safeSymbol+"_H4.csv";
   string m15File=prefix+"_"+safeSymbol+"_M15.csv";

   bool h4=ExportTimeframe(symbol,PERIOD_H4,fromTime,toTime,h4File);
   bool m15=ExportTimeframe(symbol,PERIOD_M15,fromTime,toTime,m15File);
   if(h4 && m15)
      PrintFormat("MMXM EXPORT COMPLETE: %s. Both files are in the terminal's MQL5/Files folder. Times are broker-server time.",
                  symbol);
   else
      PrintFormat("MMXM EXPORT INCOMPLETE: %s. Check the Experts log and ensure chart history has downloaded.",
                  symbol);
  }
//+------------------------------------------------------------------+
