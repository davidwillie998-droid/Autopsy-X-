//+------------------------------------------------------------------+
//|                                      InstitutionalDashboard.mqh|
//|  AUTOPSY X Dashboard v3 - institutional panels (spec section,       |
//|  Phase 10 of the institutional engine upgrade): ALPHA / LIQUIDITY /  |
//|  VOLATILITY / MICROSTRUCTURE / RISK / EXECUTION / FINAL DECISION.    |
//|  ENGINEERING DESIGN - the paper does not specify a dashboard.         |
//|                                                                    |
//|  DELIBERATELY A SEPARATE FILE/CLASS/OBJECT-PREFIX from                |
//|  Dashboard.mqh's existing CDashboard (spec section 16's original       |
//|  compact dashboard + KILL ENGINE button): that class's Render() has     |
//|  many CONDITIONAL sections (order flow/heatmap/sniper on or off,         |
//|  etc.), which is why its own header comment records a manually-           |
//|  audited pixel height constant for its background rectangle and kill      |
//|  button. Splicing new institutional panels into that function would        |
//|  require re-auditing that same fragile constant. This class instead         |
//|  renders a FIXED set of panels (every institutional engine's read is          |
//|  always shown, using this codebase's own "no data yet -> neutral,             |
//|  never fabricated" convention rather than hiding a panel conditionally),        |
//|  and sizes its own background rectangle DYNAMICALLY from the real content         |
//|  height on every call - see Render()'s own comment below for how, which           |
//|  is a strictly more robust pattern than a hand-maintained constant and              |
//|  is offered here as a genuine improvement, not a criticism of the original.          |
//|                                                                    |
//|  DELIBERATELY THIN, matching every other engine this phase: every value    |
//|  shown here is an ALREADY-COMPUTED read passed in via                       |
//|  SAxInstitutionalDashboardInputs - this class computes nothing, it only      |
//|  formats and draws.                                                            |
//|                                                                    |
//|  SIGNAL, NOT ACTION: this is a read-only display. It is not wired into the     |
//|  live OnTick loop as part of this build - see the file header comment on        |
//|  every other Phase 2-9 engine in this build for the same standing note.           |
//|                                                                    |
//|  CONFIGURATION INPUTS (spec: "no buried thresholds"): every threshold/          |
//|  weight this dashboard displays already lives behind a real Configure()          |
//|  call on its owning engine (DrawdownEngine, CrisisEngine, HiddenRiskDetector,      |
//|  TradePermissionMatrix, DynamicPositionSizing, CapacityCrowdingEngine, etc.)        |
//|  - none of them are hardcoded inside those engines either (see each file's           |
//|  own Configure() method). Wiring those into real EA `input` parameters is a           |
//|  live-integration step deliberately deferred along with the rest of this               |
//|  phase's OnTick wiring (see standing note above) - the ready-to-wire surface             |
//|  already exists on every engine's Configure() signature.                                  |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_INSTITUTIONALDASHBOARD_MQH
#define AX_INSTITUTIONALDASHBOARD_MQH
#include "Defs.mqh"
#include "TradePermissionMatrix.mqh"
#include "DynamicPositionSizing.mqh"

#define AX_INST_DASH_PREFIX "AX_INSTDASH_"

//--- every field is an ALREADY-COMPUTED read from another engine - see file header. Strings default   ---
//--- to "" / scores to 0 / bools to false when a caller hasn't wired a given engine's output yet -     ---
//--- Render() below shows those as an honest "n/a"-style neutral read, never a fabricated value. ---
struct SAxInstitutionalDashboardInputs
  {
   //--- ALPHA ---
   double   alphaScore;
   string   alphaBreakdown;

   //--- LIQUIDITY ---
   double   liquidityScore;
   string   liquidityBreakdown;

   //--- VOLATILITY ---
   ENUM_AX_VOLATILITY_STATE volatilityState;
   double   volatilityAtr;
   double   volatilityPercentileRank;

   //--- MICROSTRUCTURE ---
   double   signalPressure;       // -100..+100
   string   signalPressureLabel;
   double   priceImpactScore;

   //--- RISK ---
   ENUM_AX_DRAWDOWN_STATE drawdownState;
   string   drawdownReason;
   ENUM_AX_CRISIS_LEVEL   crisisLevel;
   string   crisisReason;
   double   hiddenRiskScore;
   string   hiddenRiskLabel;

   //--- EXECUTION ---
   double   executionCostScore;
   bool     executionEligible;
   double   capacityScore;
   double   crowdingProxyScore;

   //--- FINAL DECISION ---
   //--- hasVerdict MUST be explicitly set true by the caller once a real CTradePermissionMatrix::       ---
   //--- Update() result has actually been routed into permissionVerdict - a default-constructed struct   ---
   //--- zero-initializes permissionVerdict.decision to AX_DECISION_TRADE (Defs.mqh: AX_DECISION_TRADE=0), ---
   //--- the single most dangerous possible unintended default, unlike every other enum embedded in this   ---
   //--- struct whose 0 value happens to be its safe/neutral member. Render() below refuses to trust         ---
   //--- permissionVerdict at all unless this is true (code-review finding). ---
   bool     hasVerdict;
   SAxPermissionVerdict permissionVerdict;
   SAxSizingResult       sizingResult;
  };

