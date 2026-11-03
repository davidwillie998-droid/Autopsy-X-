//+------------------------------------------------------------------+
//|                                            TickDirectionEngine.mqh|
//|  Layer 4: Directional Tick Flow - Lee & Ready (1991) tick test (T)|
//|  and quote test (Q). PAPER-SOURCED (Malhotra SSRN 3306817,        |
//|  reference [11], findings items xx-xxii) - same methodology as    |
//|  python/autopsy_research/trade_direction.py, ported for live use. |
//|                                                                    |
//|  Definitions, from the source paper's own bullet points:           |
//|   T: buyer-initiated if price ABOVE the previous trade price,      |
//|      seller-initiated if BELOW.                                    |
//|   Q: buyer-initiated if price ABOVE the prevailing quote midpoint, |
//|      seller-initiated if BELOW.                                    |
//|                                                                    |
//|  This is an INFERENCE from price/quote behavior on a retail feed   |
//|  that does not expose a real trade-aggressor flag - never claim    |
//|  this sees actual order flow (same caveat OrderFlow.mqh already    |
//|  carries for its own, simpler dir inference).                      |
//|                                                                    |
//|  Combination rule (quote test primary, tick test fallback,         |
//|  zero-tick inheritance on an exact tie) matches the Python          |
//|  research module's own engineering choice, documented there in     |
//|  classify_trade_direction() - kept identical here so the live and  |
//|  offline implementations agree on the same methodology.            |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_TICKDIRECTIONENGINE_MQH
#define AX_TICKDIRECTIONENGINE_MQH
#include "Defs.mqh"

class CTickDirectionEngine
  {
private:
   ENUM_AX_TICK_DIRECTION m_lastDirection;         // last COMBINED (Q-or-T) classification returned
   ENUM_AX_TICK_DIRECTION m_lastTickTestDirection;  // last classification derived from the TICK TEST
                                                      // specifically (price vs prevPrice) - kept
                                                      // separate because the zero-tick fallback must
                                                      // inherit from tick-test history only, matching
                                                      // trade_direction.py's tick_test(): its
                                                      // last_nonzero is updated ONLY in the >/< price
                                                      // comparison branches, never by the quote test.
                                                      // Using m_lastDirection (the combined result) for
                                                      // the zero-tick fallback would let a quote-test-
                                                      // driven classification leak into a tick-test
                                                      // tie-break, diverging from the ported Python
                                                      // module despite this file's own "kept identical"
                                                      // claim (code-review finding).

public:
                     CTickDirectionEngine(void)
     {
      m_lastDirection=AX_TICKDIR_UNCLASSIFIED;
      m_lastTickTestDirection=AX_TICKDIR_UNCLASSIFIED;
     }

   //--- classifies one new tick. price=current mid or last trade price, prevPrice=the previous      ---
   //--- tick's price, bid/ask=current quote. Quote test runs first (the paper's own methodology       ---
   //--- treats Q as the more information-rich test since it uses the actual bid/ask); tick test with  ---
   //--- zero-tick inheritance is the fallback when price sits exactly at the midpoint. ---
   ENUM_AX_TICK_DIRECTION Classify(const double price,const double prevPrice,
                                    const double bid,const double ask)
     {
      double mid = (bid+ask)/2.0;

      if(price>prevPrice) m_lastTickTestDirection=AX_TICKDIR_BUY;
      else if(price<prevPrice) m_lastTickTestDirection=AX_TICKDIR_SELL;
      // price==prevPrice: m_lastTickTestDirection is left untouched, exactly matching
      // trade_direction.py's tick_test() (last_nonzero only reassigned in the strict > / < branches)

      if(price>mid) { m_lastDirection=AX_TICKDIR_BUY;  return(m_lastDirection); }
      if(price<mid) { m_lastDirection=AX_TICKDIR_SELL; return(m_lastDirection); }

      //--- quote test inconclusive (exactly at midpoint) - fall back to the tick test, using the     ---
      //--- tick-test-only history above for the zero-tick tie-break, never the combined result ---
      m_lastDirection = m_lastTickTestDirection;
      return(m_lastDirection);
     }

   ENUM_AX_TICK_DIRECTION LastDirection(void) const { return(m_lastDirection); }

   void              Reset(void)
     {
      m_lastDirection=AX_TICKDIR_UNCLASSIFIED;
      m_lastTickTestDirection=AX_TICKDIR_UNCLASSIFIED;
     }
  };
//+------------------------------------------------------------------+
#endif // AX_TICKDIRECTIONENGINE_MQH
