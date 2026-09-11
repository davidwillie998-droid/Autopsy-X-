//+------------------------------------------------------------------+
//|                                                       Regime.mqh |
//|  Market Regime Engine (spec section 7)                           |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_REGIME_MQH
#define AX_REGIME_MQH
#include "Defs.mqh"

#define AX_REGIME_ATR_PERIOD    14
#define AX_REGIME_ATR_LOOKBACK  100
#define AX_REGIME_TREND_BARS    20
#define AX_REGIME_BREAKOUT_BARS 20

class CRegimeEngine
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;
   int               m_atrHandle;

   double            m_currentAtr;
   double            m_avgAtr;
   double            m_volRatio;
   double            m_slope;       // points/bar, signed
   double            m_r2;          // 0..1 goodness of linear fit
   bool              m_isBreakout;
   ENUM_AX_REGIME    m_regime;

public:
                     CRegimeEngine(void) { m_atrHandle=INVALID_HANDLE; m_regime=AX_REGIME_UNSAFE; }

   bool              Init(const string symbol,ENUM_TIMEFRAMES tf=PERIOD_M1)
     {
      m_symbol = symbol;
      m_tf     = tf;
      m_atrHandle = iATR(m_symbol,m_tf,AX_REGIME_ATR_PERIOD);
      return(m_atrHandle!=INVALID_HANDLE);
     }

   void              Deinit(void)
     {
      if(m_atrHandle!=INVALID_HANDLE) IndicatorRelease(m_atrHandle);
     }

   //--- call once per new bar (cheap) ---
   void              Update(void)
     {
      if(m_atrHandle==INVALID_HANDLE) { m_regime=AX_REGIME_UNSAFE; return; }

      double atrBuf[];
      ArraySetAsSeries(atrBuf,true);
      int need = AX_REGIME_ATR_LOOKBACK+2;
      if(CopyBuffer(m_atrHandle,0,0,need,atrBuf) < AX_REGIME_ATR_LOOKBACK)
        {
         m_regime = AX_REGIME_UNSAFE;
         return;
        }
      m_currentAtr = atrBuf[0];
      double sum=0; int cnt=0;
      for(int i=0;i<AX_REGIME_ATR_LOOKBACK && i<ArraySize(atrBuf);i++) { sum+=atrBuf[i]; cnt++; }
      m_avgAtr = (cnt>0)? sum/cnt : m_currentAtr;
      m_volRatio = (m_avgAtr>0)? m_currentAtr/m_avgAtr : 1.0;

      //--- linear regression slope/R^2 of closes over trend window ---
      double closes[];
      ArraySetAsSeries(closes,true);
      int copied = CopyClose(m_symbol,m_tf,0,AX_REGIME_TREND_BARS,closes);
      ComputeRegression(closes,copied);

      //--- breakout detection: latest bar range vs average range, closing beyond prior range ---
      m_isBreakout = DetectBreakout();

      Classify();
     }

   ENUM_AX_REGIME    Regime(void)      const { return(m_regime); }
   double            VolRatio(void)    const { return(m_volRatio); }
   double            Slope(void)       const { return(m_slope); }
   double            R2(void)          const { return(m_r2); }
   double            CurrentAtr(void)  const { return(m_currentAtr); }
   double            AverageAtr(void)  const { return(m_avgAtr); }
   bool              IsBreakout(void)  const { return(m_isBreakout); }

   //--- aggression multiplier applied by EntryEngine/RiskEngine based on regime (section 7) ---
   double            AggressionMultiplier(void) const
     {
      switch(m_regime)
        {
         case AX_REGIME_STRONG_TREND:   return(1.15);
         case AX_REGIME_BREAKOUT:       return(1.10);
         case AX_REGIME_TREND:          return(1.00);
         case AX_REGIME_RANGE:          return(0.80);
         case AX_REGIME_MEAN_REVERSION: return(0.75);
         case AX_REGIME_HIGH_VOL:       return(0.70);
         case AX_REGIME_LOW_VOL:        return(0.50);
         case AX_REGIME_CHAOTIC:        return(0.25);
         case AX_REGIME_UNSAFE:         return(0.0);
        }
      return(0.5);
     }

   bool              TradingAllowed(void) const
     {
      return(m_regime!=AX_REGIME_UNSAFE);
     }

