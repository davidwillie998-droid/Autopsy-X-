//+------------------------------------------------------------------+
//| OrderFlowEngine.mqh                                                   |
//| Microstructure / order-flow "edition": Volume Profile, Cumulative     |
//| Delta, a fast Pulse oscillator, footprint-lite stacked-imbalance,     |
//| and a DOM/heatmap read.                                                |
//|                                                                        |
//| HONESTY NOTE (read before trusting any of this):                      |
//| Most retail FX/CFD feeds hand the terminal quote ticks (bid/ask        |
//| changes), not an aggressor-tagged exchange tape. Where a tick carries  |
//| a real TICK_FLAG_BUY/TICK_FLAG_SELL flag, that flag is used directly   |
//| — that IS real order flow. Where it doesn't (the common case), buy/    |
//| sell side is inferred with the classic tick rule (price up = buy-side,|
//| price down = sell-side, unchanged = inherit the prior side). This is   |
//| a standard, useful approximation, not exchange-grade order flow —      |
//| SAxfOrderFlow.ticks_are_real_trades tells the caller which one it got. |
//| DOM/heatmap needs the broker to expose Level 2 depth (MarketBookAdd);  |
//| most FX symbols do not, and this degrades to dom_available=false       |
//| rather than fabricating a heatmap. Volume Profile is real regardless   |
//| (it uses tick/quote activity as its volume proxy either way).          |
//+------------------------------------------------------------------+
#ifndef AXF_ORDERFLOWENGINE_MQH
#define AXF_ORDERFLOWENGINE_MQH

#include "../Common/Defines.mqh"

