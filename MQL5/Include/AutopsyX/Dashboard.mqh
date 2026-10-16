//+------------------------------------------------------------------+
//| Dashboard.mqh                                                      |
//| Lightweight on-chart status panel. Built once in Init(), updated  |
//| by overwriting existing object text/color only - never recreated |
//| per tick - and refreshed from OnTimer so it cannot interfere with |
//| execution.                                                        |
//+------------------------------------------------------------------+
#pragma once
#include <AutopsyX/Defines.mqh>

struct AXDashboardData
{
   ENUM_AX_STATUS     status;
   ENUM_AX_REGIME     regime;
   ENUM_AX_DIRECTION  direction;
   double             buyScore;
   double             sellScore;
   ENUM_AX_CONFIDENCE confidence;
   double             spreadPts;
   double             tickVelocity;
   int                momentumBias;
   int                tradesToday;
   double             winRatePct;
   double             dailyPL;
   double             drawdownPct;
   ENUM_AX_DIRECTION  currentPosition;
   int                holdTimeSec;
   string             exitMode;
   string             statusNote;

   // institutional overlays - volume profile / order-flow proxy / DOM / pulse
   double             pulseScore;
   string             pulseLabel;
   double             pocDistancePts;
   int                valueAreaPosition;   // -1 below, 0 inside, +1 above
   double             orderFlowDelta;
   int                orderFlowDivergence; // -1 bearish, 0 none, +1 bullish
   double             domImbalance;
   bool               domAvailable;

   // VX: Adaptive Flip Engine
   ENUM_AX_CAPITAL_STATE capitalState;
   double             accountHealth;
   double             expectedValueR;
   double             riskOfRuinPct;
   bool               flipWarmingUp;
   bool               flipEnabled;
};

#define AX_DASH_ROWS 26

class CAXDashboard
{
private:
   string   m_prefix;
   int      m_x, m_y;
   int      m_lineHeight;
   string   m_labelNames[AX_DASH_ROWS];
   string   m_valueNames[AX_DASH_ROWS];
   string   m_labelText[AX_DASH_ROWS];

   void CreateLabel(const string name, const int x, const int y, const string text,
                     const color clr, const int fontSize, const bool bold)
   {
      if(ObjectFind(0, name) < 0)
         ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetString(0, name, OBJPROP_TEXT, text);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetString(0, name, OBJPROP_FONT, bold ? "Consolas Bold" : "Consolas");
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
   }

public:
   void Init(const string prefix, const int x, const int y)
   {
      m_prefix = prefix;
      m_x = x;
      m_y = y;
      m_lineHeight = 16;

      string labels[AX_DASH_ROWS] =
      {
         "", "STATUS", "REGIME", "DIRECTION", "BUY SCORE", "SELL SCORE", "CONFIDENCE",
         "SPREAD", "TICK VELOCITY", "MOMENTUM", "TRADES TODAY", "WIN RATE", "DAILY P/L",
         "DRAWDOWN", "CURRENT POSITION", "HOLD TIME", "EXIT MODE",
         "PULSE", "VOLUME POC", "VALUE AREA", "ORDER FLOW DELTA (proxy)", "DOM IMBALANCE",
         "CAPITAL STATE", "ACCOUNT HEALTH", "EXPECTED VALUE", "RISK OF RUIN"
      };

      string bgName = m_prefix + "BG";
      if(ObjectFind(0, bgName) < 0)
         ObjectCreate(0, bgName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bgName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, bgName, OBJPROP_XDISTANCE, m_x - 10);
      ObjectSetInteger(0, bgName, OBJPROP_YDISTANCE, m_y - 8);
      ObjectSetInteger(0, bgName, OBJPROP_XSIZE, 290);
      ObjectSetInteger(0, bgName, OBJPROP_YSIZE, AX_DASH_ROWS * m_lineHeight + 12);
      ObjectSetInteger(0, bgName, OBJPROP_BGCOLOR, C'12,14,20');
      ObjectSetInteger(0, bgName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bgName, OBJPROP_COLOR, C'60,60,70');
      ObjectSetInteger(0, bgName, OBJPROP_BACK, false);
      ObjectSetInteger(0, bgName, OBJPROP_SELECTABLE, false);

      for(int i = 0; i < AX_DASH_ROWS; i++)
      {
         m_labelText[i] = labels[i];
         m_labelNames[i] = m_prefix + "L" + IntegerToString(i);
         m_valueNames[i] = m_prefix + "V" + IntegerToString(i);
         int y = m_y + i * m_lineHeight;
         bool titleRow = (i == 0);
         CreateLabel(m_labelNames[i], m_x, y, titleRow ? "AUTOPSY X HFT VX" : (labels[i] + ":"),
                     titleRow ? clrGold : clrSilver, titleRow ? 11 : 9, titleRow);
         if(!titleRow)
            CreateLabel(m_valueNames[i], m_x + 170, y, "--", clrWhite, 9, false);
      }
   }

