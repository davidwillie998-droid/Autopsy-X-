//+------------------------------------------------------------------+
//| TradeJournal.mqh                                                    |
//| Forensic record of every closed trade, persisted to a CSV file so |
//| the autopsy survives terminal restarts and can be reloaded to     |
//| seed the probability/seasonality/diagnostic engines on OnInit.    |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_AUTOPSY_TRADEJOURNAL_MQH
#define AX_AUTOPSY_TRADEJOURNAL_MQH
#include "../core/Types.mqh"

class CTradeJournal
  {
private:
   string    m_fileName;
   AXAutopsy m_records[];

   string B2S(bool v) const { return v?"1":"0"; }

public:
   void Init(const string symbol, long magic)
     {
      m_fileName = StringFormat("AutopsyX_Journal_%s_%I64d.csv", symbol, magic);
      ArrayResize(m_records, 0);
      LoadFromDisk();
     }

   int Count() const { return ArraySize(m_records); }
   AXAutopsy GetRecord(int i) const { return m_records[i]; }

   //--- append one closed-trade record to memory and disk (never overwrites prior history)
   void Append(const AXAutopsy &rec)
     {
      int n = ArraySize(m_records);
      ArrayResize(m_records, n+1);
      m_records[n] = rec;
      AppendToDisk(rec);
     }

   double WinRate(int lastN=0) const
     {
      int n = ArraySize(m_records);
      int start = (lastN>0 && lastN<n) ? n-lastN : 0;
      int wins=0, total=0;
      for(int i=start;i<n;i++)
        {
         total++;
         if(m_records[i].netProfit>0.0) wins++;
        }
      return total>0 ? (double)wins/total*100.0 : 0.0;
     }

   double AverageR(int lastN=0) const
     {
      int n = ArraySize(m_records);
      int start = (lastN>0 && lastN<n) ? n-lastN : 0;
      double sum=0.0; int total=0;
      for(int i=start;i<n;i++) { sum+=m_records[i].rMultiple; total++; }
      return total>0 ? sum/total : 0.0;
     }

   double Expectancy(int lastN=0) const { return AverageR(lastN); }

   double ProfitFactor(int lastN=0) const
     {
      int n = ArraySize(m_records);
      int start = (lastN>0 && lastN<n) ? n-lastN : 0;
      double grossWin=0.0, grossLoss=0.0;
      for(int i=start;i<n;i++)
        {
         if(m_records[i].netProfit>0.0) grossWin+=m_records[i].netProfit;
         else grossLoss += -m_records[i].netProfit;
        }
      return grossLoss>0.0 ? grossWin/grossLoss : (grossWin>0.0? DBL_MAX : 0.0);
     }

   int MaxConsecutiveLosses(int lastN=0) const
     {
      int n = ArraySize(m_records);
      int start = (lastN>0 && lastN<n) ? n-lastN : 0;
      int worst=0, cur=0;
      for(int i=start;i<n;i++)
        {
         if(m_records[i].netProfit<=0.0) { cur++; worst=MathMax(worst,cur); }
         else cur=0;
        }
      return worst;
     }

   double SetupExpectancy(ENUM_AX_SETUP setup, int lastN=0) const
     {
      string label = AXSetupToString(setup);
      int n = ArraySize(m_records);
      int start = (lastN>0 && lastN<n) ? n-lastN : 0;
      double sum=0.0; int total=0;
      for(int i=start;i<n;i++)
        {
         if(m_records[i].setupType==label) { sum+=m_records[i].rMultiple; total++; }
        }
      return total>0 ? sum/total : 0.0;
     }

   double RegimeExpectancy(ENUM_AX_REGIME regime, int lastN=0) const
     {
      string label = AXRegimeToString(regime);
      int n = ArraySize(m_records);
      int start = (lastN>0 && lastN<n) ? n-lastN : 0;
      double sum=0.0; int total=0;
      for(int i=start;i<n;i++)
        {
         if(m_records[i].regime==label) { sum+=m_records[i].rMultiple; total++; }
        }
      return total>0 ? sum/total : 0.0;
     }

private:
   void AppendToDisk(const AXAutopsy &r)
     {
      bool exists = FileIsExist(m_fileName);
      int handle = FileOpen(m_fileName, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_SHARE_READ, ',');
      if(handle==INVALID_HANDLE) return;
      if(!exists) WriteHeader(handle);
      FileSeek(handle, 0, SEEK_END);
      FileWrite(handle,
                (long)r.ticket, r.setupType, r.regime, r.htfBias, r.liquidityObjective, r.poi, r.entryTF,
                DoubleToString(r.entryPrice,_Digits), DoubleToString(r.stopLoss,_Digits),
                DoubleToString(r.tp1,_Digits), DoubleToString(r.tp2,_Digits), DoubleToString(r.tpFinal,_Digits),
                DoubleToString(r.riskPercent,3), DoubleToString(r.rMultiple,3),
                DoubleToString(r.mfeR,3), DoubleToString(r.maeR,3), (long)r.holdingSeconds,
                DoubleToString(r.spreadAtEntry,2), DoubleToString(r.commission,2), DoubleToString(r.swapTotal,2),
                DoubleToString(r.slippagePoints,2), r.newsEnvironment, r.macroContext, r.correlationNote,
                r.executionQuality, AXExitReasonToString(r.exitReason), AXOutcomeToString(r.outcome),
                (long)r.openTime, (long)r.closeTime, DoubleToString(r.netProfit,2));
      FileClose(handle);
     }

   void WriteHeader(int handle)
     {
      FileWrite(handle, "ticket","setupType","regime","htfBias","liquidityObjective","poi","entryTF",
                "entryPrice","stopLoss","tp1","tp2","tpFinal","riskPercent","rMultiple","mfeR","maeR",
                "holdingSeconds","spreadAtEntry","commission","swapTotal","slippagePoints",
                "newsEnvironment","macroContext","correlationNote","executionQuality",
                "exitReason","outcome","openTime","closeTime","netProfit");
     }

   void LoadFromDisk()
     {
      if(!FileIsExist(m_fileName)) return;
      int handle = FileOpen(m_fileName, FILE_READ|FILE_CSV|FILE_ANSI|FILE_SHARE_READ, ',');
      if(handle==INVALID_HANDLE) return;

      bool firstLine = true;
      while(!FileIsEnding(handle))
        {
         string ticketS = FileReadString(handle);
         if(ticketS=="") break;
         if(firstLine) { firstLine=false; if(ticketS=="ticket") { SkipRestOfLine(handle); continue; } }

         AXAutopsy r;
         r.ticket = (ulong)StringToInteger(ticketS);
         r.setupType = FileReadString(handle);
         r.regime = FileReadString(handle);
         r.htfBias = FileReadString(handle);
         r.liquidityObjective = FileReadString(handle);
         r.poi = FileReadString(handle);
         r.entryTF = FileReadString(handle);
         r.entryPrice = StringToDouble(FileReadString(handle));
         r.stopLoss = StringToDouble(FileReadString(handle));
         r.tp1 = StringToDouble(FileReadString(handle));
         r.tp2 = StringToDouble(FileReadString(handle));
         r.tpFinal = StringToDouble(FileReadString(handle));
         r.riskPercent = StringToDouble(FileReadString(handle));
         r.rMultiple = StringToDouble(FileReadString(handle));
         r.mfeR = StringToDouble(FileReadString(handle));
         r.maeR = StringToDouble(FileReadString(handle));
         r.holdingSeconds = StringToInteger(FileReadString(handle));
         r.spreadAtEntry = StringToDouble(FileReadString(handle));
         r.commission = StringToDouble(FileReadString(handle));
         r.swapTotal = StringToDouble(FileReadString(handle));
         r.slippagePoints = StringToDouble(FileReadString(handle));
         r.newsEnvironment = FileReadString(handle);
         r.macroContext = FileReadString(handle);
         r.correlationNote = FileReadString(handle);
         r.executionQuality = FileReadString(handle);
         r.exitReason = EXIT_NONE; // string re-parse not required for stats consumers
         FileReadString(handle); // exitReason label (kept as text on disk; stats use netProfit/rMultiple)
         r.outcome = OUT_UNKNOWN;
         FileReadString(handle); // outcome label
         r.openTime = (datetime)StringToInteger(FileReadString(handle));
         r.closeTime = (datetime)StringToInteger(FileReadString(handle));
         r.netProfit = StringToDouble(FileReadString(handle));

         int n=ArraySize(m_records); ArrayResize(m_records,n+1); m_records[n]=r;
        }
      FileClose(handle);
     }

   void SkipRestOfLine(int handle)
     {
      for(int i=0;i<29;i++) FileReadString(handle);
     }
  };
#endif // AX_AUTOPSY_TRADEJOURNAL_MQH