class CAxfOrderFlowEngine
  {
private:
   string            m_symbol;
   int               m_recalc_seconds;
   int               m_tick_lookback_minutes;
   int               m_max_ticks;
   int               m_profile_bins;
   double            m_value_area_pct;
   int               m_pulse_window_seconds;
   int               m_footprint_bars_lookback;
   double            m_footprint_imbalance_ratio;
   bool              m_dom_wanted;
   int               m_dom_wall_distance_points;

   bool              m_dom_subscribed;
   datetime          m_last_calc_time;
   SAxfOrderFlow     m_cached;

   //--- classic tick rule with real-flag preference. Returns +1/-1 and
   //--- updates 'last_sign' (the zero-tick carry-forward state).
   int               ClassifyTick(const MqlTick &now,const MqlTick &prev,int &last_sign,bool &was_real_flag)
     {
      was_real_flag = false;
      if((now.flags & TICK_FLAG_BUY) != 0)  { was_real_flag=true; last_sign=1;  return 1; }
      if((now.flags & TICK_FLAG_SELL) != 0) { was_real_flag=true; last_sign=-1; return -1; }

      double ref_now  = (now.bid>0)  ? now.bid  : now.last;
      double ref_prev = (prev.bid>0) ? prev.bid : prev.last;
      if(ref_now > ref_prev) { last_sign=1; return 1; }
      if(ref_now < ref_prev) { last_sign=-1; return -1; }
      return last_sign; // unchanged price -> inherit previous side
     }

   double            TickVolume(const MqlTick &t) const
     {
      if(t.volume_real>0) return t.volume_real;
      if(t.volume>0) return (double)t.volume;
      return 1.0; // no volume field at all -> count activity as 1 unit per quote update
     }

public:
                     CAxfOrderFlowEngine(void)
     {
      m_symbol=""; m_recalc_seconds=10; m_tick_lookback_minutes=30; m_max_ticks=20000;
      m_profile_bins=40; m_value_area_pct=70.0; m_pulse_window_seconds=60;
      m_footprint_bars_lookback=5; m_footprint_imbalance_ratio=2.0;
      m_dom_wanted=true; m_dom_wall_distance_points=100;
      m_dom_subscribed=false; m_last_calc_time=0;
      ZeroMemory(m_cached);
     }

   void              Init(const string symbol,const int recalc_seconds,const int tick_lookback_minutes,
                           const int max_ticks,const int profile_bins,const double value_area_pct,
                           const int pulse_window_seconds,const int footprint_bars_lookback,
                           const double footprint_imbalance_ratio,const bool dom_wanted,
                           const int dom_wall_distance_points)
     {
      m_symbol = symbol;
      m_recalc_seconds = MathMax(1,recalc_seconds);
      m_tick_lookback_minutes = MathMax(1,tick_lookback_minutes);
      m_max_ticks = MathMax(100,max_ticks);
      m_profile_bins = MathMax(5,profile_bins);
      m_value_area_pct = AxfClamp(value_area_pct,10.0,100.0);
      m_pulse_window_seconds = MathMax(5,pulse_window_seconds);
      m_footprint_bars_lookback = MathMax(1,footprint_bars_lookback);
      m_footprint_imbalance_ratio = MathMax(1.01,footprint_imbalance_ratio);
      m_dom_wanted = dom_wanted;
      m_dom_wall_distance_points = MathMax(1,dom_wall_distance_points);
      m_last_calc_time = 0;
      ZeroMemory(m_cached);

      m_dom_subscribed = false;
      if(m_dom_wanted)
         m_dom_subscribed = MarketBookAdd(m_symbol); // false when the broker/symbol has no Level 2 depth
     }

   void              Deinit(void)
     {
      if(m_dom_subscribed)
        {
         MarketBookRelease(m_symbol);
         m_dom_subscribed = false;
        }
     }

   //--- 'footprint_tf' is the bar timeframe used for the footprint-lite scan
   //--- (pass the EA's execution timeframe, e.g. Inp_LTF). Cheap to call every
   //--- cycle — internally throttled to Inp_OrderFlowRecalcSeconds.
   SAxfOrderFlow     Compute(const ENUM_TIMEFRAMES footprint_tf)
     {
      if(TimeCurrent()-m_last_calc_time < m_recalc_seconds)
         return m_cached; // reuse — tick fetch + binning is not free, this is a slow read by design

      m_last_calc_time = TimeCurrent();

      SAxfOrderFlow f; ZeroMemory(f);
      f.computed_time = TimeCurrent();
      f.valid = true; // "an attempt was made this cycle" — check the per-piece flags before trusting a number

      //--- fetch ticks
      ulong to_msc   = (ulong)TimeCurrent()*1000;
      ulong from_msc = to_msc - (ulong)m_tick_lookback_minutes*60*1000;

      MqlTick raw[];
      int n = CopyTicksRange(m_symbol,raw,COPY_TICKS_ALL,from_msc,to_msc);

      if(n <= 1)
        {
         m_cached = f; // nothing usable yet (fresh symbol, no history downloaded, etc.)
         return f;
        }

      MqlTick ticks[];
      if(n > m_max_ticks)
        {
         ArrayResize(ticks,m_max_ticks);
         ArrayCopy(ticks,raw,0,n-m_max_ticks,m_max_ticks); // keep the most RECENT ticks
         n = m_max_ticks;
        }
      else
        {
         ArrayResize(ticks,n);
         ArrayCopy(ticks,raw,0,0,n);
        }

      //--- classify every tick once; reused by delta/pulse/profile/footprint
      int signs[]; double vols[];
      ArrayResize(signs,n); ArrayResize(vols,n);
      signs[0]=0; vols[0]=TickVolume(ticks[0]);
      int last_sign=0;
      int real_flag_count=0;
      for(int i=1;i<n;i++)
        {
         bool was_real;
         signs[i] = ClassifyTick(ticks[i],ticks[i-1],last_sign,was_real);
         vols[i]  = TickVolume(ticks[i]);
         if(was_real) real_flag_count++;
        }
      f.ticks_are_real_trades = (real_flag_count > 0);

      //--- CUMULATIVE DELTA + PULSE
      double cum_delta=0;
      double pulse_buy=0, pulse_sell=0;
      datetime pulse_cutoff = TimeCurrent()-m_pulse_window_seconds;
      for(int i=1;i<n;i++)
        {
         cum_delta += signs[i]*vols[i];
         if(ticks[i].time >= pulse_cutoff)
           {
            if(signs[i]>0) pulse_buy += vols[i];
            else if(signs[i]<0) pulse_sell += vols[i];
           }
        }
      f.cumulative_delta = cum_delta;
      double pulse_total = pulse_buy+pulse_sell;
      f.pulse = (pulse_total>0) ? 100.0*(pulse_buy-pulse_sell)/pulse_total : 0.0;
      f.flow_valid = true;

      //--- VOLUME PROFILE (POC / Value Area)
      double min_p=ticks[0].bid>0?ticks[0].bid:ticks[0].last, max_p=min_p;
      for(int i=1;i<n;i++)
        {
         double p = ticks[i].bid>0?ticks[i].bid:ticks[i].last;
         if(p<=0) continue;
         if(p<min_p) min_p=p;
         if(p>max_p) max_p=p;
        }
      if(max_p>min_p)
        {
         double bin_w = (max_p-min_p)/m_profile_bins;
         double bin_vol[]; ArrayResize(bin_vol,m_profile_bins); ArrayInitialize(bin_vol,0.0);
         double total_vol=0;
         for(int i=0;i<n;i++)
           {
            double p = ticks[i].bid>0?ticks[i].bid:ticks[i].last;
            if(p<=0) continue;
            int bin = (int)((p-min_p)/bin_w);
            bin = AxfClampInt(bin,0,m_profile_bins-1);
            bin_vol[bin]+=vols[i];
            total_vol+=vols[i];
           }

         int poc_bin=0; double poc_v=bin_vol[0];
         for(int b=1;b<m_profile_bins;b++) if(bin_vol[b]>poc_v) { poc_v=bin_vol[b]; poc_bin=b; }

         f.poc_price = min_p+(poc_bin+0.5)*bin_w;

         //--- value area: greedily expand outward from the POC bin, always
         //--- taking whichever neighbour (above/below the current included
         //--- range) holds more volume, until the target % is covered.
         double target = total_vol*(m_value_area_pct/100.0);
         double covered = bin_vol[poc_bin];
         int lo=poc_bin, hi=poc_bin;
         while(covered<target && (lo>0 || hi<m_profile_bins-1))
           {
            double vol_below = (lo>0) ? bin_vol[lo-1] : -1;
            double vol_above = (hi<m_profile_bins-1) ? bin_vol[hi+1] : -1;
            if(vol_above>=vol_below) { hi++; covered+=bin_vol[hi]; }
            else                     { lo--; covered+=bin_vol[lo]; }
           }
         f.val_price = min_p+lo*bin_w;
         f.vah_price = min_p+(hi+1)*bin_w;
         f.profile_valid = true;
        }

      //--- FOOTPRINT-LITE: per-bar buy/sell split over the last K closed bars,
      //--- looking for a stacked imbalance (several bars in a row dominated
      //--- by the same side beyond the configured ratio).
      int stacked=0; ENUM_AXF_DIRECTION dom_dir=DIR_NONE; double dom_ratio=0;
      bool broke=false;
      for(int shift=1; shift<=m_footprint_bars_lookback && !broke; shift++)
        {
         datetime bar_open  = iTime(m_symbol,footprint_tf,shift);
         datetime bar_close = iTime(m_symbol,footprint_tf,shift-1);
         if(bar_open<=0 || bar_close<=0) break;

         double buy_v=0, sell_v=0;
         for(int i=0;i<n;i++)
           {
            if(ticks[i].time<bar_open || ticks[i].time>=bar_close) continue;
            if(signs[i]>0) buy_v+=vols[i];
            else if(signs[i]<0) sell_v+=vols[i];
           }
         if(buy_v<=0 && sell_v<=0) break; // no tick data reaches this far back — stop, don't guess

         ENUM_AXF_DIRECTION bar_dir = (buy_v>sell_v) ? DIR_LONG : (sell_v>buy_v ? DIR_SHORT : DIR_NONE);
         double bar_ratio = (MathMin(buy_v,sell_v)>0) ? MathMax(buy_v,sell_v)/MathMin(buy_v,sell_v) : 999.0;

         if(shift==1) { dom_dir=bar_dir; dom_ratio=bar_ratio; }

         if(bar_dir==dom_dir && bar_ratio>=m_footprint_imbalance_ratio) stacked++;
         else broke=true;
        }
      if(dom_dir!=DIR_NONE && dom_ratio>=m_footprint_imbalance_ratio)
        {
         f.footprint_imbalance_dir = dom_dir;
         f.footprint_imbalance_ratio = dom_ratio;
         f.footprint_stacked_bars = stacked;
         f.footprint_valid = true;
        }

      //--- DOM / HEATMAP
      if(m_dom_subscribed)
        {
         MqlBookInfo book[];
         if(MarketBookGet(m_symbol,book))
           {
            double point = SymbolInfoDouble(m_symbol,SYMBOL_POINT);
            double bid = SymbolInfoDouble(m_symbol,SYMBOL_BID);
            double ask = SymbolInfoDouble(m_symbol,SYMBOL_ASK);
            double range = m_dom_wall_distance_points*point;

            double bid_sum=0, ask_sum=0;
            double best_bid_wall_p=0, best_bid_wall_v=0;
            double best_ask_wall_p=0, best_ask_wall_v=0;

            for(int i=0;i<ArraySize(book);i++)
              {
               double vol = (book[i].volume_real>0) ? book[i].volume_real : (double)book[i].volume;
               if(book[i].type==BOOK_TYPE_BUY && book[i].price >= bid-range)
                 {
                  bid_sum+=vol;
                  if(vol>best_bid_wall_v) { best_bid_wall_v=vol; best_bid_wall_p=book[i].price; }
                 }
               else if(book[i].type==BOOK_TYPE_SELL && book[i].price <= ask+range)
                 {
                  ask_sum+=vol;
                  if(vol>best_ask_wall_v) { best_ask_wall_v=vol; best_ask_wall_p=book[i].price; }
                 }
              }

            f.dom_available = true;
            f.dom_nearest_bid_wall_price=best_bid_wall_p; f.dom_nearest_bid_wall_volume=best_bid_wall_v;
            f.dom_nearest_ask_wall_price=best_ask_wall_p; f.dom_nearest_ask_wall_volume=best_ask_wall_v;
            f.dom_imbalance_ratio = (ask_sum>0) ? bid_sum/ask_sum : (bid_sum>0?999.0:1.0);
           }
        }

      m_cached = f;
      return f;
     }

   bool              DomSubscribed(void) const { return m_dom_subscribed; }
  };

#endif // AXF_ORDERFLOWENGINE_MQH
