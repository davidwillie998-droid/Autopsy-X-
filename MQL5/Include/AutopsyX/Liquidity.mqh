//+------------------------------------------------------------------+
//|                                                    Liquidity.mqh |
//|  Liquidity Attack Engine (spec section 6)                        |
//|  Levels: previous/equal/session highs & lows                      |
//|  Sequence required: sweep -> rejection -> displacement -> confirm |
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
