//+------------------------------------------------------------------+
//| DailyExtremeProjectionEngine.mqh                                 |
//| Asia Range + CBDR + FLOUT daily-extreme projection intelligence. |
//| Projection zones are observational evidence, never entry orders. |
//+------------------------------------------------------------------+
#ifndef AX_DAILYEXTREMEPROJECTIONENGINE_MQH
#define AX_DAILYEXTREMEPROJECTIONENGINE_MQH
#property strict
#include "Defs.mqh"

#define AX_EXTREME_DEVIATION_COUNT 6

struct SAxDailyExtremeProjection
  {
   bool available;
   bool asiaAvailable;
   bool asiaComplete;
   bool cbdrAvailable;
   bool cbdrComplete;
   bool floutAvailable;
   datetime brokerDayStart;
   datetime lastUpdateBar;
   double asiaHigh;
   double asiaLow;
   double asiaRange;
   double cbdrBodyHigh;
   double cbdrBodyLow;
   double cbdrWickHigh;
   double cbdrWickLow;
   double cbdrBodyRange;
   double floutHigh;
   double floutLow;
   double floutHalfRange;
   double floutMidpoint;
   double adr20;
   double currentDayHigh;
   double currentDayLow;
   double adrUsedPercent;
   double adrRemaining;
   double nearestUpperProjection;
   double nearestLowerProjection;
   int upperConfluenceCount;
   int lowerConfluenceCount;
   double upperEvidenceScore;
   double lowerEvidenceScore;
   double asiaUpper[AX_EXTREME_DEVIATION_COUNT];
   double asiaLower[AX_EXTREME_DEVIATION_COUNT];
   double cbdrUpper[AX_EXTREME_DEVIATION_COUNT];
   double cbdrLower[AX_EXTREME_DEVIATION_COUNT];
   double floutUpper[AX_EXTREME_DEVIATION_COUNT];
   double floutLower[AX_EXTREME_DEVIATION_COUNT];
   string reason;
  };

