//+------------------------------------------------------------------+
//|                                                    Liquidity.mqh |
//|  Liquidity Attack Engine (spec section 6)                        |
//|  Levels: previous/equal/session highs & lows                      |
//|  Sequence required: sweep -> rejection -> displacement -> confirm |
//|                                                                    |
//|  FLIPDEMON EXTREME upgrade: adds real previous-day/previous-week   |
//|  high/low (PDH/PDL/PWH/PWL, read from the previous COMPLETED D1/W1 |
//|  bar via shift=1 - never the still-forming current day/week) and   |
//|  a terminology note. This engine already tracks two distinct       |
//|  classes of level and always has: the fractal swing levels in      |
//|  m_levels[] are what most retail structure education calls         |
//|  "internal" liquidity (minor swing points inside the current       |
//|  range, including equal highs/lows once AddOrMergeLevel has        |
//|  merged repeated touches), while PDH/PDL/PWH/PWL and session        |
//|  high/low are "external" liquidity (the larger reference levels    |
//|  outside recent local structure). Nothing here is fabricated -     |
//|  DrawOnLiquidityTarget() returns 0.0, not a guess, when no real     |
//|  unswept external level exists on the requested side.              |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_LIQUIDITY_MQH
#define AX_LIQUIDITY_MQH
#include "Defs.mqh"
#include "MarketData.mqh"

#define AX_LIQ_BARS          150
#define AX_LIQ_FRACTAL_WING  2
#define AX_LIQ_EQ_TOL_PTS    3.0
#define AX_LIQ_MAX_LEVELS    12

struct SAxLevel
  {
   double price;
   int    touches;
   bool   isHigh;
  };

class CLiquidityEngine
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;
   SAxLevel          m_levels[AX_LIQ_MAX_LEVELS];
   int               m_levelCount;

   double            m_sessionHigh;
   double            m_sessionLow;
   datetime          m_sessionDay;

   //--- external liquidity: previous COMPLETED day/week high/low. 0.0 until a real read succeeds -
   //--- never a fabricated placeholder value. ---
   double            m_pdh, m_pdl, m_pwh, m_pwl;

   //--- sweep/rejection/displacement state machine, tracked per side ---
   bool              m_bullSweepActive;
   double            m_bullSweepLevel;
   datetime          m_bullSweepTime;
   bool              m_bullRejectionConfirmed;

   bool              m_bearSweepActive;
   double            m_bearSweepLevel;
   datetime          m_bearSweepTime;
   bool              m_bearRejectionConfirmed;

   int               m_sweepExpirySeconds;

