//+------------------------------------------------------------------+
//|                                                VolatilityEngine.mqh|
//|  Layer 2: Volatility Engine (institutional engine upgrade) -      |
//|  ENGINEERING DESIGN, not paper-sourced. The source paper (Malhotra|
//|  SSRN 3306817) discusses volatility as a risk indicator in         |
//|  general terms and specifically warns against confusing it with   |
//|  liquidity/risk (findings item xi) - it does not specify a         |
//|  classification implementation.                                    |
//|                                                                    |
//|  Distinct from CRegimeEngine: Regime.mqh classifies TREND/RANGE/   |
//|  BREAKOUT structure (using ATR-ratio as one input among several).  |
//|  This engine answers a narrower question - purely how much price   |
//|  is moving right now, ranked against its own recent history - and  |
//|  is meant to be read ALONGSIDE regime, not instead of it. Per the  |
//|  upgrade's own instruction: "Do not assume high volatility          |
//|  automatically means high risk or low volatility automatically      |
//|  means low risk. Volatility must interact with liquidity and        |
//|  execution conditions" - this engine deliberately does NOT decide   |
//|  risk by itself; it reports a classification for other layers to   |
//|  combine.                                                           |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_VOLATILITYENGINE_MQH
#define AX_VOLATILITYENGINE_MQH
#include "Defs.mqh"

#define AX_VOL_ATR_PERIOD_DEFAULT 14
#define AX_VOL_ACCEL_LOOKBACK     3   // bars back for the acceleration read

class CVolatilityEngine
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;
   int               m_atrHandle;
   int               m_percentileLookback;

   double            m_lowPercentile;     // e.g. 20 - below this percentile rank = LOW
   double            m_highPercentile;    // e.g. 80 - at/above this = HIGH
   double            m_extremePercentile; // e.g. 95 - at/above this = EXTREME
   double            m_shockAccelPct;     // ATR rising more than this % over AX_VOL_ACCEL_LOOKBACK
                                           // bars = SHOCK, regardless of percentile rank

   double            m_currentAtr;
   double            m_percentileRank;    // 0..100
   double            m_accelerationPct;   // % change in ATR over the accel lookback window
   ENUM_AX_VOLATILITY_STATE m_state;

public:
                     CVolatilityEngine(void)
     {
      m_atrHandle=INVALID_HANDLE; m_percentileLookback=100;
      m_lowPercentile=20.0; m_highPercentile=80.0; m_extremePercentile=95.0; m_shockAccelPct=60.0;
      m_currentAtr=0; m_percentileRank=0; m_accelerationPct=0; m_state=AX_VOL_NORMAL;
     }

   bool              Init(const string symbol,const ENUM_TIMEFRAMES tf,
                           const int atrPeriod=AX_VOL_ATR_PERIOD_DEFAULT,const int percentileLookback=100)
     {
      m_symbol=symbol; m_tf=tf; m_percentileLookback=MathMax(20,percentileLookback);
      m_atrHandle = iATR(m_symbol,m_tf,atrPeriod);
      return(m_atrHandle!=INVALID_HANDLE);
     }

   void              Deinit(void)
     {
      if(m_atrHandle!=INVALID_HANDLE) IndicatorRelease(m_atrHandle);
     }

   void              Configure(const double lowPercentile,const double highPercentile,
                                const double extremePercentile,const double shockAccelPct)
     {
      m_lowPercentile     = AxClampD(lowPercentile,0.0,100.0);
      m_highPercentile    = AxClampD(highPercentile,0.0,100.0);
      m_extremePercentile = AxClampD(extremePercentile,0.0,100.0);
      m_shockAccelPct     = MathMax(0.0,shockAccelPct);
     }

   //--- call once per new bar (cheap) ---
   void              Update(void)
     {
      if(m_atrHandle==INVALID_HANDLE) { m_state=AX_VOL_NORMAL; m_currentAtr=0; return; }

      int need = m_percentileLookback+AX_VOL_ACCEL_LOOKBACK+2;
      double atrBuf[];
      ArraySetAsSeries(atrBuf,true);
      int copied = CopyBuffer(m_atrHandle,0,0,need,atrBuf);
      if(copied<m_percentileLookback+AX_VOL_ACCEL_LOOKBACK)
        {
         // not enough history yet to rank/accelerate meaningfully - report NORMAL rather than
         // fabricate a percentile/state from a partial window
         m_state=AX_VOL_NORMAL; m_currentAtr=(copied>0)?atrBuf[0]:0; m_percentileRank=0; m_accelerationPct=0;
         return;
        }

      m_currentAtr = atrBuf[0];

      //--- percentile rank: mid-rank convention (a tie counts as HALF a "below", not a full one) -    ---
      //--- a strict <= comparison would pin the rank to 100 (EXTREME) whenever the whole lookback       ---
      //--- window is flat (a quiet/holiday session, or a feed reporting a fixed ATR), which is the      ---
      //--- opposite of what "how much price is moving" should report for a market not moving at all     ---
      //--- (code-review finding). ---
      double belowWeight=0.0;
      for(int i=1;i<=m_percentileLookback;i++)
        {
         if(atrBuf[i]<m_currentAtr)       belowWeight += 1.0;
         else if(atrBuf[i]==m_currentAtr) belowWeight += 0.5;
        }
      m_percentileRank = 100.0*belowWeight/(double)m_percentileLookback;

      //--- acceleration: % change in ATR over a short recent window - a genuine SPIKE looks very    ---
      //--- different from a high reading that's been sustained for a while, even at the same         ---
      //--- percentile rank ---
      double atrThen = atrBuf[AX_VOL_ACCEL_LOOKBACK];
      m_accelerationPct = (atrThen>0) ? ((m_currentAtr-atrThen)/atrThen)*100.0 : 0.0;

      Classify();
     }

   void              Classify(void)
     {
      //--- SHOCK takes precedence over everything else - a sharp acceleration is the specific        ---
      //--- condition this state exists to flag, regardless of where the percentile rank happens to   ---
      //--- land (a shock starting from a quiet base is still a shock) ---
      if(m_accelerationPct>=m_shockAccelPct) { m_state=AX_VOL_SHOCK; return; }

      if(m_percentileRank>=m_extremePercentile) { m_state=AX_VOL_EXTREME; return; }
      if(m_percentileRank>=m_highPercentile)     { m_state=AX_VOL_HIGH; return; }
      if(m_percentileRank<=m_lowPercentile)      { m_state=AX_VOL_LOW; return; }
      m_state=AX_VOL_NORMAL;
     }

   ENUM_AX_VOLATILITY_STATE State(void)           const { return(m_state); }
   double                   CurrentAtr(void)      const { return(m_currentAtr); }
   double                   PercentileRank(void)  const { return(m_percentileRank); }
   double                   AccelerationPct(void) const { return(m_accelerationPct); }
  };
//+------------------------------------------------------------------+
#endif // AX_VOLATILITYENGINE_MQH
