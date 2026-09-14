//+------------------------------------------------------------------+
//| OrderFlowEngine.mqh                                                |
//| Real tick-level volume profile, cumulative delta, delta           |
//| divergence, absorption, and a tape-tempo "pulse" score.           |
//|                                                                    |
//| Honesty matters more here than anywhere else in the codebase:     |
//| most retail FX/CFD feeds report quote ticks (bid/ask), not real   |
//| trade prints with a buy/sell side. When the broker's feed carries |
//| TICK_FLAG_BUY/TICK_FLAG_SELL (true aggressor side - common on     |
//| exchange-traded CFDs/futures-style symbols, rare on spot FX) this |
//| is real footprint data. Otherwise every delta figure here is the  |
//| classic "tick rule" approximation (an uptick is treated as buy    |
//| pressure, a downtick as sell pressure) - directionally useful,    |
//| but not a substitute for a real trade-and-sales feed. Which mode  |
//| built the current numbers is always queryable, never hidden.      |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_INTELLIGENCE_ORDERFLOWENGINE_MQH
#define AX_INTELLIGENCE_ORDERFLOWENGINE_MQH
#include "../core/Types.mqh"

#define AX_OF_MAX_BAR_DELTA 64

struct AXVolumeNode
  {
   double price;
   double volume;
   double buyVolume;
   double sellVolume;
  };

