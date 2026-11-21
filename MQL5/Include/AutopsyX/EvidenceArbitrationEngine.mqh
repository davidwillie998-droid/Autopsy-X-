//+------------------------------------------------------------------+
//|                                      EvidenceArbitrationEngine.mqh|
//| Independent evidence contract and conservative arbitration layer. |
//| This module is observational until explicitly wired into entries. |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_EVIDENCEARBITRATIONENGINE_MQH
#define AX_EVIDENCEARBITRATIONENGINE_MQH

#include "Defs.mqh"

enum ENUM_AX_EVIDENCE_STATUS
  {
   AX_EVIDENCE_UNAVAILABLE = 0,
   AX_EVIDENCE_PROVISIONAL,
   AX_EVIDENCE_CONFIRMED
  };

struct SAxEvidence
  {
   string                 sourceId;
   string                 independenceGroup;
   ENUM_AX_DIR            direction;
   ENUM_AX_EVIDENCE_STATUS status;
   double                 quality;          // 0..100, source-specific evidence quality
   double                 reliability;      // 0..100, empirical reliability when available
   double                 weight;            // bounded configuration weight, not a probability
   datetime               observedAt;
   int                    maxAgeSeconds;
   string                 reason;
  };

struct SAxArbitrationResult
  {
   ENUM_AX_DIR direction;
   double      directionalStrength; // 0..100, evidence balance, NOT win probability
   double      conflictRatio;        // 0..1, opposing evidence / total evidence
   int         freshEvidenceCount;
   int         staleEvidenceCount;
   int         unavailableEvidenceCount;
   int         independentGroupCount;
   bool        hasMaterialConflict;
   string      reason;
  };

class CEvidenceArbitrationEngine
  {
private:
   SAxEvidence m_evidence[];
   double      m_minStrength;
   double      m_maxConflictRatio;

   double Clamp01(const double value) const
     {
      return(MathMax(0.0,MathMin(1.0,value)));
     }

public:
                     CEvidenceArbitrationEngine(void)
     {
      m_minStrength=20.0;
      m_maxConflictRatio=0.35;
      ArrayResize(m_evidence,0);
     }

   void              Configure(const double minStrength,
                               const double maxConflictRatio)
     {
      m_minStrength=MathMax(0.0,MathMin(100.0,minStrength));
      m_maxConflictRatio=Clamp01(maxConflictRatio);
     }

   void              Clear(void)
     {
      ArrayResize(m_evidence,0);
     }

   bool              Add(const SAxEvidence &item)
     {
      if(StringLen(item.sourceId)==0 ||
         StringLen(item.independenceGroup)==0 ||
         (item.direction!=AX_DIR_BUY && item.direction!=AX_DIR_SELL &&
          item.direction!=AX_DIR_NONE) ||
         item.quality<0.0 || item.quality>100.0 ||
         item.reliability<0.0 || item.reliability>100.0 ||
         item.weight<0.0 || item.maxAgeSeconds<0)
         return(false);

      int count=ArraySize(m_evidence);
      if(ArrayResize(m_evidence,count+1)!=count+1)
         return(false);
      m_evidence[count]=item;
      return(true);
     }

   int               Count(void) const
     {
      return(ArraySize(m_evidence));
     }

   // One independence group contributes at most one bounded vote. Correlated
   // indicators are therefore not allowed to manufacture extra consensus.
   // Provisional readings are discounted; stale/unavailable readings never vote.
   SAxArbitrationResult Resolve(const datetime now) const
     {
      SAxArbitrationResult result;
      ZeroMemory(result);
      result.direction=AX_DIR_NONE;
      result.reason="NO_FRESH_EVIDENCE";

      string groups[];
      double groupNet[];
      int groupCount=0;
      double buyEvidence=0.0;
      double sellEvidence=0.0;

      int count=ArraySize(m_evidence);
      for(int i=0;i<count;i++)
        {
         SAxEvidence item=m_evidence[i];
         if(item.status==AX_EVIDENCE_UNAVAILABLE ||
            item.direction==AX_DIR_NONE)
           {
            result.unavailableEvidenceCount++;
            continue;
           }

         if(item.observedAt<=0 || now<item.observedAt ||
            (item.maxAgeSeconds>0 &&
             (now-item.observedAt)>item.maxAgeSeconds))
           {
            result.staleEvidenceCount++;
            continue;
           }

         if(item.status!=AX_EVIDENCE_CONFIRMED &&
            item.status!=AX_EVIDENCE_PROVISIONAL)
           {
            result.unavailableEvidenceCount++;
            continue;
           }

         result.freshEvidenceCount++;
         double statusFactor=(item.status==AX_EVIDENCE_CONFIRMED)?1.0:0.5;
         double reliabilityFactor=(item.reliability>0.0)?
                                  item.reliability/100.0:0.5;
         double magnitude=Clamp01(item.quality/100.0)*
                          reliabilityFactor*statusFactor*
                          MathMax(0.0,MathMin(1.0,item.weight));
         double signedValue=(item.direction==AX_DIR_BUY)?magnitude:-magnitude;

         int groupIndex=-1;
         for(int g=0;g<groupCount;g++)
            if(groups[g]==item.independenceGroup)
              {
               groupIndex=g;
               break;
              }
         if(groupIndex<0)
           {
            groupIndex=groupCount;
            if(ArrayResize(groups,groupCount+1)!=groupCount+1 ||
               ArrayResize(groupNet,groupCount+1)!=groupCount+1)
              {
               result.reason="ARBITRATION_MEMORY_ERROR";
               return(result);
              }
            groups[groupCount]=item.independenceGroup;
            groupNet[groupCount]=0.0;
            groupCount++;
           }
         // Net within a correlated group, then cap that group's contribution.
         groupNet[groupIndex]+=signedValue;
        }

      result.independentGroupCount=groupCount;
      if(groupCount<=0)
        {
         if(result.staleEvidenceCount>0)
            result.reason="ALL_AVAILABLE_EVIDENCE_STALE";
         return(result);
        }

      for(int g=0;g<groupCount;g++)
        {
         double bounded=MathMax(-1.0,MathMin(1.0,groupNet[g]));
         if(bounded>0.0) buyEvidence+=bounded;
         else            sellEvidence+=-bounded;
        }

      double total=buyEvidence+sellEvidence;
      if(total<=0.0)
        {
         result.reason="NO_DIRECTIONAL_EVIDENCE";
         return(result);
        }

      result.conflictRatio=MathMin(buyEvidence,sellEvidence)/total;
      result.directionalStrength=100.0*MathAbs(buyEvidence-sellEvidence)/
                                 MathMax(1.0,(double)groupCount);
      result.hasMaterialConflict=(result.conflictRatio>m_maxConflictRatio);

      if(result.hasMaterialConflict)
        {
         result.reason="CONFLICTING_INDEPENDENT_EVIDENCE";
         return(result);
        }
      if(result.directionalStrength<m_minStrength)
        {
         result.reason="DIRECTIONAL_STRENGTH_BELOW_THRESHOLD";
         return(result);
        }

      result.direction=(buyEvidence>sellEvidence)?AX_DIR_BUY:AX_DIR_SELL;
      result.reason=(result.direction==AX_DIR_BUY)?
                    "BUY_EVIDENCE_DOMINATES":"SELL_EVIDENCE_DOMINATES";
      return(result);
     }
  };

#endif // AX_EVIDENCEARBITRATIONENGINE_MQH
//+------------------------------------------------------------------+