class CInstitutionalDashboard
  {
private:
   long     m_chartId;
   int      m_x, m_y, m_lineH, m_width;

   void              MakeLabel(const string name,const int x,const int y,const string text,
                                const color clr,const int fontSize=9,const string font="Consolas")
     {
      string full=AX_INST_DASH_PREFIX+name;
      if(ObjectFind(m_chartId,full)<0)
        {
         ObjectCreate(m_chartId,full,OBJ_LABEL,0,0,0);
         ObjectSetInteger(m_chartId,full,OBJPROP_CORNER,CORNER_LEFT_UPPER);
         ObjectSetInteger(m_chartId,full,OBJPROP_SELECTABLE,false);
         ObjectSetInteger(m_chartId,full,OBJPROP_HIDDEN,true);
         ObjectSetInteger(m_chartId,full,OBJPROP_BACK,false);
        }
      ObjectSetInteger(m_chartId,full,OBJPROP_XDISTANCE,x);
      ObjectSetInteger(m_chartId,full,OBJPROP_YDISTANCE,y);
      ObjectSetString(m_chartId,full,OBJPROP_TEXT,text);
      ObjectSetString(m_chartId,full,OBJPROP_FONT,font);
      ObjectSetInteger(m_chartId,full,OBJPROP_FONTSIZE,fontSize);
      ObjectSetInteger(m_chartId,full,OBJPROP_COLOR,clr);
     }

   //--- OBJPROP_BACK=true, unlike Dashboard.mqh's own MakeRect - a true background object always      ---
   //--- renders behind every foreground object regardless of creation order, so this rectangle can be   ---
   //--- safely created/resized AFTER the labels (once the real content height is known) without ever     ---
   //--- needing a hand-maintained height constant. See file header. ---
   void              MakeBackgroundRect(const string name,const int x,const int y,const int w,const int h,
                                         const color bg)
     {
      string full=AX_INST_DASH_PREFIX+name;
      if(ObjectFind(m_chartId,full)<0)
        {
         ObjectCreate(m_chartId,full,OBJ_RECTANGLE_LABEL,0,0,0);
         ObjectSetInteger(m_chartId,full,OBJPROP_CORNER,CORNER_LEFT_UPPER);
         ObjectSetInteger(m_chartId,full,OBJPROP_SELECTABLE,false);
         ObjectSetInteger(m_chartId,full,OBJPROP_BORDER_TYPE,BORDER_FLAT);
         ObjectSetInteger(m_chartId,full,OBJPROP_BACK,true);
        }
      ObjectSetInteger(m_chartId,full,OBJPROP_XDISTANCE,x);
      ObjectSetInteger(m_chartId,full,OBJPROP_YDISTANCE,y);
      ObjectSetInteger(m_chartId,full,OBJPROP_XSIZE,w);
      ObjectSetInteger(m_chartId,full,OBJPROP_YSIZE,h);
      ObjectSetInteger(m_chartId,full,OBJPROP_BGCOLOR,bg);
      ObjectSetInteger(m_chartId,full,OBJPROP_COLOR,C'40,40,44');
     }

   color             ScoreColor(const double v) const
     {
      if(v>=70) return(clrLime);
      if(v>=45) return(clrKhaki);
      return(clrTomato);
     }

   color             DecisionColor(const ENUM_AX_FINAL_DECISION d) const
     {
      switch(d)
        {
         case AX_DECISION_TRADE:       return(clrLime);
         case AX_DECISION_REDUCE_RISK: return(clrKhaki);
         case AX_DECISION_WAIT:        return(clrSilver);
         case AX_DECISION_NO_TRADE:    return(clrOrange);
         case AX_DECISION_HALT:        return(clrRed);
         default:                       return(clrSilver);
        }
     }

public:
                     CInstitutionalDashboard(void)
     { m_chartId=0; m_x=260; m_y=20; m_lineH=15; m_width=260; }

   //--- x defaults to 260 - to the right of Dashboard.mqh's own default 230px-wide panel plus a gap,   ---
   //--- so the two dashboards never overlap when both are used together. Caller can override either. ---
   void              Init(const int x=260,const int y=20)
     {
      m_chartId=ChartID();
      m_x=x; m_y=y;
     }

   //--- full redraw; call on a timer (e.g. every 500ms-1s), never every tick - same convention as     ---
   //--- Dashboard.mqh's own Render(). ---
   void              Render(const SAxInstitutionalDashboardInputs &in)
     {
      int y=m_y; int x=m_x+4;

      MakeLabel("T1",x,y,"AUTOPSY X - INSTITUTIONAL",clrGold,12); y+=18;
      MakeLabel("T2",x,y,"LIQUIDITY-ADJUSTED ALPHA ENGINE",clrSilver,9); y+=20;

      //--- ALPHA ---
      MakeLabel("SEC_ALPHA",x,y,"--- ALPHA ---",clrGray,8); y+=m_lineH;
      MakeLabel("ALPHA_SCORE",x,y,StringFormat("ALPHA SCORE: %.1f",in.alphaScore),
                ScoreColor(in.alphaScore),10); y+=m_lineH;
      MakeLabel("ALPHA_BD",x,y,in.alphaBreakdown,clrSilver,8); y+=m_lineH+4;

      //--- LIQUIDITY ---
      MakeLabel("SEC_LIQ",x,y,"--- LIQUIDITY ---",clrGray,8); y+=m_lineH;
      MakeLabel("LIQ_SCORE",x,y,StringFormat("LIQUIDITY SCORE: %.1f",in.liquidityScore),
                ScoreColor(in.liquidityScore),10); y+=m_lineH;
      MakeLabel("LIQ_BD",x,y,in.liquidityBreakdown,clrSilver,8); y+=m_lineH+4;

      //--- VOLATILITY ---
      MakeLabel("SEC_VOL",x,y,"--- VOLATILITY ---",clrGray,8); y+=m_lineH;
      color volClr=(in.volatilityState==AX_VOL_SHOCK||in.volatilityState==AX_VOL_EXTREME)?clrTomato:
                    (in.volatilityState==AX_VOL_HIGH)?clrKhaki:clrLime;
      MakeLabel("VOL_STATE",x,y,"REGIME: "+AxVolatilityStateToString(in.volatilityState),volClr,10); y+=m_lineH;
      MakeLabel("VOL_DETAIL",x,y,StringFormat("ATR: %.5f  PCTRANK: %.0f%%",in.volatilityAtr,in.volatilityPercentileRank),
                clrSilver,8); y+=m_lineH+4;

      //--- MICROSTRUCTURE ---
      MakeLabel("SEC_MICRO",x,y,"--- MICROSTRUCTURE ---",clrGray,8); y+=m_lineH;
      color pressureClr=(in.signalPressureLabel=="BUY_PRESSURE")?clrLime:
                          (in.signalPressureLabel=="SELL_PRESSURE")?clrTomato:clrSilver;
      MakeLabel("MICRO_PRESSURE",x,y,StringFormat("SIGNAL PRESSURE: %.0f (%s)",in.signalPressure,in.signalPressureLabel),
                pressureClr,10); y+=m_lineH;
      MakeLabel("MICRO_IMPACT",x,y,StringFormat("PRICE IMPACT SCORE: %.1f",in.priceImpactScore),
                ScoreColor(in.priceImpactScore),9); y+=m_lineH+4;

      //--- RISK ---
      MakeLabel("SEC_RISK",x,y,"--- RISK ---",clrGray,8); y+=m_lineH;
      color ddClr=(in.drawdownState==AX_DD_STATE_HALT||in.drawdownState==AX_DD_STATE_SEVERE)?clrTomato:
                   (in.drawdownState==AX_DD_STATE_DEFENSIVE||in.drawdownState==AX_DD_STATE_CAUTION)?clrKhaki:clrLime;
      MakeLabel("RISK_DD",x,y,"DRAWDOWN: "+AxDrawdownStateToString(in.drawdownState),ddClr,10); y+=m_lineH;
      color crisisClr=(in.crisisLevel==AX_CRISIS_BLACK_SWAN||in.crisisLevel==AX_CRISIS_CRISIS)?clrTomato:
                        (in.crisisLevel==AX_CRISIS_ELEVATED)?clrKhaki:clrLime;
      MakeLabel("RISK_CRISIS",x,y,"CRISIS: "+AxCrisisLevelToString(in.crisisLevel),crisisClr,10); y+=m_lineH;
      MakeLabel("RISK_HIDDEN",x,y,StringFormat("HIDDEN RISK: %.1f (%s)",in.hiddenRiskScore,in.hiddenRiskLabel),
                ScoreColor(100.0-in.hiddenRiskScore),9); y+=m_lineH+4;

      //--- EXECUTION ---
      MakeLabel("SEC_EXEC",x,y,"--- EXECUTION ---",clrGray,8); y+=m_lineH;
      MakeLabel("EXEC_COST",x,y,StringFormat("EXEC COST SCORE: %.1f   ELIGIBLE: %s",
                in.executionCostScore,in.executionEligible?"YES":"NO"),
                in.executionEligible?clrLime:clrTomato,9); y+=m_lineH;
      MakeLabel("EXEC_CAP",x,y,StringFormat("CAPACITY: %.1f   CROWDING: %.1f",in.capacityScore,in.crowdingProxyScore),
                clrSilver,9); y+=m_lineH+4;

      //--- FINAL DECISION ---
      MakeLabel("SEC_FINAL",x,y,"--- FINAL DECISION ---",clrGray,8); y+=m_lineH;
      if(!in.hasVerdict)
        {
         //--- never trust a zero-initialized permissionVerdict - see struct comment (code-review        ---
         //--- finding: value 0 of ENUM_AX_FINAL_DECISION is AX_DECISION_TRADE, not a neutral state) ---
         MakeLabel("FINAL_DECISION",x,y,"DECISION: NO DATA YET",clrSilver,12); y+=m_lineH+2;
         MakeLabel("FINAL_GATES",x,y,"GATES FAILED: n/a",clrSilver,9); y+=m_lineH;
         MakeLabel("FINAL_SIZE",x,y,"RISK: n/a",clrSilver,9); y+=m_lineH+8;
        }
      else
        {
         MakeLabel("FINAL_DECISION",x,y,"DECISION: "+AxFinalDecisionToString(in.permissionVerdict.decision),
                   DecisionColor(in.permissionVerdict.decision),12); y+=m_lineH+2;
         MakeLabel("FINAL_GATES",x,y,StringFormat("GATES FAILED: %d hard / %d soft",
                   in.permissionVerdict.hardGatesFailed,in.permissionVerdict.softGatesFailed),clrSilver,9); y+=m_lineH;
         MakeLabel("FINAL_SIZE",x,y,StringFormat("RISK: %.2f%% -> %.2f%% (x%.2f)",
                   in.sizingResult.baseRiskPercent,in.sizingResult.finalRiskPercent,in.sizingResult.totalMultiplier),
                   clrWhite,9); y+=m_lineH+8;
        }

      //--- background sized from the REAL final y - see file header on why this is safe to do after   ---
      //--- drawing every label above, unlike Dashboard.mqh's own pre-sized rectangle. ---
      int contentHeight = (y-m_y)+6;
      MakeBackgroundRect("BG",m_x-6,m_y-6,m_width,contentHeight,C'10,10,14');

      //--- matches Dashboard.mqh's own Render()/RemoveAll() convention - without this, a timer-driven  ---
      //--- object update/delete is not guaranteed an immediate visual repaint (code-review finding). ---
      ChartRedraw(m_chartId);
     }

   void              Deinit(void)
     {
      ObjectsDeleteAll(m_chartId,AX_INST_DASH_PREFIX);
      ChartRedraw(m_chartId);
     }
  };
//+------------------------------------------------------------------+
#endif // AX_INSTITUTIONALDASHBOARD_MQH
