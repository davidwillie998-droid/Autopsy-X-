//+------------------------------------------------------------------+
//| OrderFlowPanel.mqh                                                     |
//| On-chart visuals for the order-flow "edition": POC/Value-Area lines    |
//| (volume profile), a footprint-confirmation marker on the current bar,  |
//| and a screen-space DOM bid/ask imbalance gauge.                        |
//|                                                                        |
//| Scope note: this draws the SUMMARY read (POC/VAH/VAL, dominant         |
//| footprint side, DOM imbalance ratio) rather than a full per-price      |
//| histogram or a pixel-heatmap ladder — those need either exposing the   |
//| engine's internal per-bin arrays or a CCanvas bitmap renderer, and     |
//| the summary is what actually drives decisions elsewhere in the EA, so  |
//| it is what is drawn here. Pure presentation — computes nothing.        |
//+------------------------------------------------------------------+
#ifndef AXF_ORDERFLOWPANEL_MQH
#define AXF_ORDERFLOWPANEL_MQH

#include "../Common/Defines.mqh"

class CAxfOrderFlowPanel
  {
private:
   string            m_prefix;

   void              HLine(const string name,const double price,const color clr,const int style,const string text)
     {
      string full = m_prefix+name;
      if(ObjectFind(0,full)<0)
        {
         ObjectCreate(0,full,OBJ_HLINE,0,0,price);
         ObjectSetInteger(0,full,OBJPROP_SELECTABLE,false);
         ObjectSetInteger(0,full,OBJPROP_HIDDEN,true);
         ObjectSetInteger(0,full,OBJPROP_BACK,true);
        }
      ObjectSetDouble(0,full,OBJPROP_PRICE,price);
      ObjectSetInteger(0,full,OBJPROP_COLOR,clr);
      ObjectSetInteger(0,full,OBJPROP_STYLE,style);
      ObjectSetString(0,full,OBJPROP_TOOLTIP,text);
     }

   void              GaugeRect(const string name,const int x,const int y,const int w,const int h,const color clr)
     {
      string full = m_prefix+name;
      if(ObjectFind(0,full)<0)
        {
         ObjectCreate(0,full,OBJ_RECTANGLE_LABEL,0,0,0);
         ObjectSetInteger(0,full,OBJPROP_CORNER,CORNER_LEFT_UPPER);
         ObjectSetInteger(0,full,OBJPROP_SELECTABLE,false);
         ObjectSetInteger(0,full,OBJPROP_HIDDEN,true);
         ObjectSetInteger(0,full,OBJPROP_BORDER_TYPE,BORDER_FLAT);
        }
      ObjectSetInteger(0,full,OBJPROP_XDISTANCE,x);
      ObjectSetInteger(0,full,OBJPROP_YDISTANCE,y);
      ObjectSetInteger(0,full,OBJPROP_XSIZE,MathMax(1,w));
      ObjectSetInteger(0,full,OBJPROP_YSIZE,h);
      ObjectSetInteger(0,full,OBJPROP_BGCOLOR,clr);
      ObjectSetInteger(0,full,OBJPROP_COLOR,clr);
     }

   void              GaugeLabel(const string name,const int x,const int y,const string text,const color clr)
     {
      string full = m_prefix+name;
      if(ObjectFind(0,full)<0)
        {
         ObjectCreate(0,full,OBJ_LABEL,0,0,0);
         ObjectSetInteger(0,full,OBJPROP_CORNER,CORNER_LEFT_UPPER);
         ObjectSetInteger(0,full,OBJPROP_SELECTABLE,false);
         ObjectSetInteger(0,full,OBJPROP_HIDDEN,true);
         ObjectSetString(0,full,OBJPROP_FONT,"Consolas");
         ObjectSetInteger(0,full,OBJPROP_FONTSIZE,8);
        }
      ObjectSetInteger(0,full,OBJPROP_XDISTANCE,x);
      ObjectSetInteger(0,full,OBJPROP_YDISTANCE,y);
      ObjectSetString(0,full,OBJPROP_TEXT,text);
      ObjectSetInteger(0,full,OBJPROP_COLOR,clr);
     }

public:
   void              Init(const string unique_prefix)
     {
      m_prefix = unique_prefix+"_flow_";
     }

   //--- volume profile as three horizontal lines (POC solid, VAH/VAL dashed).
   //--- Drawn on whichever chart this EA is attached to — meaningful only
   //--- when that chart's symbol matches the profile's symbol.
   void              DrawVolumeProfile(const SAxfOrderFlow &of)
     {
      if(!of.valid || !of.profile_valid)
        {
         ObjectDelete(0,m_prefix+"poc"); ObjectDelete(0,m_prefix+"vah"); ObjectDelete(0,m_prefix+"val");
         return;
        }
      HLine("poc",of.poc_price,clrGold,STYLE_SOLID,"Volume Profile POC");
      HLine("vah",of.vah_price,clrDarkGray,STYLE_DASH,"Value Area High");
      HLine("val",of.val_price,clrDarkGray,STYLE_DASH,"Value Area Low");
     }

   //--- a compact DOM bid/ask imbalance gauge + footprint marker, placed
   //--- below the main text dashboard (caller passes the y-offset to start at).
   void              DrawFlowGauge(const SAxfOrderFlow &of,const int x,const int y_start)
     {
      int bar_w = 160, bar_h = 10;

      if(of.valid && of.dom_available)
        {
         double ratio = of.dom_imbalance_ratio;
         double bid_frac = AxfClamp(ratio/(ratio+1.0),0.05,0.95); // >1 ratio -> more bid depth -> longer green side
         int bid_w = (int)(bar_w*bid_frac);
         GaugeRect("dom_bid",x,y_start,bid_w,bar_h,clrLimeGreen);
         GaugeRect("dom_ask",x+bid_w,y_start,bar_w-bid_w,bar_h,clrCrimson);
         GaugeLabel("dom_lbl",x,y_start+bar_h+2,StringFormat("DOM bid/ask %.2fx",ratio),clrSilver);
        }
      else
        {
         ObjectDelete(0,m_prefix+"dom_bid"); ObjectDelete(0,m_prefix+"dom_ask");
         GaugeLabel("dom_lbl",x,y_start+bar_h+2,"DOM: unavailable",clrGray);
        }

      int y2 = y_start+bar_h+16;
      if(of.valid && of.footprint_valid)
        {
         color c = (of.footprint_imbalance_dir==DIR_LONG) ? clrLimeGreen : clrCrimson;
         GaugeLabel("fp_lbl",x,y2,StringFormat("Footprint: %s x%.1f (%d bars)",
                     of.footprint_imbalance_dir==DIR_LONG?"BUY":"SELL",
                     of.footprint_imbalance_ratio,of.footprint_stacked_bars),c);
        }
      else
         GaugeLabel("fp_lbl",x,y2,"Footprint: none",clrGray);
     }

   void              Remove(void)
     {
      ObjectsDeleteAll(0,m_prefix);
     }
  };

#endif // AXF_ORDERFLOWPANEL_MQH
