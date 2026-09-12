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

   void              PushScoreSample(const double score)
     {
      m_score_samples[m_score_head] = score;
      m_score_head = (m_score_head+1) % 20;
      if(m_score_count<20) m_score_count++;
     }

public:
                     CAxfExecutionEngine(void) { m_magic=0; m_max_retries=3; m_deviation_points=20; m_score_count=0; m_score_head=0; }

   void              Init(const ulong magic,const int deviation_points,const int max_retries)
     {
      m_magic = magic;
      m_deviation_points = deviation_points;
      m_max_retries = MathMax(1,max_retries);
      m_trade.SetExpertMagicNumber(m_magic);
      m_trade.SetDeviationInPoints(m_deviation_points);
      m_trade.SetTypeFillingBySymbol(_Symbol);
      m_trade.SetAsyncMode(false);
      for(int i=0;i<20;i++) m_score_samples[i]=80.0; // neutral-good prior until real samples exist
      m_score_count=0; m_score_head=0;
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
  };

#endif // AXF_EXECUTIONENGINE_MQH