class CDailyExtremeProjectionEngine
  {
private:
   string m_symbol;
   int m_asiaStartHour;
   int m_asiaEndHour;
   int m_cbdrStartHour;
   int m_cbdrEndHour;
   double m_toleranceAtrFraction;
   int m_manualServerOffsetMinutes;
   SAxDailyExtremeProjection m_state;
   bool m_initialized;
   datetime m_lastMinute;

   int FirstSunday(const int year,const int month) const
     {
      MqlDateTime d;
      ZeroMemory(d);
      d.year=year; d.mon=month; d.day=1;
      datetime first=StructToTime(d);
      TimeToStruct(first,d);
      return(1+((7-d.day_of_week)%7));
     }

   int NYUtcOffsetHours(const datetime utc) const
     {
      MqlDateTime p;
      TimeToStruct(utc,p);
      int dstStartDay=FirstSunday(p.year,3)+7;
      int dstEndDay=FirstSunday(p.year,11);
      MqlDateTime a,b;
      ZeroMemory(a); ZeroMemory(b);
      a.year=p.year; a.mon=3; a.day=dstStartDay; a.hour=7;
      b.year=p.year; b.mon=11; b.day=dstEndDay; b.hour=6;
      return(utc>=StructToTime(a) && utc<StructToTime(b) ? -4 : -5);
     }

   datetime NYLocalToServer(const int year,const int month,const int day,
                            const int hour,const int minute,const int serverOffsetSeconds) const
     {
      MqlDateTime local;
      ZeroMemory(local);
      local.year=year; local.mon=month; local.day=day;
      local.hour=hour; local.min=minute;
      datetime wallClock=StructToTime(local);
      int nyOffset=NYUtcOffsetHours(wallClock+5*3600);
      datetime utc=wallClock-nyOffset*3600;
      return(utc+serverOffsetSeconds);
     }

   void CurrentNYDate(const datetime utc,int &year,int &month,int &day) const
     {
      MqlDateTime p;
      TimeToStruct(utc+NYUtcOffsetHours(utc)*3600,p);
      year=p.year; month=p.mon; day=p.day;
     }

   int ResolveServerUtcOffset(const datetime serverNow,const datetime utcNow) const
     {
      if(m_manualServerOffsetMinutes!=9999) return(m_manualServerOffsetMinutes*60);
      return((int)MathRound((double)(serverNow-utcNow)/60.0)*60);
     }



   bool ReadSession(const datetime start,const datetime finish,
                    double &high,double &low,double &bodyHigh,double &bodyLow,
                    const bool useBodies) const
     {
      high=0.0;
      low=DBL_MAX;
      bodyHigh=0.0;
      bodyLow=DBL_MAX;
      MqlRates rates[];
      ArraySetAsSeries(rates,false);
      int copied=CopyRates(m_symbol,PERIOD_M1,start,finish,rates);
      if(copied<=0) return(false);
      datetime now=TimeTradeServer();
      int valid=0;
      for(int i=0;i<copied;i++)
        {
         // Exclude the still-forming minute. This keeps session extrema stable
         // and prevents a partial candle from being mistaken for a completed range.
         if(rates[i].time+60>now) continue;
         high=MathMax(high,rates[i].high);
         low=MathMin(low,rates[i].low);
         double candleBodyHigh=MathMax(rates[i].open,rates[i].close);
         double candleBodyLow=MathMin(rates[i].open,rates[i].close);
         bodyHigh=MathMax(bodyHigh,candleBodyHigh);
         bodyLow=MathMin(bodyLow,candleBodyLow);
         valid++;
        }
      if(valid<3 || high<=0.0 || low==DBL_MAX || high<=low) return(false);
      if(!useBodies)
        {
         bodyHigh=high;
         bodyLow=low;
        }
      return(true);
     }

   bool ReadAdr20(double &adr) const
     {
      adr=0.0;
      MqlRates daily[];
      ArraySetAsSeries(daily,true);
      int copied=CopyRates(m_symbol,PERIOD_D1,1,20,daily);
      if(copied<20) return(false);
      double sum=0.0;
      for(int i=0;i<20;i++)
        {
         double range=daily[i].high-daily[i].low;
         if(range<=0.0 || !MathIsValidNumber(range)) return(false);
         sum+=range;
        }
      adr=sum/20.0;
      return(adr>0.0 && MathIsValidNumber(adr));
     }

   void BuildProjections(void)
     {
      static const double multiples[AX_EXTREME_DEVIATION_COUNT]={0.5,1.0,1.5,2.0,2.5,3.0};
      if(m_state.asiaAvailable)
         for(int i=0;i<AX_EXTREME_DEVIATION_COUNT;i++)
           {
            m_state.asiaUpper[i]=m_state.asiaHigh+multiples[i]*m_state.asiaRange;
            m_state.asiaLower[i]=m_state.asiaLow-multiples[i]*m_state.asiaRange;
           }
      if(m_state.cbdrAvailable)
         for(int i=0;i<AX_EXTREME_DEVIATION_COUNT;i++)
           {
            // CBDR deviations use the body range as the primary unit.
            m_state.cbdrUpper[i]=m_state.cbdrBodyHigh+multiples[i]*m_state.cbdrBodyRange;
            m_state.cbdrLower[i]=m_state.cbdrBodyLow-multiples[i]*m_state.cbdrBodyRange;
           }
      if(m_state.floutAvailable)
         for(int i=0;i<AX_EXTREME_DEVIATION_COUNT;i++)
           {
            // FLOUT half-range is the practitioner-defined projection unit,
            // not a statistical standard deviation of returns.
            m_state.floutUpper[i]=m_state.floutMidpoint+multiples[i]*m_state.floutHalfRange;
            m_state.floutLower[i]=m_state.floutMidpoint-multiples[i]*m_state.floutHalfRange;
           }
     }

   void ScoreProjectionClusters(const double price,const double tolerance)
     {
      double upper[AX_EXTREME_DEVIATION_COUNT*3];
      double lower[AX_EXTREME_DEVIATION_COUNT*3];
      int upperCount=0,lowerCount=0;
      if(m_state.asiaAvailable)
         for(int i=0;i<AX_EXTREME_DEVIATION_COUNT;i++)
           { upper[upperCount++]=m_state.asiaUpper[i]; lower[lowerCount++]=m_state.asiaLower[i]; }
      if(m_state.cbdrAvailable)
         for(int i=0;i<AX_EXTREME_DEVIATION_COUNT;i++)
           { upper[upperCount++]=m_state.cbdrUpper[i]; lower[lowerCount++]=m_state.cbdrLower[i]; }
      if(m_state.floutAvailable)
         for(int i=0;i<AX_EXTREME_DEVIATION_COUNT;i++)
           { upper[upperCount++]=m_state.floutUpper[i]; lower[lowerCount++]=m_state.floutLower[i]; }

      m_state.nearestUpperProjection=0.0;
      m_state.nearestLowerProjection=0.0;
      double upperDistance=DBL_MAX,lowerDistance=DBL_MAX;
      for(int i=0;i<upperCount;i++)
        {
         double distance=MathAbs(price-upper[i]);
         if(upper[i]>price && distance<upperDistance)
           { upperDistance=distance; m_state.nearestUpperProjection=upper[i]; }
        }
      for(int i=0;i<lowerCount;i++)
        {
         double distance=MathAbs(price-lower[i]);
         if(lower[i]<price && distance<lowerDistance)
           { lowerDistance=distance; m_state.nearestLowerProjection=lower[i]; }
        }

      // Count distinct projection families represented inside one tolerance
      // band. Repeated levels from the same family cannot inflate confluence.
      m_state.upperConfluenceCount=0;
      m_state.lowerConfluenceCount=0;
      double familiesUpper[3],familiesLower[3];
      for(int f=0;f<3;f++) { familiesUpper[f]=0.0; familiesLower[f]=0.0; }
      for(int i=0;i<AX_EXTREME_DEVIATION_COUNT;i++)
        {
         if(m_state.asiaAvailable && MathAbs(price-m_state.asiaUpper[i])<=tolerance)
            familiesUpper[0]=1.0;
         if(m_state.cbdrAvailable && MathAbs(price-m_state.cbdrUpper[i])<=tolerance)
            familiesUpper[1]=1.0;
         if(m_state.floutAvailable && MathAbs(price-m_state.floutUpper[i])<=tolerance)
            familiesUpper[2]=1.0;
         if(m_state.asiaAvailable && MathAbs(price-m_state.asiaLower[i])<=tolerance)
            familiesLower[0]=1.0;
         if(m_state.cbdrAvailable && MathAbs(price-m_state.cbdrLower[i])<=tolerance)
            familiesLower[1]=1.0;
         if(m_state.floutAvailable && MathAbs(price-m_state.floutLower[i])<=tolerance)
            familiesLower[2]=1.0;
        }
      for(int f=0;f<3;f++)
        {
         if(familiesUpper[f]>0.0) m_state.upperConfluenceCount++;
         if(familiesLower[f]>0.0) m_state.lowerConfluenceCount++;
        }
      m_state.upperEvidenceScore=(double)m_state.upperConfluenceCount/3.0*100.0;
      m_state.lowerEvidenceScore=(double)m_state.lowerConfluenceCount/3.0*100.0;
     }

public:
                     CDailyExtremeProjectionEngine(void)
     {
      m_symbol="";
      m_asiaStartHour=0;
      m_asiaEndHour=7;
      m_cbdrStartHour=14;
      m_cbdrEndHour=20;
      m_toleranceAtrFraction=0.05;
      m_manualServerOffsetMinutes=9999;
      m_initialized=false;
      m_lastMinute=0;
      ZeroMemory(m_state);
      m_state.reason="NOT_INITIALIZED";
     }

   bool Init(const string symbol,const int asiaStartHour,const int asiaEndHour,
             const int cbdrStartHour,const int cbdrEndHour,
             const double toleranceAtrFraction=0.05,
             const int manualServerUtcOffsetMinutes=9999)
     {
      if(StringLen(symbol)==0 || asiaStartHour<0 || asiaStartHour>23 ||
         asiaEndHour<0 || asiaEndHour>23 || cbdrStartHour<0 ||
         cbdrStartHour>23 || cbdrEndHour<0 || cbdrEndHour>23 ||
         asiaStartHour==asiaEndHour || cbdrStartHour==cbdrEndHour ||
         toleranceAtrFraction<=0.0 || toleranceAtrFraction>0.5 ||
         (manualServerUtcOffsetMinutes!=9999 &&
          (manualServerUtcOffsetMinutes< -720 || manualServerUtcOffsetMinutes>840)))
        {
         m_state.reason="INVALID_CONFIGURATION";
         return(false);
        }
      m_symbol=symbol;
      m_asiaStartHour=asiaStartHour;
      m_asiaEndHour=asiaEndHour;
      m_cbdrStartHour=cbdrStartHour;
      m_cbdrEndHour=cbdrEndHour;
      m_toleranceAtrFraction=toleranceAtrFraction;
      m_manualServerOffsetMinutes=manualServerUtcOffsetMinutes;
      if(MQLInfoInteger(MQL_TESTER) && m_manualServerOffsetMinutes==9999)
        {
         m_state.reason="TESTER_REQUIRES_EXPLICIT_BROKER_UTC_OFFSET";
         return(false);
        }
      m_initialized=true;
      return(Update(true));
     }

   bool Update(const bool force=false)
     {
      if(!m_initialized) return(false);
      datetime now=TimeTradeServer();
      datetime utcNow=TimeGMT();
      if(now<=0 || utcNow<=0)
        {
         m_state.available=false;
         m_state.reason="SERVER_OR_UTC_CLOCK_UNAVAILABLE";
         return(false);
        }
      int serverOffsetSeconds=ResolveServerUtcOffset(now,utcNow);
      datetime minuteBar=iTime(m_symbol,PERIOD_M1,0);
      if(minuteBar<=0)
        {
         m_state.available=false;
         m_state.reason="M1_TIME_UNAVAILABLE";
         return(false);
        }
      if(!force && minuteBar==m_lastMinute) return(false);
      m_lastMinute=minuteBar;

      ZeroMemory(m_state);
      m_state.lastUpdateBar=minuteBar;
      int nyYear=0,nyMonth=0,nyDay=0;
      CurrentNYDate(utcNow,nyYear,nyMonth,nyDay);
      datetime nyDayStart=NYLocalToServer(nyYear,nyMonth,nyDay,0,0,serverOffsetSeconds);
      m_state.brokerDayStart=nyDayStart;
      int asiaStartYear=nyYear,asiaStartMonth=nyMonth,asiaStartDay=nyDay;
      if(m_asiaEndHour<=m_asiaStartHour)
        {
         MqlDateTime previousNY;
         TimeToStruct(nyDayStart-86400,previousNY);
         asiaStartYear=previousNY.year;
         asiaStartMonth=previousNY.mon;
         asiaStartDay=previousNY.day;
        }
      datetime asiaStart=NYLocalToServer(asiaStartYear,asiaStartMonth,asiaStartDay,
                                         m_asiaStartHour,0,serverOffsetSeconds);
      datetime asiaEnd=NYLocalToServer(nyYear,nyMonth,nyDay,
                                       m_asiaEndHour,0,serverOffsetSeconds);
      datetime cbdrStart=NYLocalToServer(nyYear,nyMonth,nyDay,m_cbdrStartHour,0,serverOffsetSeconds);
      datetime cbdrEnd=NYLocalToServer(nyYear,nyMonth,nyDay,m_cbdrEndHour,0,serverOffsetSeconds);
      if(m_cbdrEndHour<=m_cbdrStartHour) cbdrEnd+=86400;

      MqlTick tick;
      if(!SymbolInfoTick(m_symbol,tick) || tick.bid<=0.0 || tick.ask<tick.bid)
        {
         m_state.reason="VALID_QUOTE_UNAVAILABLE";
         return(false);
        }
      double price=(tick.bid+tick.ask)*0.5;
      double dayBodyHigh=0.0,dayBodyLow=0.0;
      if(!ReadSession(nyDayStart,now,m_state.currentDayHigh,m_state.currentDayLow,
                      dayBodyHigh,dayBodyLow,false))
        {
         m_state.reason="NEW_YORK_DAILY_RANGE_M1_HISTORY_UNAVAILABLE";
         return(false);
        }
      m_state.currentDayHigh=MathMax(m_state.currentDayHigh,tick.ask);
      m_state.currentDayLow=MathMin(m_state.currentDayLow,tick.bid);
      m_state.adr20=0.0;
      if(ReadAdr20(m_state.adr20))
        {
         double used=m_state.currentDayHigh-m_state.currentDayLow;
         m_state.adrUsedPercent=used/m_state.adr20*100.0;
         m_state.adrRemaining=MathMax(0.0,m_state.adr20-used);
        }

      double bodyHigh=0.0,bodyLow=0.0;
      m_state.asiaComplete=(now>=asiaEnd);
      if(now>=asiaStart)
         m_state.asiaAvailable=ReadSession(asiaStart,MathMin(now,asiaEnd),
            m_state.asiaHigh,m_state.asiaLow,bodyHigh,bodyLow,false);
      if(m_state.asiaAvailable)
         m_state.asiaRange=m_state.asiaHigh-m_state.asiaLow;

      double cbdrWickHigh=0.0,cbdrWickLow=0.0;
      m_state.cbdrComplete=(now>=cbdrEnd);
      if(now>=cbdrStart)
         m_state.cbdrAvailable=ReadSession(cbdrStart,MathMin(now,cbdrEnd),
            cbdrWickHigh,cbdrWickLow,m_state.cbdrBodyHigh,m_state.cbdrBodyLow,true);
      if(m_state.cbdrAvailable)
        {
         m_state.cbdrWickHigh=cbdrWickHigh;
         m_state.cbdrWickLow=cbdrWickLow;
         m_state.cbdrBodyRange=m_state.cbdrBodyHigh-m_state.cbdrBodyLow;
         m_state.floutHigh=MathMax(m_state.asiaHigh,m_state.cbdrWickHigh);
         m_state.floutLow=MathMin(m_state.asiaLow,m_state.cbdrWickLow);
         m_state.floutMidpoint=(m_state.floutHigh+m_state.floutLow)*0.5;
         m_state.floutHalfRange=(m_state.floutHigh-m_state.floutLow)*0.5;
         m_state.floutAvailable=(m_state.asiaAvailable && m_state.asiaComplete &&
                                 m_state.cbdrComplete && m_state.floutHalfRange>0.0);
        }

      BuildProjections();
      double tickSize=SymbolInfoDouble(m_symbol,SYMBOL_TRADE_TICK_SIZE);
      double tolerance=MathMax(tickSize*2.0,m_state.adr20*m_toleranceAtrFraction);
      if(tolerance<=0.0) tolerance=MathMax(tickSize*2.0,(m_state.asiaRange+m_state.cbdrBodyRange)*0.01);
      ScoreProjectionClusters(price,tolerance);
      m_state.available=(m_state.asiaAvailable || m_state.cbdrAvailable);
      m_state.reason=StringFormat("NY=%04d-%02d-%02d NYUTC=%d SERVERUTC=%dmin ASIA=%s/%s H=%.5f L=%.5f CBDR=%s/%s bodyH=%.5f bodyL=%.5f FLOUT=%s mid=%.5f half=%.5f ADR20=%.5f used=%.1f%% remaining=%.5f nearestUpper=%.5f upperFamilies=%d nearestLower=%.5f lowerFamilies=%d",
         nyYear,nyMonth,nyDay,NYUtcOffsetHours(utcNow),serverOffsetSeconds/60,
         m_state.asiaAvailable?"READY":"N/A",m_state.asiaComplete?"COMPLETE":"FORMING",
         m_state.asiaHigh,m_state.asiaLow,
         m_state.cbdrAvailable?"READY":"N/A",m_state.cbdrComplete?"COMPLETE":"FORMING",
         m_state.cbdrBodyHigh,m_state.cbdrBodyLow,
         m_state.floutAvailable?"READY":"WAITING",m_state.floutMidpoint,m_state.floutHalfRange,
         m_state.adr20,m_state.adrUsedPercent,m_state.adrRemaining,
         m_state.nearestUpperProjection,m_state.upperConfluenceCount,
         m_state.nearestLowerProjection,m_state.lowerConfluenceCount);
      return(m_state.available);
     }

   SAxDailyExtremeProjection Snapshot(void) const { return(m_state); }
   string Summary(void) const { return(m_state.reason); }
  };

#endif // AX_DAILYEXTREMEPROJECTIONENGINE_MQH
