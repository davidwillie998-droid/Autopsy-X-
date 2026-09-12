//+------------------------------------------------------------------+
//| StructureEngine.mqh                                                |
//| Layer 05 — STRUCTURE ENGINE (Hidden Mechanic #8).                   |
//| Fractal swing detection, BOS/CHOCH, displacement, a simple Order    |
//| Block model, Fair Value Gaps, and premium/discount relative to the |
//| current dealing range. Every zone is quality-scored rather than     |
//| treated as automatically institutional — per spec, "do not treat   |
//| every FVG or Order Block as an institutional signal."               |
//|                                                                      |
//| NOTE ON SCOPE: this is a swing/displacement-based structural read,  |
//| not a full proprietary SMC engine. It uses only bars fully closed   |
//| at or before the current moment (no look-ahead) and is deliberately |
//| simple enough to audit line-by-line.                                |
//+------------------------------------------------------------------+
#ifndef AXF_STRUCTUREENGINE_MQH
#define AXF_STRUCTUREENGINE_MQH

#include "../Common/Defines.mqh"

class CAxfStructureEngine
  {
private:
   int               m_swing_lookback;
   int               m_bars_scan;
   double            m_fvg_min_atr_fraction;

   bool              IsSwingHigh(const MqlRates &r[],const int i,const int n)
     {
      if(i-m_swing_lookback<0 || i+m_swing_lookback>=n) return false;
      for(int k=1;k<=m_swing_lookback;k++)
        {
         if(r[i].high <= r[i-k].high) return false;
         if(r[i].high <= r[i+k].high) return false;
        }
      return true;
     }

   bool              IsSwingLow(const MqlRates &r[],const int i,const int n)
     {
      if(i-m_swing_lookback<0 || i+m_swing_lookback>=n) return false;
      for(int k=1;k<=m_swing_lookback;k++)
        {
         if(r[i].low >= r[i-k].low) return false;
         if(r[i].low >= r[i+k].low) return false;
        }
      return true;
     }

public:
                     CAxfStructureEngine(void) { m_swing_lookback=5; m_bars_scan=300; m_fvg_min_atr_fraction=0.15; }

   void              Init(const int swing_lookback,const int bars_scan,const double fvg_min_atr_fraction)
     {
      m_swing_lookback = MathMax(2,swing_lookback);
      m_bars_scan = MathMax(60,bars_scan);
      m_fvg_min_atr_fraction = fvg_min_atr_fraction;
     }

   SAxfStructure     Compute(const string symbol,const ENUM_TIMEFRAMES tf,const double atr)
     {
      SAxfStructure s; ZeroMemory(s);
      s.valid=false; s.bias=DIR_NONE;

      MqlRates r[]; ArraySetAsSeries(r,true);
      int n = CopyRates(symbol,tf,1,m_bars_scan,r); // index 1 = last CLOSED bar, no look-ahead
      if(n < 40) return s;

      //--- collect swing points (indices are series-indexed, 0 = most recent closed bar)
      int sh_idx[]; int sl_idx[];
      ArrayResize(sh_idx,0); ArrayResize(sl_idx,0);
      for(int i=n-1-m_swing_lookback;i>=m_swing_lookback;i--)
        {
         if(IsSwingHigh(r,i,n)) { int sz=ArraySize(sh_idx); ArrayResize(sh_idx,sz+1); sh_idx[sz]=i; }
         if(IsSwingLow(r,i,n))  { int sz=ArraySize(sl_idx); ArrayResize(sl_idx,sz+1); sl_idx[sz]=i; }
        }
      if(ArraySize(sh_idx)<2 || ArraySize(sl_idx)<2) return s;

      // most recent two swing highs/lows (arrays built oldest->newest since loop ran high->low index)
      int last_sh = sh_idx[ArraySize(sh_idx)-1];
      int prev_sh = sh_idx[ArraySize(sh_idx)-2];
      int last_sl = sl_idx[ArraySize(sl_idx)-1];
      int prev_sl = sl_idx[ArraySize(sl_idx)-2];

      s.last_swing_high = r[last_sh].high;
      s.last_swing_low  = r[last_sl].low;

      double hh = r[last_sh].high > r[prev_sh].high ? r[last_sh].high : r[prev_sh].high;
      double hl = r[last_sl].low  < r[prev_sl].low  ? r[last_sl].low  : r[prev_sl].low;

      bool higher_high = r[last_sh].high > r[prev_sh].high;
      bool higher_low  = r[last_sl].low  > r[prev_sl].low;
      bool lower_high  = r[last_sh].high < r[prev_sh].high;
      bool lower_low   = r[last_sl].low  < r[prev_sl].low;

      double close_now = r[0].close;

      //--- BOS: close beyond the most recent swing extreme in the direction of the
      //--- prevailing structure. CHOCH: close beyond the extreme AGAINST the
      //--- prevailing structure (first sign of a character change).
      bool prevailing_bull = higher_high && higher_low;
      bool prevailing_bear = lower_low && lower_high;

      s.bos_confirmed = false; s.choch_confirmed = false;

      if(prevailing_bull && close_now > r[last_sh].high)
        { s.bos_confirmed=true; s.bias=DIR_LONG; }
      else if(prevailing_bear && close_now < r[last_sl].low)
        { s.bos_confirmed=true; s.bias=DIR_SHORT; }
      else if(prevailing_bull && close_now < r[last_sl].low)
        { s.choch_confirmed=true; s.bias=DIR_SHORT; }
      else if(prevailing_bear && close_now > r[last_sh].high)
        { s.choch_confirmed=true; s.bias=DIR_LONG; }
      else
        s.bias = prevailing_bull ? DIR_LONG : (prevailing_bear ? DIR_SHORT : DIR_NONE);

      //--- displacement: a recent close-to-close move materially larger than ATR,
      //--- in the direction of s.bias. This is what separates a "confirmed" BOS
      //--- from a slow grind through a level.
      s.displacement = false;
      if(atr>0)
        {
         for(int i=0;i<4 && i<n-1;i++)
           {
            double body = MathAbs(r[i].close-r[i].open);
            if(body >= atr*0.75)
              {
               bool dir_ok = (s.bias==DIR_LONG && r[i].close>r[i].open) ||
                             (s.bias==DIR_SHORT && r[i].close<r[i].open);
               if(dir_ok) { s.displacement=true; break; }
              }
           }
        }

      //--- Order Block: the last opposite-colour candle immediately preceding the
      //--- displacement leg that broke structure. Simple, auditable, not "every
      //--- red candle is an OB" — it must be adjacent to a displacement move.
      s.ob_price_high=0; s.ob_price_low=0;
      if(s.displacement)
        {
         for(int i=1;i<6 && i<n-1;i++)
           {
            bool is_opp_bear = (s.bias==DIR_LONG  && r[i].close<r[i].open);
            bool is_opp_bull = (s.bias==DIR_SHORT && r[i].close>r[i].open);
            if(is_opp_bear || is_opp_bull)
              {
               s.ob_price_high = r[i].high;
               s.ob_price_low  = r[i].low;
               break;
              }
           }
        }

      //--- Fair Value Gap: 3-candle imbalance, gap must clear the ATR-fraction floor
      //--- to avoid flagging noise-level gaps.
      s.fvg_high=0; s.fvg_low=0;
      double fvg_floor = atr*m_fvg_min_atr_fraction;
      for(int i=1;i<n-2;i++)
        {
         // bullish FVG: candle[i+1].high < candle[i-1].low  (gap between the two outer candles)
         double gap_bull = r[i-1].low - r[i+1].high;
         double gap_bear = r[i+1].low - r[i-1].high;
         if(gap_bull > fvg_floor && s.bias==DIR_LONG)
           { s.fvg_low=r[i+1].high; s.fvg_high=r[i-1].low; break; }
         if(gap_bear > fvg_floor && s.bias==DIR_SHORT)
           { s.fvg_low=r[i-1].high; s.fvg_high=r[i+1].low; break; }
        }

      //--- premium/discount relative to the current dealing range (last HH..HL)
      double range_high = MathMax(hh, s.last_swing_high);
      double range_low  = MathMin(hl, s.last_swing_low);
      double mid = (range_high+range_low)/2.0;
      s.in_premium  = close_now > mid;
      s.in_discount = close_now < mid;

      //--- quality score: freshness + displacement + FVG/OB confluence + regime
      //--- alignment is left to the OpportunityEngine (which knows regime); here
      //--- we score purely on structural cleanliness, 0..100.
      double q = 40.0;
      if(s.bos_confirmed) q += 20;
      if(s.displacement)  q += 15;
      if(s.ob_price_high>0) q += 10;
      if(s.fvg_high>0)      q += 10;
      if(s.choch_confirmed) q -= 15; // a fresh CHOCH is a warning, not yet a confirmed trend
      // discount-for-longs / premium-for-shorts is the "buy low, sell high within range" bonus
      if((s.bias==DIR_LONG && s.in_discount) || (s.bias==DIR_SHORT && s.in_premium)) q += 5;
      s.quality = AxfClamp(q,0,100);

      s.valid = true;
      return s;
     }
  };

#endif // AXF_STRUCTUREENGINE_MQH
