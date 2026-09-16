//+------------------------------------------------------------------+
//| Dashboard.mqh                                                       |
//| Chart-object on-screen panel. Pure presentation - it reads a       |
//| snapshot struct the main EA fills each tick and never touches     |
//| trading state itself.                                             |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_UI_DASHBOARD_MQH
#define AX_UI_DASHBOARD_MQH
#include "../core/Types.mqh"

struct AXDashboardData
  {
   //--- market
   string symbol; double price; double spreadPoints; string regime; string volState;
   //--- bias
   string macroBias, weeklyBias, dailyBias, h4Bias, h1Bias;
   //--- liquidity
   string nearestLiquidity; string majorLiquidity; string currentDraw;
   //--- setup
   string setupType; double confidence; double score; double entry, sl, tp1, tp2, tpFinal, expectedR;
   //--- sniper order (a resting limit order waiting for its precise price, distinct from an open position)
   bool   sniperWaiting; string sniperSetup; double sniperEntry; double sniperDistancePoints; string sniperExpiresIn;
   //--- order flow / volume profile / footprint / DOM
   bool   ofAvailable; bool ofRealFlags; double ofPoc; double ofVah; double ofVal;
   double ofCumulativeDelta; string ofDivergence; string ofAbsorption; double ofPulseScore; string ofPulseState;
   bool   domAvailable; double domBidVol; double domAskVol;
   //--- risk
   double equity; double currentRiskPct; double openExposurePct; double drawdownPct; string dailyStatus;
   //--- execution
   double execSpread; double execAvgSpread; double execSlippage; double execLatencyMs;
   int execPartialFills; int execFillingFallbacks; string brokerStatus;
   //--- autopsy
   int recentTrades; double expectancy; string aPlusPerformance; string regimePerformance;
   //--- state
   string tradingState; // ACTIVE / SUSPENDED / FAILSAFE
   //--- adaptive flip engine
   string capitalState; double riskOfRuinPct; double edgeHealthScore;
   int    flipsToday; int flipsThisWeek; bool flipEngineEnabled;
   //--- VWAP trend/flip (Setup G)
   bool   vwapEnabled; double vwapValue; string vwapSide; bool vwapPositionOpen;
  };

