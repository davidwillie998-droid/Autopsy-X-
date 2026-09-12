//+------------------------------------------------------------------+
//| CompoundingEngine.mqh                                               |
//| Layer 11 — COMPOUNDING ENGINE (Hidden Mechanic #1).                  |
//| Tracks equity evolution: Equity(n+1) = Equity(n)*(1 + Risk(n)*R(n)). |
//| Pure bookkeeping — no forecasting, no assumption that past          |
//| compounding continues. Persists to GlobalVariables so a terminal    |
//| restart does not lose the equity curve (Section 41).                |
//+------------------------------------------------------------------+
#ifndef AXF_COMPOUNDINGENGINE_MQH
#define AXF_COMPOUNDINGENGINE_MQH

#include "../Common/Defines.mqh"

class CAxfCompoundingEngine
  {
private:
   double            m_starting_equity;
   double            m_equity_high;
   double            m_equity_low;
   int               m_closed_trades;
   double            m_sum_r;
   double            m_sum_win_r;   int m_win_count;
   double            m_sum_loss_r;  int m_loss_count;
   int               m_consec_wins, m_consec_losses;
   string            m_gv_prefix;

   string GV(const string key) { return m_gv_prefix+"_"+key; }

   void   SavePersisted(void)
     {
      GlobalVariableSet(GV("start_eq"), m_starting_equity);
      GlobalVariableSet(GV("eq_high"),  m_equity_high);
      GlobalVariableSet(GV("eq_low"),   m_equity_low);
      GlobalVariableSet(GV("closed"),   m_closed_trades);
      GlobalVariableSet(GV("sum_r"),    m_sum_r);
      GlobalVariableSet(GV("sum_win_r"),m_sum_win_r);
      GlobalVariableSet(GV("win_cnt"),  m_win_count);
      GlobalVariableSet(GV("sum_loss_r"),m_sum_loss_r);
      GlobalVariableSet(GV("loss_cnt"), m_loss_count);
      GlobalVariableSet(GV("cwins"),    m_consec_wins);
      GlobalVariableSet(GV("closses"),  m_consec_losses);
     }

public:
                     CAxfCompoundingEngine(void) { Reset(); }

   void              Reset(void)
     {
      m_starting_equity=0; m_equity_high=0; m_equity_low=0; m_closed_trades=0;
      m_sum_r=0; m_sum_win_r=0; m_win_count=0; m_sum_loss_r=0; m_loss_count=0;
      m_consec_wins=0; m_consec_losses=0; m_gv_prefix="AXF15";
     }

   //--- called once at OnInit. Restores prior state if it exists (terminal
   //--- recovery), otherwise seeds from current equity.
   void              Init(const ulong magic,const double current_equity)
     {
      m_gv_prefix = "AXF15_" + IntegerToString((long)magic);
      if(GlobalVariableCheck(GV("start_eq")))
        {
         m_starting_equity = GlobalVariableGet(GV("start_eq"));
         m_equity_high     = GlobalVariableGet(GV("eq_high"));
         m_equity_low      = GlobalVariableGet(GV("eq_low"));
         m_closed_trades   = (int)GlobalVariableGet(GV("closed"));
         m_sum_r           = GlobalVariableGet(GV("sum_r"));
         m_sum_win_r       = GlobalVariableGet(GV("sum_win_r"));
         m_win_count       = (int)GlobalVariableGet(GV("win_cnt"));
         m_sum_loss_r      = GlobalVariableGet(GV("sum_loss_r"));
         m_loss_count      = (int)GlobalVariableGet(GV("loss_cnt"));
         m_consec_wins     = (int)GlobalVariableGet(GV("cwins"));
         m_consec_losses   = (int)GlobalVariableGet(GV("closses"));
        }
      else
        {
         m_starting_equity = current_equity;
         m_equity_high = current_equity;
         m_equity_low  = current_equity;
         SavePersisted();
        }
     }

   //--- called every tick with live equity, to track the running high/low
   //--- watermark used for drawdown calculations even between closed trades.
   void              UpdateEquityWatermark(const double equity)
     {
      if(equity>m_equity_high) m_equity_high=equity;
      if(m_equity_low<=0 || equity<m_equity_low) m_equity_low=equity;
      SavePersisted();
     }

   //--- record one closed trade's realised R-multiple and the risk % that
   //--- produced it. Equity(n+1) itself is simply the account's real equity —
   //--- we do not maintain a shadow equity number that could drift from reality.
   void              RecordClosedTrade(const double r_multiple)
     {
      m_closed_trades++;
      m_sum_r += r_multiple;
      if(r_multiple>0)
        {
         m_sum_win_r += r_multiple; m_win_count++;
         m_consec_wins++; m_consec_losses=0;
        }
      else
        {
         m_sum_loss_r += r_multiple; m_loss_count++;
         m_consec_losses++; m_consec_wins=0;
        }
      SavePersisted();
     }

   double            StartingEquity(void) const { return m_starting_equity; }
   double            EquityHigh(void)     const { return m_equity_high; }
   double            EquityLow(void)      const { return m_equity_low; }
   int               ClosedTrades(void)   const { return m_closed_trades; }
   int               ConsecWins(void)     const { return m_consec_wins; }
   int               ConsecLosses(void)   const { return m_consec_losses; }

   double            WinRate(void) const
     {
      return (m_closed_trades>0) ? (double)m_win_count/m_closed_trades : 0.0;
     }
   double            AvgWinR(void) const { return (m_win_count>0) ? m_sum_win_r/m_win_count : 0.0; }
   double            AvgLossR(void) const { return (m_loss_count>0) ? m_sum_loss_r/m_loss_count : 0.0; } // negative
   double            ExpectancyR(void) const { return (m_closed_trades>0) ? m_sum_r/m_closed_trades : 0.0; }

   double            DrawdownFromHighPct(const double equity) const
     {
      if(m_equity_high<=0) return 0.0;
      return (m_equity_high-equity)/m_equity_high*100.0;
     }

   double            GrowthFromStartPct(const double equity) const
     {
      if(m_starting_equity<=0) return 0.0;
      return (equity-m_starting_equity)/m_starting_equity*100.0;
     }
  };

#endif // AXF_COMPOUNDINGENGINE_MQH
