//+------------------------------------------------------------------+
//|                                                ExecutionEngine.mqh|
//|  Execution Engine (spec section 13)                              |
//|  Never assumes an order filled - always confirms actual state.    |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_EXECUTIONENGINE_MQH
#define AX_EXECUTIONENGINE_MQH
#include <Trade/Trade.mqh>
#include "Defs.mqh"
#include "MarketData.mqh"

class CExecutionEngine
  {
private:
   CTrade            m_trade;
   string            m_symbol;
   int               m_maxRetries;
   int               m_retryDelayMs;

   bool              RetryableRetcode(const uint code) const
     {
      return(code==TRADE_RETCODE_REQUOTE ||
             code==TRADE_RETCODE_PRICE_CHANGED ||
             code==TRADE_RETCODE_TIMEOUT ||
             code==TRADE_RETCODE_CONNECTION ||
             code==TRADE_RETCODE_PRICE_OFF ||
             code==TRADE_RETCODE_REJECT);
     }

   //--- brokers differ on supported order-filling modes (spec section 14) - never hard-code one ---
   ENUM_ORDER_TYPE_FILLING DetectFillingMode(const string symbol) const
     {
      int filling = (int)SymbolInfoInteger(symbol,SYMBOL_FILLING_MODE);
      if((filling & SYMBOL_FILLING_FOK)!=0) return(ORDER_FILLING_FOK);
      if((filling & SYMBOL_FILLING_IOC)!=0) return(ORDER_FILLING_IOC);
      return(ORDER_FILLING_RETURN);
     }

public:
                     CExecutionEngine(void) { m_maxRetries=2; m_retryDelayMs=200; }

   void              Init(const string symbol,const ulong magic,const int deviationPts,const int maxRetries=2)
     {
      m_symbol = symbol;
      m_trade.SetExpertMagicNumber(magic);
      m_trade.SetDeviationInPoints(deviationPts);
      m_trade.SetTypeFilling(DetectFillingMode(symbol));
      m_trade.SetAsyncMode(false);
      m_maxRetries = maxRetries;
     }

   //--- confirm actual open position matches expectation; never trust the send() return alone ---
   bool              ConfirmPosition(const string symbol,ENUM_AX_DIR expectedDir,const double expectedLots,
                                      ulong &ticketOut,double &fillPriceOut) const
     {
      if(!PositionSelect(symbol)) return(expectedDir==AX_DIR_NONE);
      long type = PositionGetInteger(POSITION_TYPE);
      ENUM_AX_DIR actualDir = (type==POSITION_TYPE_BUY) ? AX_DIR_BUY : AX_DIR_SELL;
      if(actualDir!=expectedDir) return(false);
      double vol = PositionGetDouble(POSITION_VOLUME);
      if(MathAbs(vol-expectedLots) > (expectedLots*0.05+0.0001)) return(false);
      ticketOut    = (ulong)PositionGetInteger(POSITION_TICKET);
      fillPriceOut = PositionGetDouble(POSITION_PRICE_OPEN);
      return(true);
     }

   bool              HasOpenPosition(const string symbol) const
     {
      return(PositionSelect(symbol));
     }

   ENUM_AX_DIR       CurrentPositionDir(const string symbol) const
     {
      if(!PositionSelect(symbol)) return(AX_DIR_NONE);
      long type = PositionGetInteger(POSITION_TYPE);
      return((type==POSITION_TYPE_BUY) ? AX_DIR_BUY : AX_DIR_SELL);
     }

   //--- market entry with confirmation + limited retry on transient broker errors ---
   bool              OpenMarket(const string symbol,const ENUM_AX_DIR dir,const double lots,
                                 const double slPrice,const double tpPrice,const string comment,
                                 ulong &ticketOut,double &fillPriceOut,string &errorReason)
     {
      if(dir==AX_DIR_NONE || lots<=0) { errorReason="Invalid direction/lots"; return(false); }

      bool ok=false;
      for(int attempt=0; attempt<=m_maxRetries; attempt++)
        {
         if(attempt>0) Sleep(m_retryDelayMs);

         double freshBid = SymbolInfoDouble(symbol,SYMBOL_BID);
         double freshAsk = SymbolInfoDouble(symbol,SYMBOL_ASK);
         if(freshBid<=0 || freshAsk<=0) { errorReason="Invalid quote on retry"; continue; }

         if(dir==AX_DIR_BUY)
            ok = m_trade.Buy(lots,symbol,0.0,slPrice,tpPrice,comment);
         else
            ok = m_trade.Sell(lots,symbol,0.0,slPrice,tpPrice,comment);

         if(ok)
           {
            if(ConfirmPosition(symbol,dir,lots,ticketOut,fillPriceOut))
              {
               errorReason="";
               return(true);
              }
            errorReason="Send reported success but position state did not confirm";
            return(false);
           }

         uint retcode = m_trade.ResultRetcode();
         errorReason = StringFormat("OrderSend failed: %u %s",retcode,m_trade.ResultRetcodeDescription());
         if(!RetryableRetcode(retcode)) return(false);
        }
      return(false);
     }

   //--- close whatever is open on symbol, confirm flat afterward ---
   bool              ClosePosition(const string symbol,string &errorReason)
     {
      if(!PositionSelect(symbol)) { errorReason=""; return(true); } // already flat

      bool ok=false;
      for(int attempt=0; attempt<=m_maxRetries; attempt++)
        {
         if(attempt>0) Sleep(m_retryDelayMs);
         if(!PositionSelect(symbol)) { errorReason=""; return(true); }
         ok = m_trade.PositionClose(symbol);
         if(ok)
           {
            if(!PositionSelect(symbol)) { errorReason=""; return(true); }
            errorReason="Close reported success but position still open";
           }
         else
           {
            uint retcode = m_trade.ResultRetcode();
            errorReason = StringFormat("Close failed: %u %s",retcode,m_trade.ResultRetcodeDescription());
            if(!RetryableRetcode(retcode)) return(false);
            continue;
           }
        }
      return(!PositionSelect(symbol));
     }

   //--- flip = close, confirm flat, then open opposite direction ---
   bool              Flip(const string symbol,const ENUM_AX_DIR newDir,const double lots,
                           const double slPrice,const double tpPrice,const string comment,
                           ulong &ticketOut,double &fillPriceOut,string &errorReason)
     {
      if(!ClosePosition(symbol,errorReason)) return(false);
      return(OpenMarket(symbol,newDir,lots,slPrice,tpPrice,comment,ticketOut,fillPriceOut,errorReason));
     }

   bool              ModifyStops(const string symbol,const double slPrice,const double tpPrice,string &errorReason)
     {
      if(!PositionSelect(symbol)) { errorReason="No position to modify"; return(false); }
      bool ok = m_trade.PositionModify(symbol,slPrice,tpPrice);
      if(!ok)
        {
         errorReason = StringFormat("Modify failed: %u %s",m_trade.ResultRetcode(),m_trade.ResultRetcodeDescription());
         return(false);
        }
      errorReason="";
      return(true);
     }

   CTrade*           TradeObject(void) { return(GetPointer(m_trade)); }
  };
//+------------------------------------------------------------------+
#endif // AX_EXECUTIONENGINE_MQH