class CDashboard
  {
private:
   string m_prefix;
   int    m_x, m_y;

   void Label(string name, string text, int x, int y, color clr, int size=9)
     {
      string full = m_prefix+name;
      if(ObjectFind(0, full)<0)
        {
         ObjectCreate(0, full, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, full, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, full, OBJPROP_XDISTANCE, x);
         ObjectSetInteger(0, full, OBJPROP_YDISTANCE, y);
         ObjectSetInteger(0, full, OBJPROP_FONTSIZE, size);
         ObjectSetString(0, full, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, full, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, full, OBJPROP_HIDDEN, true);
        }
      ObjectSetString(0, full, OBJPROP_TEXT, text);
      ObjectSetInteger(0, full, OBJPROP_COLOR, clr);
     }

   void Background(int width, int height)
     {
      string full = m_prefix+"BG";
      if(ObjectFind(0, full)<0)
        {
         ObjectCreate(0, full, OBJ_RECTANGLE_LABEL, 0, 0, 0);
         ObjectSetInteger(0, full, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, full, OBJPROP_XDISTANCE, m_x-8);
         ObjectSetInteger(0, full, OBJPROP_YDISTANCE, m_y-8);
         ObjectSetInteger(0, full, OBJPROP_BGCOLOR, C'10,12,14');
         ObjectSetInteger(0, full, OBJPROP_BORDER_TYPE, BORDER_FLAT);
         ObjectSetInteger(0, full, OBJPROP_COLOR, clrDimGray);
         ObjectSetInteger(0, full, OBJPROP_BACK, false);
         ObjectSetInteger(0, full, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, full, OBJPROP_HIDDEN, true);
        }
      ObjectSetInteger(0, full, OBJPROP_XSIZE, width);
      ObjectSetInteger(0, full, OBJPROP_YSIZE, height);
     }

public:
   void Init(string prefix="AXSD15_", int x=12, int y=20)
     {
      m_prefix = prefix; m_x=x; m_y=y;
     }

   void Deinit()
     {
      ObjectsDeleteAll(0, m_prefix);
     }

   void Render(const AXDashboardData &d)
     {
      Background(380, 700);
      int y = m_y; int lh = 15;
      color hdr = clrKhaki, val = clrWhiteSmoke, warn = clrTomato, good = clrLightGreen;

      Label("T1", "AUTOPSY X SWINGDEMON X15", m_x, y, clrGold, 11); y+=lh+4;
      Label("T2", StringFormat("State: %s", d.tradingState), m_x, y, d.tradingState=="ACTIVE"?good:warn); y+=lh+4;

      Label("H_MKT", "-- MARKET --", m_x, y, hdr); y+=lh;
      Label("MKT1", StringFormat("%s  %.5f  spread %.1fpt", d.symbol, d.price, d.spreadPoints), m_x, y, val); y+=lh;
      Label("MKT2", StringFormat("Regime: %s | Vol: %s", d.regime, d.volState), m_x, y, val); y+=lh+4;

      Label("H_BIAS", "-- BIAS --", m_x, y, hdr); y+=lh;
      Label("BIAS1", StringFormat("Macro:%s Weekly:%s Daily:%s", d.macroBias, d.weeklyBias, d.dailyBias), m_x, y, val); y+=lh;
      Label("BIAS2", StringFormat("H4:%s H1:%s", d.h4Bias, d.h1Bias), m_x, y, val); y+=lh+4;

      Label("H_LIQ", "-- LIQUIDITY --", m_x, y, hdr); y+=lh;
      Label("LIQ1", StringFormat("Nearest: %s", d.nearestLiquidity), m_x, y, val); y+=lh;
      Label("LIQ2", StringFormat("Major: %s", d.majorLiquidity), m_x, y, val); y+=lh;
      Label("LIQ3", StringFormat("Draw: %s", d.currentDraw), m_x, y, val); y+=lh+4;

      Label("H_SETUP", "-- SETUP --", m_x, y, hdr); y+=lh;
      Label("SET1", StringFormat("%s  conf %.0f  score %.0f", d.setupType, d.confidence, d.score), m_x, y, val); y+=lh;
      Label("SET2", StringFormat("E:%.5f SL:%.5f", d.entry, d.sl), m_x, y, val); y+=lh;
      Label("SET3", StringFormat("TP1:%.5f TP2:%.5f Final:%.5f", d.tp1, d.tp2, d.tpFinal), m_x, y, val); y+=lh;
      Label("SET4", StringFormat("Expected R: %.2f", d.expectedR), m_x, y, d.expectedR>0?good:warn); y+=lh+4;

      Label("H_SNIPE", "-- SNIPER ORDER --", m_x, y, hdr); y+=lh;
      if(d.sniperWaiting)
        {
         Label("SNIPE1", StringFormat("WAITING: %s at %.5f", d.sniperSetup, d.sniperEntry), m_x, y, clrGold); y+=lh;
         Label("SNIPE2", StringFormat("%.0f pts away, expires in %s", d.sniperDistancePoints, d.sniperExpiresIn), m_x, y, val); y+=lh+4;
        }
      else
        { Label("SNIPE1", "No order resting - waiting for a precise setup.", m_x, y, val); y+=lh; Label("SNIPE2","",m_x,y,val); y+=lh+4; }

      Label("H_FLOW", "-- ORDER FLOW / VOLUME PROFILE --", m_x, y, hdr); y+=lh;
      if(d.ofAvailable)
        {
         Label("FLOW1", StringFormat("POC:%.5f  VA:[%.5f - %.5f]", d.ofPoc, d.ofVal, d.ofVah), m_x, y, val); y+=lh;
         Label("FLOW2", StringFormat("Delta:%.0f  %s  %s", d.ofCumulativeDelta, d.ofDivergence, d.ofAbsorption), m_x, y,
               d.ofCumulativeDelta>0?good:(d.ofCumulativeDelta<0?warn:val)); y+=lh;
         Label("FLOW3", StringFormat("Pulse: %s (%.0f)%s", d.ofPulseState, d.ofPulseScore, d.ofRealFlags?"":" [approx]"), m_x, y, val); y+=lh;
        }
      else
        { Label("FLOW1", "No tick/volume data available yet.", m_x, y, val); y+=lh; Label("FLOW2","",m_x,y,val); y+=lh; Label("FLOW3","",m_x,y,val); y+=lh; }
      Label("FLOW4", d.domAvailable ? StringFormat("DOM: bid %.1f / ask %.1f", d.domBidVol, d.domAskVol) : "DOM: not offered by this broker/symbol", m_x, y, val); y+=lh+4;

      Label("H_RISK", "-- RISK --", m_x, y, hdr); y+=lh;
      Label("RISK1", StringFormat("Equity: %.2f  Risk/trade: %.2f%%", d.equity, d.currentRiskPct), m_x, y, val); y+=lh;
      Label("RISK2", StringFormat("Open exposure: %.2f%%  DD: %.2f%%", d.openExposurePct, d.drawdownPct), m_x, y, d.drawdownPct>5.0?warn:val); y+=lh;
      Label("RISK3", StringFormat("Daily status: %s", d.dailyStatus), m_x, y, val); y+=lh+4;

      Label("H_EXEC", "-- EXECUTION --", m_x, y, hdr); y+=lh;
      Label("EXEC1", StringFormat("Spread now:%.1f avg:%.1f", d.execSpread, d.execAvgSpread), m_x, y,
            d.execSpread>d.execAvgSpread*2.0 && d.execAvgSpread>0.0 ? warn : val); y+=lh;
      Label("EXEC2", StringFormat("Slippage avg:%.1f  Latency avg:%.0fms", d.execSlippage, d.execLatencyMs), m_x, y, val); y+=lh;
      Label("EXEC3", StringFormat("Partial fills:%d  Fill-mode fallbacks:%d", d.execPartialFills, d.execFillingFallbacks), m_x, y, val); y+=lh;
      Label("EXEC4", StringFormat("Broker: %s", d.brokerStatus), m_x, y, val); y+=lh+4;

      Label("H_AUT", "-- AUTOPSY --", m_x, y, hdr); y+=lh;
      Label("AUT1", StringFormat("Trades: %d  Expectancy: %.2fR", d.recentTrades, d.expectancy), m_x, y, val); y+=lh;
      Label("AUT2", StringFormat("A+ perf: %s", d.aPlusPerformance), m_x, y, val); y+=lh;
      Label("AUT3", StringFormat("Regime perf: %s", d.regimePerformance), m_x, y, val); y+=lh+4;

      Label("H_FLIP", "-- ADAPTIVE FLIP ENGINE --", m_x, y, hdr); y+=lh;
      Label("FLIP1", StringFormat("Capital state: %s%s", d.capitalState, d.flipEngineEnabled?"":" (flips disabled)"), m_x, y,
            d.capitalState=="Normal" ? good : (d.capitalState=="Locked" ? warn : clrKhaki)); y+=lh;
      Label("FLIP2", StringFormat("Risk-of-ruin: %.1f%%  Edge health: %.0f", d.riskOfRuinPct, d.edgeHealthScore), m_x, y,
            d.riskOfRuinPct>15.0 ? warn : val); y+=lh;
      Label("FLIP3", StringFormat("Flips today: %d  This week: %d", d.flipsToday, d.flipsThisWeek), m_x, y, val); y+=lh+4;

      Label("H_VWAP", "-- VWAP TREND (SETUP G) --", m_x, y, hdr); y+=lh;
      if(d.vwapEnabled)
        {
         Label("VWAP1", StringFormat("VWAP: %.5f  Price is: %s", d.vwapValue, d.vwapSide), m_x, y, val); y+=lh;
         Label("VWAP2", d.vwapPositionOpen ? "Position: OPEN" : "Position: flat", m_x, y, d.vwapPositionOpen?good:val); y+=lh;
        }
      else
        { Label("VWAP1", "Disabled (InpVWAPSetupEnabled=false)", m_x, y, val); y+=lh; Label("VWAP2","",m_x,y,val); y+=lh; }

      ChartRedraw(0);
     }
  };
#endif // AX_UI_DASHBOARD_MQH
