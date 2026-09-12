//+------------------------------------------------------------------+
//| DrawdownEngine.mqh                                                    |
//| Section 5 — RISK-OF-RUIN GOVERNOR state machine, plus Hidden          |
//| Mechanics #14 (Win-Streak Protection) and #15 (Loss-Streak Defense), |
//| plus the hard daily/weekly/max drawdown circuit breakers (Section 40)|
//|                                                                        |
//| This is the one place allowed to force MODE_SURVIVAL or a full HALT. |
//| No other engine may override a HALT issued here.                     |
//+------------------------------------------------------------------+
#ifndef AXF_DRAWDOWNENGINE_MQH
#define AXF_DRAWDOWNENGINE_MQH

#include "../Common/Defines.mqh"

class CAxfDrawdownEngine
  {
private:
   double            m_daily_start_equity;
   double            m_weekly_start_equity;
   datetime          m_daily_anchor_day;
   datetime          m_weekly_anchor_week;
   double            m_daily_max_dd_pct;
   double            m_weekly_max_dd_pct;
   double            m_account_max_dd_pct;
   int               m_loss_reduce1, m_loss_reduce2, m_loss_halt;
   double            m_loss_cut_factor;
   int               m_win_review_at;
   double            m_win_cap_factor;
   bool              m_manual_halt_latched; // account max DD hit -> requires manual reset

   string            m_gv_prefix;
   string GV(const string key) { return m_gv_prefix+"_dd_"+key; }

public:
                     CAxfDrawdownEngine(void)
     {
      m_daily_start_equity=0; m_weekly_start_equity=0;
      m_daily_anchor_day=0; m_weekly_anchor_week=0;
      m_daily_max_dd_pct=4; m_weekly_max_dd_pct=8; m_account_max_dd_pct=20;
      m_loss_reduce1=2; m_loss_reduce2=3; m_loss_halt=5; m_loss_cut_factor=0.5;
      m_win_review_at=4; m_win_cap_factor=1.5; m_manual_halt_latched=false;
     }

   void              Init(const ulong magic,
                           const double daily_max_dd_pct,const double weekly_max_dd_pct,
                           const double account_max_dd_pct,
                           const int loss_reduce1,const int loss_reduce2,const int loss_halt,
                           const double loss_cut_factor,
                           const int win_review_at,const double win_cap_factor,
                           const double current_equity)
     {
      m_gv_prefix = "AXF15_"+IntegerToString((long)magic);
      m_daily_max_dd_pct=daily_max_dd_pct; m_weekly_max_dd_pct=weekly_max_dd_pct;
      m_account_max_dd_pct=account_max_dd_pct;
      m_loss_reduce1=loss_reduce1; m_loss_reduce2=loss_reduce2; m_loss_halt=loss_halt;
      m_loss_cut_factor=loss_cut_factor; m_win_review_at=win_review_at; m_win_cap_factor=win_cap_factor;

      if(GlobalVariableCheck(GV("latched")))
         m_manual_halt_latched = (GlobalVariableGet(GV("latched"))>0.5);

      RollDailyWeeklyAnchors(current_equity, true);
     }

   //--- must be called on every timer tick so daily/weekly anchors reset at
   //--- the correct boundary even across terminal restarts (persisted anchor).
   void              RollDailyWeeklyAnchors(const double current_equity,const bool force_seed=false)
     {
      MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
      dt.hour=0; dt.min=0; dt.sec=0;
      datetime today = StructToTime(dt);

      int dow = dt.day_of_week; // 0=Sunday
      datetime week_start = today - dow*86400;

      bool have_daily = GlobalVariableCheck(GV("day_anchor"));
      bool have_weekly= GlobalVariableCheck(GV("week_anchor"));

      if(force_seed && !have_daily)
        {
         m_daily_anchor_day = today;
         m_daily_start_equity = current_equity;
         GlobalVariableSet(GV("day_anchor"),(double)m_daily_anchor_day);
         GlobalVariableSet(GV("day_start_eq"),m_daily_start_equity);
        }
      else if(have_daily)
        {
         m_daily_anchor_day = (datetime)GlobalVariableGet(GV("day_anchor"));
         m_daily_start_equity = GlobalVariableGet(GV("day_start_eq"));
        }

      if(today != m_daily_anchor_day)
        {
         m_daily_anchor_day = today;
         m_daily_start_equity = current_equity;
         GlobalVariableSet(GV("day_anchor"),(double)m_daily_anchor_day);
         GlobalVariableSet(GV("day_start_eq"),m_daily_start_equity);
        }

      if(force_seed && !have_weekly)
        {
         m_weekly_anchor_week = week_start;
         m_weekly_start_equity = current_equity;
         GlobalVariableSet(GV("week_anchor"),(double)m_weekly_anchor_week);
         GlobalVariableSet(GV("week_start_eq"),m_weekly_start_equity);
        }
      else if(have_weekly)
        {
         m_weekly_anchor_week = (datetime)GlobalVariableGet(GV("week_anchor"));
         m_weekly_start_equity = GlobalVariableGet(GV("week_start_eq"));
        }

      if(week_start != m_weekly_anchor_week)
        {
         m_weekly_anchor_week = week_start;
         m_weekly_start_equity = current_equity;
         GlobalVariableSet(GV("week_anchor"),(double)m_weekly_anchor_week);
         GlobalVariableSet(GV("week_start_eq"),m_weekly_start_equity);
        }
     }

   double            DailyDrawdownPct(const double equity) const
     {
      if(m_daily_start_equity<=0) return 0.0;
      return MathMax(0.0,(m_daily_start_equity-equity)/m_daily_start_equity*100.0);
     }
   double            WeeklyDrawdownPct(const double equity) const
     {
      if(m_weekly_start_equity<=0) return 0.0;
      return MathMax(0.0,(m_weekly_start_equity-equity)/m_weekly_start_equity*100.0);
     }

   bool              DailyLimitBreached(const double equity) const { return DailyDrawdownPct(equity) >= m_daily_max_dd_pct; }
   bool              WeeklyLimitBreached(const double equity) const { return WeeklyDrawdownPct(equity) >= m_weekly_max_dd_pct; }

   //--- the ONE latch that requires a human. Once tripped, stays tripped
   //--- (persisted) until an operator explicitly clears it via the EA's
   //--- chart button / manual GlobalVariableDel — never auto-clears itself.
   bool              CheckAccountMaxDrawdown(const double equity_high,const double equity)
     {
      if(m_manual_halt_latched) return true;
      if(equity_high<=0) return false;
      double dd = (equity_high-equity)/equity_high*100.0;
      if(dd >= m_account_max_dd_pct)
        {
         m_manual_halt_latched = true;
         GlobalVariableSet(GV("latched"),1.0);
        }
      return m_manual_halt_latched;
     }

   bool              IsManualHaltLatched(void) const { return m_manual_halt_latched; }
   void              ClearManualHalt(void)
     {
      m_manual_halt_latched=false;
      GlobalVariableDel(GV("latched"));
     }

   //--- Hidden Mechanic #15: progressive risk cuts on consecutive losses.
   //--- Returns a multiplier in (0,1] to apply on top of everything else.
   //--- NEVER increases risk to "recover" — only ever cuts or holds at 1.0.
   double            LossStreakFactor(const int consecutive_losses) const
     {
      if(consecutive_losses >= m_loss_halt) return 0.0; // caller must also halt new trades
      if(consecutive_losses >= m_loss_reduce2) return m_loss_cut_factor*m_loss_cut_factor;
      if(consecutive_losses >= m_loss_reduce1) return m_loss_cut_factor;
      return 1.0;
     }

   bool              LossStreakForcesHalt(const int consecutive_losses) const
     {
      return consecutive_losses >= m_loss_halt;
     }

   //--- Hidden Mechanic #14: a winning streak may never uncap exposure.
   //--- Returns the multiplier CEILING attributable to a streak — this is a
   //--- limiter, not a booster.
   double            WinStreakCeiling(const int consecutive_wins) const
     {
      if(consecutive_wins >= m_win_review_at) return m_win_cap_factor;
      return AXF_HARD_MAX_RISK_MULT; // no extra restriction below the review threshold
     }
  };

#endif // AXF_DRAWDOWNENGINE_MQH
