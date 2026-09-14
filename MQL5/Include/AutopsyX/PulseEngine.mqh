//+------------------------------------------------------------------+
//| PulseEngine.mqh                                                   |
//| A single "how alive is this market right now" gauge (0-100).      |
//| Combines tick velocity, bar volume and volatility against their   |
//| own rolling EMA baselines - self-calibrating per symbol/session,  |
//| no hard-coded activity thresholds. Used to further damp trading   |
//| in a dead tape and mildly favour genuinely active conditions.     |
//+------------------------------------------------------------------+
#pragma once
#include <AutopsyX/Defines.mqh>

class CAXPulse
{
private:
   double   m_emaVelocity;
   double   m_emaVolume;
   double   m_alphaVelocity;
   double   m_alphaVolume;
   bool     m_haveVelocity;
   bool     m_haveVolume;

   double   m_velocityRatio;
   double   m_volumeRatio;
   double   m_volatilityRatio;
   double   m_score;

public:
   CAXPulse(void) : m_emaVelocity(0), m_emaVolume(0), m_alphaVelocity(2.0 / 121.0), m_alphaVolume(2.0 / 21.0),
      m_haveVelocity(false), m_haveVolume(false), m_velocityRatio(1.0), m_volumeRatio(1.0),
      m_volatilityRatio(1.0), m_score(50.0) {}

   void Init(const int velocityEmaTicks, const int volumeEmaBars)
   {
      m_alphaVelocity = 2.0 / (MathMax(5, velocityEmaTicks) + 1.0);
      m_alphaVolume    = 2.0 / (MathMax(3, volumeEmaBars) + 1.0);
   }

   void OnTick(const double tickVelocity)
   {
      if(tickVelocity <= 0.0) return;
      if(!m_haveVelocity) { m_emaVelocity = tickVelocity; m_haveVelocity = true; }
      else m_emaVelocity += m_alphaVelocity * (tickVelocity - m_emaVelocity);

      m_velocityRatio = (m_emaVelocity > 0.0) ? AXClamp(tickVelocity / m_emaVelocity, 0.0, 4.0) : 1.0;
   }

   void OnNewBar(const long barVolume)
   {
      double vol = (double)barVolume;
      if(vol <= 0.0) return;
      if(!m_haveVolume) { m_emaVolume = vol; m_haveVolume = true; }
      else m_emaVolume += m_alphaVolume * (vol - m_emaVolume);

      m_volumeRatio = (m_emaVolume > 0.0) ? AXClamp(vol / m_emaVolume, 0.0, 4.0) : 1.0;
   }

   // volatilityRatio: pass RegimeEngine's VolatilityRatio() (current ATR / its own rolling average)
   void Update(const double volatilityRatio)
   {
      m_volatilityRatio = AXClamp(volatilityRatio, 0.0, 4.0);
      double blended = m_velocityRatio * 0.40 + m_volumeRatio * 0.30 + m_volatilityRatio * 0.30;
      m_score = AXClamp(blended * 50.0, 0.0, 100.0);
   }

   double Score(void)          const { return m_score; }
   double VelocityRatio(void)  const { return m_velocityRatio; }
   double VolumeRatio(void)    const { return m_volumeRatio; }

   string Label(void) const
   {
      if(m_score >= 75.0) return "HOT";
      if(m_score >= 45.0) return "NORMAL";
      if(m_score >= 20.0) return "QUIET";
      return "DEAD";
   }

   // multiplier applied to the confidence engine's overall score -
   // extra caution in a dead tape, mild credit for a genuinely active one
   double AsConfidenceMultiplier(void) const
   {
      if(m_score < 20.0) return 0.5;
      if(m_score < 35.0) return 0.75;
      if(m_score > 80.0) return 1.1;
      return 1.0;
   }
};
