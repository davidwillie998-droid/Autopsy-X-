//+------------------------------------------------------------------+
//| MarketScanner.mqh                                                |
//| Scan-only quote-quality gate for broker-discovered instruments.  |
//| Does not score direction, authorize risk, or send orders.         |
//+------------------------------------------------------------------+
#ifndef AUTOPSYX_MARKET_SCANNER_MQH
#define AUTOPSYX_MARKET_SCANNER_MQH
#include "BrokerUniverse.mqh"

struct SAxScanCandidate
  {
   string                symbol;
   ENUM_AX_MARKET_FAMILY family;
   double                bid;
   double                ask;
   double                spread_points;
   double                spread_percent;
   datetime              quote_time;
   double                tick_size;
   double                tick_value;
   double                volume_min;
   double                volume_max;
   double                volume_step;
  };

class CMarketScanner
  {
private:
   SAxScanCandidate m_candidates[];
   int              m_count;
   string           m_last_reject_reason;

   bool IsSupportedFamily(const ENUM_AX_MARKET_FAMILY family) const
     {
      return(family==AX_FAMILY_FX ||
             family==AX_FAMILY_GOLD ||
             family==AX_FAMILY_SYNTH_VOLATILITY ||
             family==AX_FAMILY_SYNTH_BOOM_CRASH ||
             family==AX_FAMILY_SYNTH_JUMP ||
             family==AX_FAMILY_SYNTH_STEP ||
             family==AX_FAMILY_SYNTH_RANGE_BREAK ||
             family==AX_FAMILY_SYNTH_DRIFT_SWITCH ||
             family==AX_FAMILY_SYNTH_HYBRID ||
             family==AX_FAMILY_SYNTH_OTHER);
     }

   void SortByQuoteCost(void)
     {
      // Small universe insertion sort: best (lowest relative spread) first.
      for(int i=1;i<m_count;i++)
        {
         SAxScanCandidate key=m_candidates[i];
         int j=i-1;
         while(j>=0 && m_candidates[j].spread_percent>key.spread_percent)
           {
            m_candidates[j+1]=m_candidates[j];
            j--;
           }
         m_candidates[j+1]=key;
        }
     }

public:
                     CMarketScanner(void) { m_count=0; m_last_reject_reason=""; }
   int               Count(void) const { return(m_count); }
   string            LastRejectReason(void) const { return(m_last_reject_reason); }

   // max_spread_percent is spread as a percentage of mid-price, not raw points,
   // so different digits/point sizes are more comparable. Must be > 0.
   // max_quote_age_seconds must be > 0. Invalid settings fail closed.
   bool              Refresh(const CBrokerUniverse &universe,
                             const double max_spread_percent,
                             const int max_quote_age_seconds,
                             const bool require_selected=true)
     {
      ArrayResize(m_candidates,0);
      m_count=0;
      m_last_reject_reason="";

      if(max_spread_percent<=0.0 || max_quote_age_seconds<=0)
        {
         m_last_reject_reason="Invalid scanner limits; spread and quote-age limits must be positive";
         return(false);
        }

      datetime now=TimeCurrent();
      for(int i=0;i<universe.Count();i++)
        {
         SAxBrokerSymbol meta;
         if(!universe.Get(i,meta)) continue;
         if(!meta.tradeable || !IsSupportedFamily(meta.family)) continue;
         if(require_selected && !meta.selected) continue;

         MqlTick tick;
         if(!SymbolInfoTick(meta.name,tick)) continue;
         if(tick.bid<=0.0 || tick.ask<=0.0 || tick.ask<tick.bid) continue;
         if(tick.time<=0 || (now-(datetime)tick.time)>max_quote_age_seconds) continue;

         double mid=(tick.bid+tick.ask)*0.5;
         if(mid<=0.0 || meta.point<=0.0) continue;
         double spread=tick.ask-tick.bid;
         double spread_pct=(spread/mid)*100.0;
         if(spread_pct<0.0 || spread_pct>max_spread_percent) continue;

         SAxScanCandidate candidate;
         candidate.symbol=meta.name;
         candidate.family=meta.family;
         candidate.bid=tick.bid;
         candidate.ask=tick.ask;
         candidate.spread_points=spread/meta.point;
         candidate.spread_percent=spread_pct;
         candidate.quote_time=(datetime)tick.time;
         candidate.tick_size=meta.tick_size;
         candidate.tick_value=meta.tick_value;
         candidate.volume_min=meta.volume_min;
         candidate.volume_max=meta.volume_max;
         candidate.volume_step=meta.volume_step;

         int resized=ArrayResize(m_candidates,m_count+1);
         if(resized!=m_count+1)
           {
            m_last_reject_reason="Unable to allocate candidate list";
            ArrayResize(m_candidates,0);
            m_count=0;
            return(false);
           }
         m_candidates[m_count]=candidate;
         m_count++;
        }

      SortByQuoteCost();
      if(m_count==0)
         m_last_reject_reason="No symbols passed family, metadata, quote freshness, and spread gates";
      return(m_count>0);
     }

   bool              Get(const int index,SAxScanCandidate &out) const
     {
      if(index<0 || index>=m_count) return(false);
      out=m_candidates[index];
      return(true);
     }
  };

#endif // AUTOPSYX_MARKET_SCANNER_MQH
