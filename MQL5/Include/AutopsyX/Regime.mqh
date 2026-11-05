//+------------------------------------------------------------------+
//|                                                       Regime.mqh |
//|  Market Regime Engine (spec section 7)                           |
//|                                                                    |
//|  Why short, fixed bar-count windows instead of long calendar      |
//|  formation/holding periods: fixed multi-week/month lookback       |
//|  windows are the kind of setup documented to have grown           |
//|  increasingly crowded and to decay faster since roughly the       |
//|  early 2010s as momentum-factor strategies proliferated. This     |
//|  engine instead keeps the trend/breakout lookback short           |
//|  (AX_REGIME_TREND_BARS/AX_REGIME_BREAKOUT_BARS, 20 bars on         |
//|  whatever timeframe InpRegimeTimeframe is set to - by default a   |
//|  few minutes, not weeks) and layers a volatility-ratio read        |
//|  (m_volRatio = current ATR / average ATR over                     |
//|  AX_REGIME_ATR_LOOKBACK) on top to classify the CURRENT regime     |
//|  (high-vol/low-vol/chaotic/trending). To be precise about what     |
//|  that does and doesn't mean: the lookback WINDOW LENGTH itself     |
//|  (20 bars) is fixed, not literally resized as volatility changes - |
//|  it's the regime CLASSIFICATION, and the resulting aggression      |
//|  multiplier applied elsewhere, that adapts to current volatility,  |
//|  not the window's own size. That's a real distinction worth        |
//|  stating plainly rather than overclaiming a fully adaptive-window  |
//|  design this file doesn't actually implement.                     |
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

   //--- call once per new bar. Every structural input is taken from completed bars (shift 1+).
   void              Update(void)
     {
      ResetUnavailable();
      if(m_atrHandle==INVALID_HANDLE) return;

      // The newest completed ATR is shift 1. The reference mean uses the 100
      // completed ATR observations before it, avoiding both the forming bar and
      // self-inclusion of the observation being ranked.
      double atrBuf[];
      ArraySetAsSeries(atrBuf,true);
      int need = AX_REGIME_ATR_LOOKBACK+1;
      int copiedAtr = CopyBuffer(m_atrHandle,0,1,need,atrBuf);
      if(copiedAtr<need) return;

      m_currentAtr = atrBuf[0];
      if(!MathIsValidNumber(m_currentAtr) || m_currentAtr<=0.0)
        {
         ResetUnavailable();
         return;
        }

      double sum=0.0;
      for(int i=1;i<=AX_REGIME_ATR_LOOKBACK;i++)
        {
         if(!MathIsValidNumber(atrBuf[i]) || atrBuf[i]<=0.0)
           {
            ResetUnavailable();
            return;
           }
         sum+=atrBuf[i];
        }
      m_avgAtr = sum/(double)AX_REGIME_ATR_LOOKBACK;
      if(!MathIsValidNumber(m_avgAtr) || m_avgAtr<=0.0)
        {
         ResetUnavailable();
         return;
        }
      m_volRatio = m_currentAtr/m_avgAtr;

      // Regression uses the 20 most recently completed closes, never bar 0.
      double closes[];
      ArraySetAsSeries(closes,true);
      int copied = CopyClose(m_symbol,m_tf,1,AX_REGIME_TREND_BARS,closes);
      if(copied<AX_REGIME_TREND_BARS)
        {
         ResetUnavailable();
         return;
        }
      for(int i=0;i<copied;i++)
        {
         if(!MathIsValidNumber(closes[i]) || closes[i]<=0.0)
           {
            ResetUnavailable();
            return;
           }
        }
      ComputeRegression(closes,copied);

      // A breakout is evaluated only after the latest completed OHLC bar is available.
      bool breakoutDataAvailable=false;
      m_isBreakout = DetectBreakout(breakoutDataAvailable);
      if(!breakoutDataAvailable)
        {
         ResetUnavailable();
         return;
        }

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
   void              ResetUnavailable(void)
     {
      m_currentAtr=0.0;
      m_avgAtr=0.0;
      m_volRatio=0.0;
      m_slope=0.0;
      m_r2=0.0;
      m_isBreakout=false;
      m_regime=AX_REGIME_UNSAFE;
     }

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

   bool              DetectBreakout(bool &dataAvailable)
     {
      dataAvailable=false;
      double high[],low[],close[];
      ArraySetAsSeries(high,true);
      ArraySetAsSeries(low,true);
      ArraySetAsSeries(close,true);
      int n = AX_REGIME_BREAKOUT_BARS;

      // Shift 1 is the latest completed bar. Indices 1..n-1 are the
      // preceding completed bars used to build the comparison range.
      if(CopyHigh(m_symbol,m_tf,1,n,high)<n) return(false);
      if(CopyLow(m_symbol,m_tf,1,n,low)<n) return(false);
      if(CopyClose(m_symbol,m_tf,1,n,close)<n) return(false);

      for(int i=0;i<n;i++)
        {
         if(!MathIsValidNumber(high[i]) || !MathIsValidNumber(low[i]) ||
            !MathIsValidNumber(close[i]) || high[i]<=0.0 || low[i]<=0.0 ||
            close[i]<=0.0 || high[i]<low[i] || close[i]<low[i] || close[i]>high[i])
            return(false);
        }
      dataAvailable=true;

      double priorHigh=-DBL_MAX, priorLow=DBL_MAX, sumRange=0.0;
      for(int i=1;i<n;i++)
        {
         if(high[i]>priorHigh) priorHigh=high[i];
         if(low[i]<priorLow) priorLow=low[i];
         sumRange += (high[i]-low[i]);
        }
      double avgRange = sumRange/(double)(n-1);
      double latestRange = high[0]-low[0];
      bool rangeExpansion = avgRange>0.0 && latestRange > avgRange*1.8;
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
