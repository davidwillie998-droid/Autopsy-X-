//+------------------------------------------------------------------+
//| RiskEngine.mqh                                                    |
//| Capital preservation comes before speed. Hard daily-loss / streak |
//| / frequency limits, drawdown shutdown, and an emergency kill      |
//| switch that never resets itself to "chase" a loss.                |
//+------------------------------------------------------------------+
#pragma once
#include <AutopsyX/Defines.mqh>
#include <AutopsyX/SymbolProfile.mqh>

class CAXRisk
{
private:
   double   m_riskPerTradePct;
   double   m_maxDailyLossPct;
   int      m_maxConsecutiveLosses;
   int      m_maxOpenPositions;
   int      m_maxTradesPerMinute;
   int      m_maxTradesPerSession;
   int      m_maxFlipsPerMinute;
   double   m_maxDrawdownPct;
   int      m_baseCooldownSec;

   double   m_dayStartEquity;
   double   m_dailyPL;
   int      m_consecutiveLosses;
   int      m_tradesToday;
   datetime m_currentDay;

   datetime m_tradeTimes[64];
   int      m_tradeTimesCount;
   datetime m_flipTimes[64];
   int      m_flipTimesCount;

   double   m_peakEquity;
   bool     m_killSwitch;
   string   m_killReason;

   datetime m_cooldownUntil;

public:
   CAXRisk(void) : m_riskPerTradePct(0.5), m_maxDailyLossPct(3.0), m_maxConsecutiveLosses(4),
      m_maxOpenPositions(1), m_maxTradesPerMinute(6), m_maxTradesPerSession(60),
      m_maxFlipsPerMinute(4), m_maxDrawdownPct(8.0), m_baseCooldownSec(15),
      m_dayStartEquity(0), m_dailyPL(0), m_consecutiveLosses(0), m_tradesToday(0),
      m_currentDay(0), m_tradeTimesCount(0), m_flipTimesCount(0), m_peakEquity(0),
      m_killSwitch(false), m_cooldownUntil(0) {}

   void Init(const double riskPerTradePct, const double maxDailyLossPct, const int maxConsecutiveLosses,
             const int maxOpenPositions, const int maxTradesPerMinute, const int maxTradesPerSession,
             const int maxFlipsPerMinute, const double maxDrawdownPct, const int baseCooldownSec)
   {
      m_riskPerTradePct       = riskPerTradePct;
      m_maxDailyLossPct       = maxDailyLossPct;
      m_maxConsecutiveLosses  = maxConsecutiveLosses;
      m_maxOpenPositions      = maxOpenPositions;
      m_maxTradesPerMinute    = maxTradesPerMinute;
      m_maxTradesPerSession   = maxTradesPerSession;
      m_maxFlipsPerMinute     = maxFlipsPerMinute;
      m_maxDrawdownPct        = maxDrawdownPct;
      m_baseCooldownSec       = baseCooldownSec;
      m_dayStartEquity        = AccountInfoDouble(ACCOUNT_EQUITY);
      m_peakEquity            = m_dayStartEquity;
      m_currentDay             = CurrentDayStamp();
   }

   //--- must be called periodically (e.g. every tick or on timer) --------
   void Heartbeat(void)
   {
      datetime today = CurrentDayStamp();
      if(today != m_currentDay)
      {
         m_currentDay = today;
         m_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
         m_dailyPL = 0.0;
         m_tradesToday = 0;
         m_consecutiveLosses = 0;
         // kill switch is NOT auto-cleared across days for a risk shutdown;
         // only an operator action (EA restart / manual reset) clears it.
      }
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      if(eq > m_peakEquity) m_peakEquity = eq;

      if(!m_killSwitch)
      {
         if(m_maxDailyLossPct > 0.0 && m_dayStartEquity > 0.0)
         {
            double lossPct = (m_dayStartEquity - eq) / m_dayStartEquity * 100.0;
            if(lossPct >= m_maxDailyLossPct)
               TriggerKillSwitch(StringFormat("daily loss limit hit (%.2f%%)", lossPct));
         }
         if(m_maxDrawdownPct > 0.0 && m_peakEquity > 0.0)
         {
            double ddPct = (m_peakEquity - eq) / m_peakEquity * 100.0;
            if(ddPct >= m_maxDrawdownPct)
               TriggerKillSwitch(StringFormat("drawdown shutdown (%.2f%%)", ddPct));
         }
      }
   }

