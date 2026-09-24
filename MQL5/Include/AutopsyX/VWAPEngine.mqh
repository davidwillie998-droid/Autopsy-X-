//+------------------------------------------------------------------+
//|                                                    VWAPEngine.mqh |
//|  VWAP Trend Engine                                                |
//|                                                                    |
//|  Based on Zarattini & Aziz, "Volume Weighted Average Price (VWAP):|
//|  The Holy Grail for Day Trading Systems" (SSRN 4631351, 2023).    |
//|  Their finding: a bar closing on one side of VWAP tends to keep   |
//|  drifting that way. Their strategy anchors VWAP to a single NYSE  |
//|  session open (9:30am) and sizes aggressively (up to 100% of      |
//|  equity) - but ONLY because every trade carries a mechanical,     |
//|  never-skipped exit the instant a bar closes on the wrong side of |
//|  VWAP, which is what bounded their realized losses to roughly     |
//|  -4% even at 3x leverage. This EA's instruments (XAUUSD, major FX)|
//|  trade 24 hours with no single session open, so VWAP here is      |
//|  either a rolling trailing-window read (no session-boundary       |
//|  assumption at all) or anchored to whichever of the four real     |
//|  FX liquidity resets (Sydney/Tokyo/London/New York) most recently |
//|  passed - never the original paper's single NYSE anchor.          |
//|                                                                    |
//|  THE ACTUAL LESSON, restated where it matters most: the aggressive|
//|  sizing this engine can unlock (see CAdaptiveFlipEngine's VWAP    |
//|  alignment bonus) is legitimate ONLY because it is paired with a  |
//|  real, unconditional exit rule (CExitEngine's VWAP mechanical     |
//|  exit) - not because "VWAP predicts direction so size up." A      |
//|  bullish VWAP read alone, without that exit rule actually armed,  |
//|  earns no sizing bonus at all. See both engines' own comments.    |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_VWAPENGINE_MQH
#define AX_VWAPENGINE_MQH
#include "Defs.mqh"

