//+------------------------------------------------------------------+
//| MomentumEngine.mqh                                                |
//| Short-term market structure: swing highs/lows, micro              |
//| support/resistance breaks, displacement strength, momentum bias.  |
//| Recomputed once per new bar only - deliberately cheap.            |
//+------------------------------------------------------------------+
#pragma once
#include <AutopsyX/Defines.mqh>
#include <AutopsyX/SymbolProfile.mqh>

#define AX_SWING_ARM 2      // bars on each side to confirm a fractal swing point
#define AX_SWING_SLOTS 5    // how many recent swing highs/lows to remember

class CAXMomentum
{
private:
   const CAXSymbolProfile *m_profile;
   int      m_lookback;

   double   m_swingHighs[AX_SWING_SLOTS];
   double   m_swingLows[AX_SWING_SLOTS];
   int      m_swingHighCount, m_swingLowCount;

   int      m_structureBias;      // -1,0,1
   double   m_microResistance;
   double   m_microSupport;
   bool     m_brokeResistance;
   bool     m_brokeSupport;
   double   m_displacementStrength; // last-bar body / avg range
   int      m_momentumBias;         // -1,0,1
   double   m_momentumMagnitude;    // 0..100

public:
   CAXMomentum(void) : m_profile(NULL), m_lookback(30), m_swingHighCount(0),
      m_swingLowCount(0), m_structureBias(0), m_microResistance(0), m_microSupport(0),
      m_brokeResistance(false), m_brokeSupport(false), m_displacementStrength(0),
      m_momentumBias(0), m_momentumMagnitude(0) {}

   void Init(const CAXSymbolProfile &profile, const int lookback)
   {
      m_profile = GetPointer(profile);
      m_lookback = MathMax(10, lookback);
   }

   void OnNewBar(const MqlRates &rates[], const int count)
   {
      if(count < m_lookback + AX_SWING_ARM * 2 + 2 || m_profile == NULL) return;

      m_swingHighCount = 0;
      m_swingLowCount  = 0;
      // scan from most-recent closed bars backward, series order idx1..lookback
      for(int i = 1 + AX_SWING_ARM; i < m_lookback && m_swingHighCount < AX_SWING_SLOTS
          && m_swingLowCount < AX_SWING_SLOTS; i++)
      {
         bool isHigh = true, isLow = true;
         for(int k = 1; k <= AX_SWING_ARM; k++)
         {
            if(rates[i].high < rates[i - k].high || rates[i].high < rates[i + k].high) isHigh = false;
            if(rates[i].low  > rates[i - k].low  || rates[i].low  > rates[i + k].low)  isLow = false;
         }
         if(isHigh && m_swingHighCount < AX_SWING_SLOTS) m_swingHighs[m_swingHighCount++] = rates[i].high;
         if(isLow  && m_swingLowCount  < AX_SWING_SLOTS) m_swingLows[m_swingLowCount++]   = rates[i].low;
      }

      //--- structure bias from the two most recent swings of each kind
      m_structureBias = 0;
      if(m_swingHighCount >= 2 && m_swingLowCount >= 2)
      {
         bool higherHighs = m_swingHighs[0] > m_swingHighs[1];
         bool higherLows  = m_swingLows[0]  > m_swingLows[1];
         bool lowerHighs  = m_swingHighs[0] < m_swingHighs[1];
         bool lowerLows   = m_swingLows[0]  < m_swingLows[1];
         if(higherHighs && higherLows) m_structureBias = 1;
         else if(lowerHighs && lowerLows) m_structureBias = -1;
      }

      //--- micro resistance/support = most recent untested swing high/low
      m_microResistance = (m_swingHighCount > 0) ? m_swingHighs[0] : rates[1].high;
      m_microSupport    = (m_swingLowCount  > 0) ? m_swingLows[0]  : rates[1].low;

      double closeBar = rates[1].close;
      m_brokeResistance = closeBar > m_microResistance;
      m_brokeSupport    = closeBar < m_microSupport;

      //--- displacement strength: last body vs average range over lookback
      double rangeSum = 0.0;
      for(int i = 1; i <= m_lookback; i++)
         rangeSum += (rates[i].high - rates[i].low);
      double avgRange = rangeSum / m_lookback;
      double body = MathAbs(rates[1].close - rates[1].open);
      m_displacementStrength = (avgRange > 0.0) ? (body / avgRange) : 0.0;

      //--- combine into bias + magnitude
      double score = 0.0;
      score += m_structureBias * 35.0;
      if(m_brokeResistance) score += 30.0;
      if(m_brokeSupport)    score -= 30.0;
      score += AXClamp(m_displacementStrength, 0.0, 2.0) * 15.0 * (rates[1].close >= rates[1].open ? 1.0 : -1.0);

      m_momentumBias = (score > 10.0) ? 1 : (score < -10.0 ? -1 : 0);
      m_momentumMagnitude = AXClamp(MathAbs(score), 0.0, 100.0);
   }

   int    StructureBias(void)        const { return m_structureBias; }
   double MicroResistance(void)      const { return m_microResistance; }
   double MicroSupport(void)         const { return m_microSupport; }
   bool   BrokeMicroResistance(void) const { return m_brokeResistance; }
   bool   BrokeMicroSupport(void)    const { return m_brokeSupport; }
   double DisplacementStrength(void) const { return m_displacementStrength; }
   int    MomentumBias(void)         const { return m_momentumBias; }
   double MomentumMagnitude(void)    const { return m_momentumMagnitude; }
};