   void RegisterTradeOpened(void)
   {
      m_tradesToday++;
      PushTime(m_tradeTimes, m_tradeTimesCount, TimeTradeServer());
   }

   void RegisterFlip(void)
   {
      PushTime(m_flipTimes, m_flipTimesCount, TimeTradeServer());
   }

   void RegisterTradeClosed(const double profit)
   {
      m_dailyPL += profit;
      if(profit < 0.0)
      {
         m_consecutiveLosses++;
         m_cooldownUntil = TimeTradeServer() + AdaptiveCooldownSec();
      }
      else
      {
         m_consecutiveLosses = 0;
      }
   }

   bool CanOpenNewTrade(const int openPositionsNow, string &reason)
   {
      if(m_killSwitch) { reason = "kill switch: " + m_killReason; return false; }
      if(openPositionsNow >= m_maxOpenPositions) { reason = "max open positions reached"; return false; }
      if(m_tradesToday >= m_maxTradesPerSession) { reason = "max trades per session reached"; return false; }
      if(m_consecutiveLosses >= m_maxConsecutiveLosses) { reason = "consecutive loss limit - cooling down"; return false; }
      if(TimeTradeServer() < m_cooldownUntil) { reason = "in loss cooldown"; return false; }
      if(CountRecent(m_tradeTimes, m_tradeTimesCount, 60) >= m_maxTradesPerMinute) { reason = "max trades per minute reached"; return false; }
      if(CountRecent(m_flipTimes, m_flipTimesCount, 60) >= m_maxFlipsPerMinute) { reason = "max flips per minute reached"; return false; }
      reason = "";
      return true;
   }

   int AdaptiveCooldownSec(void) const
   {
      // the worse the recent streak, the longer the cooldown - bounded
      int mult = 1 + m_consecutiveLosses;
      int sec = m_baseCooldownSec * mult;
      return AXClampInt(sec, AX_ADAPT_COOLDOWN_MIN_SEC, AX_ADAPT_COOLDOWN_MAX_SEC);
   }

   void TriggerKillSwitch(const string reason)
   {
      m_killSwitch = true;
      m_killReason = reason;
      PrintFormat("[AutopsyX][RISK] KILL SWITCH ENGAGED: %s", reason);
   }

   void ManualReset(void)
   {
      m_killSwitch = false;
      m_killReason = "";
      m_consecutiveLosses = 0;
      m_cooldownUntil = 0;
   }

   double LotsForRisk(const CAXSymbolProfile &profile, const double stopDistancePoints) const
   {
      if(stopDistancePoints <= 0.0 || profile.tick_size <= 0.0 || profile.tick_value <= 0.0)
         return profile.volume_min;

      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double riskAmount = equity * (m_riskPerTradePct / 100.0);
      double valuePerPointPerLot = profile.tick_value * (profile.point / profile.tick_size);
      if(valuePerPointPerLot <= 0.0) return profile.volume_min;

      double lots = riskAmount / (stopDistancePoints * valuePerPointPerLot);
      return profile.NormalizeVolume(lots);
   }

   bool   KillSwitchActive(void) const { return m_killSwitch; }
   string KillReason(void)       const { return m_killReason; }
   double DailyPL(void)          const { return m_dailyPL; }
   int    ConsecutiveLosses(void) const { return m_consecutiveLosses; }
   int    TradesToday(void)      const { return m_tradesToday; }
   double EquityDrawdownPct(void) const
   {
      if(m_peakEquity <= 0.0) return 0.0;
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      return MathMax(0.0, (m_peakEquity - eq) / m_peakEquity * 100.0);
   }
   bool InCooldown(void) const { return TimeTradeServer() < m_cooldownUntil; }

private:
   datetime CurrentDayStamp(void) const
   {
      MqlDateTime d;
      TimeToStruct(TimeTradeServer(), d);
      d.hour = 0; d.min = 0; d.sec = 0;
      return StructToTime(d);
   }

   void PushTime(datetime &arr[], int &count, const datetime t)
   {
      int cap = ArraySize(arr);
      if(count < cap)
      {
         arr[count++] = t;
      }
      else
      {
         for(int i = 1; i < cap; i++) arr[i - 1] = arr[i];
         arr[cap - 1] = t;
      }
   }

   int CountRecent(const datetime &arr[], const int count, const int withinSec) const
   {
      datetime now = TimeTradeServer();
      int n = 0;
      for(int i = 0; i < count; i++)
         if(now - arr[i] <= withinSec) n++;
      return n;
   }
};
