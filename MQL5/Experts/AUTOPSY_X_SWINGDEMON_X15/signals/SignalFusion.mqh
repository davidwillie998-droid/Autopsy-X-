//+------------------------------------------------------------------+
//| SignalFusion.mqh                                                    |
//| Combines independent evidence into one composite confidence score |
//| and quality tier. Weights are fixed and sum to 100 so no single   |
//| signal (e.g. a single correlated instrument) can dominate the     |
//| decision, and highly-correlated inputs (bias alignment vs IPDA    |
//| location, which both derive from the same structural read) are   |
//| deliberately kept low-weight individually to avoid double count.  |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_SIGNALS_SIGNALFUSION_MQH
#define AX_SIGNALS_SIGNALFUSION_MQH
#include "../core/Types.mqh"
#include "../core/BiasEngine.mqh"
#include "../core/IPDAEngine.mqh"
#include "../intelligence/VolatilityEngine.mqh"

class CSignalFusion
  {
private:
   double m_minConfidence;
   double m_minRR;
   double m_minExpectedR;
   bool   m_allowGradeB;

public:
   void Init(double minConfidence, double minRR, double minExpectedR, bool allowGradeB)
     {
      m_minConfidence = minConfidence;
      m_minRR = minRR;
      m_minExpectedR = minExpectedR;
      m_allowGradeB = allowGradeB;
     }

   ENUM_AX_QUALITY QualityFromConfidence(double confidence) const
     {
      if(confidence>=85.0) return QUALITY_A_PLUS;
      if(confidence>=70.0) return QUALITY_A;
      if(confidence>=55.0) return QUALITY_B;
      if(confidence>=40.0) return QUALITY_C;
      return QUALITY_D;
     }

   AXFusedSignal Fuse(const AXSignal &signal, const AXBiasStack &biasStack, bool wellLocated,
                       double structuralQualityScore, ENUM_AX_VOL_REGIME volRegime,
                       double correlationConfirmation, // -1..1, 0 if unavailable/neutral
                       double macroReliability,         // 0..1, 0 if macro data unavailable
                       double probContinuation, double probTp1, double probTp2, double probFinal,
                       double expectedR) const
     {
      AXFusedSignal fs;
      fs.signal = signal;
      fs.probContinuation = probContinuation;
      fs.probReversal = 1.0-probContinuation;
      fs.probTp1 = probTp1; fs.probTp2 = probTp2; fs.probFinal = probFinal;
      fs.expectedValueR = expectedR;

      double biasScore = biasStack.alignmentScore; // 0..100
      double locationScore = wellLocated ? 100.0 : 40.0;
      double structureScore = MathMax(0.0, MathMin(100.0, structuralQualityScore));
      double volScore = VolScoreFor(volRegime);
      double evScore = MathMax(0.0, MathMin(100.0, 50.0 + expectedR*25.0));
      double corrScore = 50.0 + correlationConfirmation*50.0*macroReliability; // neutral 50 when no macro data

      double confidence = biasScore*0.25 + locationScore*0.15 + structureScore*0.20 +
                          volScore*0.10 + evScore*0.20 + corrScore*0.10;

      fs.confidence = MathMax(0.0, MathMin(100.0, confidence));
      fs.quality = QualityFromConfidence(fs.confidence);

      fs.passesFilters = true; fs.rejectReason = "";
      double riskDist = MathAbs(signal.entryPrice-signal.stopLoss);
      double rr = (riskDist>0.0) ? MathAbs(signal.tp1-signal.entryPrice)/riskDist : 0.0;

      if(fs.quality==QUALITY_D || fs.quality==QUALITY_C)
        { fs.passesFilters=false; fs.rejectReason="Quality below tradeable threshold (C/D) - NO TRADE by design."; }
      else if(fs.quality==QUALITY_B && !m_allowGradeB)
        { fs.passesFilters=false; fs.rejectReason="Grade B requires explicit configuration to trade live."; }
      else if(fs.confidence < m_minConfidence)
        { fs.passesFilters=false; fs.rejectReason=StringFormat("Confidence %.1f below minimum %.1f", fs.confidence, m_minConfidence); }
      else if(rr < m_minRR)
        { fs.passesFilters=false; fs.rejectReason=StringFormat("R:R %.2f below minimum %.2f", rr, m_minRR); }
      else if(expectedR < m_minExpectedR)
        { fs.passesFilters=false; fs.rejectReason=StringFormat("Expected value %.2fR below minimum %.2fR", expectedR, m_minExpectedR); }

      return fs;
     }

private:
   double VolScoreFor(ENUM_AX_VOL_REGIME vr) const
     {
      switch(vr)
        {
         case VOL_ABNORMAL:   return 20.0;
         case VOL_EXPANDED:   return 60.0;
         case VOL_COMPRESSED: return 80.0;
         default:             return 90.0;
        }
     }
  };
#endif // AX_SIGNALS_SIGNALFUSION_MQH
