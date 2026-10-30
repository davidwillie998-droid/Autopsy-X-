//+------------------------------------------------------------------+
//|                                      AccountCampaignCoordinator.mqh|
//| Account-wide stop-risk accounting and campaign admission gate.   |
//| Fails closed when any open position has no verifiable stop risk. |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_ACCOUNTCAMPAIGNCOORDINATOR_MQH
#define AX_ACCOUNTCAMPAIGNCOORDINATOR_MQH

#include "Defs.mqh"

struct SAxAccountRiskSnapshot
  {
   int    openPositions;
   int    campaignPositions;
   double accountOpenRiskMoney;
   double campaignOpenRiskMoney;
   double accountOpenRiskPercent;
   double campaignOpenRiskPercent;
   string rejectionReason;
  };

class CAccountCampaignCoordinator
  {
private:
   double m_absoluteEntryRiskPercent;

   bool CalculatePositionRisk(const ulong ticket,double &riskMoneyOut,string &reasonOut) const
     {
      riskMoneyOut=0.0;
      if(ticket==0 || !PositionSelectByTicket(ticket))
        { reasonOut="POSITION_SELECTION_FAILED"; return(false); }

      string symbol=PositionGetString(POSITION_SYMBOL);
      long type=PositionGetInteger(POSITION_TYPE);
      double volume=PositionGetDouble(POSITION_VOLUME);
      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      double stop=PositionGetDouble(POSITION_SL);
      if(symbol=="" || volume<=0.0 || entry<=0.0 || stop<=0.0)
        { reasonOut=StringFormat("UNPROTECTED_OR_INVALID_POSITION ticket=%I64u symbol=%s",ticket,symbol); return(false); }

      ENUM_ORDER_TYPE orderType;
      if(type==POSITION_TYPE_BUY)
        {
         if(stop>=entry) { reasonOut=StringFormat("BUY_STOP_NOT_BELOW_ENTRY ticket=%I64u",ticket); return(false); }
         orderType=ORDER_TYPE_BUY;
        }
      else if(type==POSITION_TYPE_SELL)
        {
         if(stop<=entry) { reasonOut=StringFormat("SELL_STOP_NOT_ABOVE_ENTRY ticket=%I64u",ticket); return(false); }
         orderType=ORDER_TYPE_SELL;
        }
      else
        { reasonOut=StringFormat("UNKNOWN_POSITION_TYPE ticket=%I64u",ticket); return(false); }

      double pnlAtStop=0.0;
      if(!OrderCalcProfit(orderType,symbol,volume,entry,stop,pnlAtStop) ||
         !MathIsValidNumber(pnlAtStop) || pnlAtStop>=0.0)
        { reasonOut=StringFormat("STOP_RISK_CALCULATION_FAILED ticket=%I64u symbol=%s",ticket,symbol); return(false); }

      riskMoneyOut=MathAbs(pnlAtStop);
      if(!MathIsValidNumber(riskMoneyOut) || riskMoneyOut<=0.0)
        { reasonOut=StringFormat("INVALID_STOP_RISK ticket=%I64u",ticket); return(false); }
      reasonOut="";
      return(true);
     }

public:
                     CAccountCampaignCoordinator(void)
     {
      m_absoluteEntryRiskPercent=2.0;
     }

   void Configure(const double absoluteEntryRiskPercent=2.0)
     {
      // The caller may lower this ceiling, never raise it above 2%.
      m_absoluteEntryRiskPercent=MathMin(2.0,MathMax(0.01,absoluteEntryRiskPercent));
     }

   bool Snapshot(const string campaignSymbol,const ulong campaignMagic,
                 SAxAccountRiskSnapshot &snapshotOut) const
     {
      snapshotOut.openPositions=0;
      snapshotOut.campaignPositions=0;
      snapshotOut.accountOpenRiskMoney=0.0;
      snapshotOut.campaignOpenRiskMoney=0.0;
      snapshotOut.accountOpenRiskPercent=0.0;
      snapshotOut.campaignOpenRiskPercent=0.0;
      snapshotOut.rejectionReason="";

      double equity=AccountInfoDouble(ACCOUNT_EQUITY);
      if(!MathIsValidNumber(equity) || equity<=0.0)
        { snapshotOut.rejectionReason="INVALID_ACCOUNT_EQUITY"; return(false); }

      for(int i=0;i<PositionsTotal();i++)
        {
         ulong ticket=PositionGetTicket(i);
         if(ticket==0) continue;

         double riskMoney=0.0;
         string reason;
         if(!CalculatePositionRisk(ticket,riskMoney,reason))
           { snapshotOut.rejectionReason=reason; return(false); }

         snapshotOut.openPositions++;
         snapshotOut.accountOpenRiskMoney+=riskMoney;

         string symbol=PositionGetString(POSITION_SYMBOL);
         ulong magic=(ulong)PositionGetInteger(POSITION_MAGIC);
         if(symbol==campaignSymbol && magic==campaignMagic)
           {
            snapshotOut.campaignPositions++;
            snapshotOut.campaignOpenRiskMoney+=riskMoney;
           }
        }

      snapshotOut.accountOpenRiskPercent=snapshotOut.accountOpenRiskMoney/equity*100.0;
      snapshotOut.campaignOpenRiskPercent=snapshotOut.campaignOpenRiskMoney/equity*100.0;
      if(!MathIsValidNumber(snapshotOut.accountOpenRiskPercent) ||
         !MathIsValidNumber(snapshotOut.campaignOpenRiskPercent))
        { snapshotOut.rejectionReason="NON_FINITE_AGGREGATE_RISK"; return(false); }

      return(true);
     }

   bool CanAdmitEntry(const string symbol,const ulong magic,const double proposedRiskMoney,
                      const double maxCampaignRiskPercent,const double maxAccountRiskPercent,
                      string &reasonOut) const
     {
      reasonOut="";
      double equity=AccountInfoDouble(ACCOUNT_EQUITY);
      if(!MathIsValidNumber(equity) || equity<=0.0 ||
         !MathIsValidNumber(proposedRiskMoney) || proposedRiskMoney<=0.0)
        { reasonOut="INVALID_EQUITY_OR_PROPOSED_RISK"; return(false); }

      double proposedRiskPct=proposedRiskMoney/equity*100.0;
      if(!MathIsValidNumber(proposedRiskPct) || proposedRiskPct>m_absoluteEntryRiskPercent+0.000001)
        {
         reasonOut=StringFormat("PER_ENTRY_RISK_CAP_EXCEEDED proposed=%.4f%% cap=%.4f%%",
                                proposedRiskPct,m_absoluteEntryRiskPercent);
         return(false);
        }

      SAxAccountRiskSnapshot snapshot;
      if(!Snapshot(symbol,magic,snapshot))
        { reasonOut="ACCOUNT_RISK_UNVERIFIED: "+snapshot.rejectionReason; return(false); }

      double campaignAfter=(snapshot.campaignOpenRiskMoney+proposedRiskMoney)/equity*100.0;
      double accountAfter=(snapshot.accountOpenRiskMoney+proposedRiskMoney)/equity*100.0;
      if(campaignAfter>maxCampaignRiskPercent+0.000001)
        {
         reasonOut=StringFormat("CAMPAIGN_RISK_CAP_EXCEEDED current=%.4f proposed=%.4f cap=%.4f",
                                snapshot.campaignOpenRiskPercent,proposedRiskPct,maxCampaignRiskPercent);
         return(false);
        }
      if(accountAfter>maxAccountRiskPercent+0.000001)
        {
         reasonOut=StringFormat("ACCOUNT_OPEN_RISK_CAP_EXCEEDED current=%.4f proposed=%.4f cap=%.4f",
                                snapshot.accountOpenRiskPercent,proposedRiskPct,maxAccountRiskPercent);
         return(false);
        }

      reasonOut=StringFormat("RISK_ADMITTED campaign_after=%.4f%% account_after=%.4f%%",
                             campaignAfter,accountAfter);
      return(true);
     }

   double AbsoluteEntryRiskPercent(void) const
     {
      return(m_absoluteEntryRiskPercent);
     }
  };

#endif // AX_ACCOUNTCAMPAIGNCOORDINATOR_MQH
