//+------------------------------------------------------------------+
//| DrawdownEngine.mqh                                                  |
//| Tracks real equity drawdown over daily/weekly/monthly windows and |
//| consecutive-loss streaks, persisted through terminal restarts via |
//| global variables, and exposes the hard kill-switch checks.        |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_RISK_DRAWDOWNENGINE_MQH
#define AX_RISK_DRAWDOWNENGINE_MQH
#include "../core/Types.mqh"

class CDrawdownEngine
  {
private:
   string m_prefix;
   double m_dailyBaseline, m_weeklyBaseline, m_monthlyBaseline;
   double m_dailyPeak, m_weeklyPeak, m_monthlyPeak;
   int    m_day, m_week, m_month;
   int    m_consecutiveLosses;

   string GvName(string key) const { return m_prefix+"_"+key; }

   double GvGetOrInit(string key, double defVal)
     {
      string name = GvName(key);
      if(GlobalVariableCheck(name)) return GlobalVariableGet(name);
      GlobalVariableSet(name, defVal);
      return defVal;
     }

   void GvSet(string key, double val) { GlobalVariableSet(GvName(key), val); }

public:
   void Init(const string symbol, long magic)
     {
      m_prefix = StringFormat("AXSD15_%s_%I64d", symbol, magic);
      MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
      m_day = dt.day; m_week = ISOWeekNumber(TimeCurrent()); m_month = dt.mon;

      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      m_dailyBaseline   = GvGetOrInit("day_base",  equity);
      m_weeklyBaseline  = GvGetOrInit("week_base", equity);
      m_monthlyBaseline = GvGetOrInit("month_base",equity);
      m_dailyPeak       = GvGetOrInit("day_peak",  equity);
      m_weeklyPeak      = GvGetOrInit("week_peak", equity);
      m_monthlyPeak     = GvGetOrInit("month_peak",equity);
      m_consecutiveLosses = (int)GvGetOrInit("consec_losses", 0);
     }

   int ISOWeekNumber(datetime t) const
     {
      MqlDateTime dt; TimeToStruct(t, dt);
      int dayOfYear = dt.day_of_year;
      int dow = (dt.day_of_week==0)?7:dt.day_of_week;
      return (dayOfYear - dow + 10) / 7;
     }

   //--- call once per tick: rolls baselines forward when a new day/week/month begins
   void Update()
     {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
      int week = ISOWeekNumber(TimeCurrent());

      if(dt.day != m_day)
        {
         m_day = dt.day;
         m_dailyBaseline = equity; m_dailyPeak = equity;
         GvSet("day_base", equity); GvSet("day_peak", equity);
        }
      if(week != m_week)
        {
         m_week = week;
         m_weeklyBaseline = equity; m_weeklyPeak = equity;
         GvSet("week_base", equity); GvSet("week_peak", equity);
        }
      if(dt.mon != m_month)
        {
         m_month = dt.mon;
         m_monthlyBaseline = equity; m_monthlyPeak = equity;
         GvSet("month_base", equity); GvSet("month_peak", equity);
        }

      if(equity > m_dailyPeak)   { m_dailyPeak = equity;   GvSet("day_peak", equity); }
      if(equity > m_weeklyPeak)  { m_weeklyPeak = equity;  GvSet("week_peak", equity); }
      if(equity > m_monthlyPeak) { m_monthlyPeak = equity; GvSet("month_peak", equity); }
     }

   double DailyDrawdownPercent() const   { return DrawdownFrom(m_dailyBaseline); }
   double WeeklyDrawdownPercent() const  { return DrawdownFrom(m_weeklyBaseline); }
   double MonthlyDrawdownPercent() const { return DrawdownFrom(m_monthlyBaseline); }
   double PeakToCurrentDrawdownPercent() const { return DrawdownFrom(m_dailyPeak>0.0? m_dailyPeak : AccountInfoDouble(ACCOUNT_EQUITY)); }

   int ConsecutiveLosses() const { return m_consecutiveLosses; }

   //--- feed the outcome of every closed trade; never resets to a HIGHER risk mode automatically after a win streak spike
   void RecordTradeResult(bool wasWin)
     {
      if(wasWin) m_consecutiveLosses = 0;
      else       m_consecutiveLosses++;
      GvSet("consec_losses", m_consecutiveLosses);
     }

   bool CheckHardStops(double maxDailyLossPct, double maxWeeklyLossPct, double maxMonthlyLossPct,
                        int maxConsecutiveLosses, string &reason) const
     {
      double dd = DailyDrawdownPercent();
      if(dd >= maxDailyLossPct)
        { reason = StringFormat("Daily drawdown %.2f%% >= limit %.2f%%", dd, maxDailyLossPct); return true; }
      double wd = WeeklyDrawdownPercent();
      if(wd >= maxWeeklyLossPct)
        { reason = StringFormat("Weekly drawdown %.2f%% >= limit %.2f%%", wd, maxWeeklyLossPct); return true; }
      double md = MonthlyDrawdownPercent();
      if(md >= maxMonthlyLossPct)
        { reason = StringFormat("Monthly drawdown %.2f%% >= limit %.2f%%", md, maxMonthlyLossPct); return true; }
      if(maxConsecutiveLosses>0 && m_consecutiveLosses >= maxConsecutiveLosses)
        { reason = StringFormat("Consecutive losses %d >= limit %d", m_consecutiveLosses, maxConsecutiveLosses); return true; }
      reason = "";
      return false;
     }

private:
   double DrawdownFrom(double baseline) const
     {
      if(baseline<=0.0) return 0.0;
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double dd = (baseline-equity)/baseline*100.0;
      return MathMax(0.0, dd);
     }
  };
#endif // AX_RISK_DRAWDOWNENGINE_MQH
