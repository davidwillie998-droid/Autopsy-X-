//+------------------------------------------------------------------+
//|                                                 DataIntegrity.mqh |
//|  Layer 0: Data Integrity (institutional engine upgrade, inspired  |
//|  by Malhotra SSRN 3306817's emphasis on liquidity/microstructure  |
//|  measurement quality - the specific checks below are ENGINEERING  |
//|  DESIGN, not sourced from the paper, which does not specify a     |
//|  data-quality gate).                                              |
//|                                                                    |
//|  "If data quality fails: NO TRADE" - this engine's Check() is a   |
//|  hard, fail-closed gate meant to run before anything else in the  |
//|  pipeline reads market data as if it were trustworthy.            |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_DATAINTEGRITY_MQH
#define AX_DATAINTEGRITY_MQH
#include "Defs.mqh"
#include "MarketData.mqh"

class CDataIntegrityEngine
  {
private:
   string   m_symbol;
   double   m_maxStaleSeconds;
   double   m_maxSpreadZScore;     // how many std-devs above the rolling mean spread is "abnormal"
   double   m_maxAbsoluteSpreadPts;// a hard ceiling regardless of z-score (catches a feed that's
                                    // been consistently wide, where a z-score alone wouldn't flag it)
   int      m_maxDuplicateStreak;  // consecutive identical bid/ask ticks before treating the feed
                                    // as stuck rather than genuinely quiet
   int      m_minTickHistoryForZScore;

   datetime m_lastTickTime;
   double   m_lastBid, m_lastAsk;
   int      m_duplicateStreak;

   double   RollingSpreadZScore(const CMarketData &md,const double currentSpreadPts) const
     {
      int n = MathMin(md.Count(),101);
      if(n<m_minTickHistoryForZScore+1) return(0.0); // not enough history to judge - don't fabricate a z-score
      double sum=0,sumSq=0; int cnt=0;
      // i starts at 1, not 0: md.GetSample(0) IS the current tick whose spreadPts is currentSpreadPts -
      // including it in its own baseline mathematically caps the achievable z-score at sqrt(n-1) and
      // can make an extreme spike unable to ever cross the threshold (code-review finding) ---
      for(int i=1;i<n;i++)
        {
         SAxTick t;
         if(!md.GetSample(i,t)) continue;
         sum+=t.spreadPts; sumSq+=t.spreadPts*t.spreadPts; cnt++;
        }
      if(cnt<m_minTickHistoryForZScore) return(0.0);
      double mean = sum/cnt;
      double variance = (sumSq/cnt)-(mean*mean);
      if(variance<=0) return(0.0);
      double stdev = MathSqrt(variance);
      if(stdev<=0) return(0.0);
      return((currentSpreadPts-mean)/stdev);
     }

public:
                     CDataIntegrityEngine(void)
     {
      m_maxStaleSeconds=30.0; m_maxSpreadZScore=6.0; m_maxAbsoluteSpreadPts=500.0;
      m_maxDuplicateStreak=500; m_minTickHistoryForZScore=30;
      m_lastTickTime=0; m_lastBid=0; m_lastAsk=0; m_duplicateStreak=0;
     }

   void              Configure(const string symbol,const double maxStaleSeconds,
                                const double maxSpreadZScore,const double maxAbsoluteSpreadPts,
                                const int maxDuplicateStreak)
     {
      m_symbol=symbol;
      m_maxStaleSeconds       = MathMax(1.0,maxStaleSeconds);
      m_maxSpreadZScore       = MathMax(1.0,maxSpreadZScore);
      m_maxAbsoluteSpreadPts  = MathMax(1.0,maxAbsoluteSpreadPts);
      m_maxDuplicateStreak    = MathMax(10,maxDuplicateStreak);
     }

   //--- call every tick, after CMarketData::OnTickUpdate() has already stored the sample ---
   bool              Check(const CMarketData &md,string &reasonOut)
     {
      //--- this engine's own m_symbol (set in Configure) and the CMarketData instance being checked ---
      //--- must refer to the same instrument - otherwise the trading-state/stale-quote checks below   ---
      //--- would validate one symbol while the price/spread checks validate another (code-review       ---
      //--- finding). A mismatch here means a wiring bug, not a market condition - fail closed. ---
      if(md.Symbol()!=m_symbol)
        {
         reasonOut=StringFormat("Wiring error: CDataIntegrityEngine configured for '%s' but checking '%s'",
                                 m_symbol,md.Symbol());
         return(false);
        }

      double bid = md.CurrentBid();
      double ask = md.CurrentAsk();
      datetime now = TimeCurrent();

      //--- impossible prices - never trust a feed with a nonsensical quote ---
      if(bid<=0 || ask<=0)
        { reasonOut="Impossible price: bid or ask <= 0"; return(false); }
      if(bid>=ask)
        { reasonOut=StringFormat("Impossible price: bid (%.5f) >= ask (%.5f)",bid,ask); return(false); }

      //--- symbol / trading availability - a real broker/terminal state check, not a guess ---
      if(!SymbolInfoInteger(m_symbol,SYMBOL_SELECT))
        { reasonOut="Symbol not selected/available in Market Watch"; return(false); }
      long tradeMode = SymbolInfoInteger(m_symbol,SYMBOL_TRADE_MODE);
      if(tradeMode==SYMBOL_TRADE_MODE_DISABLED)
        { reasonOut="Symbol trading disabled by broker"; return(false); }

      //--- stale quotes - degrade to NO TRADE rather than silently treating an old quote as current ---
      datetime lastTickTime = (datetime)SymbolInfoInteger(m_symbol,SYMBOL_TIME);
      if(lastTickTime>0 && (now-lastTickTime)>m_maxStaleSeconds)
        {
         reasonOut=StringFormat("Stale quote: last tick %ds ago (max %d)",
                                 (int)(now-lastTickTime),(int)m_maxStaleSeconds);
         return(false);
        }

      //--- duplicated ticks - a feed stuck repeating the same bid/ask for an extended streak is a  ---
      //--- real broker-side symptom (connection degraded, feed frozen), not normal quiet trading;   ---
      //--- a SHORT streak of identical ticks is completely normal (low-activity periods) and is not  ---
      //--- itself flagged - only an extended one is. ---
      if(bid==m_lastBid && ask==m_lastAsk && m_lastBid>0)
         m_duplicateStreak++;
      else
         m_duplicateStreak=0;
      m_lastBid=bid; m_lastAsk=ask; m_lastTickTime=now;
      if(m_duplicateStreak>=m_maxDuplicateStreak)
        {
         reasonOut=StringFormat("Feed appears stuck: %d consecutive identical ticks",m_duplicateStreak);
         return(false);
        }

      //--- abnormal spread - both an absolute ceiling and a statistical (z-score) check against    ---
      //--- this symbol's own recent behavior, since "abnormal" for XAUUSD and a tight FX pair are   ---
      //--- very different absolute numbers ---
      double spreadPts = md.CurrentSpreadPts();
      if(spreadPts>m_maxAbsoluteSpreadPts)
        {
         reasonOut=StringFormat("Spread %.1f exceeds absolute maximum %.1f",spreadPts,m_maxAbsoluteSpreadPts);
         return(false);
        }
      double z = RollingSpreadZScore(md,spreadPts);
      if(z>m_maxSpreadZScore)
        {
         reasonOut=StringFormat("Spread %.1f is %.1f std-devs above its recent rolling mean (max %.1f)",
                                 spreadPts,z,m_maxSpreadZScore);
         return(false);
        }

      reasonOut="";
      return(true);
     }

   int               DuplicateStreak(void) const { return(m_duplicateStreak); }
   datetime          LastTickTime(void) const { return(m_lastTickTime); } // for dashboard/diagnostic
                                                                            // display of this engine's
                                                                            // own last-checked time
  };
//+------------------------------------------------------------------+
#endif // AX_DATAINTEGRITY_MQH