   void Deinit(void)
   {
      ObjectsDeleteAll(0, m_prefix);
   }

   void Update(const AXDashboardData &d)
   {
      SetValue(1, StatusText(d.status), StatusColor(d.status));
      SetValue(2, AXRegimeToString(d.regime), RegimeColor(d.regime));
      SetValue(3, AXDirToString(d.direction), DirColor(d.direction));
      SetValue(4, StringFormat("%.1f", d.buyScore), clrLime);
      SetValue(5, StringFormat("%.1f", d.sellScore), clrTomato);
      SetValue(6, AXConfidenceToString(d.confidence), ConfColor(d.confidence));
      SetValue(7, StringFormat("%.1f pts", d.spreadPts), clrSilver);
      SetValue(8, VelocityLabel(d.tickVelocity), clrSilver);
      SetValue(9, MomentumLabel(d.momentumBias), DirColor((ENUM_AX_DIRECTION)d.momentumBias));
      SetValue(10, IntegerToString(d.tradesToday), clrSilver);
      SetValue(11, StringFormat("%.1f%%", d.winRatePct), (d.winRatePct >= 50.0) ? clrLime : clrOrange);
      SetValue(12, StringFormat("$%.2f", d.dailyPL), (d.dailyPL >= 0) ? clrLime : clrTomato);
      SetValue(13, StringFormat("%.1f%%", d.drawdownPct), (d.drawdownPct >= 5.0) ? clrTomato : clrSilver);
      SetValue(14, AXDirToString(d.currentPosition), DirColor(d.currentPosition));
      SetValue(15, d.holdTimeSec > 0 ? StringFormat("%d sec", d.holdTimeSec) : "--", clrSilver);
      SetValue(16, d.exitMode, clrSilver);

      SetValue(17, StringFormat("%.0f (%s)", d.pulseScore, d.pulseLabel), PulseColor(d.pulseScore));
      SetValue(18, StringFormat("%.1f pts away", d.pocDistancePts), clrSilver);
      SetValue(19, ValueAreaLabel(d.valueAreaPosition), DirColor((ENUM_AX_DIRECTION)d.valueAreaPosition));
      SetValue(20, StringFormat("%.1f%s", d.orderFlowDelta, DivergenceSuffix(d.orderFlowDivergence)),
               DirColor((ENUM_AX_DIRECTION)(d.orderFlowDelta > 0 ? 1 : (d.orderFlowDelta < 0 ? -1 : 0))));
      SetValue(21, d.domAvailable ? StringFormat("%.2f", d.domImbalance) : "N/A (no DOM)", clrSilver);

      if(!d.flipEnabled)
      {
         SetValue(22, "DISABLED", clrGray);
         SetValue(23, "--", clrSilver);
         SetValue(24, "--", clrSilver);
         SetValue(25, "--", clrSilver);
      }
      else if(d.flipWarmingUp)
      {
         SetValue(22, "WARMING UP", clrDeepSkyBlue);
         SetValue(23, "--", clrSilver);
         SetValue(24, "--", clrSilver);
         SetValue(25, "--", clrSilver);
      }
      else
      {
         SetValue(22, AXCapitalStateToString(d.capitalState), CapitalStateColor(d.capitalState));
         SetValue(23, StringFormat("%.0f / 100", d.accountHealth), HealthColor(d.accountHealth));
         SetValue(24, StringFormat("%.3fR", d.expectedValueR), (d.expectedValueR >= 0) ? clrLime : clrTomato);
         SetValue(25, StringFormat("%.1f%%", d.riskOfRuinPct), (d.riskOfRuinPct >= 15.0) ? clrTomato : clrSilver);
      }

      ChartRedraw(0);
   }

private:
   void SetValue(const int row, const string text, const color clr)
   {
      ObjectSetString(0, m_valueNames[row], OBJPROP_TEXT, text);
      ObjectSetInteger(0, m_valueNames[row], OBJPROP_COLOR, clr);
   }

