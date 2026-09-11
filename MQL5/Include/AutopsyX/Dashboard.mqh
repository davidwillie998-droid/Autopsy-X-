//+------------------------------------------------------------------+
//|                                                    Dashboard.mqh |
//|  Compact on-chart dashboard + KILL ENGINE button (spec section 16)|
//|  Uses a handful of chart objects, updated on a timer - never on   |
//|  every tick - so it cannot interfere with execution speed.        |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_DASHBOARD_MQH
#define AX_DASHBOARD_MQH
#include "Defs.mqh"
#include "RiskEngine.mqh"
#include "Statistics.mqh"

#define AX_DASH_PREFIX "AX_FDX_"

//--- next-gen metrics bundled separately so Render() doesn't grow an unwieldy flat parameter list ---
struct SAxDashboardExtras
  {
   ENUM_AX_REGIME htfRegime;
   double         htfSlope;
   double         accuracy5s;
   double         accuracy30s;
   double         flipAccuracy;
   double         grossProfitFactor;
   double         adaptiveMultiplier;
   bool           partialTaken;
   bool           htfConfluenceEnabled;
  };

class CDashboard
  {
private:
   long              m_chartId;
   string            m_symbol;
   int               m_x, m_y, m_lineH, m_width;
   bool              m_created;

   void              MakeLabel(const string name,const int x,const int y,const string text,
                                const color clr,const int fontSize=9,const string font="Consolas")
     {
      string full = AX_DASH_PREFIX+name;
      if(ObjectFind(m_chartId,full)<0)
        {
         ObjectCreate(m_chartId,full,OBJ_LABEL,0,0,0);
         ObjectSetInteger(m_chartId,full,OBJPROP_CORNER,CORNER_LEFT_UPPER);
         ObjectSetInteger(m_chartId,full,OBJPROP_XDISTANCE,x);
         ObjectSetInteger(m_chartId,full,OBJPROP_YDISTANCE,y);
         ObjectSetInteger(m_chartId,full,OBJPROP_SELECTABLE,false);
         ObjectSetInteger(m_chartId,full,OBJPROP_HIDDEN,true);
         ObjectSetInteger(m_chartId,full,OBJPROP_BACK,false);
        }
      ObjectSetString(m_chartId,full,OBJPROP_TEXT,text);
      ObjectSetString(m_chartId,full,OBJPROP_FONT,font);
      ObjectSetInteger(m_chartId,full,OBJPROP_FONTSIZE,fontSize);
      ObjectSetInteger(m_chartId,full,OBJPROP_COLOR,clr);
     }

   void              MakeRect(const string name,const int x,const int y,const int w,const int h,const color bg)
     {
      string full = AX_DASH_PREFIX+name;
      if(ObjectFind(m_chartId,full)<0)
        {
         ObjectCreate(m_chartId,full,OBJ_RECTANGLE_LABEL,0,0,0);
         ObjectSetInteger(m_chartId,full,OBJPROP_CORNER,CORNER_LEFT_UPPER);
         ObjectSetInteger(m_chartId,full,OBJPROP_SELECTABLE,false);
         ObjectSetInteger(m_chartId,full,OBJPROP_BACK,false);
         ObjectSetInteger(m_chartId,full,OBJPROP_BORDER_TYPE,BORDER_FLAT);
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

public:
                     CDashboard(void) { m_chartId=0; m_created=false; m_x=10; m_y=20; m_lineH=15; m_width=230; }

   void              Init(const string symbol,const int x=10,const int y=20)
     {
      m_chartId = ChartID();
      m_symbol  = symbol;
      m_x=x; m_y=y;
      m_created=true;
     }

   //--- KILL ENGINE button, created once ---
   void              CreateKillButton(void)
     {
      string full = AX_DASH_PREFIX+"KILL_BTN";
      if(ObjectFind(m_chartId,full)<0)
        {
         ObjectCreate(m_chartId,full,OBJ_BUTTON,0,0,0);
         ObjectSetInteger(m_chartId,full,OBJPROP_CORNER,CORNER_LEFT_UPPER);
         ObjectSetInteger(m_chartId,full,OBJPROP_XDISTANCE,m_x);
         ObjectSetInteger(m_chartId,full,OBJPROP_YDISTANCE,m_y+615);
         ObjectSetInteger(m_chartId,full,OBJPROP_XSIZE,m_width);
         ObjectSetInteger(m_chartId,full,OBJPROP_YSIZE,26);
         ObjectSetString(m_chartId,full,OBJPROP_TEXT,"KILL ENGINE");
         ObjectSetInteger(m_chartId,full,OBJPROP_COLOR,clrWhite);
         ObjectSetInteger(m_chartId,full,OBJPROP_BGCOLOR,C'140,20,20');
         ObjectSetInteger(m_chartId,full,OBJPROP_BORDER_COLOR,clrBlack);
         ObjectSetInteger(m_chartId,full,OBJPROP_FONTSIZE,10);
         ObjectSetInteger(m_chartId,full,OBJPROP_SELECTABLE,false);
        }
     }

   bool              IsKillButtonClick(const string sparam) const
     {
      return(sparam==(AX_DASH_PREFIX+"KILL_BTN"));
     }

   void              ResetKillButtonState(void)
     {
      ObjectSetInteger(m_chartId,AX_DASH_PREFIX+"KILL_BTN",OBJPROP_STATE,false);
     }

   //--- full redraw; call on a timer (e.g. every 500ms-1s), never every tick ---
   void              Render(const ENUM_AX_MODE mode,const ENUM_AX_REGIME regime,const SAxScore &score,
                             const string tickVelocityLabel,const string momentumLabel,
                             const double spreadPts,const ENUM_AX_DIR positionDir,const double entryPrice,
                             const double currentPrice,const double floatingPnl,const int holdSeconds,
                             const int flipsToday,const int tradesToday,const SAxStatsSnapshot &stats,
                             const double dailyPnl,const double drawdownPct,const double riskPercent,
                             const ENUM_AX_ENGINE_STATE engineState,const ENUM_AX_GATE gate,
                             const SAxDashboardExtras &extras)
     {
      MakeRect("BG",m_x-6,m_y-6,m_width,680,C'12,12,14');

      int y=m_y; int x=m_x+4;
      MakeLabel("T1",x,y,"AUTOPSY X",clrGold,12); y+=18;
      MakeLabel("T2",x,y,"FLIPDEMON EXTREME",clrSilver,10); y+=20;

      string modeStr = (mode==AX_MODE_NORMAL)?"NORMAL":(mode==AX_MODE_AGGRESSIVE)?"AGGRESSIVE":"EXTREME";
      string stateStr = EngineStateLabel(engineState);
      color stateClr = (engineState==AX_ENGINE_KILLED)?clrRed:(engineState==AX_ENGINE_ATTACKING)?clrLime:clrSilver;

      MakeLabel("STATUS",x,y,"STATUS: "+stateStr,stateClr); y+=m_lineH;
      MakeLabel("MODE",x,y,"MODE: "+modeStr,clrWhite); y+=m_lineH;
      MakeLabel("SYMBOL",x,y,"SYMBOL: "+m_symbol,clrWhite); y+=m_lineH+4;

      MakeLabel("REGIME_L",x,y,"REGIME:",clrSilver); y+=m_lineH;
      MakeLabel("REGIME_V",x,y,AxRegimeToString(regime),clrAqua,10); y+=m_lineH+4;

      MakeLabel("BUY",x,y,StringFormat("BUY SCORE: %.0f",score.buyScore),ScoreColor(score.buyScore)); y+=m_lineH;
      MakeLabel("SELL",x,y,StringFormat("SELL SCORE: %.0f",score.sellScore),ScoreColor(score.sellScore)); y+=m_lineH;
      MakeLabel("CONF_L",x,y,"CONFIDENCE:",clrSilver); y+=m_lineH;
      MakeLabel("CONF_V",x,y,StringFormat("%.0f%%",score.confidence),ScoreColor(score.confidence),10); y+=m_lineH+4;

      MakeLabel("TVEL_L",x,y,"TICK VELOCITY:",clrSilver); y+=m_lineH;
      MakeLabel("TVEL_V",x,y,tickVelocityLabel,clrWhite); y+=m_lineH;
      MakeLabel("MOM_L",x,y,"MOMENTUM:",clrSilver); y+=m_lineH;
      MakeLabel("MOM_V",x,y,momentumLabel,clrWhite); y+=m_lineH;
      MakeLabel("SPREAD",x,y,StringFormat("SPREAD: %.1f",spreadPts),clrWhite); y+=m_lineH+4;

      string posStr = (positionDir==AX_DIR_NONE)?"FLAT":AxDirToString(positionDir);
      color posClr = (positionDir==AX_DIR_BUY)?clrLime:(positionDir==AX_DIR_SELL)?clrTomato:clrSilver;
      MakeLabel("POS",x,y,"POSITION: "+posStr,posClr); y+=m_lineH;
      if(positionDir!=AX_DIR_NONE)
        {
         MakeLabel("ENTRY",x,y,StringFormat("ENTRY: %s",DoubleToString(entryPrice,_Digits)),clrWhite); y+=m_lineH;
         MakeLabel("CURR",x,y,StringFormat("CURRENT: %s",DoubleToString(currentPrice,_Digits)),clrWhite); y+=m_lineH;
         color pnlClr = (floatingPnl>=0)?clrLime:clrTomato;
         MakeLabel("FPL",x,y,StringFormat("FLOATING P/L: %s$%.2f",(floatingPnl>=0?"+":"-"),MathAbs(floatingPnl)),pnlClr); y+=m_lineH;
         int mm=holdSeconds/60, ss=holdSeconds%60;
         MakeLabel("HOLD",x,y,StringFormat("HOLD: %02d:%02d",mm,ss),clrWhite); y+=m_lineH;
        }
      else
        {
         MakeLabel("ENTRY",x,y,"ENTRY: -",clrSilver); y+=m_lineH;
         MakeLabel("CURR",x,y,StringFormat("CURRENT: %s",DoubleToString(currentPrice,_Digits)),clrWhite); y+=m_lineH;
         MakeLabel("FPL",x,y,"FLOATING P/L: -",clrSilver); y+=m_lineH;
         MakeLabel("HOLD",x,y,"HOLD: -",clrSilver); y+=m_lineH;
        }
      y+=4;

      MakeLabel("FLIPS",x,y,StringFormat("FLIPS TODAY: %d",flipsToday),clrWhite); y+=m_lineH;
      MakeLabel("TRADES",x,y,StringFormat("TRADES TODAY: %d",tradesToday),clrWhite); y+=m_lineH;
      MakeLabel("WINRATE",x,y,StringFormat("WIN RATE: %.0f%%",stats.winRate),clrWhite); y+=m_lineH;
      MakeLabel("PF",x,y,StringFormat("PROFIT FACTOR: %.2f (gross %.2f)",stats.profitFactor,extras.grossProfitFactor),clrWhite); y+=m_lineH+4;

      color dailyClr = (dailyPnl>=0)?clrLime:clrTomato;
      MakeLabel("DPL",x,y,StringFormat("DAILY P/L: %s$%.2f",(dailyPnl>=0?"+":"-"),MathAbs(dailyPnl)),dailyClr); y+=m_lineH;
      MakeLabel("DD",x,y,StringFormat("DRAWDOWN: %.1f%%",drawdownPct),clrWhite); y+=m_lineH;
      MakeLabel("RISK",x,y,StringFormat("RISK: %.1f%%",riskPercent),clrWhite); y+=m_lineH;
      MakeLabel("GATE",x,y,"GATE: "+AxGateToString(gate),clrGold); y+=m_lineH+4;

      //--- next-generation metrics: HTF confluence, adaptive tuning, directional accuracy, scale-out ---
      string htfStr = extras.htfConfluenceEnabled ? (AxRegimeToString(extras.htfRegime)+StringFormat(" (slope %s)",extras.htfSlope>=0?"UP":"DOWN")) : "OFF";
      MakeLabel("HTF",x,y,"HTF BIAS: "+htfStr,clrAqua); y+=m_lineH;
      MakeLabel("ACC",x,y,StringFormat("ACCURACY 5S/30S: %.0f%% / %.0f%%",extras.accuracy5s,extras.accuracy30s),clrWhite); y+=m_lineH;
      MakeLabel("FLIPACC",x,y,StringFormat("FLIP ACCURACY: %.0f%%",extras.flipAccuracy),clrWhite); y+=m_lineH;
      MakeLabel("ADAPT",x,y,StringFormat("ADAPTIVE CONF x%.2f",extras.adaptiveMultiplier),clrWhite); y+=m_lineH;
      string partialStr = extras.partialTaken ? "TAKEN" : (positionDir!=AX_DIR_NONE ? "PENDING" : "-");
      MakeLabel("PARTIAL",x,y,"PARTIAL TP: "+partialStr,extras.partialTaken?clrLime:clrSilver); y+=m_lineH;

      color engClr = (engineState==AX_ENGINE_ATTACKING)?clrLime:(engineState==AX_ENGINE_KILLED)?clrRed:clrSilver;
      MakeLabel("ENGINE",x,y,"ENGINE: "+stateStr,engClr); y+=m_lineH;

      CreateKillButton();
      ChartRedraw(m_chartId);
     }

   string            EngineStateLabel(const ENUM_AX_ENGINE_STATE s) const
     {
      switch(s)
        {
         case AX_ENGINE_ACTIVE:     return("ACTIVE");
         case AX_ENGINE_ATTACKING:  return("ATTACKING");
         case AX_ENGINE_MANAGING:   return("MANAGING");
         case AX_ENGINE_COOLDOWN:   return("COOLDOWN");
         case AX_ENGINE_PAUSED:     return("PAUSED");
         case AX_ENGINE_KILLED:     return("KILLED");
        }
      return("UNKNOWN");
     }

   void              RemoveAll(void)
     {
      ObjectsDeleteAll(m_chartId,AX_DASH_PREFIX);
      ChartRedraw(m_chartId);
     }
  };
#endif // AX_DASHBOARD_MQH
//+------------------------------------------------------------------+
