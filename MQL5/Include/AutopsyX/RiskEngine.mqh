//+------------------------------------------------------------------+
//|                                                    RiskEngine.mqh|
//|  Risk Engine - hard protections (spec section 12)                |
//|  No martingale. No averaging down. No unlimited risk, ever.       |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_RISKENGINE_MQH
#define AX_RISKENGINE_MQH
#include "Defs.mqh"
#include "MarketData.mqh"

#define AX_RISK_TRADE_BUFFER 256
#define AX_RISK_LOSS_HISTORY 4

class CRiskEngine
  {
private:
   //--- configuration ---
   double            m_riskPercent;
   double            m_dailyLossLimitPercent;
   int               m_maxLossesRolling24h;
   int               m_maxOpenPositions;
   double            m_maxExposureLots;
   int               m_maxFlipsPerDay;
   int               m_maxTradesPerRollingPeriod;
   int               m_rollingPeriodSec;
   double            m_maxSpreadPts;
   double            m_maxSlippagePts;
   double            m_minFreeMarginPercent;

   //--- FLIPDEMON EXTREME upgrade (spec section 18): additional hard circuit breakers ---
   double            m_weeklyLossLimitPercent;
   int               m_maxPositionsPerSymbol;
   double            m_maxDirectionalExposureLots;
   double            m_maxMarginUsagePercent;   // ACCOUNT_MARGIN / ACCOUNT_EQUITY * 100 - distinct
                                                  // from margin LEVEL (which is the broker's own
                                                  // equity/margin ratio, already checked above)
   int               m_maxExecutionFailures;    // consecutive failed order attempts (send rejected,
                                                  // fill unconfirmed) before this becomes a hard block -
                                                  // distinct from AFE's poor-FILL-quality tracking,
                                                  // which is about slippage/latency on FILLED orders

   //--- state ---
   double            m_dayStartEquity;
   datetime          m_dayStartTime;
   double            m_weekStartEquity;
   datetime          m_weekStartTime;
   datetime          m_lossTimes[AX_RISK_LOSS_HISTORY];
   int               m_lossTimeCount;
   bool              m_lossPersistenceOk;
   int               m_flipsToday;
   int               m_consecutiveExecutionFailures;
   bool              m_dailyLockout;
   bool              m_weeklyLockout;
   string            m_lockoutReason;

   datetime          m_tradeTimes[AX_RISK_TRADE_BUFFER];
   int               m_tradeTimeCount;

   bool              m_killed;
   string            m_killReason;

   //--- Monday 00:00 server time of the week containing t - a fixed, deterministic week boundary   ---
   //--- (not "7 days ago", which would drift and never actually reset) ---
   datetime          WeekStart(const datetime t) const
     {
      MqlDateTime dt;
      TimeToStruct(t,dt);
      datetime dayStart = t-(dt.hour*3600+dt.min*60+dt.sec);
      // MqlDateTime.day_of_week: 0=Sunday..6=Saturday. Days since Monday = (day_of_week+6)%7.
      // Same datetime-minus-int arithmetic pattern already used for dayStart above and elsewhere
      // in this codebase (e.g. OnTickHousekeeping below), not a new/uncertain construct.
      int daysSinceMonday = (dt.day_of_week+6)%7;
      return(dayStart-daysSinceMonday*86400);
     }

   string            LossStorageKey(const int slot) const
     {
      // Shared by this account and symbol across EA restarts and EA instances.
      // Keep the key short enough for MT5 terminal global-variable limits.
      return(StringFormat("AXFDX24_%I64d_%s_%d",AccountInfoInteger(ACCOUNT_LOGIN),_Symbol,slot));
     }

   string            LossStorageReadyKey(void) const
     {
      return(StringFormat("AXFDX24_%I64d_%s_READY",AccountInfoInteger(ACCOUNT_LOGIN),_Symbol));
     }

   bool              PersistLossTimes(void)
     {
      for(int i=0;i<AX_RISK_LOSS_HISTORY;i++)
        {
         double storedValue=(i<m_lossTimeCount) ? (double)m_lossTimes[i] : 0.0;
         string key=LossStorageKey(i);
         GlobalVariableSet(key,storedValue);
         if(!GlobalVariableCheck(key) || MathAbs(GlobalVariableGet(key)-storedValue)>0.5)
            return(false);
        }
      string readyKey=LossStorageReadyKey();
      GlobalVariableSet(readyKey,1.0);
      return(GlobalVariableCheck(readyKey) && MathAbs(GlobalVariableGet(readyKey)-1.0)<0.1);
     }

   bool              LoadLossTimes(void)
     {
      m_lossTimeCount=0;
      bool anySlotExists=false;
      for(int i=0;i<AX_RISK_LOSS_HISTORY;i++)
         if(GlobalVariableCheck(LossStorageKey(i))) anySlotExists=true;

      string readyKey=LossStorageReadyKey();
      if(!GlobalVariableCheck(readyKey))
        {
         // No prior state is normal on first install. Partial state without the ready
         // marker is ambiguous, so fail closed rather than assuming there were no losses.
         if(anySlotExists) return(false);
         return(PersistLossTimes());
        }

      for(int i=0;i<AX_RISK_LOSS_HISTORY;i++)
        {
         string key=LossStorageKey(i);
         if(!GlobalVariableCheck(key)) return(false);
         datetime lossTime=(datetime)GlobalVariableGet(key);
         if(lossTime>0)
           {
            if(m_lossTimeCount>=AX_RISK_LOSS_HISTORY) return(false);
            m_lossTimes[m_lossTimeCount]=lossTime;
            m_lossTimeCount++;
           }
        }
      return(true);
     }

   void              PushTradeTime(const datetime t)
     {
      if(m_tradeTimeCount<AX_RISK_TRADE_BUFFER) { m_tradeTimes[m_tradeTimeCount]=t; m_tradeTimeCount++; }
      else
        {
         for(int i=1;i<AX_RISK_TRADE_BUFFER;i++) m_tradeTimes[i-1]=m_tradeTimes[i];
         m_tradeTimes[AX_RISK_TRADE_BUFFER-1]=t;
        }
     }

public:
                     CRiskEngine(void)
     {
      m_riskPercent=1.0; m_dailyLossLimitPercent=4.0; m_maxLossesRolling24h=4;
      m_maxOpenPositions=1; m_maxExposureLots=1.0; m_maxFlipsPerDay=20;
      m_maxTradesPerRollingPeriod=10; m_rollingPeriodSec=300;
      m_maxSpreadPts=250; m_maxSlippagePts=30; m_minFreeMarginPercent=150.0;
      m_weeklyLossLimitPercent=8.0; m_maxPositionsPerSymbol=1; m_maxDirectionalExposureLots=1.0;
      m_maxMarginUsagePercent=50.0; m_maxExecutionFailures=5;
      m_dayStartEquity=0; m_dayStartTime=0; m_weekStartEquity=0; m_weekStartTime=0;
      m_lossTimeCount=0; m_lossPersistenceOk=true; m_flipsToday=0; m_consecutiveExecutionFailures=0;
      m_dailyLockout=false; m_weeklyLockout=false; m_tradeTimeCount=0; m_killed=false;
     }

   void              Configure(const double riskPercent,const double dailyLossLimitPercent,
                                const int maxLossesRolling24h,const int maxOpenPositions,
                                const double maxExposureLots,const int maxFlipsPerDay,
                                const int maxTradesPerRollingPeriod,const int rollingPeriodSec,
                                const double maxSpreadPts,const double maxSlippagePts,
                                const double minFreeMarginPercent,
                                const double weeklyLossLimitPercent=8.0,
                                const int maxPositionsPerSymbol=1,
                                const double maxDirectionalExposureLots=1.0,
                                const double maxMarginUsagePercent=50.0,
                                const int maxExecutionFailures=5)
     {
      m_riskPercent               = AxClampD(riskPercent,0.05,2.0);   // hard ceiling: never >2% (spec section 2)
      m_dailyLossLimitPercent     = dailyLossLimitPercent;
      m_maxLossesRolling24h        = maxLossesRolling24h;
      m_maxOpenPositions          = maxOpenPositions;
      m_maxExposureLots           = maxExposureLots;
      m_maxFlipsPerDay            = maxFlipsPerDay;
      m_maxTradesPerRollingPeriod = maxTradesPerRollingPeriod;
      m_rollingPeriodSec          = rollingPeriodSec;
      m_maxSpreadPts              = maxSpreadPts;
      m_maxSlippagePts            = maxSlippagePts;
      m_minFreeMarginPercent      = minFreeMarginPercent;
      m_weeklyLossLimitPercent    = weeklyLossLimitPercent;
      m_maxPositionsPerSymbol     = maxPositionsPerSymbol;
      m_maxDirectionalExposureLots= maxDirectionalExposureLots;
      m_maxMarginUsagePercent     = maxMarginUsagePercent;
      m_maxExecutionFailures      = maxExecutionFailures;
      m_lossPersistenceOk=LoadLossTimes();
     }

   //--- call every tick: rolls the trading day/week and clears the corresponding lockout ---
   void              OnTickHousekeeping(void)
     {
      MqlDateTime dtNow;
      datetime now=TimeCurrent();
      TimeToStruct(now,dtNow);
      datetime dayStart=now-(dtNow.hour*3600+dtNow.min*60+dtNow.sec);
      datetime weekStart=WeekStart(now);
      double equity=AccountInfoDouble(ACCOUNT_EQUITY);
      bool stateExists=false;

      // Restore account-wide baselines and lockouts so restarts cannot reset loss budgets.
      if(!LoadEquityState(stateExists)) { m_equityPersistenceOk=false; return; }
      if(!stateExists)
        {
         m_dayStartTime=dayStart; m_dayStartEquity=equity; m_dailyLockout=false;
         m_weekStartTime=weekStart; m_weekStartEquity=equity; m_weeklyLockout=false;
         if(equity<=0.0 || !PersistEquityState()) m_equityPersistenceOk=false;
         return;
        }

      bool changed=false;
      if(dayStart!=m_dayStartTime)
        {
         m_dayStartTime=dayStart; m_dayStartEquity=equity; m_dailyLockout=false;
         m_flipsToday=0; m_lockoutReason=""; changed=true;
        }
      if(weekStart!=m_weekStartTime)
        {
         m_weekStartTime=weekStart; m_weekStartEquity=equity; m_weeklyLockout=false;
         changed=true;
        }
      if(m_dayStartEquity<=0.0 || m_weekStartEquity<=0.0 || equity<=0.0)
        {
         m_equityPersistenceOk=false;
         return;
        }
      if(changed && !PersistEquityState()) m_equityPersistenceOk=false;
     }

   //--- position sizing: risk-percent based, never martingale, never scaled by loss streak. ---
   //--- uses the mode-clamped percent fixed once in Configure() - a single source of truth. ---
   double            CalculateLotSize(const CMarketData &md,const double stopDistancePts) const
     {
      if(stopDistancePts<=0) return(0.0);

      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double riskAmount = equity*(m_riskPercent/100.0);

      double point     = md.Point();
      double tickSize  = md.TickSize();
      double tickValue = md.TickValue();
      if(point<=0 || tickSize<=0 || tickValue<=0) return(0.0);

      double stopDistancePrice = stopDistancePts*point;
      double valuePerLot = (stopDistancePrice/tickSize)*tickValue;
      if(valuePerLot<=0) return(0.0);

      double lots = riskAmount/valuePerLot;
      lots = md.NormalizeVolume(lots);
      lots = MathMin(lots,m_maxExposureLots);
      //--- re-normalized AFTER the exposure clamp, not just before it - m_maxExposureLots is a       ---
      //--- user-configured input (Configure()) with no guarantee of being volume-step-aligned for a   ---
      //--- given broker; without this second pass, an exposure cap like 0.375 lots on a 0.01-step      ---
      //--- broker would be returned as-is instead of floored to a broker-valid size (Section A risk-   ---
      //--- invariant audit finding: every return value must be broker-valid regardless of what config  ---
      //--- does, never contingent on the config itself being well-behaved). ---
      lots = md.NormalizeVolume(lots);
      return(lots);
     }

   //--- daily loss limit: once breached, session is done. No auto-recovery, ever. ---
   bool              DailyLossLimitBreached(void)
     {
      if(m_dailyLockout) return(true);
      if(m_dayStartEquity<=0) return(false);
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double lossPct = (m_dayStartEquity-equity)/m_dayStartEquity*100.0;
      if(lossPct>=m_dailyLossLimitPercent)
        {
         m_dailyLockout = true;
         m_lockoutReason = StringFormat("Daily loss limit hit: -%.2f%% (limit %.2f%%)",lossPct,m_dailyLossLimitPercent);
         return(true);
        }
      return(false);
     }

   int               LossesInRolling24Hours(void) const
     {
      datetime now=TimeCurrent();
      int count=0;
      for(int i=0;i<m_lossTimeCount;i++)
         if(m_lossTimes[i]>0 && m_lossTimes[i]<=now && (now-m_lossTimes[i])<=86400) count++;
      return(count);
     }

   bool              Rolling24HourLossLimitBreached(void) const
     {
      return(LossesInRolling24Hours()>=m_maxLossesRolling24h);
     }

   //--- weekly loss limit - same "no auto-recovery" discipline as the daily one, on a Monday-      ---
   //--- anchored week boundary rather than a rolling 7-day window (spec section 18) ---
   bool              WeeklyLossLimitBreached(void)
     {
      if(m_weeklyLockout) return(true);
      if(m_weekStartEquity<=0) return(false);
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double lossPct = (m_weekStartEquity-equity)/m_weekStartEquity*100.0;
      if(lossPct>=m_weeklyLossLimitPercent)
        {
         m_weeklyLockout = true;
         m_lockoutReason = StringFormat("Weekly loss limit hit: -%.2f%% (limit %.2f%%)",lossPct,m_weeklyLossLimitPercent);
         return(true);
        }
      return(false);
     }

   //--- margin USAGE (how much of equity is currently tied up as margin) - distinct from margin     ---
   //--- LEVEL (the broker's equity/margin ratio) already checked in PreTradeAllowed. A high margin   ---
   //--- level can still coexist with heavy margin usage on a large account; this catches that. ---
   //--- equity<=0 (no real account data) fails CLOSED here, deliberately NOT expressed as
   //--- "MarginUsagePercent() < max" (0.0 < max would read as acceptable) - see MarginUsagePercent()'s
   //--- own comment for why that reformulation would silently drop this exact guard. ---
   bool              MarginUsageAcceptable(void) const
     {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity<=0) return(false);
      double marginUsed = AccountInfoDouble(ACCOUNT_MARGIN);
      double usagePct = (marginUsed/equity)*100.0;
      return(usagePct<m_maxMarginUsagePercent);
     }

   // Reject a proposed order that would breach symbol or directional lot caps after fill.
   bool              ProjectedExposureAcceptable(const double currentSymbolLots,
                                                   const double currentDirectionalLots,
                                                   const double proposedLots) const
     {
      if(currentSymbolLots<0.0 || currentDirectionalLots<0.0 || proposedLots<=0.0) return(false);
      if(currentSymbolLots+proposedLots>m_maxExposureLots+1e-8) return(false);
      if(currentDirectionalLots+proposedLots>m_maxDirectionalExposureLots+1e-8) return(false);
      return(true);
     }

   // Evaluate margin after adding the proposed order, not merely current account usage.
   bool              ProjectedMarginAcceptable(const double additionalMargin) const
     {
      if(additionalMargin<0.0) return(false);
      double equity=AccountInfoDouble(ACCOUNT_EQUITY);
      double freeMargin=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(equity<=0.0 || freeMargin<additionalMargin) return(false);
      double projectedUsage=((AccountInfoDouble(ACCOUNT_MARGIN)+additionalMargin)/equity)*100.0;
      return(projectedUsage<m_maxMarginUsagePercent);
     }

   //--- consecutive execution failures (order send rejected, fill never confirmed) - distinct from  ---
   //--- AFE's poor-FILL-quality tracking (slippage/latency on orders that DID fill). A string of raw ---
   //--- failures to even get an order accepted is a different, more basic signal that something is   ---
   //--- wrong (connectivity, broker-side account issue, invalid parameters) and blocks new entries    ---
   //--- until a success resets the streak - existing positions are still managed regardless. ---
   void              RegisterExecutionFailure(void) { m_consecutiveExecutionFailures++; }
   void              RegisterExecutionSuccess(void) { m_consecutiveExecutionFailures=0; }
   bool              ExecutionFailureLimitBreached(void) const
     {
      return(m_consecutiveExecutionFailures>=m_maxExecutionFailures);
     }
   int               ConsecutiveExecutionFailures(void) const { return(m_consecutiveExecutionFailures); }

   void              RegisterTradeClosed(const double netProfit)
     {
      datetime closedAt=TimeCurrent();
      if(netProfit<0)
        {
         if(m_lossTimeCount<AX_RISK_LOSS_HISTORY)
           {
            m_lossTimes[m_lossTimeCount]=closedAt;
            m_lossTimeCount++;
           }
         else
           {
            for(int i=1;i<AX_RISK_LOSS_HISTORY;i++) m_lossTimes[i-1]=m_lossTimes[i];
            m_lossTimes[AX_RISK_LOSS_HISTORY-1]=closedAt;
           }
         if(!PersistLossTimes()) m_lossPersistenceOk=false;
        }
      PushTradeTime(closedAt);
     }

   void              RegisterFlip(void) { m_flipsToday++; }

   int               TradesInRollingWindow(void) const
     {
      datetime now = TimeCurrent();
      int c=0;
      for(int i=0;i<m_tradeTimeCount;i++)
         if((now-m_tradeTimes[i])<=m_rollingPeriodSec) c++;
      return(c);
     }

   //--- master pre-trade gate; returns false with reason if any hard limit blocks trading. ---
   //--- positionsForSymbol/directionalExposureLots default to the same values as openPositions/     ---
   //--- currentExposureLots - for a single-symbol EA (this one only ever trades _Symbol) those ARE   ---
   //--- the per-symbol/directional figures, so no separate caller-side tracking is invented just to  ---
   //--- fill a parameter; a multi-symbol deployment would pass genuinely distinct values here. ---
   bool              PreTradeAllowed(const int openPositions,const double currentExposureLots,
                                      const double spreadPts,string &reason,
                                      const int positionsForSymbol=-1,
                                      const double directionalExposureLots=-1)
     {
      int posForSymbol = (positionsForSymbol<0) ? openPositions : positionsForSymbol;
      double dirExposure = (directionalExposureLots<0) ? currentExposureLots : directionalExposureLots;

      if(m_killed) { reason="Kill switch active"; return(false); }
      if(!m_lossPersistenceOk) { reason="Rolling 24-hour loss history persistence failed; entries blocked"; return(false); }
      if(DailyLossLimitBreached()) { reason=m_lockoutReason; return(false); }
      if(WeeklyLossLimitBreached()) { reason=m_lockoutReason; return(false); }
      if(Rolling24HourLossLimitBreached()) { reason=StringFormat("Rolling 24-hour loss limit reached (%d losing trades)",LossesInRolling24Hours()); return(false); }
      if(ExecutionFailureLimitBreached())
        { reason=StringFormat("Max consecutive execution failures reached (%d)",m_consecutiveExecutionFailures); return(false); }
      if(openPositions>=m_maxOpenPositions) { reason="Max open positions reached"; return(false); }
      if(posForSymbol>=m_maxPositionsPerSymbol) { reason="Max positions for this symbol reached"; return(false); }
      if(currentExposureLots>=m_maxExposureLots) { reason="Max exposure reached"; return(false); }
      if(dirExposure>=m_maxDirectionalExposureLots) { reason="Max directional exposure reached"; return(false); }
      if(m_flipsToday>=m_maxFlipsPerDay) { reason="Max flips per day reached"; return(false); }
      if(TradesInRollingWindow()>=m_maxTradesPerRollingPeriod) { reason="Max trades in rolling window reached"; return(false); }
      if(spreadPts>m_maxSpreadPts) { reason="Spread above maximum allowed"; return(false); }
      if(!MarginUsageAcceptable()) { reason="Margin usage above maximum allowed"; return(false); }

      double marginFree  = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      double marginLevel = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL); // 0 when no margin is currently used
      if(marginLevel>0 && marginLevel<m_minFreeMarginPercent)
        { reason="Margin level below minimum threshold"; return(false); }
      if(marginFree<=0) { reason="No free margin"; return(false); }

      reason="";
      return(true);
     }

   bool              SlippageAcceptable(const double slippagePts) const
     {
      return(MathAbs(slippagePts)<=m_maxSlippagePts);
     }

   void              ActivateKillSwitch(const string reasonText)
     {
      m_killed = true;
      m_killReason = reasonText;
     }
   void              DeactivateKillSwitch(void) { m_killed=false; m_killReason=""; }
   bool              IsKilled(void) const { return(m_killed); }
   string            KillReason(void) const { return(m_killReason); }

   double            RiskPercent(void) const { return(m_riskPercent); }
   int               FlipsToday(void) const { return(m_flipsToday); }
   bool              DailyLockout(void) const { return(m_dailyLockout); }
   string            LockoutReason(void) const { return(m_lockoutReason); }
   double            DayStartEquity(void) const { return(m_dayStartEquity); }
   double            DailyPnL(void) const
     {
      if(m_dayStartEquity<=0) return(0.0);
      return(AccountInfoDouble(ACCOUNT_EQUITY)-m_dayStartEquity);
     }
   double            DailyPnLPercent(void) const
     {
      if(m_dayStartEquity<=0) return(0.0);
      return(DailyPnL()/m_dayStartEquity*100.0);
     }

   bool              WeeklyLockout(void) const { return(m_weeklyLockout); }
   double            WeekStartEquity(void) const { return(m_weekStartEquity); }
   double            WeeklyPnL(void) const
     {
      if(m_weekStartEquity<=0) return(0.0);
      return(AccountInfoDouble(ACCOUNT_EQUITY)-m_weekStartEquity);
     }
   double            WeeklyPnLPercent(void) const
     {
      if(m_weekStartEquity<=0) return(0.0);
      return(WeeklyPnL()/m_weekStartEquity*100.0);
     }
   //--- dashboard/reporting accessor - returns 0.0 (not an error) when equity is unavailable, since  ---
   //--- 0.0 reads correctly as "nothing to report" on a display. MarginUsageAcceptable() above does  ---
   //--- its OWN equity<=0 check rather than calling this and testing "< max", precisely because 0.0   ---
   //--- would then read as acceptable - do not collapse the two into one implementation. ---
   double            MarginUsagePercent(void) const
     {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity<=0) return(0.0);
      return((AccountInfoDouble(ACCOUNT_MARGIN)/equity)*100.0);
     }
  };
//+------------------------------------------------------------------+
#endif // AX_RISKENGINE_MQH
