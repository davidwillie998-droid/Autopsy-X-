//+------------------------------------------------------------------+
//| ExecutionEngine.mqh                                               |
//| Precise order-state management: builds requests directly (not a   |
//| generic wrapper), retries transient broker errors with bounded    |
//| backoff, and records signal/submit/fill timestamps + slippage for |
//| every trade so execution quality is measurable, not assumed.      |
//+------------------------------------------------------------------+
#pragma once
#include <AutopsyX/Defines.mqh>
#include <AutopsyX/SymbolProfile.mqh>

struct AXExecResult
{
   bool     success;
   ulong    order_ticket;
   ulong    deal_ticket;
   double   requested_price;
   double   filled_price;
   double   slippage_points;
   ulong    submit_msc;
   ulong    fill_msc;
   int      retcode;
   string   comment;
};

class CAXExecution
{
private:
   long     m_magic;
   int      m_deviationPoints;
   int      m_maxRetries;
   int      m_retryDelayMs;

   ENUM_ORDER_TYPE_FILLING DetectFilling(const string symbol) const
   {
      int flags = (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
      if((flags & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
      if((flags & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
      return ORDER_FILLING_RETURN;
   }

   bool IsRetryable(const int retcode) const
   {
      return retcode == TRADE_RETCODE_REQUOTE ||
             retcode == TRADE_RETCODE_PRICE_CHANGED ||
             retcode == TRADE_RETCODE_TIMEOUT ||
             retcode == TRADE_RETCODE_PRICE_OFF ||
             retcode == TRADE_RETCODE_CONNECTION;
   }

public:
   CAXExecution(void) : m_magic(0), m_deviationPoints(20), m_maxRetries(2), m_retryDelayMs(150) {}

   void Init(const long magic, const int deviationPoints, const int maxRetries, const int retryDelayMs)
   {
      m_magic = magic;
      m_deviationPoints = deviationPoints;
      m_maxRetries = MathMax(0, maxRetries);
      m_retryDelayMs = MathMax(0, retryDelayMs);
   }

   AXExecResult OpenMarketOrder(const CAXSymbolProfile &profile, const ENUM_AX_DIRECTION direction,
                                 double lots, const double sl, const double tp, const string comment)
   {
      AXExecResult out;
      out.success = false; out.order_ticket = 0; out.deal_ticket = 0;
      out.requested_price = 0; out.filled_price = 0; out.slippage_points = 0;
      out.submit_msc = 0; out.fill_msc = 0; out.retcode = -1; out.comment = "";

      lots = profile.NormalizeVolume(lots);
      ENUM_ORDER_TYPE otype = (direction == AX_DIR_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

      int attempts = 0;
      while(attempts <= m_maxRetries)
      {
         double price = (direction == AX_DIR_BUY) ? SymbolInfoDouble(profile.symbol, SYMBOL_ASK)
                                                    : SymbolInfoDouble(profile.symbol, SYMBOL_BID);
         if(price <= 0.0) { out.retcode = -2; out.comment = "invalid price"; break; }

         MqlTradeRequest req;
         MqlTradeResult  res;
         ZeroMemory(req);
         ZeroMemory(res);

         req.action       = TRADE_ACTION_DEAL;
         req.symbol       = profile.symbol;
         req.volume       = lots;
         req.type         = otype;
         req.price        = price;
         req.sl            = sl;
         req.tp            = tp;
         req.deviation     = m_deviationPoints;
         req.magic         = (ulong)m_magic;
         req.comment       = comment;
         req.type_time     = ORDER_TIME_GTC;
         req.type_filling  = DetectFilling(profile.symbol);

         out.requested_price = price;
         out.submit_msc = GetMicrosecondCount() / 1000;

         bool sent = OrderSend(req, res);

         out.fill_msc = GetMicrosecondCount() / 1000;
         out.retcode = (int)res.retcode;

         if(sent && (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_DONE_PARTIAL))
         {
            out.success = true;
            out.order_ticket = res.order;
            out.deal_ticket  = res.deal;
            out.filled_price = (res.price > 0.0) ? res.price : price;
            double deltaPrice = (direction == AX_DIR_BUY) ? (out.filled_price - out.requested_price)
                                                            : (out.requested_price - out.filled_price);
            out.slippage_points = profile.PriceToPoints(deltaPrice);
            out.comment = "filled";
            return out;
         }

         if(!IsRetryable((int)res.retcode))
         {
            out.comment = StringFormat("rejected: retcode=%d %s", res.retcode, res.comment);
            return out;
         }

         attempts++;
         if(attempts <= m_maxRetries)
            Sleep(m_retryDelayMs);
      }

      out.comment = StringFormat("failed after retries: retcode=%d", out.retcode);
      return out;
   }

   bool ClosePosition(const CAXSymbolProfile &profile, const ulong ticket, string &errComment)
   {
      if(!PositionSelectByTicket(ticket))
      {
         errComment = "position not found";
         return false;
      }
      double lots = PositionGetDouble(POSITION_VOLUME);
      long ptype  = PositionGetInteger(POSITION_TYPE);
      ENUM_ORDER_TYPE otype = (ptype == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;

      int attempts = 0;
      while(attempts <= m_maxRetries)
      {
         double price = (otype == ORDER_TYPE_SELL) ? SymbolInfoDouble(profile.symbol, SYMBOL_BID)
                                                     : SymbolInfoDouble(profile.symbol, SYMBOL_ASK);
         MqlTradeRequest req;
         MqlTradeResult  res;
         ZeroMemory(req);
         ZeroMemory(res);

         req.action      = TRADE_ACTION_DEAL;
         req.symbol      = profile.symbol;
         req.volume      = lots;
         req.type        = otype;
         req.position    = ticket;
         req.price       = price;
         req.deviation    = m_deviationPoints;
         req.magic        = (ulong)m_magic;
         req.type_filling = DetectFilling(profile.symbol);

         bool sent = OrderSend(req, res);
         if(sent && (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_DONE_PARTIAL))
            return true;

         if(!IsRetryable((int)res.retcode))
         {
            errComment = StringFormat("close rejected: retcode=%d %s", res.retcode, res.comment);
            return false;
         }
         attempts++;
         if(attempts <= m_maxRetries) Sleep(m_retryDelayMs);
      }
      errComment = "close failed after retries";
      return false;
   }

   bool ModifyPosition(const CAXSymbolProfile &profile, const ulong ticket, const double sl, const double tp)
   {
      MqlTradeRequest req;
      MqlTradeResult  res;
      ZeroMemory(req);
      ZeroMemory(res);

      req.action   = TRADE_ACTION_SLTP;
      req.symbol   = profile.symbol;
      req.position = ticket;
      req.sl        = sl;
      req.tp        = tp;
      req.magic     = (ulong)m_magic;

      return OrderSend(req, res) && (res.retcode == TRADE_RETCODE_DONE);
   }
};