class CVWAPEngine
  {
private:
   ENUM_AX_VWAP_MODE m_mode;
   int               m_rollingBars;
   int               m_sydneyHour;    // server-time hours (0-23) - broker-dependent, verify against
   int               m_tokyoHour;     // your broker's actual server timezone before trusting these
   int               m_londonHour;
   int               m_newYorkHour;
   double            m_deadbandAtrMult;

public:
                     CVWAPEngine(void)
     {
      m_mode=AX_VWAP_ROLLING; m_rollingBars=240;
      m_sydneyHour=22; m_tokyoHour=0; m_londonHour=8; m_newYorkHour=13;
      m_deadbandAtrMult=0.1;
     }

   void              Configure(const ENUM_AX_VWAP_MODE mode,const int rollingBars,
                                const int sydneyHour,const int tokyoHour,
                                const int londonHour,const int newYorkHour,
                                const double deadbandAtrMult)
     {
      m_mode         = mode;
      m_rollingBars  = MathMax(10,rollingBars);
      m_sydneyHour   = (int)AxClampD(sydneyHour,0,23);
      m_tokyoHour    = (int)AxClampD(tokyoHour,0,23);
      m_londonHour   = (int)AxClampD(londonHour,0,23);
      m_newYorkHour  = (int)AxClampD(newYorkHour,0,23);
      m_deadbandAtrMult = MathMax(0.0,deadbandAtrMult);
     }

   //--- computed fresh from real OHLCV data every call - no caching inside this method itself, no  ---
   //--- interpolation of missing bars. The EA's own call site chooses to invoke this once per new   ---
   //--- bar (see main.mq5), the same cadence CLiquidityEngine/CRegimeEngine/CVolumeProfileEngine     ---
   //--- already use for structural reads - that is a call-CADENCE choice for tick-loop performance,  ---
   //--- not an approximation of the VWAP value itself, which is exact real data every time this runs. ---
   //--- Returns -1 ("unavailable") rather than 0 when there isn't enough real data to compute a      ---
   //--- meaningful value - callers must treat -1 as "no read", never as a price. ---
   double            GetVWAP(const string symbol,const ENUM_TIMEFRAMES tf) const
     {
      if(m_mode==AX_VWAP_SESSION_ANCHORED) return(GetSessionAnchoredVwap(symbol,tf));
      return(GetRollingVwap(symbol,tf));
     }

   //--- BULLISH/BEARISH if price sits clearly on one side of VWAP, NEUTRAL if VWAP is unavailable  ---
   //--- or price is within m_deadbandAtrMult x ATR of it (avoids flip-flopping on noise at the line) ---
   string            ClassifyVWAPTrend(const double currentClose,const double vwapValue,
                                        const double atrPrice) const
     {
      if(vwapValue<=0) return("NEUTRAL"); // -1 (unavailable) or a defensive <=0 guard either way
      double deadband = MathAbs(atrPrice)*m_deadbandAtrMult;
      if(MathAbs(currentClose-vwapValue)<=deadband) return("NEUTRAL");
      return(currentClose>vwapValue ? "BULLISH" : "BEARISH");
     }

   ENUM_AX_VWAP_MODE Mode(void) const { return(m_mode); }

private:
   double            GetRollingVwap(const string symbol,const ENUM_TIMEFRAMES tf) const
     {
      MqlRates rates[];
      ArraySetAsSeries(rates,true);
      int copied = CopyRates(symbol,tf,0,m_rollingBars,rates);
      // "insufficient bars" per Task 1: didn't get the full configured window - never silently
      // compute on a partial window pretending it's the configured one
      if(copied<m_rollingBars) return(-1);
      return(ComputeVwapFromRates(rates,copied));
     }

   //--- resets at whichever of the 4 configured FX session-open hours (server time) most recently   ---
   //--- passed - a 24-hour market has multiple genuine liquidity resets, not the original paper's    ---
   //--- single NYSE 9:30am anchor, so anchoring to just one of the four would misrepresent exactly    ---
   //--- the thing being adapted for. ---
   double            GetSessionAnchoredVwap(const string symbol,const ENUM_TIMEFRAMES tf) const
     {
      datetime anchor = FindSessionAnchor(TimeCurrent());
      MqlRates rates[];
      ArraySetAsSeries(rates,true);
      int copied = CopyRates(symbol,tf,anchor,TimeCurrent(),rates);
      // a session anchor can be minutes old right after a reset - require at least a couple of real
      // bars before trusting the read, rather than computing VWAP off a single just-formed bar
      if(copied<2) return(-1);
      return(ComputeVwapFromRates(rates,copied));
     }

   datetime          FindSessionAnchor(const datetime now) const
     {
      MqlDateTime dt;
      TimeToStruct(now,dt);
      datetime todayStart = now - (dt.hour*3600+dt.min*60+dt.sec);

      int hours[4] = {m_sydneyHour,m_tokyoHour,m_londonHour,m_newYorkHour};
      for(int i=1;i<4;i++) // small insertion sort, ascending
        {
         int key=hours[i]; int j=i-1;
         while(j>=0 && hours[j]>key) { hours[j+1]=hours[j]; j--; }
         hours[j+1]=key;
        }

      datetime bestAnchor = 0;
      for(int i=0;i<4;i++)
        {
         datetime candidate = todayStart + hours[i]*3600;
         if(candidate<=now && candidate>bestAnchor) bestAnchor=candidate;
        }
      // now is before every one of today's session opens - the true anchor is yesterday's latest one
      if(bestAnchor==0) bestAnchor = todayStart - 86400 + hours[3]*3600;
      return(bestAnchor);
     }

   //--- typical price (H+L+C)/3 weighted by volume. real_volume is checked first across the whole   ---
   //--- window (summed, not per-bar - a feed either genuinely reports real traded size or it        ---
   //--- doesn't, so mixing real/tick weight bar-to-bar would be an inconsistent yardstick) and used  ---
   //--- only if that sum is positive; otherwise falls back to tick_volume, the realistic weight for  ---
   //--- spot FX/CFDs where real_volume is usually 0. If the chosen weight sums to zero across the    ---
   //--- whole window (degenerate/all-zero volume data), returns -1 rather than computing a           ---
   //--- meaningless unweighted average dressed up as a VWAP. ---
   double            ComputeVwapFromRates(const MqlRates &rates[],const int count) const
     {
      double sumRealVol=0;
      for(int i=0;i<count;i++) sumRealVol += (double)rates[i].real_volume;
      bool useReal = (sumRealVol>0);

      double sumPV=0, sumV=0;
      for(int i=0;i<count;i++)
        {
         double vol = useReal ? (double)rates[i].real_volume : (double)rates[i].tick_volume;
         double typical = (rates[i].high+rates[i].low+rates[i].close)/3.0;
         sumPV += typical*vol;
         sumV  += vol;
        }
      if(sumV<=0) return(-1);
      return(sumPV/sumV);
     }
  };
//+------------------------------------------------------------------+
#endif // AX_VWAPENGINE_MQH
