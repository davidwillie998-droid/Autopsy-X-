//+------------------------------------------------------------------+
//| FlipDemonCampaignManager.mqh                                     |
//| In-memory campaign state machine for conditional pyramiding.     |
//| Persistence and broker reconciliation are separate required work. |
//+------------------------------------------------------------------+
#ifndef AUTOPSYX_FLIPDEMON_CAMPAIGN_MANAGER_MQH
#define AUTOPSYX_FLIPDEMON_CAMPAIGN_MANAGER_MQH
#property strict

enum ENUM_AX_CAMPAIGN_STATE
  {
   AX_CAMPAIGN_FLAT=0,
   AX_CAMPAIGN_INITIAL_ENTRY_PENDING=1,
   AX_CAMPAIGN_ACTIVE=2,
   AX_CAMPAIGN_ADD_PENDING=3,
   AX_CAMPAIGN_EXITING=4,
   AX_CAMPAIGN_REVERSAL_PENDING=5,
   AX_CAMPAIGN_BLOCKED=6
  };

class CFlipDemonCampaignManager
  {
private:
   ENUM_AX_CAMPAIGN_STATE m_state;
   string                 m_campaignId;
   string                 m_symbol;
   ENUM_AX_DIR            m_direction;
   int                    m_entryCount;
   int                    m_maxEntries;
   datetime               m_startedAt;
   datetime               m_lastAddAt;
   datetime               m_lastSignalTime;
   string                 m_lastSignalId;
   double                 m_realizedPnl;
   double                 m_openVolume;
   string                 m_blockReason;

   bool ValidDirection(const ENUM_AX_DIR dir) const
     {
      return(dir==AX_DIR_BUY || dir==AX_DIR_SELL);
     }

public:
   CFlipDemonCampaignManager(void)
     {
      Reset();
      m_maxEntries=10;
     }

   void Configure(const int maxEntries)
     {
      // Campaign cap is deliberately bounded. Initial entry counts as entry 1.
      m_maxEntries=(maxEntries<1 || maxEntries>10) ? 10 : maxEntries;
     }

   void Reset(void)
     {
      m_state=AX_CAMPAIGN_FLAT;
      m_campaignId="";
      m_symbol="";
      m_direction=AX_DIR_NONE;
      m_entryCount=0;
      m_startedAt=0;
      m_lastAddAt=0;
      m_lastSignalTime=0;
      m_lastSignalId="";
      m_realizedPnl=0.0;
      m_openVolume=0.0;
      m_blockReason="";
     }

   bool BeginInitialEntry(const string campaignId,const string symbol,
                          const ENUM_AX_DIR direction,const string signalId,
                          const datetime signalTime,string &reason)
     {
      reason="";
      if(m_state!=AX_CAMPAIGN_FLAT)
        { reason="Campaign is not flat"; return(false); }
      if(campaignId=="" || symbol=="" || signalId=="" || signalTime<=0 || signalTime>TimeCurrent() || !ValidDirection(direction))
        { reason="Initial campaign identity, symbol, direction, or signal is invalid"; return(false); }
      m_campaignId=campaignId;
      m_symbol=symbol;
      m_direction=direction;
      m_lastSignalId=signalId;
      m_lastSignalTime=signalTime;
      m_entryCount=0;
      m_startedAt=TimeCurrent();
      m_lastAddAt=0;
      m_realizedPnl=0.0;
      m_openVolume=0.0;
      m_blockReason="";
      m_state=AX_CAMPAIGN_INITIAL_ENTRY_PENDING;
      return(true);
     }

   bool ConfirmInitialEntry(const double actualFilledVolume,const double realizedPnl,
                            string &reason)
     {
      reason="";
      if(m_state!=AX_CAMPAIGN_INITIAL_ENTRY_PENDING)
        { reason="No initial entry is pending confirmation"; return(false); }
      if(actualFilledVolume<=0.0)
        { m_state=AX_CAMPAIGN_BLOCKED; m_blockReason="Initial fill volume is invalid"; reason=m_blockReason; return(false); }
      m_entryCount=1;
      m_lastAddAt=TimeCurrent(); // last campaign entry time; enforces spacing before first add too
      m_openVolume=actualFilledVolume;
      m_realizedPnl=realizedPnl;
      m_state=AX_CAMPAIGN_ACTIVE;
      return(true);
     }

   bool CanAdd(const string symbol,const ENUM_AX_DIR direction,
               const string freshSignalId,const datetime signalTime,
               const datetime now,const int minimumSpacingSeconds,
               const double campaignPnlAfterEstimatedCosts,
               const bool allEntryGatesPass,const bool aggregateRiskVerified,
               const bool projectedRiskAndMarginPass,string &reason) const
     {
      reason="";
      if(m_state!=AX_CAMPAIGN_ACTIVE)
        { reason="Campaign is not active and reconciled"; return(false); }
      if(symbol!=m_symbol || direction!=m_direction || !ValidDirection(direction))
        { reason="Add does not match the active campaign symbol and direction"; return(false); }
      if(freshSignalId=="" || freshSignalId==m_lastSignalId || signalTime<=0 || signalTime>now || signalTime<=m_lastSignalTime)
        { reason="Signal is missing, duplicated, or not yet valid"; return(false); }
      if(m_entryCount>=m_maxEntries)
        { reason="Campaign entry cap reached (initial entry included)"; return(false); }
      if(minimumSpacingSeconds<0)
        { reason="Minimum add spacing is invalid"; return(false); }
      if(m_lastAddAt>0 && (now-m_lastAddAt)<minimumSpacingSeconds)
        { reason="Minimum spacing between adds has not elapsed"; return(false); }
      if(campaignPnlAfterEstimatedCosts<=0.0)
        { reason="Campaign is not profitable after estimated costs; add rejected"; return(false); }
      if(!allEntryGatesPass)
        { reason="One or more existing entry gates failed"; return(false); }
      if(!aggregateRiskVerified || !projectedRiskAndMarginPass)
        { reason="Aggregate exposure or projected risk/margin is unverified or exceeds limits"; return(false); }
      return(true);
     }

   bool BeginAdd(const string symbol,const ENUM_AX_DIR direction,
                 const string freshSignalId,const datetime signalTime,
                 const datetime now,const int minimumSpacingSeconds,
                 const double campaignPnlAfterEstimatedCosts,
                 const bool allEntryGatesPass,const bool aggregateRiskVerified,
                 const bool projectedRiskAndMarginPass,string &reason)
     {
      // Re-run every eligibility check atomically at the state transition. A
      // caller cannot bypass risk/continuation gates by calling BeginAdd alone.
      if(!CanAdd(symbol,direction,freshSignalId,signalTime,now,minimumSpacingSeconds,
                 campaignPnlAfterEstimatedCosts,allEntryGatesPass,
                 aggregateRiskVerified,projectedRiskAndMarginPass,reason))
         return(false);
      m_lastSignalId=freshSignalId;
      m_lastSignalTime=signalTime;
      m_lastAddAt=now;
      m_state=AX_CAMPAIGN_ADD_PENDING;
      return(true);
     }

   bool ConfirmAdd(const double actualFilledVolume,string &reason)
     {
      reason="";
      if(m_state!=AX_CAMPAIGN_ADD_PENDING)
        { reason="No add is pending confirmation"; return(false); }
      if(actualFilledVolume<=0.0)
        { m_state=AX_CAMPAIGN_BLOCKED; m_blockReason="Add fill volume is invalid or unconfirmed"; reason=m_blockReason; return(false); }
      if(m_entryCount>=m_maxEntries)
        { m_state=AX_CAMPAIGN_BLOCKED; m_blockReason="Entry count invariant violated"; reason=m_blockReason; return(false); }
      m_entryCount++;
      m_openVolume+=actualFilledVolume;
      m_state=AX_CAMPAIGN_ACTIVE;
      return(true);
     }

   void MarkExiting(void)
     {
      if(m_state!=AX_CAMPAIGN_FLAT) m_state=AX_CAMPAIGN_EXITING;
     }

   void MarkReversalPending(void)
     {
      if(m_state!=AX_CAMPAIGN_FLAT) m_state=AX_CAMPAIGN_REVERSAL_PENDING;
     }

   void Block(const string reasonText)
     {
      m_state=AX_CAMPAIGN_BLOCKED;
      m_blockReason=(reasonText=="") ? "Campaign blocked pending reconciliation" : reasonText;
     }

   // Only a separately verified broker reconciliation may call this method.
   bool ConfirmFlatAfterReconciliation(const bool brokerConfirmedFlat,string &reason)
     {
      reason="";
      if(!brokerConfirmedFlat)
        { m_state=AX_CAMPAIGN_BLOCKED; m_blockReason="Broker exposure is not confirmed flat"; reason=m_blockReason; return(false); }
      Reset();
      return(true);
     }

   ENUM_AX_CAMPAIGN_STATE State(void) const { return(m_state); }
   string CampaignId(void) const { return(m_campaignId); }
   string Symbol(void) const { return(m_symbol); }
   ENUM_AX_DIR Direction(void) const { return(m_direction); }
   int EntryCount(void) const { return(m_entryCount); }
   int MaxEntries(void) const { return(m_maxEntries); }
   double OpenVolume(void) const { return(m_openVolume); }
   double RealizedPnl(void) const { return(m_realizedPnl); }
   string BlockReason(void) const { return(m_blockReason); }
  };

#endif // AUTOPSYX_FLIPDEMON_CAMPAIGN_MANAGER_MQH