class COrderFlowEngine
  {
private:
   string   m_symbol;
   int      m_buckets;
   int      m_lookbackHours;
   int      m_maxTicks;
   int      m_refreshSeconds;

   AXVolumeNode m_profile[];
   double   m_poc, m_vah, m_val, m_rangeHigh, m_rangeLow;
   double   m_cumulativeDelta;
   double   m_totalVolume;

   datetime m_barDeltaTime[AX_OF_MAX_BAR_DELTA]; // index 0 = most recently completed H1 bar
   double   m_barDelta[AX_OF_MAX_BAR_DELTA];
   double   m_barVolume[AX_OF_MAX_BAR_DELTA];
   int      m_barDeltaCount;

   double   m_pulseScore;
   bool     m_dataAvailable;
   bool     m_builtFromTicks;
   bool     m_hasTradeSideFlags;
   bool     m_hasRealVolume;
   int      m_ticksAnalyzed;
   datetime m_lastRefresh;

public:
   void Init(const string symbol, int lookbackHours=6, int buckets=48, int maxTicks=150000, int refreshSeconds=90)
     {
      m_symbol=symbol;
      m_lookbackHours=MathMax(1,lookbackHours);
      m_buckets=MathMax(10,buckets);
      m_maxTicks=MathMax(1000,maxTicks);
      m_refreshSeconds=MathMax(15,refreshSeconds);
      m_dataAvailable=false; m_builtFromTicks=false; m_hasTradeSideFlags=false; m_hasRealVolume=false;
      m_lastRefresh=0; m_barDeltaCount=0; m_cumulativeDelta=0.0; m_totalVolume=0.0;
      m_poc=0.0; m_vah=0.0; m_val=0.0; m_rangeHigh=0.0; m_rangeLow=0.0; m_pulseScore=50.0; m_ticksAnalyzed=0;
     }

   //--- throttled: this pulls real tick history, so it must not run on every tick
   void Refresh()
     {
      if(TimeCurrent()-m_lastRefresh < m_refreshSeconds) return;
      m_lastRefresh = TimeCurrent();
      BuildFromTicks();
     }

   bool   DataAvailable() const      { return m_dataAvailable; }
   bool   BuiltFromRealTicks() const { return m_builtFromTicks; }
   bool   HasRealTradeFlags() const  { return m_hasTradeSideFlags; }
   bool   HasRealVolume() const      { return m_hasRealVolume; }
   int    TicksAnalyzed() const      { return m_ticksAnalyzed; }

   double POC() const { return m_poc; }
   double VAH() const { return m_vah; }
   double VAL() const { return m_val; }
   bool   InValueArea(double price) const { return m_dataAvailable && price>=m_val && price<=m_vah; }

   double VolumeAtPrice(double price) const
     {
      int n=ArraySize(m_profile);
      if(n==0 || m_rangeHigh<=m_rangeLow) return 0.0;
      double step=(m_rangeHigh-m_rangeLow)/n;
      int b=(int)((price-m_rangeLow)/step);
      if(b<0 || b>=n) return 0.0;
      return m_profile[b].volume;
     }

   double CumulativeDelta() const { return m_cumulativeDelta; }

   //--- price trended one way over the last N completed H1 bars while net delta over the same window
   //--- disagreed - a real order-flow divergence signal, not a lagging price-pattern guess
   bool HasBearishDivergence(int lookbackBars=5) const
     {
      if(!m_dataAvailable || m_barDeltaCount<2) return false;
      int n = MathMin(lookbackBars, m_barDeltaCount-1);
      double priceMove = iClose(m_symbol,PERIOD_H1,1) - iClose(m_symbol,PERIOD_H1,1+n);
      return priceMove>0.0 && SumRecentDelta(n)<0.0;
     }

   bool HasBullishDivergence(int lookbackBars=5) const
     {
      if(!m_dataAvailable || m_barDeltaCount<2) return false;
      int n = MathMin(lookbackBars, m_barDeltaCount-1);
      double priceMove = iClose(m_symbol,PERIOD_H1,1) - iClose(m_symbol,PERIOD_H1,1+n);
      return priceMove<0.0 && SumRecentDelta(n)>0.0;
     }

   //--- large one-sided delta on the most recently completed bar that failed to move price - absorption.
   //--- +1 = buyers being absorbed here (bearish tell), -1 = sellers being absorbed (bullish tell), 0 = none
   int AbsorptionDirection() const
     {
      if(!m_dataAvailable || m_barDeltaCount<6) return 0;
      double avgVol=0.0;
      for(int i=1;i<6;i++) avgVol+=m_barVolume[i];
      avgVol/=5.0;
      if(avgVol<=0.0) return 0;

      double avgRange=0.0;
      for(int i=2;i<7;i++) avgRange += (iHigh(m_symbol,PERIOD_H1,i)-iLow(m_symbol,PERIOD_H1,i));
      avgRange/=5.0;
      if(avgRange<=0.0) return 0;

      double lastVol   = m_barVolume[0];
      double lastDelta = m_barDelta[0];
      double lastRange = iHigh(m_symbol,PERIOD_H1,1)-iLow(m_symbol,PERIOD_H1,1);

      bool highVolume = lastVol > avgVol*1.6;
      bool smallRange = lastRange < avgRange*0.6;
      if(!highVolume || !smallRange) return 0;
      return lastDelta>0.0 ? 1 : (lastDelta<0.0 ? -1 : 0);
     }

   double PulseScore() const { return m_pulseScore; }
   string PulseState() const
     {
      if(m_pulseScore>=80.0) return "Surging";
      if(m_pulseScore>=60.0) return "Elevated";
      if(m_pulseScore>=35.0) return "Normal";
      return "Quiet";
     }

private:
   double SumRecentDelta(int bars) const
     {
      double sum=0.0;
      for(int i=0;i<bars && i<m_barDeltaCount;i++) sum+=m_barDelta[i];
      return sum;
     }

   void ClassifyTick(const MqlTick &t, double &price, double &vol, int &side, double prevPrice) const
     {
      price = ((t.flags & TICK_FLAG_LAST)!=0 && t.last>0.0) ? t.last : (t.bid+t.ask)/2.0;
      vol = t.volume_real>0.0 ? t.volume_real : (t.volume>0 ? (double)t.volume : 1.0);
      if((t.flags & TICK_FLAG_BUY)!=0) side=1;
      else if((t.flags & TICK_FLAG_SELL)!=0) side=-1;
      else if(prevPrice>0.0) side = price>prevPrice ? 1 : (price<prevPrice ? -1 : 0);
      else side=0;
     }

   void BuildFromTicks()
     {
      MqlTick ticks[];
      datetime toTime = TimeCurrent();
      datetime fromTime = toTime - m_lookbackHours*3600;
      ulong fromMsc = (ulong)fromTime*1000;
      ulong toMsc   = (ulong)toTime*1000;

      int copied = CopyTicksRange(m_symbol, ticks, COPY_TICKS_ALL, fromMsc, toMsc);
      if(copied<=0) { BuildFromBarsFallback(); return; }

      int startIdx = (copied>m_maxTicks) ? copied-m_maxTicks : 0; // keep the most recent slice if there's too much
      m_ticksAnalyzed = copied-startIdx;

      double hi=-DBL_MAX, lo=DBL_MAX;
      bool sawTradeFlag=false, sawRealVolume=false;
      for(int i=startIdx;i<copied;i++)
        {
         double p = ((ticks[i].flags & TICK_FLAG_LAST)!=0 && ticks[i].last>0.0) ? ticks[i].last : (ticks[i].bid+ticks[i].ask)/2.0;
         if(p<=0.0) continue;
         hi=MathMax(hi,p); lo=MathMin(lo,p);
         if((ticks[i].flags & (TICK_FLAG_BUY|TICK_FLAG_SELL))!=0) sawTradeFlag=true;
         if(ticks[i].volume_real>0.0) sawRealVolume=true;
        }
      if(hi==-DBL_MAX || lo==DBL_MAX || hi<=lo) { BuildFromBarsFallback(); return; }

      m_hasTradeSideFlags=sawTradeFlag; m_hasRealVolume=sawRealVolume;
      m_rangeHigh=hi; m_rangeLow=lo;

      ArrayResize(m_profile, m_buckets);
      double step=(hi-lo)/m_buckets;
      for(int b=0;b<m_buckets;b++)
        { m_profile[b].price=lo+step*(b+0.5); m_profile[b].volume=0.0; m_profile[b].buyVolume=0.0; m_profile[b].sellVolume=0.0; }

      m_cumulativeDelta=0.0; m_totalVolume=0.0;
      int h1secs = PeriodSeconds(PERIOD_H1);
      datetime localBarTimes[AX_OF_MAX_BAR_DELTA]; double localDelta[AX_OF_MAX_BAR_DELTA]; double localVolume[AX_OF_MAX_BAR_DELTA];
      int localCount=0;
      datetime curBarTime=-1; double curDelta=0.0, curVol=0.0;
      double prevPrice=0.0;

      for(int i=startIdx;i<copied;i++)
        {
         double price, vol; int side;
         ClassifyTick(ticks[i], price, vol, side, prevPrice);
         if(price<=0.0) continue;
         prevPrice=price;

         int bucket=(int)((price-lo)/step);
         bucket=MathMax(0,MathMin(m_buckets-1,bucket));
         m_profile[bucket].volume += vol;
         if(side>0) m_profile[bucket].buyVolume += vol;
         else if(side<0) m_profile[bucket].sellVolume += vol;
         m_cumulativeDelta += side*vol;
         m_totalVolume += vol;

         datetime barTime=(datetime)((long)(ticks[i].time/h1secs)*h1secs);
         if(barTime!=curBarTime)
           {
            if(curBarTime!=-1 && localCount<AX_OF_MAX_BAR_DELTA)
              { localBarTimes[localCount]=curBarTime; localDelta[localCount]=curDelta; localVolume[localCount]=curVol; localCount++; }
            curBarTime=barTime; curDelta=0.0; curVol=0.0;
           }
         curDelta += side*vol; curVol += vol;
        }
      if(curBarTime!=-1 && localCount<AX_OF_MAX_BAR_DELTA)
        { localBarTimes[localCount]=curBarTime; localDelta[localCount]=curDelta; localVolume[localCount]=curVol; localCount++; }

      m_barDeltaCount = MathMin(localCount, AX_OF_MAX_BAR_DELTA);
      for(int k=0;k<m_barDeltaCount;k++)
        {
         int srcIdx = localCount-1-k;
         m_barDeltaTime[k]=localBarTimes[srcIdx]; m_barDelta[k]=localDelta[srcIdx]; m_barVolume[k]=localVolume[srcIdx];
        }

      ComputePOCAndValueArea();
      ComputePulseFromTicks(ticks, startIdx, copied);
      m_builtFromTicks=true;
      m_dataAvailable=true;
     }

   //--- when tick history is unavailable/too sparse: approximate the profile by distributing each M5
   //--- bar's tick_volume across its High..Low span, and its "delta" by whether it closed up or down.
   //--- Directionally informative, explicitly NOT real footprint data - HasRealTradeFlags()/HasRealVolume()
   //--- and BuiltFromRealTicks() all report false so nothing downstream mistakes this for the real thing.
   void BuildFromBarsFallback()
     {
      MqlRates rates[];
      int copied = CopyRates(m_symbol, PERIOD_M5, 0, m_lookbackHours*12, rates);
      if(copied<=0) { m_dataAvailable=false; return; }
      ArraySetAsSeries(rates,true);

      double hi=-DBL_MAX, lo=DBL_MAX;
      for(int i=0;i<copied;i++) { hi=MathMax(hi,rates[i].high); lo=MathMin(lo,rates[i].low); }
      if(hi<=lo) { m_dataAvailable=false; return; }
      m_rangeHigh=hi; m_rangeLow=lo;

      ArrayResize(m_profile, m_buckets);
      double step=(hi-lo)/m_buckets;
      for(int b=0;b<m_buckets;b++)
        { m_profile[b].price=lo+step*(b+0.5); m_profile[b].volume=0.0; m_profile[b].buyVolume=0.0; m_profile[b].sellVolume=0.0; }

      m_cumulativeDelta=0.0; m_totalVolume=0.0;
      int h1secs = PeriodSeconds(PERIOD_H1);
      datetime localBarTimes[AX_OF_MAX_BAR_DELTA]; double localDelta[AX_OF_MAX_BAR_DELTA]; double localVolume[AX_OF_MAX_BAR_DELTA];
      int localCount=0;
      datetime curBarTime=-1; double curDelta=0.0, curVol=0.0;

      for(int i=copied-1;i>=0;i--) // rates[] is newest-first; walk oldest -> newest
        {
         double barVol=(double)rates[i].tick_volume;
         bool barUp = rates[i].close>=rates[i].open;
         if(rates[i].high>rates[i].low)
           {
            int loBucket=(int)((rates[i].low-lo)/step), hiBucket=(int)((rates[i].high-lo)/step);
            loBucket=MathMax(0,MathMin(m_buckets-1,loBucket)); hiBucket=MathMax(0,MathMin(m_buckets-1,hiBucket));
            int span=hiBucket-loBucket+1; double perBucket=barVol/span;
            for(int b=loBucket;b<=hiBucket;b++)
              { m_profile[b].volume+=perBucket; if(barUp) m_profile[b].buyVolume+=perBucket; else m_profile[b].sellVolume+=perBucket; }
           }
         double delta = barUp ? barVol : -barVol;
         m_cumulativeDelta += delta; m_totalVolume += barVol;

         datetime barTime=(datetime)((long)(rates[i].time/h1secs)*h1secs);
         if(barTime!=curBarTime)
           {
            if(curBarTime!=-1 && localCount<AX_OF_MAX_BAR_DELTA)
              { localBarTimes[localCount]=curBarTime; localDelta[localCount]=curDelta; localVolume[localCount]=curVol; localCount++; }
            curBarTime=barTime; curDelta=0.0; curVol=0.0;
           }
         curDelta += delta; curVol += barVol;
        }
      if(curBarTime!=-1 && localCount<AX_OF_MAX_BAR_DELTA)
        { localBarTimes[localCount]=curBarTime; localDelta[localCount]=curDelta; localVolume[localCount]=curVol; localCount++; }

      m_barDeltaCount = MathMin(localCount, AX_OF_MAX_BAR_DELTA);
      for(int k=0;k<m_barDeltaCount;k++)
        {
         int srcIdx = localCount-1-k;
         m_barDeltaTime[k]=localBarTimes[srcIdx]; m_barDelta[k]=localDelta[srcIdx]; m_barVolume[k]=localVolume[srcIdx];
        }

      m_hasTradeSideFlags=false; m_hasRealVolume=false; m_builtFromTicks=false; m_ticksAnalyzed=0;
      ComputePOCAndValueArea();
      ComputePulseFallback();
      m_dataAvailable=true;
     }

   void ComputePOCAndValueArea()
     {
      int n=ArraySize(m_profile);
      if(n==0) { m_poc=0.0; m_vah=0.0; m_val=0.0; return; }
      int pocIdx=0; double maxVol=-1.0, totalVol=0.0;
      for(int b=0;b<n;b++) { totalVol+=m_profile[b].volume; if(m_profile[b].volume>maxVol) { maxVol=m_profile[b].volume; pocIdx=b; } }
      m_poc = m_profile[pocIdx].price;
      if(totalVol<=0.0) { m_vah=m_poc; m_val=m_poc; return; }

      double target=totalVol*0.70, accumulated=m_profile[pocIdx].volume;
      int lowIdx=pocIdx, highIdx=pocIdx;
      while(accumulated<target && (lowIdx>0 || highIdx<n-1))
        {
         double belowVol=(lowIdx>0)?m_profile[lowIdx-1].volume:-1.0;
         double aboveVol=(highIdx<n-1)?m_profile[highIdx+1].volume:-1.0;
         if(aboveVol>=belowVol && highIdx<n-1) { highIdx++; accumulated+=m_profile[highIdx].volume; }
         else if(lowIdx>0) { lowIdx--; accumulated+=m_profile[lowIdx].volume; }
         else break;
        }
      m_val=m_profile[lowIdx].price; m_vah=m_profile[highIdx].price;
     }

   //--- tape tempo (real tick arrival rate now vs this window's own average) blended with ATR-relative
   //--- price velocity - a composite intensity heuristic, not a single validated indicator
   void ComputePulseFromTicks(const MqlTick &ticks[], int startIdx, int copied)
     {
      int n=copied-startIdx;
      if(n<10) { ComputePulseFallback(); return; }
      datetime windowStart=ticks[startIdx].time, windowEnd=ticks[copied-1].time;
      double totalMinutes=MathMax(1.0,(double)(windowEnd-windowStart)/60.0);
      double avgTicksPerMin=n/totalMinutes;

      datetime recentCutoff=windowEnd-180;
      int recentCount=0;
      for(int i=copied-1;i>=startIdx;i--) { if(ticks[i].time<recentCutoff) break; recentCount++; }
      double recentTicksPerMin=recentCount/3.0;
      double rateRatio = avgTicksPerMin>0.0 ? recentTicksPerMin/avgTicksPerMin : 1.0;

      double velocityRatio = PriceVelocityRatio();
      double score = 50.0 + (rateRatio-1.0)*30.0 + (velocityRatio-1.0)*20.0;
      m_pulseScore = MathMax(0.0, MathMin(100.0, score));
     }

   void ComputePulseFallback()
     {
      double velocityRatio = PriceVelocityRatio();
      m_pulseScore = MathMax(0.0, MathMin(100.0, 50.0+(velocityRatio-1.0)*30.0));
     }

   double PriceVelocityRatio() const
     {
      double avgRange=0.0;
      for(int i=1;i<=14;i++) avgRange += (iHigh(m_symbol,PERIOD_H1,i)-iLow(m_symbol,PERIOD_H1,i));
      avgRange/=14.0;
      if(avgRange<=0.0) return 1.0;
      double curRange = iHigh(m_symbol,PERIOD_H1,0)-iLow(m_symbol,PERIOD_H1,0);
      return curRange/avgRange;
     }
  };
#endif // AX_INTELLIGENCE_ORDERFLOWENGINE_MQH
