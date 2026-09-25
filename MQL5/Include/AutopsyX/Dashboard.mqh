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
   bool           isLiveAccount;
   double         avgSlippagePts;
   double         avgLatencyMs;
   int            poorFillsToday;
   int            consecutivePoorFills;
   bool           sniperEnabled;
   bool           sniperArmed;
   bool           sniperPullbackSeen;
   int            sniperSecondsWaiting;

   //--- order flow / volume profile / footprint / pulse / heatmap ---
   bool           orderFlowEnabled;
   double         sessionCvd;
   double         orderFlowImbalance;    // -1..+1
   bool           bullAbsorption;
   bool           bearAbsorption;
   bool           volProfileValid;
   int            volProfilePosition;    // +1 above VAH, -1 below VAL, 0 inside
   int            footprintStackedDir;   // +1/-1/0, last completed bar
   double         pulseValue;            // 0..100
   int            pulseDirection;        // +1/-1/0
   string         pulseLabel;
   bool           heatmapEnabled;
   bool           heatmapAvailable;
   double         heatmapBuyPressure;    // 0..100
   double         heatmapSellPressure;   // 0..100

   //--- Adaptive Flip Engine ---
   bool           afeEnabled;
   ENUM_AX_CAPITAL_STATE afeState;
   double         afeDrawdownFromPeakPct;
   double         afeRiskOfRuinPct;
   double         afeExpectedValueR;
   double         afeCostR;               // cost component already subtracted out of afeExpectedValueR
   double         afeWinProbability;      // 0..1
   double         afeAccountHealth;       // 0..100
   double         afeRiskMultiplier;      // 0..1, last applied

   //--- order-book impact-cost sizing ---
   bool           impactCostEnabled;
   double         impactCostPct;          // last measured, for the originally-intended size

   //--- VWAP Trend Engine ---
   string         vwapTrend;              // "BULLISH"/"BEARISH"/"NEUTRAL"
   double         vwapValue;              // -1 when unavailable
   bool           vwapExitEnabled;        // the raw InpUseVWAPExit toggle - whether the feature is ON
                                            // at all, NOT whether it will fire for the CURRENT position
   bool           vwapExitArmedForPosition; // true only when the OPEN position's own
                                              // g_posState.vwapAlignedAtEntry is true - CExitEngine
                                              // gates its entire VWAP exit branch on this per-position
                                              // flag (ExitEngine.mqh), not on the raw toggle above, so
                                              // this is what the dashboard's "[EXIT ARMED]" tag must
                                              // reflect (code-review finding: it previously read the
                                              // toggle alone and could claim ARMED for a position VWAP
                                              // was NEUTRAL/disagreeing for at entry, which never fires).

   //--- FLIPDEMON EXTREME upgrade: execution mode + emergency controls (spec sections 37/38) - ---
   //--- these ARE live-wired (CEmergencyControls is instantiated and checked every entry attempt) ---
   ENUM_AX_EXECUTION_MODE executionMode;
   bool           enableTrading;
   bool           enableLong;
   bool           enableShort;
   bool           emergencyStopActive;
   string         emergencyStopReason;

   //--- weekly risk (spec section 18) - ALSO live-wired (CRiskEngine.Configure/OnTickHousekeeping) ---
   double         weeklyPnl;
   double         weeklyPnlPercent;
   bool           weeklyLockout;
   double         marginUsagePercent;

   //--- structure/composite-direction/eligibility/lifecycle engines built this rewrite but NOT yet  ---
   //--- integrated into the live tick loop (Phases 2-6) - shown honestly as pending rather than      ---
   //--- fabricating a placeholder reading for each. See the Phase 10 engineering report for the full ---
   //--- list of what still needs main-EA wiring. ---
   bool           extendedEnginesIntegrated; // flips true once composite direction/structure/
                                               // eligibility/lifecycle are actually wired into OnTick
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
         // code-review manually traced every y+= in Render() (including continuation lines a naive
         // regex-based estimate missed) and found the true worst-case content end (InpUseOrderFlow
         // AND InpUseHeatmap both on, the longest render path) is m_y+1002 - this offset leaves a
         // real ~74px margin below that, not the smaller margin an earlier estimate implied.
         ObjectSetInteger(m_chartId,full,OBJPROP_YDISTANCE,m_y+1076);
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
      MakeRect("BG",m_x-6,m_y-6,m_width,1076+26+20,C'12,12,14'); // kill-button offset + its own
                                                                    // height (26) + bottom margin (20)

      int y=m_y; int x=m_x+4;
      MakeLabel("T1",x,y,"AUTOPSY X",clrGold,12); y+=18;
      MakeLabel("T2",x,y,"FLIPDEMON EXTREME",clrSilver,10); y+=20;

      //--- ACCOUNT section (spec section 36) ---
      MakeLabel("SEC_ACCOUNT",x,y,"--- ACCOUNT ---",clrGray,8); y+=m_lineH;
      MakeLabel("ACCT",x,y,extras.isLiveAccount?"● LIVE ACCOUNT":"○ DEMO ACCOUNT",
                extras.isLiveAccount?clrTomato:clrSilver,10); y+=m_lineH+4;

      string modeStr = (mode==AX_MODE_NORMAL)?"NORMAL":(mode==AX_MODE_AGGRESSIVE)?"AGGRESSIVE":"EXTREME";
      string stateStr = EngineStateLabel(engineState);
      color stateClr = (engineState==AX_ENGINE_KILLED)?clrRed:(engineState==AX_ENGINE_ATTACKING)?clrLime:clrSilver;

      MakeLabel("STATUS",x,y,"STATUS: "+stateStr,stateClr); y+=m_lineH;
      MakeLabel("MODE",x,y,"MODE: "+modeStr,clrWhite); y+=m_lineH;
      MakeLabel("SYMBOL",x,y,"SYMBOL: "+m_symbol,clrWhite); y+=m_lineH+4;

      //--- MARKET section ---
      MakeLabel("SEC_MARKET",x,y,"--- MARKET ---",clrGray,8); y+=m_lineH;
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

      //--- SIGNALS / DECISION / POSITION section ---
      MakeLabel("SEC_POSITION",x,y,"--- SIGNALS / DECISION / POSITION ---",clrGray,8); y+=m_lineH;
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

      //--- STATISTICS section ---
      MakeLabel("SEC_STATS",x,y,"--- STATISTICS ---",clrGray,8); y+=m_lineH;
      MakeLabel("FLIPS",x,y,StringFormat("FLIPS TODAY: %d",flipsToday),clrWhite); y+=m_lineH;
      MakeLabel("TRADES",x,y,StringFormat("TRADES TODAY: %d",tradesToday),clrWhite); y+=m_lineH;
      MakeLabel("WINRATE",x,y,StringFormat("WIN RATE: %.0f%%",stats.winRate),clrWhite); y+=m_lineH;
      MakeLabel("PF",x,y,StringFormat("PROFIT FACTOR: %.2f (gross %.2f)",stats.profitFactor,extras.grossProfitFactor),clrWhite); y+=m_lineH+4;

      //--- RISK section ---
      MakeLabel("SEC_RISK",x,y,"--- RISK ---",clrGray,8); y+=m_lineH;
      color dailyClr = (dailyPnl>=0)?clrLime:clrTomato;
      MakeLabel("DPL",x,y,StringFormat("DAILY P/L: %s$%.2f",(dailyPnl>=0?"+":"-"),MathAbs(dailyPnl)),dailyClr); y+=m_lineH;
      color weeklyClr = (extras.weeklyPnl>=0)?clrLime:clrTomato;
      string weeklyLockStr = extras.weeklyLockout ? " [LOCKED OUT]" : "";
      MakeLabel("WPL",x,y,StringFormat("WEEKLY P/L: %s$%.2f (%.1f%%)%s",
                (extras.weeklyPnl>=0?"+":"-"),MathAbs(extras.weeklyPnl),extras.weeklyPnlPercent,weeklyLockStr),
                extras.weeklyLockout?clrRed:weeklyClr); y+=m_lineH;
      MakeLabel("DD",x,y,StringFormat("DRAWDOWN: %.1f%%",drawdownPct),clrWhite); y+=m_lineH;
      MakeLabel("RISK",x,y,StringFormat("RISK: %.1f%%   MARGIN USED: %.1f%%",riskPercent,extras.marginUsagePercent),clrWhite); y+=m_lineH;
      MakeLabel("GATE",x,y,"GATE: "+AxGateToString(gate),clrGold); y+=m_lineH+4;

      //--- EXECUTION MODE + EMERGENCY CONTROLS section (spec sections 37/38) ---
      MakeLabel("SEC_EXEC",x,y,"--- EXECUTION / EMERGENCY ---",clrGray,8); y+=m_lineH;
      color execModeClr = (extras.executionMode==AX_EXEC_LIVE) ? clrTomato :
                           (extras.executionMode==AX_EXEC_PAPER) ? clrGold : clrSilver;
      MakeLabel("EXECMODE",x,y,"MODE: "+AxExecutionModeToString(extras.executionMode),execModeClr); y+=m_lineH;
      string enableStr = StringFormat("TRADING:%s LONG:%s SHORT:%s",
                          extras.enableTrading?"ON":"OFF",extras.enableLong?"ON":"OFF",extras.enableShort?"ON":"OFF");
      MakeLabel("ENABLES",x,y,enableStr,(extras.enableTrading&&extras.enableLong&&extras.enableShort)?clrWhite:clrGold); y+=m_lineH;
      string emStr = extras.emergencyStopActive ? ("ACTIVE: "+extras.emergencyStopReason) : "clear";
      MakeLabel("ESTOP",x,y,"EMERGENCY STOP: "+emStr,extras.emergencyStopActive?clrRed:clrSilver); y+=m_lineH+4;

      //--- SYSTEM section ---
      MakeLabel("SEC_SYSTEM",x,y,"--- SYSTEM ---",clrGray,8); y+=m_lineH;
      MakeLabel("EXTENDED",x,y,extras.extendedEnginesIntegrated ?
                "EXTENDED ENGINES: integrated" : "EXTENDED ENGINES: built, pending integration (see report)",
                extras.extendedEnginesIntegrated?clrLime:clrGold); y+=m_lineH+4;

      //--- next-generation metrics: HTF confluence, adaptive tuning, directional accuracy, scale-out ---
      string htfStr = extras.htfConfluenceEnabled ? (AxRegimeToString(extras.htfRegime)+StringFormat(" (slope %s)",extras.htfSlope>=0?"UP":"DOWN")) : "OFF";
      MakeLabel("HTF",x,y,"HTF BIAS: "+htfStr,clrAqua); y+=m_lineH;
      MakeLabel("ACC",x,y,StringFormat("ACCURACY 5S/30S: %.0f%% / %.0f%%",extras.accuracy5s,extras.accuracy30s),clrWhite); y+=m_lineH;
      MakeLabel("FLIPACC",x,y,StringFormat("FLIP ACCURACY: %.0f%%",extras.flipAccuracy),clrWhite); y+=m_lineH;
      MakeLabel("ADAPT",x,y,StringFormat("ADAPTIVE CONF x%.2f",extras.adaptiveMultiplier),clrWhite); y+=m_lineH;
      string partialStr = extras.partialTaken ? "TAKEN" : (positionDir!=AX_DIR_NONE ? "PENDING" : "-");
      MakeLabel("PARTIAL",x,y,"PARTIAL TP: "+partialStr,extras.partialTaken?clrLime:clrSilver); y+=m_lineH+4;

      //--- live execution quality: what the account is actually experiencing, not a demo feed's ---
      color execClr = (extras.consecutivePoorFills>0)?clrTomato:clrWhite;
      MakeLabel("EXECQ",x,y,StringFormat("AVG SLIP/LAT: %.1fpts / %.0fms",extras.avgSlippagePts,extras.avgLatencyMs),execClr); y+=m_lineH;
      MakeLabel("POORFILL",x,y,StringFormat("POOR FILLS: %d today (streak %d)",extras.poorFillsToday,extras.consecutivePoorFills),execClr); y+=m_lineH+4;

      //--- sniper entry timing: OFF when disabled, otherwise ARMED/waiting-for-pullback/-resume ---
      string sniperStr;
      color sniperClr;
      if(!extras.sniperEnabled) { sniperStr="OFF"; sniperClr=clrSilver; }
      else if(!extras.sniperArmed) { sniperStr="IDLE"; sniperClr=clrSilver; }
      else if(extras.sniperPullbackSeen) { sniperStr=StringFormat("ARMED - awaiting resume (%ds)",extras.sniperSecondsWaiting); sniperClr=clrGold; }
      else { sniperStr=StringFormat("ARMED - awaiting pullback (%ds)",extras.sniperSecondsWaiting); sniperClr=clrAqua; }
      MakeLabel("SNIPER",x,y,"SNIPER: "+sniperStr,sniperClr); y+=m_lineH+4;

      //--- order flow / volume profile / footprint / pulse / heatmap ---
      if(extras.orderFlowEnabled)
        {
         color cvdClr = (extras.sessionCvd>=0) ? clrLime : clrTomato;
         MakeLabel("CVD",x,y,StringFormat("CVD: %s%.0f  IMB: %+.0f%%",
                   extras.sessionCvd>=0?"+":"",extras.sessionCvd,extras.orderFlowImbalance*100.0),cvdClr); y+=m_lineH;

         string absorbStr = extras.bullAbsorption?"BULLISH":(extras.bearAbsorption?"BEARISH":"-");
         color absorbClr  = extras.bullAbsorption?clrLime:(extras.bearAbsorption?clrTomato:clrSilver);
         MakeLabel("ABSORB",x,y,"ABSORPTION: "+absorbStr,absorbClr); y+=m_lineH;

         string vpStr = !extras.volProfileValid ? "N/A" :
                        (extras.volProfilePosition>0 ? "ABOVE VALUE AREA" :
                         (extras.volProfilePosition<0 ? "BELOW VALUE AREA" : "INSIDE VALUE AREA"));
         MakeLabel("VP",x,y,"VOL PROFILE: "+vpStr,clrAqua); y+=m_lineH;

         string fpStr = (extras.footprintStackedDir>0) ? "STACKED BUY" :
                        (extras.footprintStackedDir<0 ? "STACKED SELL" : "-");
         color fpClr  = (extras.footprintStackedDir>0) ? clrLime : (extras.footprintStackedDir<0 ? clrTomato : clrSilver);
         MakeLabel("FOOTPRINT",x,y,"FOOTPRINT: "+fpStr,fpClr); y+=m_lineH;

         string pulseDirStr = (extras.pulseDirection>0)?"UP":(extras.pulseDirection<0?"DOWN":"FLAT");
         color pulseClr = (extras.pulseValue>=55)?clrGold:clrWhite;
         MakeLabel("PULSE",x,y,StringFormat("PULSE: %.0f %s (%s)",extras.pulseValue,extras.pulseLabel,pulseDirStr),pulseClr); y+=m_lineH;

         if(extras.heatmapEnabled)
           {
            string hmStr = !extras.heatmapAvailable ? "N/A (no broker depth)" :
                           StringFormat("BUY %.0f%% / SELL %.0f%%",extras.heatmapBuyPressure,extras.heatmapSellPressure);
            // impact-cost sizing rides on the same line rather than claiming its own row - it only
            // ever produces a reading when the heatmap itself is available, so they share a fate
            if(extras.impactCostEnabled && extras.heatmapAvailable)
               hmStr += StringFormat("   IMPACT: %.3f%%",extras.impactCostPct);
            MakeLabel("HEATMAP",x,y,"HEATMAP: "+hmStr,extras.heatmapAvailable?clrWhite:clrSilver); y+=m_lineH;
           }
         y+=4;
        }

      //--- Adaptive Flip Engine - always rendered (matches the SNIPER section's pattern) so the ---
      //--- panel's reserved height/kill-button offset never goes stale when the toggle changes ---
      if(!extras.afeEnabled)
        {
         MakeLabel("AFE_STATE",x,y,"AFE: OFF",clrSilver); y+=m_lineH;
         MakeLabel("AFE_ROR",x,y,"",clrSilver); y+=m_lineH;
         MakeLabel("AFE_PROB",x,y,"",clrSilver); y+=m_lineH;
         MakeLabel("AFE_MULT",x,y,"",clrSilver); y+=m_lineH+4;
        }
      else
        {
         color stateClr2 = (extras.afeState==AX_CAPITAL_LOCKED) ? clrRed :
                            (extras.afeState==AX_CAPITAL_DEFENSIVE) ? clrOrange :
                            (extras.afeState==AX_CAPITAL_CAUTION) ? clrGold : clrLime;
         MakeLabel("AFE_STATE",x,y,StringFormat("AFE: %s (%.1f%% off peak)",
                   AxCapitalStateToString(extras.afeState),extras.afeDrawdownFromPeakPct),stateClr2); y+=m_lineH;

         color rorClr = (extras.afeRiskOfRuinPct>=10.0) ? clrTomato : clrWhite;
         MakeLabel("AFE_ROR",x,y,StringFormat("RISK OF RUIN: %.1f%%   EV: %.2fR (cost %.2fR)",
                   extras.afeRiskOfRuinPct,extras.afeExpectedValueR,extras.afeCostR),rorClr); y+=m_lineH;

         MakeLabel("AFE_PROB",x,y,StringFormat("WIN PROB: %.0f%%   HEALTH: %.0f",
                   extras.afeWinProbability*100.0,extras.afeAccountHealth),clrWhite); y+=m_lineH;

         color multClr = (extras.afeRiskMultiplier<1.0) ? clrGold : clrSilver;
         MakeLabel("AFE_MULT",x,y,StringFormat("RISK MULTIPLIER: x%.2f",extras.afeRiskMultiplier),multClr); y+=m_lineH+4;
        }

      //--- VWAP Trend Engine - one line, always rendered so the panel height/kill-button offset ---
      //--- never goes stale (same reasoning as the AFE/SNIPER sections above) ---
      string vwapStr = (extras.vwapValue<=0) ? "N/A" :
                        StringFormat("%s @ %s",extras.vwapTrend,DoubleToString(extras.vwapValue,_Digits));
      //--- the per-position armed flag, not the raw feature toggle - see struct field comment above ---
      if(extras.vwapExitArmedForPosition) vwapStr += " [EXIT ARMED]";
      else if(extras.vwapExitEnabled)     vwapStr += " [EXIT: not armed this trade]";
      color vwapClr = (extras.vwapTrend=="BULLISH") ? clrLime :
                       (extras.vwapTrend=="BEARISH") ? clrTomato : clrSilver;
      MakeLabel("VWAP",x,y,"VWAP: "+vwapStr,vwapClr); y+=m_lineH+4;

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
