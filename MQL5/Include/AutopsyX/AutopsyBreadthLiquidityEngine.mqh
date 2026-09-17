//+------------------------------------------------------------------+
//| AutopsyBreadthLiquidityEngine.mqh                                    |
//| BREADTH_SCORE and LIQUIDITY_SCORE.                                 |
//|                                                                    |
//| Honesty first: MT5 has no native Nasdaq advance/decline line, no  |
//| "% of stocks above their moving average" feed, and no official    |
//| constituent list. Breadth here is a REAL measurement, not a       |
//| fabrication - but of a user-configured basket of large-cap/       |
//| semiconductor symbols (whatever the broker actually offers as     |
//| tradeable CFDs/stocks), not the official Nasdaq breadth series.   |
//| An empty basket degrades to zero reliability rather than          |
//| pretending to know Nasdaq-wide participation.                     |
//+------------------------------------------------------------------+
#property strict
#ifndef AUTOPSYX_BREADTHLIQUIDITYENGINE_MQH
#define AUTOPSYX_BREADTHLIQUIDITYENGINE_MQH
#include "AutopsyTypes.mqh"

class CAutopsyBreadthLiquidityEngine
  {
private:
   string m_qqqSymbol;
   string m_basketSymbols[];
   int    m_basketMaHandles[];
   int    m_maPeriod;

   bool SymbolAvailable(const string sym) const
     {
      return sym!="" && SymbolSelect(sym,true) && SymbolInfoDouble(sym,SYMBOL_BID)>0.0;
     }

   void ParseBasketAndBuildHandles(const string csv)
     {
      ArrayResize(m_basketSymbols,0);
      ArrayResize(m_basketMaHandles,0);
      string parts[];
      int n = StringSplit(csv, ',', parts);
      for(int i=0;i<n;i++)
        {
         string s = parts[i];
         StringTrimLeft(s); StringTrimRight(s);
         if(s=="" || !SymbolAvailable(s)) continue;
         int h = iMA(s, PERIOD_D1, m_maPeriod, 0, MODE_SMA, PRICE_CLOSE);
         if(h==INVALID_HANDLE) continue;
         int k = ArraySize(m_basketSymbols);
         ArrayResize(m_basketSymbols, k+1); ArrayResize(m_basketMaHandles, k+1);
         m_basketSymbols[k]=s; m_basketMaHandles[k]=h;
        }
     }

   double RelativeVolume(int avgLookback=20) const
     {
      MqlRates rates[];
      int copied = CopyRates(m_qqqSymbol, PERIOD_D1, 1, MathMax(5,avgLookback)+1, rates);
      if(copied<6) return 1.0;
      ArraySetAsSeries(rates, true);
      double todayVol = rates[0].real_volume>0 ? (double)rates[0].real_volume : (double)rates[0].tick_volume;
      double sum=0.0; int n=0;
      for(int i=1;i<copied;i++)
        {
         double v = rates[i].real_volume>0 ? (double)rates[i].real_volume : (double)rates[i].tick_volume;
         if(v>0.0) { sum+=v; n++; }
        }
      if(n<3 || sum<=0.0) return 1.0;
      return todayVol/(sum/n);
     }

   double DayChangePct() const
     {
      double now = iClose(m_qqqSymbol, PERIOD_D1, 1);
      double prev = iClose(m_qqqSymbol, PERIOD_D1, 2);
      if(now<=0.0 || prev<=0.0) return 0.0;
      return (now-prev)/prev*100.0;
     }

   //--- participation at the CURRENT hour-of-day vs this symbol's own trailing average volume at that
   //--- same hour - most informative right at the session open, but computed generally so it degrades
   //--- gracefully (and stays honest) whenever called mid-session rather than pretending it's the open
   double IntradayParticipationRatio(int lookbackDays=20) const
     {
      MqlDateTime nowDt; TimeToStruct(TimeCurrent(), nowDt);
      int targetHour = nowDt.hour;

      MqlRates h1[];
      int needed = 24*(lookbackDays+2);
      int copied = CopyRates(m_qqqSymbol, PERIOD_H1, 1, needed, h1);
      if(copied<48) return 1.0;
      ArraySetAsSeries(h1, true);

      bool haveCurrent=false; double currentVol=0.0;
      double sumHist=0.0; int nHist=0;
      for(int i=0;i<copied;i++)
        {
         MqlDateTime dt; TimeToStruct(h1[i].time, dt);
         if(dt.hour != targetHour) continue;
         double v = h1[i].real_volume>0 ? (double)h1[i].real_volume : (double)h1[i].tick_volume;
         if(!haveCurrent) { currentVol=v; haveCurrent=true; continue; }
         sumHist+=v; nHist++;
         if(nHist>=lookbackDays) break;
        }
      if(!haveCurrent || nHist<3 || sumHist<=0.0) return 1.0;
      double avgHist = sumHist/nHist;
      return avgHist>0.0 ? currentVol/avgHist : 1.0;
     }

public:
   void Init(const string qqqSymbol, const string breadthBasketCsv="", int maPeriod=50)
     {
      m_qqqSymbol = qqqSymbol;
      m_maPeriod = MathMax(5, maPeriod);
      if(m_qqqSymbol!="") SymbolSelect(m_qqqSymbol, true);
      ParseBasketAndBuildHandles(breadthBasketCsv);
     }

   void Deinit()
     {
      for(int i=0;i<ArraySize(m_basketMaHandles);i++)
         if(m_basketMaHandles[i]!=INVALID_HANDLE) IndicatorRelease(m_basketMaHandles[i]);
     }

   int BasketUsableCount() const { return ArraySize(m_basketSymbols); }

   //--- BREADTH_SCORE -100..100 = (%basket-above-its-own-MA - 50) x 2; reliabilityOut = fraction of the
   //--- configured basket that actually resolved to real, live data this call
   double ComputeBreadthScore(double &reliabilityOut) const
     {
      int total = ArraySize(m_basketSymbols);
      if(total==0) { reliabilityOut=0.0; return 0.0; }

      int above=0, usable=0;
      for(int i=0;i<total;i++)
        {
         if(!SymbolAvailable(m_basketSymbols[i])) continue;
         double price = SymbolInfoDouble(m_basketSymbols[i], SYMBOL_BID);
         double buf[];
         if(CopyBuffer(m_basketMaHandles[i],0,0,1,buf)<=0) continue;
         usable++;
         if(price>buf[0]) above++;
        }
      if(usable==0) { reliabilityOut=0.0; return 0.0; }
      reliabilityOut = (double)usable/(double)total;
      double pctAbove = (double)above/(double)usable*100.0;
      return MathMax(-100.0, MathMin(100.0, (pctAbove-50.0)*2.0));
     }

   //--- LIQUIDITY_SCORE 0..100: relative volume (60%), current-hour participation (40%), with a
   //--- penalty when a significant day's move happened on below-average volume (unconfirmed move)
   double ComputeLiquidityScore(bool &dataAvailable) const
     {
      dataAvailable = SymbolAvailable(m_qqqSymbol);
      if(!dataAvailable) return 50.0;

      double relVol = RelativeVolume();
      double intraday = IntradayParticipationRatio();
      double relVolScore   = MathMax(0.0, MathMin(100.0, relVol*50.0));   // 1.0x->50, 2.0x+->100
      double intradayScore = MathMax(0.0, MathMin(100.0, intraday*50.0));

      double dayChange = DayChangePct();
      double confirmAdj = 0.0;
      if(MathAbs(dayChange)>=0.3) confirmAdj = (relVol>=1.0) ? 10.0 : -15.0;

      double score = relVolScore*0.6 + intradayScore*0.4 + confirmAdj;
      return MathMax(0.0, MathMin(100.0, score));
     }
  };
#endif // AUTOPSYX_BREADTHLIQUIDITYENGINE_MQH
