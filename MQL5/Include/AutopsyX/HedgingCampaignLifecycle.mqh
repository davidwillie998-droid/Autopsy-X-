//+------------------------------------------------------------------+
//|                                      HedgingCampaignLifecycle.mqh |
//| Ticket-by-ticket campaign invariant audit.                       |
//| Observation only: this module cannot submit or modify orders.    |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_HEDGINGCAMPAIGNLIFECYCLE_MQH
#define AX_HEDGINGCAMPAIGNLIFECYCLE_MQH

#include <AutopsyX/HedgingPositionManager.mqh>
#include <AutopsyX/VirtualExitRegistry.mqh>
#include <AutopsyX/PyramidCampaignRegistry.mqh>

struct SAxHedgingCampaignSnapshot
  {
   int         positionCount;
   int         protectedCount;
   int         virtualExitCount;
   int         campaignCount;
   double      grossLots;
   ENUM_AX_DIR direction;
   bool        sameDirection;
   bool        allProtected;
   bool        allVirtualExitsReady;
   bool        allCampaignsReady;
   bool        noUnresolvedActions;
   bool        multiLeg;
   bool        valid;
   string      failureReason;
  };

class CHedgingCampaignLifecycle
  {
public:
   CHedgingCampaignLifecycle(void) {}

   // Audits every broker-owned leg against its own durable virtual-exit and
   // pyramid records. A single missing, stale, cross-direction or action-locked
   // record invalidates the entire snapshot. This is deliberately not an
   // execution authorization and never replaces ticket-specific exit handling.
   bool Evaluate(const CHedgingPositionManager &positions,
                 const CVirtualExitRegistry &virtualExits,
                 const CPyramidCampaignRegistry &campaigns,
                 SAxHedgingCampaignSnapshot &snapshot) const
     {
      snapshot.positionCount=0;
      snapshot.protectedCount=0;
      snapshot.virtualExitCount=0;
      snapshot.campaignCount=0;
      snapshot.grossLots=0.0;
      snapshot.direction=AX_DIR_NONE;
      snapshot.sameDirection=true;
      snapshot.allProtected=true;
      snapshot.allVirtualExitsReady=true;
      snapshot.allCampaignsReady=true;
      snapshot.noUnresolvedActions=true;
      snapshot.multiLeg=false;
      snapshot.valid=false;
      snapshot.failureReason="";

      if(!positions.IsComplete() || !virtualExits.IsPersisting() ||
         !campaigns.IsPersisting())
        {
         snapshot.failureReason="INCOMPLETE_BROKER_OR_DURABLE_STATE";
         return(false);
        }

      snapshot.positionCount=positions.Count();
      snapshot.multiLeg=(snapshot.positionCount>1);
      if(snapshot.positionCount<=0)
        {
         snapshot.valid=true;
         return(true);
        }

      for(int i=0;i<snapshot.positionCount;i++)
        {
         SAxManagedPosition live;
         if(!positions.GetAt(i,live))
           {
            snapshot.failureReason="BROKER_POSITION_ROW_UNREADABLE";
            return(false);
           }
         if(live.ticket==0 || live.positionIdentifier==0 ||
            live.volume<=0.0 || !MathIsValidNumber(live.volume) ||
            (live.direction!=AX_DIR_BUY && live.direction!=AX_DIR_SELL))
           {
            snapshot.failureReason="INVALID_BROKER_POSITION_IDENTITY_OR_VOLUME";
            return(false);
           }

         if(i==0) snapshot.direction=live.direction;
         else if(live.direction!=snapshot.direction)
           {
            snapshot.sameDirection=false;
            snapshot.failureReason="MIXED_DIRECTION_CAMPAIGN";
            return(false);
           }

         snapshot.grossLots+=live.volume;
         if(live.hasValidBrokerStop) snapshot.protectedCount++;
         else snapshot.allProtected=false;

         SAxVirtualExitRecord exitRecord;
         if(!virtualExits.Find(live.positionIdentifier,exitRecord) ||
            exitRecord.positionIdentifier!=live.positionIdentifier ||
            exitRecord.ticket!=live.ticket || exitRecord.symbol!=live.symbol ||
            exitRecord.dir!=live.direction || exitRecord.initialSlPrice<=0.0 ||
            exitRecord.emergencySlPrice<=0.0 || exitRecord.virtualSlPrice<=0.0)
           {
            snapshot.allVirtualExitsReady=false;
            snapshot.failureReason="TICKET_SPECIFIC_VIRTUAL_EXIT_MISSING_OR_STALE";
            return(false);
           }
         snapshot.virtualExitCount++;
         if(exitRecord.actionLocked)
           {
            snapshot.noUnresolvedActions=false;
            snapshot.failureReason="TICKET_HAS_UNRESOLVED_EXIT_ACTION";
            return(false);
           }

         SAxPyramidCampaignRecord campaign;
         if(!campaigns.Find(live.positionIdentifier,campaign) ||
            !campaign.active || campaign.positionIdentifier!=live.positionIdentifier ||
            campaign.ticket!=live.ticket || campaign.symbol!=live.symbol ||
            campaign.dir!=live.direction || campaign.tierCount<1 ||
            campaign.lastTierDealTicket==0 || campaign.lastTierFillPrice<=0.0 ||
            campaign.lastTierFilledLots<=0.0)
           {
            snapshot.allCampaignsReady=false;
            snapshot.failureReason="TICKET_SPECIFIC_CAMPAIGN_RECORD_MISSING_OR_STALE";
            return(false);
           }
         snapshot.campaignCount++;
        }

      if(!snapshot.allProtected)
        {
         snapshot.failureReason="ONE_OR_MORE_LEGS_LACK_VALID_BROKER_STOP";
         return(false);
        }
      if(!MathIsValidNumber(snapshot.grossLots) || snapshot.grossLots<=0.0)
        {
         snapshot.failureReason="INVALID_CAMPAIGN_GROSS_VOLUME";
         return(false);
        }

      snapshot.valid=true;
      return(true);
     }
  };

#endif // AX_HEDGINGCAMPAIGNLIFECYCLE_MQH
