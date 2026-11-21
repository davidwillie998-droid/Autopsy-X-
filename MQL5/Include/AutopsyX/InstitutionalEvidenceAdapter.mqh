//+------------------------------------------------------------------+
//| InstitutionalEvidenceAdapter.mqh                                 |
//| Converts existing closed-period institutional reads into the     |
//| supervisory evidence contract. Shadow use only.                  |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_INSTITUTIONAL_EVIDENCE_ADAPTER_MQH
#define AX_INSTITUTIONAL_EVIDENCE_ADAPTER_MQH

#include "Defs.mqh"
#include "W1InstitutionalDirection.mqh"
#include "D1InstitutionalLevels.mqh"
#include "EvidenceArbitrationEngine.mqh"

class CInstitutionalEvidenceAdapter
  {
private:
   bool AddDirectional(const string sourceId,
                       const string groupId,
                       const ENUM_AX_DIR direction,
                       const ENUM_AX_EVIDENCE_STATUS status,
                       const datetime observedAt,
                       const int maxAgeSeconds,
                       const string reason,
                       CEvidenceArbitrationEngine &engine)
     {
      SAxEvidence item;
      ZeroMemory(item);
      item.sourceId=sourceId;
      item.independenceGroup=groupId;
      item.direction=direction;
      item.status=status;
      // Neutral placeholder until source-specific quality is calibrated from
      // labelled replay. This is not a measured confidence or win probability.
      item.quality=50.0;
      item.reliability=0.0;
      item.weight=1.0;
      item.observedAt=observedAt;
      item.maxAgeSeconds=maxAgeSeconds;
      item.reason=reason;
      return(engine.Add(item));
     }

public:
   bool AddW1(const SAxW1Snapshot &snapshot,
              CEvidenceArbitrationEngine &engine)
     {
      ENUM_AX_DIR direction=AX_DIR_NONE;
      if(snapshot.bias==AX_W1_BULLISH) direction=AX_DIR_BUY;
      else if(snapshot.bias==AX_W1_BEARISH) direction=AX_DIR_SELL;

      ENUM_AX_EVIDENCE_STATUS status=(direction==AX_DIR_NONE)?
         AX_EVIDENCE_UNAVAILABLE:AX_EVIDENCE_CONFIRMED;
      string reason=StringFormat("W1_BIAS_%d: %s",(int)snapshot.bias,snapshot.reason);
      return(AddDirectional("W1_INSTITUTIONAL_BIAS","HTF_DIRECTION",
                            direction,status,snapshot.lastClosedWeekTime,
                            10*86400,reason,engine));
     }

   bool AddD1(const SAxD1Snapshot &snapshot,
              CEvidenceArbitrationEngine &engine)
     {
      ENUM_AX_DIR direction=AX_DIR_NONE;
      if(snapshot.bias==AX_D1_BULLISH) direction=AX_DIR_BUY;
      else if(snapshot.bias==AX_D1_BEARISH) direction=AX_DIR_SELL;

      ENUM_AX_EVIDENCE_STATUS status=(direction==AX_DIR_NONE)?
         AX_EVIDENCE_UNAVAILABLE:AX_EVIDENCE_CONFIRMED;
      string reason=StringFormat("D1_BIAS_%d: %s",(int)snapshot.bias,snapshot.reason);
      return(AddDirectional("D1_INSTITUTIONAL_BIAS","HTF_DIRECTION",
                            direction,status,snapshot.lastClosedDayTime,
                            3*86400,reason,engine));
     }

   bool AddStructureEvent(const ENUM_AX_STRUCTURE_EVENT event,
                          const datetime eventTime,
                          const int maxAgeSeconds,
                          CEvidenceArbitrationEngine &engine)
     {
      ENUM_AX_DIR direction=AX_DIR_NONE;
      if(event==AX_STRUCT_BOS_BULLISH ||
         event==AX_STRUCT_CHOCH_BULLISH ||
         event==AX_STRUCT_MSS_BULLISH) direction=AX_DIR_BUY;
      else if(event==AX_STRUCT_BOS_BEARISH ||
              event==AX_STRUCT_CHOCH_BEARISH ||
              event==AX_STRUCT_MSS_BEARISH) direction=AX_DIR_SELL;

      ENUM_AX_EVIDENCE_STATUS status=(direction==AX_DIR_NONE)?
         AX_EVIDENCE_UNAVAILABLE:AX_EVIDENCE_CONFIRMED;
      string reason=StringFormat("STRUCTURE_EVENT_%d",(int)event);
      return(AddDirectional("LTF_STRUCTURE_EVENT","MARKET_STRUCTURE",
                            direction,status,eventTime,maxAgeSeconds,
                            reason,engine));
     }
  };

#endif // AX_INSTITUTIONAL_EVIDENCE_ADAPTER_MQH
//+------------------------------------------------------------------+
