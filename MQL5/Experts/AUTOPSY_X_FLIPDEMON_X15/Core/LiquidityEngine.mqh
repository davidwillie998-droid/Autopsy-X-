//+------------------------------------------------------------------+
//| LiquidityEngine.mqh                                                 |
//| Layer 04 — LIQUIDITY ENGINE (Hidden Mechanic #7).                   |
//| Maps previous day/week highs & lows, the current session's high/low,|
//| and equal highs/lows (resting liquidity pools), then determines     |
//| whether price is seeking, sweeping, or accepting beyond a level.    |
//+------------------------------------------------------------------+
#ifndef AXF_LIQUIDITYENGINE_MQH
#define AXF_LIQUIDITYENGINE_MQH

#include "../Common/Defines.mqh"

class CAxfLiquidityEngine
  {
private:
   double            EqualLevel(const MqlRates &r[],const int n,const bool highs,const double tolerance)
     {
      // scans for two or more closed-bar extremes within 'tolerance' of one another —
      // a simple, auditable proxy for "equal highs/lows" resting liquidity.
      for(int i=0;i<n-1;i++)
        {
         double v1 = highs ? r[i].high : r[i].low;
         for(int j=i+1;j<n;j++)
           {
            double v2 = highs ? r[j].high : r[j].low;
            if(MathAbs(v1-v2) <= tolerance)
               return highs ? MathMax(v1,v2) : MathMin(v1,v2);
           }
        }
      return 0.0;
     }

public:
   SAxfLiquidityMap  Compute(const string symbol,const ENUM_TIMEFRAMES tf,const double atr)
     {
      SAxfLiquidityMap m; ZeroMemory(m); m.valid=false;

      MqlRates d1[]; ArraySetAsSeries(d1,true);
      int nd = CopyRates(symbol,PERIOD_D1,1,3,d1); // 1 = yesterday, no look-ahead
      if(nd<2) return m;
      m.prev_day_high = d1[0].high;
      m.prev_day_low  = d1[0].low;

      MqlRates w1[]; ArraySetAsSeries(w1,true);
      int nw = CopyRates(symbol,PERIOD_W1,1,2,w1);
      if(nw>=1) { m.prev_week_high=w1[0].high; m.prev_week_low=w1[0].low; }

      //--- current session range: bars since the most recent D1 open, on tf
      MqlRates today[]; ArraySetAsSeries(today,true);
      datetime day_open = iTime(symbol,PERIOD_D1,0);
      int bars_today = Bars(symbol,tf,day_open,TimeCurrent());
      bars_today = AxfClampInt(bars_today,1,500);
      int nt = CopyRates(symbol,tf,0,bars_today,today);
      if(nt>=1)
        {
         double hh=today[0].high, ll=today[0].low;
         for(int i=1;i<nt;i++) { hh=MathMax(hh,today[i].high); ll=MathMin(ll,today[i].low); }
         m.session_high=hh; m.session_low=ll;
        }

      double price = SymbolInfoDouble(symbol,SYMBOL_BID);
      if(price<=0) return m;

      //--- assemble candidate levels above/below price, find nearest of each
      double above[]; double below[];
      ArrayResize(above,0); ArrayResize(below,0);

      double eq_high=0, eq_low=0;
      MqlRates scan[]; ArraySetAsSeries(scan,true);
      int ns = CopyRates(symbol,tf,1,150,scan);
      if(ns>=20)
        {
         double tol = (atr>0) ? atr*0.08 : price*0.0004;
         eq_high = EqualLevel(scan,ns,true,tol);
         eq_low  = EqualLevel(scan,ns,false,tol);
        }

      double candidates[8]; int cnt=0;
      candidates[cnt++] = m.prev_day_high;
      candidates[cnt++] = m.prev_day_low;
      candidates[cnt++] = m.prev_week_high;
      candidates[cnt++] = m.prev_week_low;
      candidates[cnt++] = m.session_high;
      candidates[cnt++] = m.session_low;
      candidates[cnt++] = eq_high;
      candidates[cnt++] = eq_low;

      double best_above=0, best_below=0;
      for(int i=0;i<cnt;i++)
        {
         if(candidates[i]<=0) continue;
         if(candidates[i] > price && (best_above==0 || candidates[i]<best_above)) best_above=candidates[i];
         if(candidates[i] < price && (best_below==0 || candidates[i]>best_below)) best_below=candidates[i];
        }
      m.nearest_liquidity_above = best_above;
      m.nearest_liquidity_below = best_below;

      //--- sweep / acceptance: did the last few closed bars pierce a level and
      //--- then close back on the other side (sweep), or close through and stay
      //--- (acceptance)?
      if(nt>=2)
        {
         double last_high=today[0].high, last_low=today[0].low, last_close=today[0].close;
         if(m.prev_day_high>0 && last_high>m.prev_day_high)
           {
            m.sweeping_highs = (last_close < m.prev_day_high);
            m.accepted_above = (last_close > m.prev_day_high);
           }
         if(m.prev_day_low>0 && last_low<m.prev_day_low)
           {
            m.sweeping_lows = (last_close > m.prev_day_low);
            m.accepted_below = (last_close < m.prev_day_low);
           }
        }

      m.valid = true;
      return m;
     }
  };

#endif // AXF_LIQUIDITYENGINE_MQH
