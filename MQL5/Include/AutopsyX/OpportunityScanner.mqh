//+------------------------------------------------------------------+
//|                                      OpportunityScanner.mqh       |
//| Deterministic ranking of already-qualified per-symbol candidates.|
//| This class does not manufacture trading signals or place orders. |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_OPPORTUNITYSCANNER_MQH
#define AX_OPPORTUNITYSCANNER_MQH

#include "Defs.mqh"

#define AX_MAX_OPPORTUNITY_CANDIDATES 5

struct SAxOpportunityCandidate
  {
   string          symbol;
   ENUM_AX_DIR     direction;
   double          score;
   double          confidence;
   double          spreadPoints;
   datetime        signalTime;
   bool            qualified;
  };

class COpportunityScanner
  {
private:
   SAxOpportunityCandidate m_candidates[AX_MAX_OPPORTUNITY_CANDIDATES];
   int                     m_count;
   int                     m_maxCandidates;
   double                  m_minScore;
   double                  m_minConfidence;
   int                     m_maxAgeSeconds;

   bool IsFresh(const SAxOpportunityCandidate &candidate,const datetime now) const
     {
      if(candidate.signalTime<=0 || now<candidate.signalTime) return(false);
      return((now-candidate.signalTime)<=m_maxAgeSeconds);
     }

   bool IsUsable(const SAxOpportunityCandidate &candidate,const datetime now) const
     {
      if(!candidate.qualified || candidate.symbol=="") return(false);
      if(candidate.direction!=AX_DIR_BUY && candidate.direction!=AX_DIR_SELL) return(false);
      if(!MathIsValidNumber(candidate.score) || candidate.score<m_minScore) return(false);
      if(!MathIsValidNumber(candidate.confidence) || candidate.confidence<m_minConfidence) return(false);
      if(!MathIsValidNumber(candidate.spreadPoints) || candidate.spreadPoints<0.0) return(false);
      return(IsFresh(candidate,now));
     }

   // Positive means lhs outranks rhs. Score is primary, confidence secondary,
   // then lower spread. Symbol name is the final deterministic tie-break.
   int Compare(const SAxOpportunityCandidate &lhs,const SAxOpportunityCandidate &rhs) const
     {
      if(lhs.score>rhs.score+0.000001) return(1);
      if(rhs.score>lhs.score+0.000001) return(-1);
      if(lhs.confidence>rhs.confidence+0.000001) return(1);
      if(rhs.confidence>lhs.confidence+0.000001) return(-1);
      if(lhs.spreadPoints<rhs.spreadPoints-0.000001) return(1);
      if(rhs.spreadPoints<lhs.spreadPoints-0.000001) return(-1);
      if(lhs.symbol<rhs.symbol) return(1);
      if(lhs.symbol>rhs.symbol) return(-1);
      return(0);
     }

public:
                     COpportunityScanner(void)
     {
      m_count=0;
      m_maxCandidates=5;
      m_minScore=60.0;
      m_minConfidence=0.0;
      m_maxAgeSeconds=10;
     }

   void Configure(const int maxCandidates,const double minScore,
                  const double minConfidence,const int maxAgeSeconds)
     {
      m_maxCandidates=(int)MathMax(1,MathMin(AX_MAX_OPPORTUNITY_CANDIDATES,maxCandidates));
      m_minScore=MathMax(0.0,minScore);
      m_minConfidence=MathMax(0.0,MathMin(100.0,minConfidence));
      m_maxAgeSeconds=(int)MathMax(1,maxAgeSeconds);
      Reset();
     }

   void Reset(void)
     {
      m_count=0;
     }

   // Called only by a per-symbol analysis context after its complete signal
   // pipeline has passed. A preliminary momentum/indicator score is not enough.
   bool SubmitQualifiedCandidate(const SAxOpportunityCandidate &candidate,const datetime now)
     {
      if(!IsUsable(candidate,now)) return(false);

      for(int i=0;i<m_count;i++)
        {
         if(m_candidates[i].symbol==candidate.symbol)
           {
            m_candidates[i]=candidate;
            return(true);
           }
        }

      if(m_count<m_maxCandidates)
        {
         m_candidates[m_count]=candidate;
         m_count++;
         return(true);
        }

      int weakest=0;
      for(int i=1;i<m_count;i++)
         if(Compare(m_candidates[i],m_candidates[weakest])<0) weakest=i;

      if(Compare(candidate,m_candidates[weakest])<=0) return(false);
      m_candidates[weakest]=candidate;
      return(true);
     }

   bool SelectStrongest(const datetime now,SAxOpportunityCandidate &selectedOut)
     {
      int strongest=-1;
      for(int i=0;i<m_count;i++)
        {
         if(!IsUsable(m_candidates[i],now)) continue;
         if(strongest<0 || Compare(m_candidates[i],m_candidates[strongest])>0)
            strongest=i;
        }

      if(strongest<0) return(false);
      selectedOut=m_candidates[strongest];
      return(true);
     }

   int CandidateCount(void) const
     {
      return(m_count);
     }

   int MaximumCandidates(void) const
     {
      return(m_maxCandidates);
     }
  };

#endif // AX_OPPORTUNITYSCANNER_MQH
