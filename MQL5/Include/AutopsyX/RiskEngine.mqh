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

class CRiskEngine
  {
private:
   //--- configuration ---
   double            m_riskPercent;
   double            m_dailyLossLimitPercent;
   int               m_maxConsecutiveLosses;
   int               m_maxOpenPositions;
   double            m_maxExposureLots;
   int               m_maxFlipsPerDay;
   int               m_maxTradesPerRollingPeriod;
   int               m_rollingPeriodSec;
   double            m_maxSpreadPts;
   double            m_maxSlippagePts;
   double            m_minFreeMarginPercent;

   //--- state ---
   double            m_dayStartEquity;
   datetime          m_dayStartTime;
   int               m_consecutiveLosses;
   int               m_flipsToday;
   bool              m_dailyLockout;
   string            m_lockoutReason;

   datetime          m_tradeTimes[AX_RISK_TRADE_BUFFER];
   int               m_tradeTimeCount;

   bool              m_killed;
   string            m_killReason;

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
      m_riskPercent=1.0; m_dailyLossLimitPercent=8.0; m_maxConsecutiveLosses=5;
      m_maxOpenPositions=1; m_maxExposureLots=1.0; m_maxFlipsPerDay=20;
      m_maxTradesPerRollingPeriod=10; m_rollingPeriodSec=300;
      m_maxSpreadPts=250; m_maxSlippagePts=30; m_minFreeMarginPercent=150.0;
      m_dayStartEquity=0; m_dayStartTime=0; m_consecutiveLosses=0; m_flipsToday=0;
      m_dailyLockout=false; m_tradeTimeCount=0; m_killed=false;
     }

   void              Configure(const double riskPercent,const double dailyLossLimitPercent,
                                const int maxConsecutiveLosses,const int maxOpenPositions,
                                const double maxExposureLots,const int maxFlipsPerDay,
                                const int maxTradesPerRollingPeriod,const int rollingPeriodSec,
                                const double maxSpreadPts,const double maxSlippagePts,
                                const double minFreeMarginPercent)
     {
      m_riskPercent               = AxClampD(riskPercent,0.05,2.0);   // hard ceiling: never >2% (spec section 2)
      m_dailyLossLimitPercent     = dailyLossLimitPercent;
      m_maxConsecutiveLosses      = maxConsecutiveLosses;
      m_maxOpenPositions          = maxOpenPositions;
      m_maxExposureLots           = maxExposureLots;
      m_maxFlipsPerDay            = maxFlipsPerDay;
      m_maxTradesPerRollingPeriod = maxTradesPerRollingPeriod;
      m_rollingPeriodSec          = rollingPeriodSec;
      m_maxSpreadPts              = maxSpreadPts;
      m_maxSlippagePts            = maxSlippagePts;
      m_minFreeMarginPercent      = minFreeMarginPercent;
     }

   //--- call every tick: rolls the trading day and clears the daily lockout ---
   void              OnTickHousekeeping(void)
     {
      MqlDateTime dtNow;
      TimeToStruct(TimeCurrent(),dtNow);
      datetime dayStart = TimeCurrent() - (dtNow.hour*3600+dtNow.min*60+dtNow.sec);
      if(dayStart != m_dayStartTime)
        {
         m_dayStartTime   = dayStart;
         m_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
         m_consecutiveLosses = 0;
         m_flipsToday = 0;
         m_dailyLockout = false;
         m_lockoutReason = "";
        }
      if(m_dayStartEquity<=0) m_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
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

   bool              ConsecutiveLossLimitBreached(void) const
     {
      return(m_consecutiveLosses>=m_maxConsecutiveLosses);
     }

   void              RegisterTradeClosed(const double netProfit)
     {
      if(netProfit<0) m_consecutiveLosses++;
      else if(netProfit>0) m_consecutiveLosses=0;
      PushTradeTime(TimeCurrent());
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

   //--- master pre-trade gate; returns false with reason if any hard limit blocks trading ---
   bool              PreTradeAllowed(const int openPositions,const double currentExposureLots,
                                      const double spreadPts,string &reason)
     {
      if(m_killed) { reason="Kill switch active"; return(false); }
      if(DailyLossLimitBreached()) { reason=m_lockoutReason; return(false); }
      if(ConsecutiveLossLimitBreached()) { reason="Max consecutive losses reached - session paused"; return(false); }
      if(openPositions>=m_maxOpenPositions) { reason="Max open positions reached"; return(false); }
      if(currentExposureLots>=m_maxExposureLots) { reason="Max exposure reached"; return(false); }
      if(m_flipsToday>=m_maxFlipsPerDay) { reason="Max flips per day reached"; return(false); }
      if(TradesInRollingWindow()>=m_maxTradesPerRollingPeriod) { reason="Max trades in rolling window reached"; return(false); }
      if(spreadPts>m_maxSpreadPts) { reason="Spread above maximum allowed"; return(false); }

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
   int               ConsecutiveLosses(void) const { return(m_consecutiveLosses); }
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
  };
//+------------------------------------------------------------------+
#endif // AX_RISKENGINE_MQH