   string StatusText(const ENUM_AX_STATUS s) const
   {
      switch(s)
      {
         case AX_STATUS_ACTIVE:      return "ACTIVE";
         case AX_STATUS_PAUSED:      return "PAUSED";
         case AX_STATUS_LOCKED:      return "LOCKED";
         case AX_STATUS_CALIBRATING: return "CALIBRATING";
      }
      return "?";
   }

   color StatusColor(const ENUM_AX_STATUS s) const
   {
      switch(s)
      {
         case AX_STATUS_ACTIVE:      return clrLime;
         case AX_STATUS_PAUSED:      return clrOrange;
         case AX_STATUS_LOCKED:      return clrTomato;
         case AX_STATUS_CALIBRATING: return clrDeepSkyBlue;
      }
      return clrSilver;
   }

   color RegimeColor(const ENUM_AX_REGIME r) const
   {
      if(r == AX_REGIME_CHAOTIC || r == AX_REGIME_UNSAFE) return clrTomato;
      if(r == AX_REGIME_TRENDING || r == AX_REGIME_BREAKOUT) return clrLime;
      return clrSilver;
   }

   color DirColor(const ENUM_AX_DIRECTION d) const
   {
      if(d == AX_DIR_BUY) return clrLime;
      if(d == AX_DIR_SELL) return clrTomato;
      return clrSilver;
   }

   color ConfColor(const ENUM_AX_CONFIDENCE c) const
   {
      switch(c)
      {
         case AX_CONF_HIGH:   return clrLime;
         case AX_CONF_MEDIUM: return clrOrange;
         case AX_CONF_LOW:    return clrGray;
      }
      return clrGray;
   }

   string VelocityLabel(const double v) const
   {
      string tag = (v > 8.0) ? "HIGH" : (v > 3.0 ? "MEDIUM" : "LOW");
      return StringFormat("%s (%.1f/s)", tag, v);
   }

   string MomentumLabel(const int bias) const
   {
      if(bias > 0) return "BULLISH";
      if(bias < 0) return "BEARISH";
      return "NEUTRAL";
   }

   color PulseColor(const double score) const
   {
      if(score >= 75.0) return clrLime;
      if(score >= 45.0) return clrSilver;
      if(score >= 20.0) return clrOrange;
      return clrTomato;
   }

   string ValueAreaLabel(const int position) const
   {
      if(position > 0) return "ABOVE VALUE";
      if(position < 0) return "BELOW VALUE";
      return "INSIDE VALUE";
   }

   string DivergenceSuffix(const int divergence) const
   {
      if(divergence > 0) return " (BULL DIV)";
      if(divergence < 0) return " (BEAR DIV)";
      return "";
   }

   color CapitalStateColor(const ENUM_AX_CAPITAL_STATE s) const
   {
      switch(s)
      {
         case AX_CAPSTATE_CONFIDENT: return clrLime;
         case AX_CAPSTATE_NORMAL:    return clrSilver;
         case AX_CAPSTATE_CAUTION:   return clrOrange;
         case AX_CAPSTATE_RECOVERY:  return clrTomato;
      }
      return clrSilver;
   }

   color HealthColor(const double health) const
   {
      if(health >= 70.0) return clrLime;
      if(health >= 40.0) return clrOrange;
      return clrTomato;
   }
};