private:
   void              ComputeRegression(const double &y[],const int n)
     {
      m_slope=0; m_r2=0;
      if(n<5) return;
      double sumX=0,sumY=0,sumXY=0,sumXX=0,sumYY=0;
      // series-indexed: y[0] most recent. Use x = bars-ago so x increases into the past.
      for(int i=0;i<n;i++)
        {
         double x = (double)i;
         double v = y[i];
         sumX+=x; sumY+=v; sumXY+=x*v; sumXX+=x*x; sumYY+=v*v;
        }
      double denom = (n*sumXX - sumX*sumX);
      if(MathAbs(denom)<1e-12) return;
      double slopeRaw = (n*sumXY - sumX*sumY)/denom;
      // slopeRaw is d(price)/d(x) where x increases into the past -> invert sign for forward-time slope
      double point = SymbolInfoDouble(m_symbol,SYMBOL_POINT);
      if(point<=0) point=0.00001;
      m_slope = -slopeRaw/point;

      double corrNum = (n*sumXY - sumX*sumY);
      double corrDenom = MathSqrt((n*sumXX-sumX*sumX)*(n*sumYY-sumY*sumY));
      double corr = (corrDenom>1e-12)? corrNum/corrDenom : 0.0;
      m_r2 = corr*corr;
     }

   bool              DetectBreakout(void)
     {
      double high[],low[],close[];
      ArraySetAsSeries(high,true); ArraySetAsSeries(low,true); ArraySetAsSeries(close,true);
      int n = AX_REGIME_BREAKOUT_BARS;
      if(CopyHigh(m_symbol,m_tf,0,n,high)<n) return(false);
      if(CopyLow(m_symbol,m_tf,0,n,low)<n) return(false);
      if(CopyClose(m_symbol,m_tf,0,n,close)<n) return(false);

      double priorHigh=-DBL_MAX, priorLow=DBL_MAX, sumRange=0;
      for(int i=1;i<n;i++)
        {
         if(high[i]>priorHigh) priorHigh=high[i];
         if(low[i]<priorLow) priorLow=low[i];
         sumRange += (high[i]-low[i]);
        }
      double avgRange = sumRange/(n-1);
      double latestRange = high[0]-low[0];
      bool rangeExpansion = avgRange>0 && latestRange > avgRange*1.8;
      bool closedBeyond = (close[0]>priorHigh) || (close[0]<priorLow);
      return(rangeExpansion && closedBeyond);
     }

   void              Classify(void)
     {
      if(m_currentAtr<=0 || m_avgAtr<=0) { m_regime=AX_REGIME_UNSAFE; return; }

      bool erratic = (m_volRatio>2.2 && m_r2<0.25);
      if(erratic) { m_regime=AX_REGIME_CHAOTIC; return; }

      if(m_isBreakout) { m_regime=AX_REGIME_BREAKOUT; return; }

      if(m_r2>=0.70 && MathAbs(m_slope)>0)
        {
         m_regime = (m_volRatio>=1.15) ? AX_REGIME_STRONG_TREND : AX_REGIME_TREND;
         return;
        }
      if(m_r2>=0.40)
        {
         m_regime = AX_REGIME_TREND;
         return;
        }

      if(m_volRatio>=1.6) { m_regime=AX_REGIME_HIGH_VOL; return; }
      if(m_volRatio<=0.55) { m_regime=AX_REGIME_LOW_VOL; return; }

      if(m_r2<0.20) { m_regime=AX_REGIME_MEAN_REVERSION; return; }

      m_regime = AX_REGIME_RANGE;
     }
  };
//+------------------------------------------------------------------+
#endif // AX_REGIME_MQH
