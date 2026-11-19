//+------------------------------------------------------------------+
//| AdvancedSessionORBEngine.mqh                                      |
//| Multi-session 15-minute Opening Range Breakout evidence engine    |
//| Closed-bar only. Signal and telemetry only, never sends orders.   |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_ADVANCED_SESSION_ORB_ENGINE_MQH
#define AX_ADVANCED_SESSION_ORB_ENGINE_MQH
#include "Defs.mqh"

enum ENUM_AX_ORB_SIGNAL
  {
   AX_ORB_SIGNAL_NONE=0,
   AX_ORB_BREAKOUT_BUY,
   AX_ORB_BREAKOUT_SELL,
   AX_ORB_RETEST_BUY,
   AX_ORB_RETEST_SELL,
   AX_ORB_FAILED_BULLISH,
   AX_ORB_FAILED_BEARISH
  };

struct SAxOrbSessionState
  {
   string name;
   int hour;
   datetime start;
   datetime rangeEnd;
   datetime lastProcessedBar;
   datetime signalBar;
   double rangeHigh;
   double rangeLow;
   double rangeWidthPoints;
   ENUM_AX_ORB_SIGNAL signal;
   bool rangeReady;
  };

struct SAxAdvancedOrbReading
  {
   bool available;
   ENUM_AX_DIR direction;
   int bullishSessionCount;
   int bearishSessionCount;
   int sessionCount;
   string sessionNames;
   string status;
   double rangeHigh;
   double rangeLow;
   double rangeWidthPoints;
   double volumeRatio;
   datetime signalBar;
   bool htfLevelsAvailable;
   double previousDayHigh;
   double previousDayLow;
   double previousWeekHigh;
   double previousWeekLow;
   double nearestResistance;
   double nearestSupport;
   double roomToNextLevelPoints;
  };