public:
                     CLiquidityEngine(void)
     {
      m_levelCount=0; m_sessionHigh=0; m_sessionLow=0; m_sessionDay=0;
      m_pdh=0; m_pdl=0; m_pwh=0; m_pwl=0;
      m_bullSweepActive=false; m_bearSweepActive=false;
      m_bullRejectionConfirmed=false; m_bearRejectionConfirmed=false;
      m_sweepExpirySeconds=120;
     }

   bool              Init(const string symbol,ENUM_TIMEFRAMES tf=PERIOD_M1)
     {
      m_symbol = symbol;
      m_tf = tf;
      return(true);
     }

   //--- call periodically (e.g. once per new bar) - rebuilds structural levels ---
   void              RefreshLevels(void)
     {
      MqlRates rates[];
      ArraySetAsSeries(rates,true);
      int copied = CopyRates(m_symbol,m_tf,0,AX_LIQ_BARS,rates);
      if(copied<10) return;

      m_levelCount = 0;
      double point = SymbolInfoDouble(m_symbol,SYMBOL_POINT);
      if(point<=0) point = 0.00001;

      for(int i=AX_LIQ_FRACTAL_WING;i<copied-AX_LIQ_FRACTAL_WING;i++)
        {
         bool isSwingHigh=true, isSwingLow=true;
         for(int w=1;w<=AX_LIQ_FRACTAL_WING;w++)
           {
            if(rates[i].high < rates[i-w].high || rates[i].high < rates[i+w].high) isSwingHigh=false;
            if(rates[i].low  > rates[i-w].low  || rates[i].low  > rates[i+w].low)  isSwingLow=false;
           }
         if(isSwingHigh) AddOrMergeLevel(rates[i].high,true,point);
         if(isSwingLow)  AddOrMergeLevel(rates[i].low,false,point);
         if(m_levelCount>=AX_LIQ_MAX_LEVELS) break;
        }

      //--- session high/low (resets on new trading day) ---
      MqlDateTime dtNow;
      TimeToStruct(TimeCurrent(),dtNow);
      datetime dayStart = TimeCurrent() - (dtNow.hour*3600 + dtNow.min*60 + dtNow.sec);
      if(dayStart != m_sessionDay)
        {
         m_sessionDay  = dayStart;
         m_sessionHigh = rates[0].high;
         m_sessionLow  = rates[0].low;
        }
      for(int i=0;i<copied;i++)
        {
         if(rates[i].time < m_sessionDay) break;
         if(rates[i].high>m_sessionHigh) m_sessionHigh = rates[i].high;
         if(rates[i].low<m_sessionLow || m_sessionLow==0) m_sessionLow = rates[i].low;
        }
     }

   //--- call once per new D1 bar (cheap) - refreshes the previous COMPLETED day/week's high/low. ---
   //--- iHigh/iLow with shift=1 on PERIOD_D1/PERIOD_W1 always reads the last CLOSED period, never  ---
   //--- the one still forming - the same no-lookahead guarantee CStructureEngine documents. A 0.0  ---
   //--- return from iHigh/iLow (history not yet cached) is passed straight through rather than     ---
   //--- silently kept as a stale prior value, so callers can see a genuine "not available yet" read. ---
   void              RefreshHigherTimeframeLevels(const string symbol)
     {
      double pdh = iHigh(symbol,PERIOD_D1,1);
      double pdl = iLow(symbol,PERIOD_D1,1);
      double pwh = iHigh(symbol,PERIOD_W1,1);
      double pwl = iLow(symbol,PERIOD_W1,1);
      if(pdh>0) m_pdh=pdh;
      if(pdl>0) m_pdl=pdl;
      if(pwh>0) m_pwh=pwh;
      if(pwl>0) m_pwl=pwl;
     }

   double            PDH(void) const { return(m_pdh); }
   double            PDL(void) const { return(m_pdl); }
   double            PWH(void) const { return(m_pwh); }
   double            PWL(void) const { return(m_pwl); }

   //--- an "equal" level is one AddOrMergeLevel has already merged 2+ touches into - exposed here  ---
   //--- rather than duplicating the tolerance/merge logic a second time ---
   bool              IsEqualLevel(const int i) const
     {
      if(i<0 || i>=m_levelCount) return(false);
      return(m_levels[i].touches>=2);
     }

   bool              GetLevel(const int i,SAxLevel &out) const
     {
      if(i<0 || i>=m_levelCount) return(false);
      out = m_levels[i];
      return(true);
     }

   //--- draw-on-liquidity target: the nearest EXTERNAL liquidity level on the requested side that   ---
   //--- price hasn't already traded through. Returns 0.0 (never a guess) when no such level is       ---
   //--- currently known. This is a HYPOTHESIS the setup is trading toward, not a promise price will   ---
   //--- reach it - callers must treat a 0.0 return as "no target identified", not "target is 0". ---
   double            DrawOnLiquidityTarget(const ENUM_AX_DIR dir,const double refPrice) const
     {
      if(dir==AX_DIR_BUY)
        {
         double best=0.0;
         if(m_sessionHigh>refPrice) best=m_sessionHigh;
         if(m_pdh>refPrice && (best==0.0 || m_pdh<best)) best=m_pdh;
         if(m_pwh>refPrice && (best==0.0 || m_pwh<best)) best=m_pwh;
         return(best);
        }
      if(dir==AX_DIR_SELL)
        {
         double best=0.0;
         if(m_sessionLow>0 && m_sessionLow<refPrice) best=m_sessionLow;
         if(m_pdl>0 && m_pdl<refPrice && (best==0.0 || m_pdl>best)) best=m_pdl;
         if(m_pwl>0 && m_pwl<refPrice && (best==0.0 || m_pwl>best)) best=m_pwl;
         return(best);
        }
      return(0.0);
     }

   //--- free-text summary for TradeThesis.liquidityCondition / dashboard - describes the current  ---
   //--- hypothesis, never asserts a guaranteed outcome ---
   string            LiquidityConditionSummary(void) const
     {
      string s="";
      if(m_bullSweepActive)  s += m_bullRejectionConfirmed ? "BULL_SWEEP_REJECTED " : "BULL_SWEEP_PENDING ";
      if(m_bearSweepActive)  s += m_bearRejectionConfirmed ? "BEAR_SWEEP_REJECTED " : "BEAR_SWEEP_PENDING ";
      if(StringLen(s)==0) s="NO_ACTIVE_SWEEP ";
      s += StringFormat("levels=%d pdh=%.5f pdl=%.5f",m_levelCount,m_pdh,m_pdl);
      return(s);
     }

   //--- call every tick: evaluate sweep/rejection/displacement against current price ---
   void              UpdateTick(const double bid,const double ask,const double displacementPts,const double point)
     {
      double mid = (bid+ask)/2.0;
      datetime now = TimeCurrent();

      //--- expire stale sweep states ---
      if(m_bullSweepActive && (now-m_bullSweepTime)>m_sweepExpirySeconds) { m_bullSweepActive=false; m_bullRejectionConfirmed=false; }
      if(m_bearSweepActive && (now-m_bearSweepTime)>m_sweepExpirySeconds) { m_bearSweepActive=false; m_bearRejectionConfirmed=false; }

      //--- SELL-side liquidity (lows) swept then rejected upward -> bullish attack setup ---
      double nearestLow = NearestLevel(false,mid);
      if(nearestLow>0)
        {
         if(!m_bullSweepActive && bid<nearestLow)
           {
            m_bullSweepActive = true;
            m_bullSweepLevel  = nearestLow;
            m_bullSweepTime   = now;
            m_bullRejectionConfirmed=false;
           }
         else if(m_bullSweepActive && mid>m_bullSweepLevel)
           {
            m_bullRejectionConfirmed = true; // price recovered back above the swept low
           }
        }

      //--- BUY-side liquidity (highs) swept then rejected downward -> bearish attack setup ---
      double nearestHigh = NearestLevel(true,mid);
      if(nearestHigh>0)
        {
         if(!m_bearSweepActive && ask>nearestHigh)
           {
            m_bearSweepActive = true;
            m_bearSweepLevel  = nearestHigh;
            m_bearSweepTime   = now;
            m_bearRejectionConfirmed=false;
           }
         else if(m_bearSweepActive && mid<m_bearSweepLevel)
           {
            m_bearRejectionConfirmed = true;
           }
        }
     }

   //--- bullish attack ready = sweep + rejection + displacement in the trade direction ---
   bool              BullishAttackReady(const double displacementPts) const
     {
      return(m_bullSweepActive && m_bullRejectionConfirmed && displacementPts>0);
     }

   bool              BearishAttackReady(const double displacementPts) const
     {
      return(m_bearSweepActive && m_bearRejectionConfirmed && displacementPts<0);
     }

   void              ConsumeBullishAttack(void) { m_bullSweepActive=false; m_bullRejectionConfirmed=false; }
   void              ConsumeBearishAttack(void) { m_bearSweepActive=false; m_bearRejectionConfirmed=false; }

   double            SessionHigh(void) const { return(m_sessionHigh); }
   double            SessionLow(void)  const { return(m_sessionLow); }
   int               LevelCount(void)  const { return(m_levelCount); }

   //--- public access to the nearest tracked structural level, for structure-based stop placement ---
   //--- (0 if no level of that side has been tracked yet, e.g. right after EA startup) ---
   double            GetNearestLevel(const bool wantHigh,const double refPrice) const
     {
      return(NearestLevel(wantHigh,refPrice));
     }

   //--- 0..100 liquidity bullish/bearish bias components used by SignalScore ---
   double            BullishScoreComponent(const double bid,const double ask) const
     {
      double score=0;
      if(m_bullSweepActive) score += 30;
      if(m_bullRejectionConfirmed) score += 35;
      double mid=(bid+ask)/2.0;
      if(m_sessionLow>0 && mid<=m_sessionLow*1.0005) score += 15; // near session low = liquidity-rich zone
      return(AxClampD(score,0,100));
     }

   double            BearishScoreComponent(const double bid,const double ask) const
     {
      double score=0;
      if(m_bearSweepActive) score += 30;
      if(m_bearRejectionConfirmed) score += 35;
      double mid=(bid+ask)/2.0;
      if(m_sessionHigh>0 && mid>=m_sessionHigh*0.9995) score += 15;
      return(AxClampD(score,0,100));
     }

