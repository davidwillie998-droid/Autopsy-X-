//+------------------------------------------------------------------+
//| ProbabilityEngine.mqh                                               |
//| Layer 08 — PROBABILITY ENGINE.                                      |
//| Estimates P(TP1)/P(TP2)/P(SL) for a setup class from this EA's OWN  |
//| trade journal — never from a fabricated or borrowed number. With    |
//| fewer than Inp_MinSampleForConfidence trades in a class, confidence |
//| is shrunk toward 0 rather than reported at face value (spec: "a     |
//| setup with 3 historical examples must never receive the same        |
//| confidence as a setup with thousands of observations").             |
//+------------------------------------------------------------------+
#ifndef AXF_PROBABILITYENGINE_MQH
#define AXF_PROBABILITYENGINE_MQH

#include "../Common/Defines.mqh"

class CAxfProbabilityEngine
  {
private:
   int               m_min_sample_full_confidence;

public:
                     CAxfProbabilityEngine(void) { m_min_sample_full_confidence=50; }

   void              Init(const int min_sample_full_confidence)
     {
      m_min_sample_full_confidence = MathMax(10,min_sample_full_confidence);
     }

   //--- 'records' should already be filtered by the caller to the relevant setup
   //--- class (same regime + same direction, typically). Only CLOSED trades count.
   SAxfProbability   Compute(const SAxfTradeRecord &records[])
     {
      SAxfProbability p; ZeroMemory(p); p.valid=false;
      int n = ArraySize(records);
      if(n<=0)
        {
         // zero history: probability is genuinely unknown, not "assume 50%"
         p.p_tp1=0; p.p_tp2=0; p.p_tp3=0; p.p_sl=0;
         p.sample_size=0; p.confidence=0.0; p.valid=true;
         return p;
        }

      int wins_tp1=0, wins_tp2=0, losses=0;
      for(int i=0;i<n;i++)
        {
         if(records[i].r_multiple > 0) wins_tp1++;
         if(records[i].r_multiple >= 2.0) wins_tp2++;
         if(records[i].r_multiple <= 0)   losses++;
        }

      p.p_tp1 = (double)wins_tp1/n;
      p.p_tp2 = (double)wins_tp2/n;
      p.p_tp3 = 0.0; // only tracked if the journal records a 3rd target hit; conservative default
      p.p_sl  = (double)losses/n;
      p.sample_size = n;

      // confidence ramps 0..1 with sample size, capped at 1.0 once the sample is
      // large enough to trust at face value. sqrt curve: fast early gains, slow tail.
      p.confidence = AxfClamp(MathSqrt((double)n/m_min_sample_full_confidence),0.0,1.0);
      p.valid = true;
      return p;
     }
  };

#endif // AXF_PROBABILITYENGINE_MQH