class CAdvancedSessionORBEngine
  {
private:
   bool m_enabled;
   int m_rangeMinutes;
   ENUM_TIMEFRAMES m_breakoutTimeframe;
   int m_hours[3];
   string m_names[3];
   double m_point;
   double m_bufferPoints;
   double m_minBodyRatio;
   double m_minCloseLocation;
   double m_minVolumeRatio;
   double m_minRangePoints;
   double m_maxRangePoints;
   int m_dayKey;
   datetime m_lastUpdateBar;
   SAxOrbSessionState m_sessions[3];
   SAxAdvancedOrbReading m_reading;
   long m_chartId;
   string m_objectPrefix;

   bool EnsureTrend(const string name,const datetime from,const datetime to,
                    const double price,const color lineColor,const ENUM_LINE_STYLE style)
     {
      if(from<=0 || to<=from || price<=0.0) return(false);
      if(ObjectFind(m_chartId,name)<0)
        {
         if(!ObjectCreate(m_chartId,name,OBJ_TREND,0,from,price,to,price))
            return(false);
        }
      else
        {
         if(!ObjectMove(m_chartId,name,0,from,price) ||
            !ObjectMove(m_chartId,name,1,to,price))
            return(false);
        }
      ObjectSetInteger(m_chartId,name,OBJPROP_COLOR,lineColor);
      ObjectSetInteger(m_chartId,name,OBJPROP_STYLE,style);
      ObjectSetInteger(m_chartId,name,OBJPROP_WIDTH,1);
      ObjectSetInteger(m_chartId,name,OBJPROP_RAY_LEFT,false);
      ObjectSetInteger(m_chartId,name,OBJPROP_RAY_RIGHT,false);
      ObjectSetInteger(m_chartId,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(m_chartId,name,OBJPROP_HIDDEN,true);
      return(true);
     }

   bool EnsureText(const string name,const datetime when,const double price,
                   const string caption,const color textColor,const int fontSize=8)
     {
      if(when<=0 || price<=0.0) return(false);
      if(ObjectFind(m_chartId,name)<0)
        {
         if(!ObjectCreate(m_chartId,name,OBJ_TEXT,0,when,price))
            return(false);
        }
      else if(!ObjectMove(m_chartId,name,0,when,price))
         return(false);
      ObjectSetString(m_chartId,name,OBJPROP_TEXT,caption);
      ObjectSetString(m_chartId,name,OBJPROP_FONT,"Arial");
      ObjectSetInteger(m_chartId,name,OBJPROP_FONTSIZE,fontSize);
      ObjectSetInteger(m_chartId,name,OBJPROP_COLOR,textColor);
      ObjectSetInteger(m_chartId,name,OBJPROP_ANCHOR,ANCHOR_LEFT_LOWER);
      ObjectSetInteger(m_chartId,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(m_chartId,name,OBJPROP_HIDDEN,true);
      return(true);
     }

   bool EnsureRectangle(const string name,const datetime from,const datetime to,
                        const double high,const double low,const color fillColor)
     {
      if(from<=0 || to<=from || high<=low || low<=0.0) return(false);
      if(ObjectFind(m_chartId,name)<0)
        {
         if(!ObjectCreate(m_chartId,name,OBJ_RECTANGLE,0,from,high,to,low))
            return(false);
        }
      else
        {
         if(!ObjectMove(m_chartId,name,0,from,high) ||
            !ObjectMove(m_chartId,name,1,to,low))
            return(false);
        }
      ObjectSetInteger(m_chartId,name,OBJPROP_COLOR,fillColor);
      ObjectSetInteger(m_chartId,name,OBJPROP_FILL,true);
      ObjectSetInteger(m_chartId,name,OBJPROP_BACK,true);
      ObjectSetInteger(m_chartId,name,OBJPROP_STYLE,STYLE_DOT);
      ObjectSetInteger(m_chartId,name,OBJPROP_WIDTH,1);
      ObjectSetInteger(m_chartId,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(m_chartId,name,OBJPROP_HIDDEN,true);
      return(true);
     }

   void DrawSignal(const string symbol,const int index,const datetime dayEnd)
     {
      SAxOrbSessionState session=m_sessions[index];
      if(!session.rangeReady || session.signalBar<=0 ||
         session.signal==AX_ORB_SIGNAL_NONE)
         return;

      string key=m_objectPrefix+IntegerToString(m_dayKey)+"_S"+
                 IntegerToString(index)+"_B"+IntegerToString((int)session.signalBar);
      bool bullish=(session.signal==AX_ORB_BREAKOUT_BUY ||
                    session.signal==AX_ORB_RETEST_BUY ||
                    session.signal==AX_ORB_FAILED_BULLISH);
      bool failed=(session.signal==AX_ORB_FAILED_BULLISH ||
                   session.signal==AX_ORB_FAILED_BEARISH);
      double price=bullish?session.rangeHigh:session.rangeLow;
      color markerColor=failed?clrTomato:(bullish?clrLimeGreen:clrOrangeRed);
      string caption=failed?"FAILED "+session.name:
                     (session.signal==AX_ORB_RETEST_BUY ||
                      session.signal==AX_ORB_RETEST_SELL)?"RETEST "+session.name:
                     "BREAKOUT "+session.name;
      string markerName=key+"_MARK";
      if(ObjectFind(m_chartId,markerName)<0)
         ObjectCreate(m_chartId,markerName,OBJ_ARROW,0,session.signalBar,price);
      else
         ObjectMove(m_chartId,markerName,0,session.signalBar,price);
      ObjectSetInteger(m_chartId,markerName,OBJPROP_ARROWCODE,failed?251:(bullish?233:234));
      ObjectSetInteger(m_chartId,markerName,OBJPROP_COLOR,markerColor);
      ObjectSetInteger(m_chartId,markerName,OBJPROP_WIDTH,1);
      ObjectSetInteger(m_chartId,markerName,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(m_chartId,markerName,OBJPROP_HIDDEN,true);
      EnsureText(key+"_LABEL",session.signalBar,price,caption,markerColor,8);
     }

   void DrawDiagnostics(const string symbol)
     {
      if(!m_enabled || m_chartId<=0 || StringLen(m_objectPrefix)==0)
         return;
      datetime dayEnd=(datetime)(m_sessions[0].start+86400);
      color sessionColors[3]={clrSteelBlue,clrDarkOrange,clrMediumPurple};
      for(int i=0;i<3;i++)
        {
         SAxOrbSessionState session=m_sessions[i];
         if(!session.rangeReady) continue;
         string key=m_objectPrefix+IntegerToString(m_dayKey)+"_S"+IntegerToString(i);
         EnsureRectangle(key+"_RANGE",session.start,dayEnd,
                         session.rangeHigh,session.rangeLow,sessionColors[i]);
         EnsureTrend(key+"_HIGH",session.start,dayEnd,session.rangeHigh,
                     sessionColors[i],STYLE_DASH);
         EnsureTrend(key+"_LOW",session.start,dayEnd,session.rangeLow,
                     sessionColors[i],STYLE_DASH);
         EnsureText(key+"_NAME",session.start,session.rangeHigh,
                    session.name+" OR",sessionColors[i],8);
         DrawSignal(symbol,i,dayEnd);
        }

      if(m_reading.htfLevelsAvailable)
        {
         datetime from=m_sessions[0].start;
         EnsureTrend(m_objectPrefix+"PDH",from,dayEnd,m_reading.previousDayHigh,
                     clrGoldenrod,STYLE_DOT);
         EnsureTrend(m_objectPrefix+"PDL",from,dayEnd,m_reading.previousDayLow,
                     clrGoldenrod,STYLE_DOT);
         EnsureTrend(m_objectPrefix+"PWH",from,dayEnd,m_reading.previousWeekHigh,
                     clrMagenta,STYLE_DASHDOT);
         EnsureTrend(m_objectPrefix+"PWL",from,dayEnd,m_reading.previousWeekLow,
                     clrMagenta,STYLE_DASHDOT);
         EnsureText(m_objectPrefix+"PDH_LABEL",from,m_reading.previousDayHigh,"PDH",clrGoldenrod,8);
         EnsureText(m_objectPrefix+"PDL_LABEL",from,m_reading.previousDayLow,"PDL",clrGoldenrod,8);
         EnsureText(m_objectPrefix+"PWH_LABEL",from,m_reading.previousWeekHigh,"PWH",clrMagenta,8);
         EnsureText(m_objectPrefix+"PWL_LABEL",from,m_reading.previousWeekLow,"PWL",clrMagenta,8);
        }
      ChartRedraw(m_chartId);
     }

   int DayKey(const datetime when) const
     {
      MqlDateTime parts;
      if(!TimeToStruct(when,parts)) return(0);
      return(parts.year*10000+parts.mon*100+parts.day);
     }

   datetime SessionStart(const datetime when,const int hour) const
     {
      MqlDateTime parts;
      if(!TimeToStruct(when,parts)) return(0);
      parts.hour=hour;
      parts.min=0;
      parts.sec=0;
      return(StructToTime(parts));
     }

   void ResetSession(const int index,const datetime start)
     {
      m_sessions[index].name=m_names[index];
      m_sessions[index].hour=m_hours[index];
      m_sessions[index].start=start;
      m_sessions[index].rangeEnd=start+(datetime)(m_rangeMinutes*60);
      m_sessions[index].lastProcessedBar=0;
      m_sessions[index].signalBar=0;
      m_sessions[index].rangeHigh=0.0;
      m_sessions[index].rangeLow=0.0;
      m_sessions[index].rangeWidthPoints=0.0;
      m_sessions[index].signal=AX_ORB_SIGNAL_NONE;
      m_sessions[index].rangeReady=false;
     }

   bool BuildOpeningRange(const string symbol,const int index)
     {
      if(index<0 || index>=3) return(false);
      datetime from=m_sessions[index].start;
      datetime to=m_sessions[index].rangeEnd-1;
      MqlRates bars[];
      ArraySetAsSeries(bars,true);
      int copied=CopyRates(symbol,PERIOD_M1,from,to,bars);
      // Require almost the full one-minute anchor window. A sparse or partial
      // history segment is not promoted into a valid opening range.
      if(copied<m_rangeMinutes-2) return(false);

      double high=-DBL_MAX;
      double low=DBL_MAX;
      for(int i=0;i<copied;i++)
        {
         if(bars[i].high>high) high=bars[i].high;
         if(bars[i].low<low) low=bars[i].low;
        }
      if(high<=0.0 || low<=0.0 || high<=low || m_point<=0.0) return(false);

      double width=(high-low)/m_point;
      if(width<m_minRangePoints) return(false);
      if(m_maxRangePoints>0.0 && width>m_maxRangePoints) return(false);

      m_sessions[index].rangeHigh=high;
      m_sessions[index].rangeLow=low;
      m_sessions[index].rangeWidthPoints=width;
      m_sessions[index].rangeReady=true;
      return(true);
     }

   double CandleBodyRatio(const MqlRates &bar) const
     {
      double span=bar.high-bar.low;
      if(span<=0.0) return(0.0);
      return(MathAbs(bar.close-bar.open)/span);
     }

   double CandleCloseLocation(const MqlRates &bar) const
     {
      double span=bar.high-bar.low;
      if(span<=0.0) return(0.5);
      return((bar.close-bar.low)/span);
     }

   double VolumeRatio(const string symbol,const MqlRates &signalBar) const
     {
      MqlRates history[];
      ArraySetAsSeries(history,true);
      int copied=CopyRates(symbol,m_breakoutTimeframe,2,20,history);
      if(copied<10) return(0.0);
      double average=0.0;
      for(int i=0;i<copied;i++) average+=(double)history[i].tick_volume;
      average/=(double)copied;
      if(average<=0.0) return(0.0);
      return((double)signalBar.tick_volume/average);
     }

   void EvaluateSession(const int index,
                        const MqlRates &latest,const MqlRates &previous,
                        const double volumeRatio)
     {
      if(!m_sessions[index].rangeReady || latest.time<m_sessions[index].rangeEnd)
         return;
      if(latest.time<=m_sessions[index].lastProcessedBar) return;
      m_sessions[index].lastProcessedBar=latest.time;

      double high=m_sessions[index].rangeHigh;
      double low=m_sessions[index].rangeLow;
      double buffer=m_bufferPoints*m_point;
      double bodyRatio=CandleBodyRatio(latest);
      double closeLocation=CandleCloseLocation(latest);
      bool quality=(bodyRatio>=m_minBodyRatio && volumeRatio>=m_minVolumeRatio);

      if(latest.close>high+buffer && quality &&
         closeLocation>=m_minCloseLocation)
        {
         if(previous.close>high && latest.low<=high+buffer)
            m_sessions[index].signal=AX_ORB_RETEST_BUY;
         else
            m_sessions[index].signal=AX_ORB_BREAKOUT_BUY;
         m_sessions[index].signalBar=latest.time;
         return;
        }

      if(latest.close<low-buffer && quality &&
         closeLocation<=(1.0-m_minCloseLocation))
        {
         if(previous.close<low && latest.high>=low-buffer)
            m_sessions[index].signal=AX_ORB_RETEST_SELL;
         else
            m_sessions[index].signal=AX_ORB_BREAKOUT_SELL;
         m_sessions[index].signalBar=latest.time;
         return;
        }

      // A close back inside the range invalidates the previous directional
      // breakout. It is recorded as a failure, never auto-traded in reverse.
      if(previous.close>high && latest.close<=high)
        {
         m_sessions[index].signal=AX_ORB_FAILED_BULLISH;
         m_sessions[index].signalBar=latest.time;
        }
      else if(previous.close<low && latest.close>=low)
        {
         m_sessions[index].signal=AX_ORB_FAILED_BEARISH;
         m_sessions[index].signalBar=latest.time;
        }
     }

   void PopulateHigherTimeframeLevels(const string symbol,const double price)
     {
      m_reading.previousDayHigh=iHigh(symbol,PERIOD_D1,1);
      m_reading.previousDayLow=iLow(symbol,PERIOD_D1,1);
      m_reading.previousWeekHigh=iHigh(symbol,PERIOD_W1,1);
      m_reading.previousWeekLow=iLow(symbol,PERIOD_W1,1);
      m_reading.htfLevelsAvailable=
         (m_reading.previousDayHigh>0.0 && m_reading.previousDayLow>0.0 &&
          m_reading.previousWeekHigh>0.0 && m_reading.previousWeekLow>0.0);
      m_reading.nearestResistance=0.0;
      m_reading.nearestSupport=0.0;
      if(price<=0.0) return;

      double resistanceCandidates[2];
      resistanceCandidates[0]=m_reading.previousDayHigh;
      resistanceCandidates[1]=m_reading.previousWeekHigh;
      for(int r=0;r<2;r++)
         if(resistanceCandidates[r]>price &&
            (m_reading.nearestResistance<=0.0 ||
             resistanceCandidates[r]<m_reading.nearestResistance))
            m_reading.nearestResistance=resistanceCandidates[r];

      double supportCandidates[2];
      supportCandidates[0]=m_reading.previousDayLow;
      supportCandidates[1]=m_reading.previousWeekLow;
      for(int q=0;q<2;q++)
         if(supportCandidates[q]>0.0 && supportCandidates[q]<price &&
            (m_reading.nearestSupport<=0.0 ||
             supportCandidates[q]>m_reading.nearestSupport))
            m_reading.nearestSupport=supportCandidates[q];

      if(m_reading.direction==AX_DIR_BUY && m_reading.nearestResistance>0.0)
         m_reading.roomToNextLevelPoints=(m_reading.nearestResistance-price)/m_point;
      else if(m_reading.direction==AX_DIR_SELL && m_reading.nearestSupport>0.0)
         m_reading.roomToNextLevelPoints=(price-m_reading.nearestSupport)/m_point;
     }

   void AggregateReading(const double volumeRatio)
     {
      ZeroMemory(m_reading);
      m_reading.available=false;
      m_reading.volumeRatio=volumeRatio;
      string bullishNames="";
      string bearishNames="";
      for(int i=0;i<3;i++)
        {
         if(!m_sessions[i].rangeReady) continue;
         m_reading.available=true;
         ENUM_AX_ORB_SIGNAL signal=m_sessions[i].signal;
         if(signal==AX_ORB_BREAKOUT_BUY || signal==AX_ORB_RETEST_BUY)
           {
            m_reading.bullishSessionCount++;
            if(StringLen(bullishNames)>0) bullishNames+=",";
            bullishNames+=m_sessions[i].name;
            m_reading.rangeHigh=m_sessions[i].rangeHigh;
            m_reading.rangeLow=m_sessions[i].rangeLow;
            m_reading.rangeWidthPoints=m_sessions[i].rangeWidthPoints;
            m_reading.signalBar=m_sessions[i].lastProcessedBar;
           }
         else if(signal==AX_ORB_BREAKOUT_SELL || signal==AX_ORB_RETEST_SELL)
           {
            m_reading.bearishSessionCount++;
            if(StringLen(bearishNames)>0) bearishNames+=",";
            bearishNames+=m_sessions[i].name;
            m_reading.rangeHigh=m_sessions[i].rangeHigh;
            m_reading.rangeLow=m_sessions[i].rangeLow;
            m_reading.rangeWidthPoints=m_sessions[i].rangeWidthPoints;
            m_reading.signalBar=m_sessions[i].lastProcessedBar;
           }
         else if(signal==AX_ORB_FAILED_BULLISH || signal==AX_ORB_FAILED_BEARISH)
            m_reading.status="FAILED_BREAKOUT";
        }
      m_reading.sessionCount=m_reading.bullishSessionCount+m_reading.bearishSessionCount;
      if(m_reading.bullishSessionCount>0 && m_reading.bearishSessionCount==0)
        {
         m_reading.direction=AX_DIR_BUY;
         m_reading.sessionNames=bullishNames;
         m_reading.status="BULLISH_BREAKOUT_OR_RETEST";
        }
      else if(m_reading.bearishSessionCount>0 && m_reading.bullishSessionCount==0)
        {
         m_reading.direction=AX_DIR_SELL;
         m_reading.sessionNames=bearishNames;
         m_reading.status="BEARISH_BREAKOUT_OR_RETEST";
        }
      else if(m_reading.bullishSessionCount>0 && m_reading.bearishSessionCount>0)
        {
         m_reading.direction=AX_DIR_NONE;
         m_reading.sessionNames=bullishNames+" | "+bearishNames;
         m_reading.status="CONFLICTING_SESSION_BREAKOUTS";
        }
      else if(StringLen(m_reading.status)==0)
         m_reading.status=m_reading.available?"NO_CONFIRMED_BREAKOUT":"NO_COMPLETED_OPENING_RANGE";
     }

public:
   CAdvancedSessionORBEngine(void)
     {
      m_enabled=false;
      m_rangeMinutes=15;
      m_breakoutTimeframe=PERIOD_M5;
      m_hours[0]=0; m_hours[1]=8; m_hours[2]=13;
      m_names[0]="ASIA"; m_names[1]="LONDON"; m_names[2]="NEW_YORK";
      m_point=0.0;
      m_bufferPoints=5.0;
      m_minBodyRatio=0.45;
      m_minCloseLocation=0.72;
      m_minVolumeRatio=1.20;
      m_minRangePoints=0.0;
      m_maxRangePoints=0.0;
      m_dayKey=0;
      m_lastUpdateBar=0;
      m_chartId=0;
      m_objectPrefix="";
      for(int i=0;i<3;i++) ResetSession(i,0);
      ZeroMemory(m_reading);
     }

   void Configure(const bool enabled,const int rangeMinutes,
                  const ENUM_TIMEFRAMES breakoutTimeframe,
                  const int asiaHour,const int londonHour,const int newYorkHour,
                  const double bufferPoints,const double minBodyRatio,
                  const double minCloseLocation,const double minVolumeRatio,
                  const double minRangePoints,const double maxRangePoints)
     {
      m_enabled=enabled;
      m_rangeMinutes=(int)MathMax(5,MathMin(rangeMinutes,60));
      m_breakoutTimeframe=breakoutTimeframe;
      m_hours[0]=(int)MathMax(0,MathMin(asiaHour,23));
      m_hours[1]=(int)MathMax(0,MathMin(londonHour,23));
      m_hours[2]=(int)MathMax(0,MathMin(newYorkHour,23));
      m_bufferPoints=MathMax(0.0,bufferPoints);
      m_minBodyRatio=AxClampD(minBodyRatio,0.10,0.95);
      m_minCloseLocation=AxClampD(minCloseLocation,0.55,0.95);
      m_minVolumeRatio=MathMax(0.0,minVolumeRatio);
      m_minRangePoints=MathMax(0.0,minRangePoints);
      m_maxRangePoints=MathMax(0.0,maxRangePoints);
      m_dayKey=0;
      m_lastUpdateBar=0;
      ZeroMemory(m_reading);
     }

   bool Update(const string symbol,const datetime serverTime,const double point)
     {
      if(!m_enabled)
        {
         ZeroMemory(m_reading);
         m_reading.status="DISABLED";
         return(false);
        }
      if(StringLen(symbol)==0 || serverTime<=0 || point<=0.0)
        {
         ZeroMemory(m_reading);
         m_reading.status="INVALID_INPUT";
         return(false);
        }
      m_point=point;
      int key=DayKey(serverTime);
      if(key==0) return(false);
      if(key!=m_dayKey)
        {
         m_dayKey=key;
         m_lastUpdateBar=0;
         for(int i=0;i<3;i++)
            ResetSession(i,SessionStart(serverTime,m_hours[i]));
        }

      datetime latestClosedBar=iTime(symbol,m_breakoutTimeframe,1);
      if(latestClosedBar<=0) return(false);
      // The engine is intentionally bar-clocked. Do not copy M1/M5 history
      // repeatedly on every incoming tick of the same breakout candle.
      if(latestClosedBar==m_lastUpdateBar) return(true);

      MqlRates recent[];
      ArraySetAsSeries(recent,true);
      if(CopyRates(symbol,m_breakoutTimeframe,1,2,recent)<2)
        {
         ZeroMemory(m_reading);
         m_reading.status="BREAKOUT_HISTORY_UNAVAILABLE";
         return(false);
        }
      m_lastUpdateBar=recent[0].time;
      double volumeRatio=VolumeRatio(symbol,recent[0]);
      for(int i=0;i<3;i++)
        {
         if(serverTime<m_sessions[i].rangeEnd) continue;
         if(!m_sessions[i].rangeReady && !BuildOpeningRange(symbol,i)) continue;
         EvaluateSession(i,recent[0],recent[1],volumeRatio);
        }
      AggregateReading(volumeRatio);
      PopulateHigherTimeframeLevels(symbol,recent[0].close);
      DrawDiagnostics(symbol);
      return(m_reading.available);
     }

   SAxAdvancedOrbReading Read(void) const
     {
      return(m_reading);
     }

   bool GetSessionAt(const int index,SAxOrbSessionState &out) const
     {
      if(index<0 || index>=3) return(false);
      out=m_sessions[index];
      return(true);
     }

   void SetChartIdentity(const string symbol,const ulong magic)
     {
      m_chartId=ChartID();
      m_objectPrefix="AXORB_"+StringFormat("%I64d",m_chartId)+"_"+symbol+"_";
      m_objectPrefix+=
                     StringFormat("%I64u",magic)+"_";
     }

   void Cleanup(void)
     {
      if(m_chartId>0 && StringLen(m_objectPrefix)>0)
        {
         ObjectsDeleteAll(m_chartId,m_objectPrefix);
         ChartRedraw(m_chartId);
        }
      m_objectPrefix="";
     }

   bool IsEnabled(void) const { return(m_enabled); }
  };
#endif // AX_ADVANCED_SESSION_ORB_ENGINE_MQH
