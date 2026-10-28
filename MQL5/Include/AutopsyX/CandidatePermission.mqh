//+------------------------------------------------------------------+
//|                                      CandidatePermission.mqh     |
//| Centralized fail-closed gate for analysis candidate ranking      |
//| This class does NOT authorize execution or submit orders.        |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_CANDIDATEPERMISSION_MQH
#define AX_CANDIDATEPERMISSION_MQH
#include "Defs.mqh"

struct SAxCandidateVerdict
  {
   bool        accepted;
   string      symbol;
   ENUM_AX_DIR direction;
   double      strength;
   datetime    scoreTime;
   datetime    signalBarTime;
   string      reason;
  };

class CAxCandidatePermission
  {
private:
   int m_maxScoreAgeSeconds;
   double m_minDirectionalScore;

public:
                     CAxCandidatePermission(void)
     {
      m_maxScoreAgeSeconds=10;
      m_minDirectionalScore=0.0;
     }

   void              Configure(const int maxScoreAgeSeconds,const double minDirectionalScore)
     {
      m_maxScoreAgeSeconds=(int)MathMax(1,maxScoreAgeSeconds);
      m_minDirectionalScore=MathMax(0.0,minDirectionalScore);
     }

   SAxCandidateVerdict Evaluate(const string symbol,
                                const SAxScore &score,
                                const bool dataReady,
                                const datetime signalBarTime) const
     {
      SAxCandidateVerdict v;
      v.accepted=false;
      v.symbol=symbol;
      v.direction=AX_DIR_NONE;
      v.strength=0.0;
      v.scoreTime=score.time;
      v.signalBarTime=signalBarTime;
      v.reason="not evaluated";

      if(symbol=="")
        { v.reason="empty symbol"; return(v); }
      if(!dataReady)
        { v.reason="symbol data not ready"; return(v); }
      if(signalBarTime<=0)
        { v.reason="signal bar timestamp unavailable"; return(v); }
      if(score.time<=0)
        { v.reason="score timestamp unavailable"; return(v); }

      int age=(int)(TimeCurrent()-score.time);
      if(age<0 || age>m_maxScoreAgeSeconds)
        { v.reason=StringFormat("score stale or future-dated (%d seconds)",age); return(v); }

      if(score.action!=AX_DIR_BUY && score.action!=AX_DIR_SELL)
        { v.reason="no directional score"; return(v); }

      double directionalScore=(score.action==AX_DIR_BUY ? score.buyScore : score.sellScore);
      if(directionalScore<m_minDirectionalScore)
        { v.reason=StringFormat("directional score %.1f below minimum %.1f",directionalScore,m_minDirectionalScore); return(v); }

      v.accepted=true;
      v.direction=score.action;
      v.strength=directionalScore;
      v.reason="analysis candidate accepted; execution not authorized";
      return(v);
     }
  };

#endif // AX_CANDIDATEPERMISSION_MQH
