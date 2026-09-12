//+------------------------------------------------------------------+
//| Dashboard.mqh                                                          |
//| Section 45 (dashboard layout) + Section 31 (probability-of-ruin       |
//| readout). Pure presentation — builds and updates chart objects only,  |
//| computes nothing. Danger states (ELEVATED/DEFENSIVE/HALT, negative    |
//| expectancy) are rendered in red so they are impossible to miss.       |
//+------------------------------------------------------------------+
#ifndef AXF_DASHBOARD_MQH
#define AXF_DASHBOARD_MQH

#include "../Common/Defines.mqh"

struct SAxfDashboardData
  {
   string            symbol;
   double            price, spread_points;
   ENUM_AXF_VOLATILITY vol_class;
   ENUM_AXF_REGIME  regime;

   ENUM_AXF_DIRECTION htf_bias;
   string            structure_desc;
   string            liquidity_target_desc;
   string            setup_desc;

   double            flip_score;
   string            flip_grade;
   double            opportunity_magnitude_r;
   double            expected_r;
   double            expected_net_value_r;

   double            equity, drawdown_pct, base_risk_pct, current_risk_pct, portfolio_risk_pct;
   SAxfRuinEstimate  ruin;
   ENUM_AXF_GROWTH_MODE mode;

   double            execution_score;

   double            pos_entry, pos_sl, pos_tp1, pos_tp2, pos_final, pos_r, pos_mfe_r, pos_mae_r;
   long              pos_holding_seconds;
   bool              has_position;

   int               journal_count;
   double            expectancy_r, win_rate, avg_r;
   int               consec_streak; // positive = wins, negative = losses

   string            state_name;
   string            last_decision_reason;
  };

