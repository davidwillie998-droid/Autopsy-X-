//+------------------------------------------------------------------+
//|                                         CampaignCoordinator.mqh |
//|  Profit-only continuation policy for FlipDemon campaign scaling. |
//|  This class does not place orders or calculate account risk.      |
//|  Every approved candidate must still pass AxAttemptEntry gates.   |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_CAMPAIGNCOORDINATOR_MQH
#define AX_CAMPAIGNCOORDINATOR_MQH
#include "Defs.mqh"

struct SAxCampaignState
  {
   string       campaignId;
   string       symbol;
   ENUM_AX_DIR  direction;
   double       netProfitMoney;
   double       initialRiskMoney;
   datetime     startedAt;
   datetime     lastAdditionAt;
   string       lastSignalKey;
   int          additionCount;
   bool         active;
   bool         thesisValid;
  };

class CCampaignCoordinator
  {
private:
   SAxCampaignState m_campaign;

public:
                     CCampaignCoordinator(void) { Reset(); }

   void              Reset(void)
     {
      m_campaign.campaignId="";
      m_campaign.symbol="";
      m_campaign.direction=AX_DIR_NONE;
      m_campaign.netProfitMoney=0.0;
      m_campaign.initialRiskMoney=0.0;
      m_campaign.startedAt=0;
      m_campaign.lastAdditionAt=0;
      m_campaign.lastSignalKey="";
      m_campaign.additionCount=0;
      m_campaign.active=false;
      m_campaign.thesisValid=false;
     }

   bool              Start(const string campaignId,const string symbol,const ENUM_AX_DIR direction,
                           const double initialRiskMoney,const datetime startedAt)
     {
      if(m_campaign.active || StringLen(campaignId)==0 || StringLen(symbol)==0 ||
         (direction!=AX_DIR_BUY && direction!=AX_DIR_SELL) ||
         !MathIsValidNumber(initialRiskMoney) || initialRiskMoney<=0.0 || startedAt<=0)
         return(false);
      m_campaign.campaignId=campaignId;
      m_campaign.symbol=symbol;
      m_campaign.direction=direction;
      m_campaign.netProfitMoney=0.0;
      m_campaign.initialRiskMoney=initialRiskMoney;
      m_campaign.startedAt=startedAt;
      m_campaign.lastAdditionAt=0;
      m_campaign.lastSignalKey="";
      m_campaign.additionCount=0;
      m_campaign.active=true;
      m_campaign.thesisValid=true;
      return(true);
     }

   // This is a strategy eligibility gate only. Account-wide monetary risk,
   // broker volume, margin, execution and recovery gates remain mandatory.
   bool              CanAdd(const string symbol,const ENUM_AX_DIR direction,
                            const string freshSignalKey,const double campaignNetProfitMoney,
                            const bool structureValid,const bool momentumResumed,
                            const bool allLegsProtected) const
     {
      if(!m_campaign.active || !m_campaign.thesisValid) return(false);
      if(symbol!=m_campaign.symbol || direction!=m_campaign.direction) return(false);
      if(StringLen(freshSignalKey)==0 || freshSignalKey==m_campaign.lastSignalKey) return(false);
      if(!MathIsValidNumber(campaignNetProfitMoney) || campaignNetProfitMoney<=0.0) return(false);
      if(!structureValid || !momentumResumed || !allLegsProtected) return(false);
      return(true);
     }

   bool              RegisterAddition(const string signalKey,const datetime addedAt)
     {
      if(!m_campaign.active || !m_campaign.thesisValid ||
         StringLen(signalKey)==0 || signalKey==m_campaign.lastSignalKey || addedAt<=0)
         return(false);
      m_campaign.lastSignalKey=signalKey;
      m_campaign.lastAdditionAt=addedAt;
      m_campaign.additionCount++;
      return(true);
     }

   void              UpdateNetProfit(const double netProfitMoney)
     {
      if(!MathIsValidNumber(netProfitMoney)) return;
      m_campaign.netProfitMoney=netProfitMoney;
     }

   void              Invalidate(void)
     {
      m_campaign.thesisValid=false;
     }

   void              Close(void)
     {
      m_campaign.active=false;
      m_campaign.thesisValid=false;
     }

   bool              IsActive(void) const { return(m_campaign.active); }
   bool              IsThesisValid(void) const { return(m_campaign.thesisValid); }
   int               AdditionCount(void) const { return(m_campaign.additionCount); }
   string            CampaignId(void) const { return(m_campaign.campaignId); }
   string            LastSignalKey(void) const { return(m_campaign.lastSignalKey); }
   double            NetProfitMoney(void) const { return(m_campaign.netProfitMoney); }
   bool              GetState(SAxCampaignState &out) const { out=m_campaign; return(true); }
  };
//+------------------------------------------------------------------+
#endif // AX_CAMPAIGNCOORDINATOR_MQH
