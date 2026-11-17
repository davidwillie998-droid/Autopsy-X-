//+------------------------------------------------------------------+
//|                                                AccountFlipEngine.mqh |
//|  Account-growth milestones and capital-preservation sizing layer. |
//|  Never increases risk, never overrides CRiskEngine or account-wide  |
//|  risk reservations. Reaching the target does not stop compounding.  |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_ACCOUNTFLIPENGINE_MQH
#define AX_ACCOUNTFLIPENGINE_MQH

class CAccountFlipEngine
  {
private:
   bool              m_enabled;
   double            m_startingEquity;
   double            m_targetEquity;
   double            m_peakEquity;
   double            m_currentEquity;
   double            m_riskMultiplier;
   int               m_milestone;
   bool              m_targetReached;
   bool              m_dataValid;
   string            m_persistKey;

   int               MilestoneForEquity(const double equity) const
     {
      if(m_startingEquity<=0.0) return(0);
      double multiple=equity/m_startingEquity;
      if(multiple>=100.0) return(6);
      if(multiple>=50.0)  return(5);
      if(multiple>=25.0)  return(4);
      if(multiple>=10.0)  return(3);
      if(multiple>=5.0)   return(2);
      if(multiple>=2.0)   return(1);
      return(0);
     }

   double            MultiplierForMilestone(const int milestone) const
     {
      // These are capital-preservation scalers, not risk increases.
      // The existing 2% aggregate stop-risk ceiling remains authoritative.
      if(milestone>=6) return(0.50); // 100x and beyond
      if(milestone>=5) return(0.55); // 50x
      if(milestone>=4) return(0.60); // 25x
      if(milestone>=3) return(0.70); // 10x
      if(milestone>=2) return(0.80); // 5x
      if(milestone>=1) return(0.90); // 2x
      return(1.00);
     }

public:
                     CAccountFlipEngine(void)
     {
      m_enabled=true;
      m_startingEquity=100.0;
      m_targetEquity=10000.0;
      m_peakEquity=0.0;
      m_currentEquity=0.0;
      m_riskMultiplier=0.0;
      m_milestone=0;
      m_targetReached=false;
      m_dataValid=false;
      m_persistKey="";
     }

   void              Configure(const bool enabled,const double startingEquity,
                                const double targetEquity)
     {
      m_enabled=enabled;
      m_startingEquity=startingEquity;
      m_targetEquity=targetEquity;
     }

   // Terminal Global Variables persist the equity high-water mark across EA restarts.
   // The key includes account login, symbol and magic to prevent cross-account collisions.
   bool              Init(const string symbol,const ulong magic)
     {
      long login=AccountInfoInteger(ACCOUNT_LOGIN);
      m_persistKey=StringFormat("AXFlipPeak_%I64d_%s_%I64u",login,symbol,magic);
      m_currentEquity=AccountInfoDouble(ACCOUNT_EQUITY);
      if(m_startingEquity<=0.0 || m_targetEquity<=m_startingEquity ||
         !MathIsValidNumber(m_currentEquity) || m_currentEquity<=0.0)
        {
         m_dataValid=false;
         m_riskMultiplier=0.0;
         return(false);
        }

      double storedPeak=GlobalVariableCheck(m_persistKey) ?
                        GlobalVariableGet(m_persistKey) : 0.0;
      m_peakEquity=MathMax(m_currentEquity,storedPeak);
      if(m_peakEquity<=0.0 || !MathIsValidNumber(m_peakEquity))
        {
         m_dataValid=false;
         m_riskMultiplier=0.0;
         return(false);
        }
      if(GlobalVariableSet(m_persistKey,m_peakEquity)==0)
        {
         m_dataValid=false;
         m_riskMultiplier=0.0;
         return(false);
        }
      m_dataValid=true;
      OnTickHousekeeping();
      return(true);
     }

   // Call on each valid market tick. Peak equity is monotonic and survives restarts.
   void              OnTickHousekeeping(void)
     {
      if(!m_enabled)
        {
         m_dataValid=true;
         m_riskMultiplier=1.0;
         return;
        }

      double equity=AccountInfoDouble(ACCOUNT_EQUITY);
      if(!MathIsValidNumber(equity) || equity<=0.0 ||
         m_startingEquity<=0.0 || m_targetEquity<=m_startingEquity ||
         m_persistKey=="")
        {
         m_dataValid=false;
         m_riskMultiplier=0.0;
         return;
        }

      m_currentEquity=equity;
      if(equity>m_peakEquity)
        {
         m_peakEquity=equity;
         if(GlobalVariableSet(m_persistKey,m_peakEquity)==0)
           {
            m_dataValid=false;
            m_riskMultiplier=0.0;
            return;
           }
        }

      m_milestone=MilestoneForEquity(m_peakEquity);
      m_targetReached=(m_peakEquity>=m_targetEquity);
      m_riskMultiplier=MultiplierForMilestone(m_milestone);
      m_riskMultiplier=MathMax(0.0,MathMin(1.0,m_riskMultiplier));
      m_dataValid=true;
     }

   // Returns a scaler in [0,1]. Zero means account state cannot be trusted.
   // Target reached is informational: trading can continue beyond 100x.
   double            RiskMultiplier(void) const
     {
      if(!m_enabled) return(1.0);
      if(!m_dataValid) return(0.0);
      return(MathMax(0.0,MathMin(1.0,m_riskMultiplier)));
     }

   double            StartingEquity(void) const { return(m_startingEquity); }
   double            TargetEquity(void) const { return(m_targetEquity); }
   double            CurrentEquity(void) const { return(m_currentEquity); }
   double            PeakEquity(void) const { return(m_peakEquity); }
   double            ProgressMultiple(void) const
     {
      return(m_startingEquity>0.0 ? m_peakEquity/m_startingEquity : 0.0);
     }
   int               Milestone(void) const { return(m_milestone); }
   bool              TargetReached(void) const { return(m_targetReached); }
   bool              DataValid(void) const { return(m_dataValid); }
   bool              Enabled(void) const { return(m_enabled); }
  };

#endif // AX_ACCOUNTFLIPENGINE_MQH
