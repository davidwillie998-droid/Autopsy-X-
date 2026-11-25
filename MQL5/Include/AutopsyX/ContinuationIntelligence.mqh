//+------------------------------------------------------------------+
//| ContinuationIntelligence.mqh                                     |
//| VWAP pullback + ADX, completed overnight bias, twin continuation |
//| Evidence only: no order, stop, sizing, or risk authority.         |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_CONTINUATIONINTELLIGENCE_MQH
#define AX_CONTINUATIONINTELLIGENCE_MQH
#include "Defs.mqh"

struct SAxContinuationSnapshot
  {
   bool available;
   datetime barTime;
   double adx;
   double plusDI;
   double minusDI;
   ENUM_AX_DIR vwapPullbackDirection;
   double vwapPullbackScore;
   ENUM_AX_DIR overnightBias;
   double overnightBiasScore;
   double overnightHigh;
   double overnightLow;
   datetime overnightStart;
   datetime overnightEnd;
   int overnightBars;
   ENUM_AX_DIR twinDirection;
   double twinContinuationScore;
   string state;
   string reason;
  };

class CContinuationIntelligence
  {
private:
   string m_symbol;
   ENUM_TIMEFRAMES m_tf;
   int m_adxPeriod;
   int m_adxHandle;
   int m_overnightStartHour;
   int m_overnightEndHour;
   datetime m_lastBar;
   SAxContinuationSnapshot m_read;

   void Reset(void)
     {
      m_read.available=false;
      m_read.barTime=0;
      m_read.adx=0.0;
      m_read.plusDI=0.0;
      m_read.minusDI=0.0;
      m_read.vwapPullbackDirection=AX_DIR_NONE;
      m_read.vwapPullbackScore=0.0;
      m_read.overnightBias=AX_DIR_NONE;
      m_read.overnightBiasScore=0.0;
      m_read.overnightHigh=0.0;
      m_read.overnightLow=0.0;
      m_read.overnightStart=0;
      m_read.overnightEnd=0;
      m_read.overnightBars=0;
      m_read.twinDirection=AX_DIR_NONE;
      m_read.twinContinuationScore=0.0;
      m_read.state="UNAVAILABLE";
      m_read.reason="NOT_EVALUATED";
     }

   datetime DayStart(const datetime when) const
     {
      MqlDateTime d;
      if(!TimeToStruct(when,d)) return(0);
      d.hour=0; d.min=0; d.sec=0;
      return(StructToTime(d));
     }

   bool BuildCompletedOvernight(const datetime now,const int startHour,const int endHour,
                                double &high,double &low,double &openPrice,double &closePrice,
                                datetime &start,datetime &finish,int &bars) const
     {
      high=0.0; low=0.0; openPrice=0.0; closePrice=0.0;
      start=0; finish=0; bars=0;
      if(now<=0 || startHour<0 || startHour>23 || endHour<0 || endHour>23 ||
         startHour==endHour)
         return(false);

      datetime today=DayStart(now);
      if(today<=0) return(false);
      finish=today+(datetime)(endHour*3600);
      if(now<finish) finish-=86400;
      start=finish-86400+(datetime)(startHour*3600);
      if(start>=finish) return(false);

      MqlRates session[];
      ArraySetAsSeries(session,true);
      int copied=CopyRates(m_symbol,PERIOD_M1,start,finish-1,session);
      // Missing history or a very sparse session is not promoted into a directional bias.
      if(copied<30) return(false);

      high=-DBL_MAX;
      low=DBL_MAX;
      for(int i=0;i<copied;i++)
        {
         if(session[i].high>high) high=session[i].high;
         if(session[i].low<low) low=session[i].low;
        }
      if(high<=0.0 || low<=0.0 || high<=low) return(false);

      // CopyRates physical order is oldest-to-newest; the first and last timestamps
      // are checked against the requested interval to reject partial history windows.
      int oldest=copied-1;
      if(session[oldest].time>start+1800 || session[0].time<finish-1800)
         return(false);
      openPrice=session[oldest].open;
      closePrice=session[0].close;
      bars=copied;
      return(openPrice>0.0 && closePrice>0.0);
     }

public:
                     CContinuationIntelligence(void)
     {
      m_adxHandle=INVALID_HANDLE;
      m_adxPeriod=14;
      m_overnightStartHour=22;
      m_overnightEndHour=7;
      m_lastBar=0;
      Reset();
     }

   bool Init(const string symbol,const ENUM_TIMEFRAMES tf,const int adxPeriod=14)
     {
      Deinit();
      m_symbol=symbol;
      m_tf=tf;
      m_adxPeriod=MathMax(2,adxPeriod);
      m_adxHandle=iADX(m_symbol,m_tf,m_adxPeriod);
      m_lastBar=0;
      Reset();
      return(m_adxHandle!=INVALID_HANDLE);
     }

   void ConfigureOvernight(const int startHour,const int endHour)
     {
      m_overnightStartHour=(int)AxClampD(startHour,0,23);
      m_overnightEndHour=(int)AxClampD(endHour,0,23);
     }

   void Deinit(void)
     {
      if(m_adxHandle!=INVALID_HANDLE) IndicatorRelease(m_adxHandle);
      m_adxHandle=INVALID_HANDLE;
     }

   bool Update(const datetime serverTime,const double vwap,const double atr,
               const string vwapTrend,const bool force=false)
     {
      if(m_adxHandle==INVALID_HANDLE || serverTime<=0) return(false);
      datetime barTime=iTime(m_symbol,m_tf,1);
      if(barTime<=0 || (!force && barTime==m_lastBar)) return(false);

      double adx[],plus[],minus[];
      ArraySetAsSeries(adx,true);
      ArraySetAsSeries(plus,true);
      ArraySetAsSeries(minus,true);
      MqlRates rates[];
      ArraySetAsSeries(rates,true);
      if(CopyBuffer(m_adxHandle,0,1,3,adx)!=3 ||
         CopyBuffer(m_adxHandle,1,1,3,plus)!=3 ||
         CopyBuffer(m_adxHandle,2,1,3,minus)!=3 ||
         CopyRates(m_symbol,m_tf,1,4,rates)!=4)
        {
         Reset();
         m_read.reason="ADX_OR_PRICE_HISTORY_INCOMPLETE";
         return(false);
        }
      for(int i=0;i<3;i++)
         if(!MathIsValidNumber(adx[i]) || !MathIsValidNumber(plus[i]) ||
            !MathIsValidNumber(minus[i]) || adx[i]<0.0 || plus[i]<0.0 || minus[i]<0.0)
           {
            Reset();
            m_read.reason="ADX_DATA_INVALID";
            return(false);
           }

      m_read.available=true;
      m_read.barTime=barTime;
      m_read.adx=adx[0];
      m_read.plusDI=plus[0];
      m_read.minusDI=minus[0];
      m_read.state="OBSERVATION_READY";
      m_read.reason="VALID_CLOSED_BAR_DATA";

      // VWAP pullback: a prior bar touches the VWAP area; the latest closed bar
      // must reclaim the touch-bar extreme in the original direction. ADX is a
      // strength filter; +DI/-DI supply direction. No forming-bar data is used.
      if(vwap>0.0 && atr>0.0 && MathIsValidNumber(atr))
        {
         double zone=atr*0.25;
         bool adxTrend=(adx[0]>=20.0 && adx[0]>=adx[1]);
         bool bullishDI=(plus[0]>minus[0]);
         bool bearishDI=(minus[0]>plus[0]);
         bool bullTouch=(rates[1].low<=vwap+zone && rates[1].close>=vwap-zone);
         bool bearTouch=(rates[1].high>=vwap-zone && rates[1].close<=vwap+zone);
         bool bullResume=(rates[0].close>rates[1].high && rates[0].close>rates[0].open);
         bool bearResume=(rates[0].close<rates[1].low && rates[0].close<rates[0].open);
         if(vwapTrend=="BULLISH" && adxTrend && bullishDI && bullTouch && bullResume)
           {
            m_read.vwapPullbackDirection=AX_DIR_BUY;
            m_read.vwapPullbackScore=AxClampD(55.0+(adx[0]-20.0)*1.5,0.0,90.0);
           }
         else if(vwapTrend=="BEARISH" && adxTrend && bearishDI && bearTouch && bearResume)
           {
            m_read.vwapPullbackDirection=AX_DIR_SELL;
            m_read.vwapPullbackScore=AxClampD(55.0+(adx[0]-20.0)*1.5,0.0,90.0);
           }
        }

      // Overnight bias is derived only from a completed broker-server session.
      double onOpen=0.0,onClose=0.0;
      if(BuildCompletedOvernight(serverTime,m_overnightStartHour,m_overnightEndHour,
                                 m_read.overnightHigh,m_read.overnightLow,onOpen,onClose,
                                 m_read.overnightStart,m_read.overnightEnd,m_read.overnightBars))
        {
         double mid=(m_read.overnightHigh+m_read.overnightLow)*0.5;
         double width=m_read.overnightHigh-m_read.overnightLow;
         if(width>0.0)
           {
            double location=(onClose-mid)/width;
            double displacement=(onClose-onOpen)/width;
            if(location>0.15 && displacement>0.05)
              {
               m_read.overnightBias=AX_DIR_BUY;
               m_read.overnightBiasScore=AxClampD(50.0+MathAbs(location)*35.0+MathAbs(displacement)*15.0,0.0,90.0);
              }
            else if(location< -0.15 && displacement< -0.05)
              {
               m_read.overnightBias=AX_DIR_SELL;
               m_read.overnightBiasScore=AxClampD(50.0+MathAbs(location)*35.0+MathAbs(displacement)*15.0,0.0,90.0);
              }
           }
        }

      // Twin continuation is an explicitly defined AUTOPSY X pattern, not a
      // claimed industry-standard name: impulse -> controlled retracement ->
      // second impulse through the retracement extreme on a completed candle.
      double range2=rates[2].high-rates[2].low;
      double body2=MathAbs(rates[2].close-rates[2].open);
      double range0=rates[0].high-rates[0].low;
      if(atr>0.0 && range2>0.0 && range0>0.0)
        {
         bool firstBull=(rates[2].close>rates[2].open && body2>=atr*0.45 &&
                         (rates[2].high-rates[2].close)<=range2*0.30);
         bool pullbackBull=(rates[1].close<rates[1].open &&
                            rates[1].low>rates[2].low &&
                            rates[1].close>rates[2].open);
         bool secondBull=(rates[0].close>rates[0].open &&
                          rates[0].close>rates[1].high &&
                          rates[0].close>rates[2].close);
         bool firstBear=(rates[2].close<rates[2].open && body2>=atr*0.45 &&
                         (rates[2].close-rates[2].low)<=range2*0.30);
         bool pullbackBear=(rates[1].close>rates[1].open &&
                            rates[1].high<rates[2].high &&
                            rates[1].close<rates[2].open);
         bool secondBear=(rates[0].close<rates[0].open &&
                          rates[0].close<rates[1].low &&
                          rates[0].close<rates[2].close);
         if(firstBull && pullbackBull && secondBull && plus[0]>minus[0] && adx[0]>=20.0)
           {
            m_read.twinDirection=AX_DIR_BUY;
            m_read.twinContinuationScore=AxClampD(60.0+(adx[0]-20.0),0.0,90.0);
           }
         else if(firstBear && pullbackBear && secondBear && minus[0]>plus[0] && adx[0]>=20.0)
           {
            m_read.twinDirection=AX_DIR_SELL;
            m_read.twinContinuationScore=AxClampD(60.0+(adx[0]-20.0),0.0,90.0);
           }
        }

      m_lastBar=barTime;
      return(true);
     }

   SAxContinuationSnapshot Read(void) const { return(m_read); }

   string Summary(void) const
     {
      return(StringFormat("ADX=%.1f +DI=%.1f -DI=%.1f VWAPPB=%s/%.1f ON=%s/%.1f TWIN=%s/%.1f overnightBars=%d",
         m_read.adx,m_read.plusDI,m_read.minusDI,
         AxDirToString(m_read.vwapPullbackDirection),m_read.vwapPullbackScore,
         AxDirToString(m_read.overnightBias),m_read.overnightBiasScore,
         AxDirToString(m_read.twinDirection),m_read.twinContinuationScore,
         m_read.overnightBars));
     }
  };
#endif