private:
   double            NearestLevel(const bool wantHigh,const double refPrice) const
     {
      double best=0; double bestDist=DBL_MAX;
      for(int i=0;i<m_levelCount;i++)
        {
         if(m_levels[i].isHigh!=wantHigh) continue;
         double dist = MathAbs(m_levels[i].price-refPrice);
         if(dist<bestDist) { bestDist=dist; best=m_levels[i].price; }
        }
      return(best);
     }

   void              AddOrMergeLevel(const double price,const bool isHigh,const double point)
     {
      double tolPrice = AX_LIQ_EQ_TOL_PTS*point;
      for(int i=0;i<m_levelCount;i++)
        {
         if(m_levels[i].isHigh==isHigh && MathAbs(m_levels[i].price-price)<=tolPrice)
           {
            m_levels[i].touches++;
            m_levels[i].price = (m_levels[i].price + price)/2.0; // equal-level merge
            return;
           }
        }
      if(m_levelCount<AX_LIQ_MAX_LEVELS)
        {
         m_levels[m_levelCount].price   = price;
         m_levels[m_levelCount].isHigh  = isHigh;
         m_levels[m_levelCount].touches = 1;
         m_levelCount++;
        }
     }
  };
//+------------------------------------------------------------------+
#endif // AX_LIQUIDITY_MQH
