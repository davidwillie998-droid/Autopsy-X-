//+------------------------------------------------------------------+
//| AutopsyVolatilityEngine.mqh                                         |
//| VOLATILITY_SCORE (0..100, higher = more volatile), its LOW/NORMAL/ |
//| ELEVATED/HIGH/EXTREME classification, and the R6 volatility-shock |
//| detector. Distinguishes LOW-VOL-TREND from HIGH-VOL-TREND - high  |
//| volatility changes risk conditions, it does not by itself mean    |
//| bearish, and this module never asserts a direction of its own.    |
//+------------------------------------------------------------------+
#property strict
#ifndef AUTOPSYX_VOLATILITYENGINE_MQH
#define AUTOPSYX_VOLATILITYENGINE_MQH
#include "AutopsyTypes.mqh"

class CAutopsyVolatilityEngine
  {
private:
   string          m_symbol;
   ENUM_TIMEFRAMES m_tf;
   string          m_vixSymbol;      // optional VIX-proxy CFD/index symbol; "" = not configured
   int             m_atrHandle;
   int             m_atrPeriod;
   int             m_percentileLookback;   // bars of history to rank ATR/realized-vol percentile against
   int             m_realizedVolLookback;  // window (bars) each realized-vol reading is computed over

   //--- classification thresholds on the 0..100 VOLATILITY_SCORE
   double m_lowThresh, m_normalThresh, m_elevatedThresh, m_highThresh;
   //--- VIX reference band used only to normalize an index-level VIX proxy into 0..100 (VIX has no
   //--- meaningful "percentile vs this instrument's own history" the way ATR/realized-vol do)
   double m_vixLowRef, m_vixHighRef;

   //--- shock-detector thresholds (section 7) - "several conditions... simultaneously", never one alone
   double m_shockVixChangePct;
   double m_shockRvolPercentile;
   double m_shockDailyMovePct;
   double m_shockAtrExpansionRatio;
   double m_shockVolumeRatio;
   int    m_shockMinConditions;

   bool   m_dataValid;

public:
   void Init(const string symbol, ENUM_TIMEFRAMES tf=PERIOD_D1, const string vixSymbol="",
             int atrPeriod=14, int percentileLookback=252, int realizedVolLookback=20,
             double lowThresh=20.0, double normalThresh=45.0, double elevatedThresh=65.0, double highThresh=85.0,
             double vixLowRef=12.0, double vixHighRef=40.0,
             double shockVixChangePct=15.0, double shockRvolPercentile=90.0, double shockDailyMovePct=3.0,
             double shockAtrExpansionRatio=1.8, double shockVolumeRatio=2.0, int shockMinConditions=2)
     {
      m_symbol = symbol; m_tf = tf; m_vixSymbol = vixSymbol;
      m_atrPeriod = MathMax(2, atrPeriod);
      m_percentileLookback = MathMax(30, percentileLookback);
      m_realizedVolLookback = MathMax(5, realizedVolLookback);
      m_lowThresh=lowThresh; m_normalThresh=normalThresh; m_elevatedThresh=elevatedThresh; m_highThresh=highThresh;
      m_vixLowRef=vixLowRef; m_vixHighRef=MathMax(vixLowRef+1.0, vixHighRef);
      m_shockVixChangePct=shockVixChangePct; m_shockRvolPercentile=shockRvolPercentile;
      m_shockDailyMovePct=shockDailyMovePct; m_shockAtrExpansionRatio=shockAtrExpansionRatio;
      m_shockVolumeRatio=shockVolumeRatio; m_shockMinConditions=MathMax(1,shockMinConditions);

      m_atrHandle = iATR(m_symbol, m_tf, m_atrPeriod);
      m_dataValid = (m_atrHandle!=INVALID_HANDLE);
      if(m_vixSymbol!="") SymbolSelect(m_vixSymbol, true);
     }

   void Deinit()
     {
      if(m_atrHandle!=INVALID_HANDLE) IndicatorRelease(m_atrHandle);
     }

   bool IsDataValid() const { return m_dataValid; }
   bool VixAvailable() const { return m_vixSymbol!="" && SymbolInfoInteger(m_vixSymbol, SYMBOL_SELECT)!=0; }

   double VixLevel() const { return VixAvailable() ? SymbolInfoDouble(m_vixSymbol, SYMBOL_BID) : 0.0; }

   double VixChangePct() const
     {
      if(!VixAvailable()) return 0.0;
      double now = iClose(m_vixSymbol, PERIOD_D1, 1);
      double prev = iClose(m_vixSymbol, PERIOD_D1, 2);
      if(now<=0.0 || prev<=0.0) return 0.0;
      return (now-prev)/prev*100.0;
     }

   //--- rank of the most recently completed ATR reading against its own trailing distribution, 0..100
   double AtrPercentile(double &currentAtrOut, double &avgAtrOut) const
     {
      currentAtrOut = 0.0; avgAtrOut = 0.0;
      if(!m_dataValid) return 50.0;
      double buf[];
      int n = CopyBuffer(m_atrHandle, 0, 1, m_percentileLookback, buf);
      if(n<10) return 50.0;
      currentAtrOut = buf[0];
      double sum=0.0; int below=0;
      for(int i=1;i<n;i++) { sum+=buf[i]; if(buf[i]<=buf[0]) below++; }
      avgAtrOut = sum/(n-1);
      return (double)below/(double)(n-1)*100.0;
     }

   //--- true annualized-realized-volatility percentile: builds a rolling series of realized-vol
   //--- readings (each an annualized stdev of log returns over m_realizedVolLookback bars) across
   //--- m_percentileLookback historical windows, then ranks today's reading against that distribution.
   //--- Distinct from AtrPercentile - a genuinely separate measurement, not the same number twice.
   double RealizedVolPercentile(double &currentRvolOut) const
     {
      currentRvolOut = 0.0;
      int totalNeeded = m_percentileLookback + m_realizedVolLookback + 2;
      MqlRates rates[];
      int copied = CopyRates(m_symbol, m_tf, 1, totalNeeded, rates);
      if(copied < m_realizedVolLookback+10) return 50.0;
      ArraySetAsSeries(rates, true);

      int maxK = copied - m_realizedVolLookback - 1;
      if(maxK<10) return 50.0;

      double rv[]; ArrayResize(rv, maxK);
      for(int k=0;k<maxK;k++)
        {
         double sum=0.0,sumsq=0.0; int n=0;
         for(int i=k;i<k+m_realizedVolLookback;i++)
           {
            if(rates[i].close<=0.0 || rates[i+1].close<=0.0) continue;
            double r = MathLog(rates[i].close/rates[i+1].close);
            sum+=r; sumsq+=r*r; n++;
           }
         if(n<5) { rv[k]=0.0; continue; }
         double mean=sum/n;
         double variance=MathMax(0.0, sumsq/n-mean*mean);
         rv[k] = MathSqrt(variance)*MathSqrt(252.0)*100.0;
        }

      currentRvolOut = rv[0];
      int below=0;
      for(int k=1;k<maxK;k++) if(rv[k]<=rv[0]) below++;
      return (double)below/(double)(maxK-1)*100.0;
     }

   //--- day's absolute move on the reference symbol, as a percentage of the prior close
   double DailyMovePct() const
     {
      double closeNow = iClose(m_symbol, m_tf, 1);
      double closePrev = iClose(m_symbol, m_tf, 2);
      if(closeNow<=0.0 || closePrev<=0.0) return 0.0;
      return MathAbs(closeNow-closePrev)/closePrev*100.0;
     }

   //--- today's (completed) bar's volume vs its own trailing average - a real, if approximate,
   //--- relative-volume read off tick_volume (or real_volume where the broker/symbol provides it)
   double RelativeVolume(int avgLookback=20) const
     {
      MqlRates rates[];
      int copied = CopyRates(m_symbol, m_tf, 1, MathMax(5,avgLookback)+1, rates);
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
      double avg = sum/n;
      return avg>0.0 ? todayVol/avg : 1.0;
     }

   //--- VOLATILITY_SCORE: 0.4 x ATR percentile + 0.3 x realized-vol percentile + 0.3 x VIX-band score,
   //--- with VIX's weight redistributed proportionally onto the other two when no VIX proxy is configured
   double ComputeScore() const
     {
      if(!m_dataValid) return 50.0;
      double atrCur, atrAvg;
      double atrPct = AtrPercentile(atrCur, atrAvg);
      double rvolCur;
      double rvolPct = RealizedVolPercentile(rvolCur);

      double wAtr=0.4, wRvol=0.3, wVix=0.3, vixScore=0.0;
      if(VixAvailable())
        {
         double lvl = VixLevel();
         vixScore = MathMax(0.0, MathMin(100.0, (lvl-m_vixLowRef)/(m_vixHighRef-m_vixLowRef)*100.0));
        }
      else
        {
         double sum = wAtr+wRvol;
         wAtr/=sum; wRvol/=sum; wVix=0.0;
        }

      double score = wAtr*atrPct + wRvol*rvolPct + wVix*vixScore;
      return MathMax(0.0, MathMin(100.0, score));
     }

   ENUM_AXR_VOL_STATE ClassifyFromScore(double score) const
     {
      if(score<m_lowThresh)      return AXR_VOL_LOW;
      if(score<m_normalThresh)   return AXR_VOL_NORMAL;
      if(score<m_elevatedThresh) return AXR_VOL_ELEVATED;
      if(score<m_highThresh)     return AXR_VOL_HIGH;
      return AXR_VOL_EXTREME;
     }

   //--- R6 trigger: requires m_shockMinConditions (default 2) of the following simultaneously true -
   //--- never a single measurement alone, per the spec's explicit "several conditions" requirement
   bool IsVolatilityShock(string &reasonOut) const
     {
      int hits=0; string reasons="";
      double atrCur, atrAvg;
      double atrPct = AtrPercentile(atrCur, atrAvg);
      double rvolCur;
      double rvolPct = RealizedVolPercentile(rvolCur);
      double dailyMove = DailyMovePct();
      double relVol = RelativeVolume();

      if(VixAvailable() && VixChangePct()>=m_shockVixChangePct)
        { hits++; reasons += StringFormat("VIX +%.1f%%; ", VixChangePct()); }
      if(rvolPct>=m_shockRvolPercentile)
        { hits++; reasons += StringFormat("RealizedVol pct=%.0f; ", rvolPct); }
      if(dailyMove>=m_shockDailyMovePct)
        { hits++; reasons += StringFormat("DailyMove=%.2f%%; ", dailyMove); }
      if(atrAvg>0.0 && (atrCur/atrAvg)>=m_shockAtrExpansionRatio)
        { hits++; reasons += StringFormat("ATR expansion=%.2fx; ", atrCur/atrAvg); }
      if(dailyMove>=m_shockDailyMovePct*0.6 && relVol>=m_shockVolumeRatio)
        { hits++; reasons += StringFormat("Displacement+volume=%.2fx; ", relVol); }

      reasonOut = reasons;
      return hits>=m_shockMinConditions;
     }
  };
#endif // AUTOPSYX_VOLATILITYENGINE_MQH
