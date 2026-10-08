//+------------------------------------------------------------------+
//| ExecutionEngine.mqh                                                   |
//| Layer 13 — EXECUTION ENGINE, plus Section 27 (Execution Quality       |
//| Score). Sends orders via the standard CTrade wrapper, retries on      |
//| transient rejects, verifies the resulting position actually exists    |
//| (never assumes success from a return code alone), and maintains a     |
//| rolling 0-100 execution score that other engines throttle on.         |
//+------------------------------------------------------------------+
#ifndef AXF_EXECUTIONENGINE_MQH
#define AXF_EXECUTIONENGINE_MQH

#include <Trade\Trade.mqh>
#include "../Common/Defines.mqh"

//--- per-symbol rolling realized-slippage history. This is what lets the EV
//--- engine use what THIS live account actually experiences instead of a
//--- static guess — demo fills are not a reliable proxy for live slippage.
struct SAxfSlipStat
  {
   string            symbol;
   double            hist[];
   int               head;
   int               count;
   int               capacity;
  };

class CAxfExecutionEngine
  {
private:
   CTrade            m_trade;
   ulong             m_magic;
   int               m_max_retries;
   int               m_deviation_points;

   double            m_score_samples[20];
   int               m_score_count;
   int               m_score_head;

   SAxfSlipStat      m_slip[];
   int               m_slip_capacity;
   int               m_min_slip_samples;

   void              PushScoreSample(const double score)
     {
      m_score_samples[m_score_head] = score;
      m_score_head = (m_score_head+1) % 20;
      if(m_score_count<20) m_score_count++;
     }

   int               FindOrCreateSlip(const string symbol)
     {
      int n = ArraySize(m_slip);
      for(int i=0;i<n;i++) if(m_slip[i].symbol==symbol) return i;
      ArrayResize(m_slip,n+1);
      m_slip[n].symbol=symbol;
      ArrayResize(m_slip[n].hist,m_slip_capacity);
      m_slip[n].head=0; m_slip[n].count=0; m_slip[n].capacity=m_slip_capacity;
      return n;
     }

public:
                     CAxfExecutionEngine(void)
     {
      m_magic=0; m_max_retries=3; m_deviation_points=20; m_score_count=0; m_score_head=0;
      m_slip_capacity=50; m_min_slip_samples=15;
     }

   void              Init(const ulong magic,const int deviation_points,const int max_retries,
                           const int slip_history_capacity=50,const int min_slip_samples=15)
     {
      m_magic = magic;
      m_deviation_points = deviation_points;
      m_max_retries = MathMax(1,max_retries);
      m_slip_capacity = MathMax(5,slip_history_capacity);
      m_min_slip_samples = MathMax(1,min_slip_samples);
      m_trade.SetExpertMagicNumber(m_magic);
      m_trade.SetDeviationInPoints(m_deviation_points);
      m_trade.SetTypeFillingBySymbol(_Symbol);
      m_trade.SetAsyncMode(false);
      for(int i=0;i<20;i++) m_score_samples[i]=80.0; // neutral-good prior until real samples exist
      m_score_count=0; m_score_head=0;
      ArrayResize(m_slip,0);
     }

   //--- opens a market position with SL/TP, retries transient failures,
   //--- and VERIFIES the position exists afterwards. Returns the ticket, or
   //--- 0 on failure (with reason_out filled).
   ulong             OpenMarket(const string symbol,const ENUM_AXF_DIRECTION dir,
                                 const double lots,const double sl,const double tp,
                                 const string comment,string &reason_out)
     {
      reason_out = "";
      m_trade.SetExpertMagicNumber(m_magic);
      m_trade.SetDeviationInPoints(m_deviation_points);
      m_trade.SetTypeFillingBySymbol(symbol);

      double requested_price = (dir==DIR_LONG) ? SymbolInfoDouble(symbol,SYMBOL_ASK)
                                                : SymbolInfoDouble(symbol,SYMBOL_BID);

      for(int attempt=0; attempt<m_max_retries; attempt++)
        {
         bool ok;
         if(dir==DIR_LONG)
            ok = m_trade.Buy(lots,symbol,0.0,sl,tp,comment);
         else
            ok = m_trade.Sell(lots,symbol,0.0,sl,tp,comment);

         uint retcode = m_trade.ResultRetcode();

         if(ok && (retcode==TRADE_RETCODE_DONE || retcode==TRADE_RETCODE_DONE_PARTIAL))
           {
            ulong ticket = m_trade.ResultOrder();
            // give the terminal a moment to reflect the position, then verify
            if(!PositionSelectByTicket(ticket))
              {
               // fall back: find newest position on this symbol+magic
               ticket = FindLatestPositionTicket(symbol);
              }
            if(ticket>0 && PositionSelectByTicket(ticket))
              {
               double filled_price = PositionGetDouble(POSITION_PRICE_OPEN);
               double point = SymbolInfoDouble(symbol,SYMBOL_POINT);
               double slip_points = (point>0) ? MathAbs(filled_price-requested_price)/point : 0;
               RecordExecutionSample(slip_points,true);
               RecordSlippageSample(symbol,slip_points);
               return ticket;
              }
            reason_out = "order reported done but position not found on verification";
            RecordExecutionSample(999,false);
            return 0;
           }

         // retryable retcodes only; anything else (e.g. invalid stops, no money) aborts immediately
         bool retryable = (retcode==TRADE_RETCODE_REQUOTE || retcode==TRADE_RETCODE_PRICE_CHANGED ||
                           retcode==TRADE_RETCODE_TIMEOUT || retcode==TRADE_RETCODE_CONNECTION);
         if(!retryable)
           {
            reason_out = StringFormat("order rejected, retcode=%d (%s)",retcode,m_trade.ResultRetcodeDescription());
            RecordExecutionSample(999,false);
            return 0;
           }
         Sleep(200);
        }

      reason_out = "exhausted retries on transient errors";
      RecordExecutionSample(999,false);
      return 0;
     }

   //--- SNIPER ENTRY support: places a pending limit order at a precise
   //--- retracement price rather than executing at market. Verifies the order
   //--- actually exists afterwards, same discipline as OpenMarket.
   ulong             PlacePendingLimit(const string symbol,const ENUM_AXF_DIRECTION dir,
                                        const double lots,const double limit_price,
                                        const double sl,const double tp,
                                        const datetime expiration,const string comment,
                                        string &reason_out)
     {
      reason_out = "";
      m_trade.SetExpertMagicNumber(m_magic);
      m_trade.SetTypeFillingBySymbol(symbol);

      ENUM_ORDER_TYPE_TIME time_type = (expiration>0) ? ORDER_TIME_SPECIFIED : ORDER_TIME_GTC;

      for(int attempt=0; attempt<m_max_retries; attempt++)
        {
         bool ok;
         if(dir==DIR_LONG)
            ok = m_trade.BuyLimit(lots,limit_price,symbol,sl,tp,time_type,expiration,comment);
         else
            ok = m_trade.SellLimit(lots,limit_price,symbol,sl,tp,time_type,expiration,comment);

         uint retcode = m_trade.ResultRetcode();

         if(ok && (retcode==TRADE_RETCODE_DONE || retcode==TRADE_RETCODE_PLACED))
           {
            ulong order_ticket = m_trade.ResultOrder();
            if(order_ticket>0 && OrderSelect(order_ticket))
               return order_ticket;
            reason_out = "pending order reported placed but not found on verification";
            return 0;
           }

         bool retryable = (retcode==TRADE_RETCODE_REQUOTE || retcode==TRADE_RETCODE_PRICE_CHANGED ||
                           retcode==TRADE_RETCODE_TIMEOUT || retcode==TRADE_RETCODE_CONNECTION);
         if(!retryable)
           {
            reason_out = StringFormat("pending order rejected, retcode=%d (%s)",retcode,m_trade.ResultRetcodeDescription());
            return 0;
           }
         Sleep(200);
        }

      reason_out = "exhausted retries placing pending order";
      return 0;
     }

   bool              CancelPendingOrder(const ulong ticket,string &reason_out)
     {
      reason_out="";
      if(!OrderSelect(ticket)) { reason_out="order not found (already filled/cancelled)"; return false; }
      m_trade.SetExpertMagicNumber(m_magic);
      bool ok = m_trade.OrderDelete(ticket);
      if(!ok) reason_out = m_trade.ResultRetcodeDescription();
      return ok;
     }

   bool              ClosePosition(const ulong ticket,string &reason_out)
     {
      reason_out="";
      if(!PositionSelectByTicket(ticket)) { reason_out="position not found"; return false; }
      m_trade.SetExpertMagicNumber(m_magic);
      bool ok = m_trade.PositionClose(ticket,m_deviation_points);
      if(!ok) reason_out = m_trade.ResultRetcodeDescription();
      return ok;
     }

   bool              ModifySLTP(const ulong ticket,const double sl,const double tp,string &reason_out)
     {
      reason_out="";
      if(!PositionSelectByTicket(ticket)) { reason_out="position not found"; return false; }
      bool ok = m_trade.PositionModify(ticket,sl,tp);
      if(!ok) reason_out = m_trade.ResultRetcodeDescription();
      return ok;
     }

   bool              PartialClose(const ulong ticket,const double lots,string &reason_out)
     {
      reason_out="";
      if(!PositionSelectByTicket(ticket)) { reason_out="position not found"; return false; }
      bool ok = m_trade.PositionClosePartial(ticket,lots);
      if(!ok) reason_out = m_trade.ResultRetcodeDescription();
      return ok;
     }

   ulong             FindLatestPositionTicket(const string symbol)
     {
      ulong best=0; datetime best_time=0;
      for(int i=0;i<PositionsTotal();i++)
        {
         ulong t = PositionGetTicket(i);
         if(t==0) continue;
         if(!PositionSelectByTicket(t)) continue;
         if(PositionGetString(POSITION_SYMBOL)!=symbol) continue;
         if((ulong)PositionGetInteger(POSITION_MAGIC)!=m_magic) continue;
         datetime ot = (datetime)PositionGetInteger(POSITION_TIME);
         if(ot>=best_time) { best_time=ot; best=t; }
        }
      return best;
     }

   //--- 0-100 score: high slippage and rejections pull it down; clean, on-price
   //--- fills over time pull it back up. Rolling window of last 20 attempts.
   void              RecordExecutionSample(const double slippage_points,const bool succeeded)
     {
      double sample;
      if(!succeeded) sample = 0.0;
      else sample = AxfClamp(100.0 - slippage_points*4.0, 0.0, 100.0);
      PushScoreSample(sample);
     }

   double            CurrentScore(void) const
     {
      if(m_score_count==0) return 80.0;
      double sum=0; for(int i=0;i<m_score_count;i++) sum+=m_score_samples[i];
      return sum/m_score_count;
     }

   //--- per-symbol realized slippage, in points. Used by the EV engine so a
   //--- live account's actual fills — not a static assumption — drive the
   //--- cost model once enough of this account's own trades exist to trust.
   void              RecordSlippageSample(const string symbol,const double slippage_points)
     {
      int idx = FindOrCreateSlip(symbol);
      m_slip[idx].hist[m_slip[idx].head] = slippage_points;
      m_slip[idx].head = (m_slip[idx].head+1) % m_slip[idx].capacity;
      if(m_slip[idx].count<m_slip[idx].capacity) m_slip[idx].count++;
     }

   //--- returns realized average if enough samples exist; otherwise returns
   //--- 'fallback_points' unchanged (the caller's conservative static estimate).
   double            AvgSlippagePoints(const string symbol,const double fallback_points)
     {
      int n = ArraySize(m_slip);
      for(int i=0;i<n;i++)
        {
         if(m_slip[i].symbol!=symbol) continue;
         if(m_slip[i].count < m_min_slip_samples) return fallback_points;
         double sum=0; for(int k=0;k<m_slip[i].count;k++) sum+=m_slip[i].hist[k];
         double realized = sum/m_slip[i].count;
         // never let a live-observed average UNDERCUT the conservative floor —
         // only ever widen the cost assumption toward reality, never narrow it
         // below what the caller judged safe to assume with no data at all.
         return MathMax(realized,fallback_points);
        }
      return fallback_points;
     }
  };

#endif // AXF_EXECUTIONENGINE_MQH