class CAxfDashboard
  {
private:
   string            m_prefix;
   int               m_x, m_y_start, m_line_h;

   void              Label(const string name,const string text,const int x,const int y,
                            const color clr,const int size=9)
     {
      string full = m_prefix+name;
      if(ObjectFind(0,full)<0)
        {
         ObjectCreate(0,full,OBJ_LABEL,0,0,0);
         ObjectSetInteger(0,full,OBJPROP_CORNER,CORNER_LEFT_UPPER);
         ObjectSetInteger(0,full,OBJPROP_XDISTANCE,x);
         ObjectSetInteger(0,full,OBJPROP_YDISTANCE,y);
         ObjectSetString(0,full,OBJPROP_FONT,"Consolas");
         ObjectSetInteger(0,full,OBJPROP_FONTSIZE,size);
         ObjectSetInteger(0,full,OBJPROP_SELECTABLE,false);
         ObjectSetInteger(0,full,OBJPROP_HIDDEN,true);
        }
      ObjectSetString(0,full,OBJPROP_TEXT,text);
      ObjectSetInteger(0,full,OBJPROP_COLOR,clr);
     }

   color             RuinColor(const ENUM_AXF_RUIN_STATE s)
     {
      switch(s)
        {
         case RUIN_LOW: return clrLimeGreen;
         case RUIN_NORMAL: return clrKhaki;
         case RUIN_ELEVATED: return clrOrange;
         case RUIN_DEFENSIVE: return clrOrangeRed;
         case RUIN_HALT: return clrRed;
         default: return clrWhite;
        }
     }

public:
                     CAxfDashboard(void) { m_x=10; m_y_start=20; m_line_h=15; }

   void              Init(const string unique_prefix)
     {
      m_prefix = unique_prefix+"_dash_";
     }

   void              Update(const SAxfDashboardData &d)
     {
      int y = m_y_start;
      color hdr = clrDodgerBlue;
      color normal = clrWhiteSmoke;
      color danger = clrRed;
      color ok = clrLimeGreen;

      Label("title", StringFormat("%s  v%s  [%s]",AXF_NAME,AXF_VERSION,d.state_name), m_x, y, clrGold, 10); y+=m_line_h+4;

      Label("mkt_hdr","-- MARKET --",m_x,y,hdr); y+=m_line_h;
      Label("mkt", StringFormat("%s  %.5f  spread:%.1fpt  vol:%s  regime:%s",
            d.symbol,d.price,d.spread_points,AxfVolToString(d.vol_class),AxfRegimeToString(d.regime)),
            m_x,y,normal); y+=m_line_h+4;

      Label("intel_hdr","-- INTELLIGENCE --",m_x,y,hdr); y+=m_line_h;
      Label("intel", StringFormat("HTF bias:%s | %s | Liquidity: %s",
            d.htf_bias==DIR_LONG?"LONG":(d.htf_bias==DIR_SHORT?"SHORT":"NONE"),
            d.structure_desc, d.liquidity_target_desc), m_x,y,normal); y+=m_line_h;
      Label("setup", "Setup: "+d.setup_desc, m_x,y,normal); y+=m_line_h+4;

      Label("flip_hdr","-- FLIP --",m_x,y,hdr); y+=m_line_h;
      color flip_clr = (d.flip_grade=="NO TRADE") ? clrGray : ((d.flip_grade=="ELITE"||d.flip_grade=="A+") ? ok : normal);
      Label("flip", StringFormat("Score:%.1f [%s]  Magnitude:%.2fR  E[R]:%.2f  NetEV:%.2fR",
            d.flip_score,d.flip_grade,d.opportunity_magnitude_r,d.expected_r,d.expected_net_value_r),
            m_x,y,flip_clr); y+=m_line_h+4;

      Label("risk_hdr","-- RISK --",m_x,y,hdr); y+=m_line_h;
      Label("risk1", StringFormat("Equity:%.2f  DD:%.2f%%  BaseRisk:%.2f%%  CurRisk:%.2f%%  PortfRisk:%.2f%%",
            d.equity,d.drawdown_pct,d.base_risk_pct,d.current_risk_pct,d.portfolio_risk_pct),
            m_x,y, (d.drawdown_pct>10)?danger:normal); y+=m_line_h;
      Label("risk2", StringFormat("[MODEL ESTIMATE] P(20%%DD):%.1f%%  P(50%%DD):%.1f%%  P(severe):%.1f%%  State:%s",
            d.ruin.p_dd20,d.ruin.p_dd50,d.ruin.p_near_total,AxfRuinStateToString(d.ruin.state)),
            m_x,y,RuinColor(d.ruin.state)); y+=m_line_h;
      Label("mode", "Operating Mode: "+AxfModeToString(d.mode), m_x,y,
            (d.mode==MODE_SURVIVAL)?danger:(d.mode==MODE_FLIP?clrCyan:normal)); y+=m_line_h+4;

      Label("exec_hdr","-- EXECUTION --",m_x,y,hdr); y+=m_line_h;
      Label("exec", StringFormat("Execution Score: %.0f/100",d.execution_score), m_x,y,
            (d.execution_score<40)?danger:normal); y+=m_line_h+4;

      Label("pos_hdr","-- POSITION --",m_x,y,hdr); y+=m_line_h;
      if(d.has_position)
         Label("pos", StringFormat("Entry:%.5f SL:%.5f TP1:%.5f TP2:%.5f Final:%.5f R:%.2f MFE:%.2fR MAE:%.2fR Held:%dm",
               d.pos_entry,d.pos_sl,d.pos_tp1,d.pos_tp2,d.pos_final,d.pos_r,d.pos_mfe_r,d.pos_mae_r,
               (int)(d.pos_holding_seconds/60)), m_x,y,normal);
      else
         Label("pos","(no open position)",m_x,y,clrGray);
      y+=m_line_h+4;

      Label("autopsy_hdr","-- AUTOPSY --",m_x,y,hdr); y+=m_line_h;
      Label("autopsy", StringFormat("Trades:%d  Expectancy:%.2fR  WinRate:%.1f%%  AvgR:%.2f  Streak:%d",
            d.journal_count,d.expectancy_r,d.win_rate*100.0,d.avg_r,d.consec_streak),
            m_x,y,(d.expectancy_r<0 && d.journal_count>=20)?danger:normal); y+=m_line_h;
      Label("decision","Last decision: "+d.last_decision_reason, m_x,y,clrSilver);

      ChartRedraw(0);
     }

   void              Remove(void)
     {
      ObjectsDeleteAll(0,m_prefix);
     }
  };

#endif // AXF_DASHBOARD_MQH
