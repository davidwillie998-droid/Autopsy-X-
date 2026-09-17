//+------------------------------------------------------------------+
//| AutopsyDirectionEngine.mqh                                          |
//| DIRECTION_SCORE (-100..100): EMA20/50/200 structure alignment,     |
//| fractal-based HH/HL vs LH/LL swing detection, N-day breakout/      |
//| breakdown, and normalized momentum. No single component may       |
//| override the composite - each contributes a bounded slice of the  |
//| total, per the spec's explicit instruction not to let one          |
//| indicator dictate the reading.                                    |
//+------------------------------------------------------------------+
#property strict
#ifndef AUTOPSYX_DIRECTIONENGINE_MQH
#define AUTOPSYX_DIRECTIONENGINE_MQH
#include "AutopsyTypes.mqh"

class CAutopsyDirectionEngine
  {
private:
   string          m_symbol;
   ENUM_TIMEFRAMES m_tf;
   int             m_emaFastHandle, m_emaMedHandle, m_emaSlowHandle;
   int             m_breakoutLookback;
   int             m_momentumLookback;
   int             m_swingLookback;
   int             m_fractalWing;      // bars required on each side to confirm a fractal swing point
   bool            m_dataValid;

public:
   void Init(const string symbol, ENUM_TIMEFRAMES tf=PERIOD_D1,
             int emaFast=20, int emaMed=50, int emaSlow=200,
             int breakoutLookback=20, int momentumLookback=10,
             int swingLookback=80, int fractalWing=2)
     {
      m_symbol = symbol; m_tf = tf;
      m_breakoutLookback = MathMax(5, breakoutLookback);
      m_momentumLookback = MathMax(1, momentumLookback);
      m_swingLookback    = MathMax(20, swingLookback);
      m_fractalWing       = MathMax(1, fractalWing);

      m_emaFastHandle = iMA(m_symbol, m_tf, MathMax(1,emaFast), 0, MODE_EMA, PRICE_CLOSE);
      m_emaMedHandle  = iMA(m_symbol, m_tf, MathMax(1,emaMed),  0, MODE_EMA, PRICE_CLOSE);
      m_emaSlowHandle = iMA(m_symbol, m_tf, MathMax(1,emaSlow), 0, MODE_EMA, PRICE_CLOSE);
      m_dataValid = (m_emaFastHandle!=INVALID_HANDLE && m_emaMedHandle!=INVALID_HANDLE && m_emaSlowHandle!=INVALID_HANDLE);
     }

   void Deinit()
     {
      if(m_emaFastHandle!=INVALID_HANDLE) IndicatorRelease(m_emaFastHandle);
      if(m_emaMedHandle!=INVALID_HANDLE)  IndicatorRelease(m_emaMedHandle);
      if(m_emaSlowHandle!=INVALID_HANDLE) IndicatorRelease(m_emaSlowHandle);
     }

   bool IsDataValid() const { return m_dataValid; }

   //--- DIRECTION_SCORE, -100..100, plus a convenience bias bucket
   double Compute(ENUM_AXR_BIAS &bias) const
     {
      bias = AXR_BIAS_NEUTRAL;
      if(!m_dataValid) return 0.0;

      double emaFast[], emaMed[], emaSlow[];
      if(CopyBuffer(m_emaFastHandle,0,0,1,emaFast)<=0) return 0.0;
      if(CopyBuffer(m_emaMedHandle,0,0,1,emaMed)<=0)   return 0.0;
      if(CopyBuffer(m_emaSlowHandle,0,0,1,emaSlow)<=0) return 0.0;

      double price = iClose(m_symbol, m_tf, 0);
      if(price<=0.0) return 0.0;

      double total = StructureScore(price, emaFast[0], emaMed[0], emaSlow[0])
                    + SwingScore()
                    + BreakoutScore(price)
                    + MomentumScore();
      total = MathMax(-100.0, MathMin(100.0, total));

      if(total>=15.0)       bias = AXR_BIAS_BULLISH;
      else if(total<=-15.0) bias = AXR_BIAS_BEARISH;
      else                  bias = AXR_BIAS_NEUTRAL;

      return total;
     }

private:
   //--- +/-40 max: full 3-of-3 EMA stack alignment (price>EMA20>EMA50>EMA200 or fully inverted),
   //--- partial credit for 2-of-3 or 1-of-3 so a transitioning stack isn't scored identically to chop
   double StructureScore(double price, double emaFast, double emaMed, double emaSlow) const
     {
      int bullConds = (price>emaFast?1:0) + (emaFast>emaMed?1:0) + (emaMed>emaSlow?1:0);
      int bearConds = (price<emaFast?1:0) + (emaFast<emaMed?1:0) + (emaMed<emaSlow?1:0);
      if(bullConds==3) return 40.0;
      if(bearConds==3) return -40.0;
      if(bullConds==2) return 22.0;
      if(bearConds==2) return -22.0;
      if(bullConds==1) return 8.0;
      if(bearConds==1) return -8.0;
      return 0.0;
     }

   //--- +/-20: the two most recent confirmed fractal swings form Higher-High+Higher-Low (bull) or
   //--- Lower-High+Lower-Low (bear). Only fully-confirmed historical bars are scanned (shift>=1) -
   //--- today's still-forming bar can't confirm a fractal.
   double SwingScore() const
     {
      MqlRates rates[];
      int copied = CopyRates(m_symbol, m_tf, 1, m_swingLookback, rates);
      if(copied < m_fractalWing*2+3) return 0.0;
      ArraySetAsSeries(rates, true); // index 0 = most recent CONFIRMED bar

      double swingHighs[]; double swingLows[];
      ArrayResize(swingHighs,0); ArrayResize(swingLows,0);

      for(int i=m_fractalWing; i<copied-m_fractalWing; i++)
        {
         bool isHigh=true, isLow=true;
         for(int w=1; w<=m_fractalWing; w++)
           {
            if(rates[i].high<=rates[i-w].high || rates[i].high<=rates[i+w].high) isHigh=false;
            if(rates[i].low >=rates[i-w].low  || rates[i].low >=rates[i+w].low)  isLow=false;
           }
         if(isHigh && ArraySize(swingHighs)<2) { int n=ArraySize(swingHighs); ArrayResize(swingHighs,n+1); swingHighs[n]=rates[i].high; }
         if(isLow  && ArraySize(swingLows)<2)  { int n=ArraySize(swingLows);  ArrayResize(swingLows,n+1);  swingLows[n]=rates[i].low; }
         if(ArraySize(swingHighs)>=2 && ArraySize(swingLows)>=2) break;
        }

      if(ArraySize(swingHighs)<2 || ArraySize(swingLows)<2) return 0.0;
      bool higherHigh = swingHighs[0] > swingHighs[1];
      bool higherLow  = swingLows[0]  > swingLows[1];
      bool lowerHigh  = swingHighs[0] < swingHighs[1];
      bool lowerLow   = swingLows[0]  < swingLows[1];

      if(higherHigh && higherLow) return 20.0;
      if(lowerHigh  && lowerLow)  return -20.0;
      return 0.0;
     }

   //--- +/-20: a new N-bar high/low over fully-confirmed bars (today's forming bar excluded)
   double BreakoutScore(double price) const
     {
      double hh=-DBL_MAX, ll=DBL_MAX;
      for(int shift=1; shift<=m_breakoutLookback; shift++)
        {
         double h=iHigh(m_symbol,m_tf,shift), l=iLow(m_symbol,m_tf,shift);
         if(h<=0.0 || l<=0.0) continue;
         hh=MathMax(hh,h); ll=MathMin(ll,l);
        }
      if(hh<=-DBL_MAX || ll>=DBL_MAX) return 0.0;
      if(price>hh) return 20.0;
      if(price<ll) return -20.0;
      return 0.0;
     }

   //--- +/-20: rate of change over the momentum lookback, scaled so a +/-10% move over that window
   //--- already saturates the score (beyond that doesn't add more - this is a directional confirmation,
   //--- not a leverage dial)
   double MomentumScore() const
     {
      double priceNow  = iClose(m_symbol, m_tf, 1);
      double pricePast = iClose(m_symbol, m_tf, 1+m_momentumLookback);
      if(priceNow<=0.0 || pricePast<=0.0) return 0.0;
      double rocPct = (priceNow-pricePast)/pricePast*100.0;
      return MathMax(-20.0, MathMin(20.0, rocPct*2.0));
     }
  };
#endif // AUTOPSYX_DIRECTIONENGINE_MQH
