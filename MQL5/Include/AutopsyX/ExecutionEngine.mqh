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
      // Retry only broker-declared price/quote rejections. TIMEOUT and CONNECTION
      // are ambiguous: the server may have accepted the request before the reply
      // was lost. Those outcomes must never trigger a second market submission.
      return(code==TRADE_RETCODE_REQUOTE ||
             code==TRADE_RETCODE_PRICE_CHANGED ||
             code==TRADE_RETCODE_PRICE_OFF ||
             code==TRADE_RETCODE_REJECT);
     }

   bool              AmbiguousRetcode(const uint code) const
     {
      return(code==TRADE_RETCODE_TIMEOUT ||
             code==TRADE_RETCODE_CONNECTION ||
             code==TRADE_RETCODE_PLACED ||
             code==TRADE_RETCODE_DONE_PARTIAL);
     }

   bool              PrepareProtectionPrices(const string symbol,const ENUM_AX_DIR dir,
                                              double &sl,double &tp,const bool modifying,
                                              const double oldSl,const double oldTp,
                                              string &reason) const
     {
      reason="";
      if(dir!=AX_DIR_BUY && dir!=AX_DIR_SELL)
        { reason="INVALID_PROTECTION_DIRECTION"; return(false); }
      double point=SymbolInfoDouble(symbol,SYMBOL_POINT);
      double tickSize=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_SIZE);
      long digits=SymbolInfoInteger(symbol,SYMBOL_DIGITS);
      long stopsLevel=SymbolInfoInteger(symbol,SYMBOL_TRADE_STOPS_LEVEL);
      long freezeLevel=SymbolInfoInteger(symbol,SYMBOL_TRADE_FREEZE_LEVEL);
      if(point<=0.0 || tickSize<=0.0 || digits<0 || stopsLevel<0 || freezeLevel<0)
        { reason="BROKER_PROTECTION_METADATA_INVALID"; return(false); }
      MqlTick quote;
      if(!SymbolInfoTick(symbol,quote) || quote.bid<=0.0 || quote.ask<=0.0 || quote.ask<quote.bid)
        { reason="BROKER_PROTECTION_QUOTE_INVALID"; return(false); }
      bool roundUp=(dir==AX_DIR_BUY);
      if(sl>0.0)
         sl=NormalizeDouble((roundUp ? MathCeil(sl/tickSize-1e-10) : MathFloor(sl/tickSize+1e-10))*tickSize,(int)digits);
      if(tp>0.0)
         tp=NormalizeDouble((roundUp ? MathCeil(tp/tickSize-1e-10) : MathFloor(tp/tickSize+1e-10))*tickSize,(int)digits);
      double reference=(dir==AX_DIR_BUY)?quote.bid:quote.ask;
      double stopDistance=(double)stopsLevel*point;
      double freezeDistance=(double)freezeLevel*point;
      if(dir==AX_DIR_BUY)
        {
         if(sl>0.0 && (sl>=quote.bid || quote.bid-sl+tickSize*1e-8<stopDistance))
           { reason="BUY_STOP_INSIDE_BROKER_STOPS_LEVEL"; return(false); }
         if(tp>0.0 && (tp<=quote.bid || tp-quote.bid+tickSize*1e-8<stopDistance))
           { reason="BUY_TP_INSIDE_BROKER_STOPS_LEVEL"; return(false); }
        }
      else
        {
         if(sl>0.0 && (sl<=quote.ask || sl-quote.ask+tickSize*1e-8<stopDistance))
           { reason="SELL_STOP_INSIDE_BROKER_STOPS_LEVEL"; return(false); }
         if(tp>0.0 && (tp>=quote.ask || quote.ask-tp+tickSize*1e-8<stopDistance))
           { reason="SELL_TP_INSIDE_BROKER_STOPS_LEVEL"; return(false); }
        }
      if(modifying && freezeDistance>0.0)
        {
         bool slChanged=(sl>0.0 && MathAbs(sl-oldSl)>tickSize*0.5) || (sl<=0.0 && oldSl>0.0);
         bool tpChanged=(tp>0.0 && MathAbs(tp-oldTp)>tickSize*0.5) || (tp<=0.0 && oldTp>0.0);
         if(slChanged && sl>0.0 && MathAbs(reference-sl)<=freezeDistance)
           { reason="STOP_MODIFICATION_INSIDE_BROKER_FREEZE_LEVEL"; return(false); }
         if(tpChanged && tp>0.0 && MathAbs(reference-tp)<=freezeDistance)
           { reason="TP_MODIFICATION_INSIDE_BROKER_FREEZE_LEVEL"; return(false); }
        }
      return(true);
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

   //--- live spread can widen well beyond what a demo feed ever shows; a fixed deviation either
   //--- rejects good fills during normal spread widening or lets slippage run unchecked during
   //--- a real spike. Called with a spread-scaled value right before sending an order. ---
   void              SetDeviationPoints(const int deviationPts)
     {
      m_trade.SetDeviationInPoints(deviationPts);
     }

   //--- confirm actual open position matches expectation; never trust the send() return alone ---
   bool              ConfirmPosition(const string symbol,ENUM_AX_DIR expectedDir,const double expectedLots,
                                      ulong &ticketOut,double &fillPriceOut,double &actualLotsOut) const
     {
      actualLotsOut=0.0;
      if(!PositionSelect(symbol)) return(expectedDir==AX_DIR_NONE);
      long type = PositionGetInteger(POSITION_TYPE);
      ENUM_AX_DIR actualDir = (type==POSITION_TYPE_BUY) ? AX_DIR_BUY : AX_DIR_SELL;
      if(actualDir!=expectedDir) return(false);
      double vol = PositionGetDouble(POSITION_VOLUME);
      // A market deal may be partially filled. A smaller confirmed position is safe to
      // manage and must not be treated as a failed entry. An overfill is never accepted.
      if(vol<=0.0 || vol>expectedLots+0.0000001) return(false);
      actualLotsOut = vol;
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

   //--- market entry with confirmation + limited retry on transient broker errors. latencyMsOut  ---
   //--- measures total wall time in this call - on a live account under load (slow server round ---
   //--- trip, repeated requotes) this rises well above what a demo feed ever shows, and the      ---
   //--- caller uses it as a live-execution-quality signal alongside slippage. ---
   bool              OpenMarket(const string symbol,const ENUM_AX_DIR dir,const double lots,
                                 const double slPrice,const double tpPrice,const string comment,
                                 ulong &ticketOut,double &fillPriceOut,string &errorReason,
                                 int &latencyMsOut,double &actualLotsOut,
                                 bool &outcomeUncertain)
     {
      uint startTick = GetTickCount();
      latencyMsOut = 0;
      actualLotsOut = 0.0;
      outcomeUncertain = false;
      if(dir==AX_DIR_NONE || lots<=0) { errorReason="Invalid direction/lots"; return(false); }

      bool ok=false;
      for(int attempt=0; attempt<=m_maxRetries; attempt++)
        {
         if(attempt>0) Sleep(m_retryDelayMs);

         double freshBid = SymbolInfoDouble(symbol,SYMBOL_BID);
         double freshAsk = SymbolInfoDouble(symbol,SYMBOL_ASK);
         if(freshBid<=0 || freshAsk<=0) { errorReason="Invalid quote on retry"; continue; }
         double alignedSl=slPrice,alignedTp=tpPrice;
         if(!PrepareProtectionPrices(symbol,dir,alignedSl,alignedTp,false,0.0,0.0,errorReason))
            return(false);
         if(dir==AX_DIR_BUY)
            ok = m_trade.Buy(lots,symbol,0.0,alignedSl,alignedTp,comment);
         else
            ok = m_trade.Sell(lots,symbol,0.0,alignedSl,alignedTp,comment);

         if(ok)
           {
            latencyMsOut = (int)(GetTickCount()-startTick);
            if(ConfirmPosition(symbol,dir,lots,ticketOut,fillPriceOut,actualLotsOut))
              {
               errorReason="";
               return(true);
              }
            // The broker accepted the request, but the terminal cannot yet prove
            // the resulting position. Preserve the risk reservation and reconcile.
            outcomeUncertain=true;
            errorReason="Send reported success but position state did not confirm";
            return(false);
           }

         uint retcode = m_trade.ResultRetcode();
         errorReason = StringFormat("OrderSend failed: %u %s",retcode,m_trade.ResultRetcodeDescription());
         if(AmbiguousRetcode(retcode))
           {
            outcomeUncertain=true;
            latencyMsOut=(int)(GetTickCount()-startTick);
            return(false);
           }
         if(!RetryableRetcode(retcode)) { latencyMsOut=(int)(GetTickCount()-startTick); return(false); }
        }
      latencyMsOut = (int)(GetTickCount()-startTick);
      return(false);
     }

   //--- add to an existing NETTING position without using OpenMarket's fresh-entry
   //--- confirmation rule. This path never retries: a timeout/connection result can
   //--- represent a broker-accepted deal, so the caller must reconcile before any resend.
   bool              AddToNettingPosition(const string symbol,const ENUM_AX_DIR dir,
                                          const ulong expectedTicket,const ulong expectedPositionId,
                                          const double requestedLots,const ulong expectedMagic,
                                          const string comment,ulong &positionTicketOut,
                                          ulong &positionIdOut,ulong &orderTicketOut,
                                          double &actualAddLotsOut,double &fillPriceOut,
                                          bool &outcomeUncertain,string &errorReason)
     {
      positionTicketOut=0;
      positionIdOut=0;
      orderTicketOut=0;
      actualAddLotsOut=0.0;
      fillPriceOut=0.0;
      outcomeUncertain=false;
      errorReason="";

      if(dir!=AX_DIR_BUY && dir!=AX_DIR_SELL)
        { errorReason="Invalid pyramid direction"; return(false); }
      if(requestedLots<=0.0 || !MathIsValidNumber(requestedLots))
        { errorReason="Invalid pyramid volume"; return(false); }
      if(!PositionSelect(symbol))
        { errorReason="Existing netting position is missing"; return(false); }

      ulong beforeTicket=(ulong)PositionGetInteger(POSITION_TICKET);
      ulong beforeId=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
      long beforeType=PositionGetInteger(POSITION_TYPE);
      ENUM_AX_DIR beforeDir=(beforeType==POSITION_TYPE_BUY)?AX_DIR_BUY:AX_DIR_SELL;
      double beforeVolume=PositionGetDouble(POSITION_VOLUME);
      double beforeSl=PositionGetDouble(POSITION_SL);
      double beforeTp=PositionGetDouble(POSITION_TP);
      ulong beforeMagic=(ulong)PositionGetInteger(POSITION_MAGIC);
      double volumeStep=SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
      double tickSize=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_SIZE);
      double tolerance=MathMax(volumeStep*0.51,0.00000001);
      double priceTolerance=MathMax(tickSize*0.51,0.00000001);

      if(beforeTicket==0 || beforeId==0 || beforeTicket!=expectedTicket ||
         beforeId!=expectedPositionId || beforeMagic!=expectedMagic ||
         beforeDir!=dir || beforeVolume<=0.0 ||
         beforeSl<=0.0 || volumeStep<=0.0 || tickSize<=0.0)
        { errorReason="Existing position identity, direction, volume or protection changed"; return(false); }

      MqlTick tick;
      if(!SymbolInfoTick(symbol,tick) || tick.bid<=0.0 || tick.ask<=0.0 || tick.ask<tick.bid)
        { errorReason="Pyramid quote unavailable"; return(false); }
      if((dir==AX_DIR_BUY && beforeSl>=tick.bid) ||
         (dir==AX_DIR_SELL && beforeSl<=tick.ask))
        { errorReason="Existing protective stop is crossed or invalid"; return(false); }

      // One submission only. Even a failed return can be ambiguous at the transport layer.
      bool sent=(dir==AX_DIR_BUY)
                ?m_trade.Buy(requestedLots,symbol,0.0,beforeSl,beforeTp,comment)
                :m_trade.Sell(requestedLots,symbol,0.0,beforeSl,beforeTp,comment);
      uint retcode=m_trade.ResultRetcode();
      orderTicketOut=m_trade.ResultOrder();

      if(!sent)
        {
         outcomeUncertain=(retcode==TRADE_RETCODE_TIMEOUT ||
                           retcode==TRADE_RETCODE_CONNECTION ||
                           retcode==TRADE_RETCODE_PLACED);
         errorReason=StringFormat("Pyramid add send failed: %u %s",
                                  retcode,m_trade.ResultRetcodeDescription());
         if(PositionSelect(symbol))
           {
            ulong currentId=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
            double currentVolume=PositionGetDouble(POSITION_VOLUME);
            if(currentId==beforeId && currentVolume>beforeVolume+tolerance)
               outcomeUncertain=true;
           }
         return(false);
        }

      // A true CTrade return is not fill evidence. Reconcile the exact order's entry
      // deals against the stable position identifier and the broker's current volume.
      if(orderTicketOut==0 || !HistorySelectByPosition((long)beforeId))
        {
         outcomeUncertain=true;
         errorReason="Pyramid add accepted but order/history confirmation is not available";
         return(false);
        }

      double dealVolume=0.0;
      double dealPriceValue=0.0;
      int historyDeals=HistoryDealsTotal();
      for(int i=0;i<historyDeals;i++)
        {
         ulong deal=HistoryDealGetTicket(i);
         if(deal==0 || (ulong)HistoryDealGetInteger(deal,DEAL_ORDER)!=orderTicketOut)
            continue;
         if(HistoryDealGetInteger(deal,DEAL_ENTRY)!=DEAL_ENTRY_IN ||
            HistoryDealGetString(deal,DEAL_SYMBOL)!=symbol ||
            (ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)!=expectedMagic ||
            (ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID)!=beforeId)
            continue;
         long dealType=HistoryDealGetInteger(deal,DEAL_TYPE);
         if((dir==AX_DIR_BUY && dealType!=DEAL_TYPE_BUY) ||
            (dir==AX_DIR_SELL && dealType!=DEAL_TYPE_SELL))
            continue;
         double volume=HistoryDealGetDouble(deal,DEAL_VOLUME);
         double price=HistoryDealGetDouble(deal,DEAL_PRICE);
         if(volume<=0.0 || price<=0.0 ||
            !MathIsValidNumber(volume) || !MathIsValidNumber(price))
           {
            outcomeUncertain=true;
            errorReason="Pyramid add deal contains invalid broker data";
            return(false);
           }
         dealVolume+=volume;
         dealPriceValue+=volume*price;
        }

      if(dealVolume<=0.0 || !PositionSelect(symbol))
        {
         outcomeUncertain=true;
         errorReason="Pyramid add has no confirmed entry deal or live position";
         return(false);
        }

      ulong afterTicket=(ulong)PositionGetInteger(POSITION_TICKET);
      ulong afterId=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
      long afterType=PositionGetInteger(POSITION_TYPE);
      double afterVolume=PositionGetDouble(POSITION_VOLUME);
      double afterSl=PositionGetDouble(POSITION_SL);
      double afterTp=PositionGetDouble(POSITION_TP);
      double volumeIncrease=afterVolume-beforeVolume;
      bool sameDirection=((dir==AX_DIR_BUY && afterType==POSITION_TYPE_BUY) ||
                          (dir==AX_DIR_SELL && afterType==POSITION_TYPE_SELL));
      bool stopsPreserved=(MathAbs(afterSl-beforeSl)<=priceTolerance &&
                           MathAbs(afterTp-beforeTp)<=priceTolerance);
      bool fillMatchesPosition=(MathAbs(volumeIncrease-dealVolume)<=tolerance);
      if(afterId!=beforeId || !sameDirection || afterVolume<=beforeVolume ||
         volumeIncrease>requestedLots+tolerance || !fillMatchesPosition || !stopsPreserved)
        {
         outcomeUncertain=true;
         errorReason=StringFormat("Pyramid add broker state mismatch id=%s direction=%s volumeDelta=%.8f dealVolume=%.8f stopsPreserved=%s",
                                  afterId==beforeId?"same":"changed",
                                  sameDirection?"same":"changed",
                                  volumeIncrease,dealVolume,stopsPreserved?"true":"false");
         return(false);
        }

      positionTicketOut=afterTicket;
      positionIdOut=afterId;
      actualAddLotsOut=dealVolume;
      fillPriceOut=dealPriceValue/dealVolume;
      return(true);
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

   //--- close part of an open position (scale-out). This EA runs on NETTING accounts, where
   //--- CTrade::PositionClosePartial() is a hedging-only helper. On netting we reduce the
   //--- existing position with an opposite market deal for the exact requested volume.
   //--- close part of one broker-identified position. Ticket selection is mandatory on
   //--- hedging accounts, where symbol selection can target a different same-symbol position.
   bool              ClosePartial(const string symbol,const ulong positionTicket,
                                  const ulong expectedPositionId,const ulong expectedMagic,
                                  const double volumeToClose,string &errorReason,
                                  bool &outcomeUncertain)
     {
      outcomeUncertain=false;
      if(positionTicket==0 || expectedPositionId==0 || expectedMagic==0 ||
         !PositionSelectByTicket(positionTicket))
        { errorReason="Tracked position ticket is not open"; return(false); }
      if(PositionGetString(POSITION_SYMBOL)!=symbol ||
         (ulong)PositionGetInteger(POSITION_IDENTIFIER)!=expectedPositionId ||
         (ulong)PositionGetInteger(POSITION_MAGIC)!=expectedMagic)
        { errorReason="Tracked position identity/magic mismatch before partial close"; return(false); }
      double before=PositionGetDouble(POSITION_VOLUME);
      if(volumeToClose<=0.0 || volumeToClose>=before)
        { errorReason="Invalid partial close volume"; return(false); }

      long marginMode=AccountInfoInteger(ACCOUNT_MARGIN_MODE);
      bool isHedging=(marginMode==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
      bool ok=false;
      for(int attempt=0;attempt<=m_maxRetries;attempt++)
        {
         if(attempt>0) Sleep(m_retryDelayMs);
         if(!PositionSelectByTicket(positionTicket))
           { errorReason="Tracked position closed before partial could execute"; return(false); }
         if(PositionGetString(POSITION_SYMBOL)!=symbol ||
            (ulong)PositionGetInteger(POSITION_IDENTIFIER)!=expectedPositionId ||
            (ulong)PositionGetInteger(POSITION_MAGIC)!=expectedMagic)
           { errorReason="Tracked position identity/magic changed before partial close"; return(false); }

         if(isHedging)
            ok=m_trade.PositionClosePartial(positionTicket,volumeToClose);
         else
           {
            long type=PositionGetInteger(POSITION_TYPE);
            if(type==POSITION_TYPE_BUY) ok=m_trade.Sell(volumeToClose,symbol,0.0,0.0,0.0,"AXFDX|PARTIAL");
            else if(type==POSITION_TYPE_SELL) ok=m_trade.Buy(volumeToClose,symbol,0.0,0.0,0.0,"AXFDX|PARTIAL");
            else { errorReason="Unknown position type"; return(false); }
           }

         uint retcode=m_trade.ResultRetcode();
         bool serverAccepted=(retcode==TRADE_RETCODE_DONE || retcode==TRADE_RETCODE_DONE_PARTIAL);
         if(ok && serverAccepted)
           {
            // A server-accepted partial fill is not automatically the requested
            // volume. Reconcile any short fill or disappearance from deal history
            // before another scale-out can be attempted.
            if(!PositionSelectByTicket(positionTicket))
              {
               outcomeUncertain=true;
               errorReason="Partial close accepted but tracked position disappeared; broker/history reconciliation required";
               return(false);
              }
            if(PositionGetString(POSITION_SYMBOL)!=symbol ||
               (ulong)PositionGetInteger(POSITION_IDENTIFIER)!=expectedPositionId ||
               (ulong)PositionGetInteger(POSITION_MAGIC)!=expectedMagic)
              {
               outcomeUncertain=true;
               errorReason="Partial close accepted but tracked position identity changed; broker/history reconciliation required";
               return(false);
              }
            double after=PositionGetDouble(POSITION_VOLUME);
            double actualClosed=before-after;
            double volumeStep=SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
            double volumeTolerance=MathMax(volumeStep*0.5,0.0000001);
            if(actualClosed<=volumeTolerance || after<=0.0)
              {
               outcomeUncertain=true;
               errorReason="Partial close accepted but resulting volume is not safely reconcilable";
               return(false);
              }
            if(MathAbs(actualClosed-volumeToClose)>volumeTolerance)
              {
               outcomeUncertain=true;
               errorReason=StringFormat("Partial fill differs from requested volume (requested=%.8f confirmed=%.8f); broker/history reconciliation required",
                                        volumeToClose,actualClosed);
               return(false);
              }
            errorReason="";
            return(true);
           }

         errorReason=StringFormat("Partial close failed: %u %s",retcode,m_trade.ResultRetcodeDescription());
         // A timeout or lost connection does not prove rejection. Never resend blindly.
         if(retcode==TRADE_RETCODE_TIMEOUT || retcode==TRADE_RETCODE_CONNECTION)
           {
            outcomeUncertain=true;
            errorReason="Partial close outcome uncertain; broker reconciliation required: "+
                        m_trade.ResultRetcodeDescription();
            return(false);
           }
         if(!RetryableRetcode(retcode)) return(false);
        }
      return(false);
     }

   //--- flip = close, confirm flat, then open opposite direction ---
   bool              Flip(const string symbol,const ENUM_AX_DIR newDir,const double lots,
                           const double slPrice,const double tpPrice,const string comment,
                           ulong &ticketOut,double &fillPriceOut,string &errorReason)
     {
      if(!ClosePosition(symbol,errorReason)) return(false);
      int latencyMs;
      double actualLots;
      return(OpenMarket(symbol,newDir,lots,slPrice,tpPrice,comment,ticketOut,fillPriceOut,errorReason,latencyMs,actualLots));
     }

   bool              ModifyStops(const string symbol,const double slPrice,const double tpPrice,string &errorReason)
     {
      if(!PositionSelect(symbol)) { errorReason="No position to modify"; return(false); }
      bool ok = m_trade.PositionModify(symbol,slPrice,tpPrice);
      uint retcode = m_trade.ResultRetcode();
      if(!ok || retcode!=TRADE_RETCODE_DONE)
        {
         errorReason = StringFormat("Modify failed: %u %s",retcode,m_trade.ResultRetcodeDescription());
         return(false);
        }
      errorReason="";
      return(true);
     }

   // Ticket-specific stop modification for hedging lifecycle management.
   // Both the transient ticket and stable POSITION_IDENTIFIER are checked before
   // and after the broker call. Never fall back to symbol-based selection.
   bool              ModifyStopsByTicket(const string symbol,const ulong positionTicket,
                                          const ulong expectedPositionId,const ulong expectedMagic,
                                          const double slPrice,const double tpPrice,
                                          string &errorReason)
     {
      if(positionTicket==0 || expectedPositionId==0 || expectedMagic==0 ||
         !PositionSelectByTicket(positionTicket))
        { errorReason="Tracked position ticket is unavailable"; return(false); }
      if(PositionGetString(POSITION_SYMBOL)!=symbol ||
         (ulong)PositionGetInteger(POSITION_IDENTIFIER)!=expectedPositionId ||
         (ulong)PositionGetInteger(POSITION_MAGIC)!=expectedMagic)
        { errorReason="Tracked position identity changed before stop modification"; return(false); }

      long type=PositionGetInteger(POSITION_TYPE);
      ENUM_AX_DIR dir=(type==POSITION_TYPE_BUY)?AX_DIR_BUY:AX_DIR_SELL;
      double oldSl=PositionGetDouble(POSITION_SL),oldTp=PositionGetDouble(POSITION_TP);
      double alignedSl=slPrice,alignedTp=tpPrice;
      if(!PrepareProtectionPrices(symbol,dir,alignedSl,alignedTp,true,oldSl,oldTp,errorReason))
         return(false);
      bool ok=m_trade.PositionModify(positionTicket,alignedSl,alignedTp);
      uint retcode=m_trade.ResultRetcode();
      if(!ok || retcode!=TRADE_RETCODE_DONE)
        {
         errorReason=StringFormat("Ticket stop modification failed: %u %s",
                                  retcode,m_trade.ResultRetcodeDescription());
         return(false);
        }

      if(!PositionSelectByTicket(positionTicket) ||
         PositionGetString(POSITION_SYMBOL)!=symbol ||
         (ulong)PositionGetInteger(POSITION_IDENTIFIER)!=expectedPositionId ||
         (ulong)PositionGetInteger(POSITION_MAGIC)!=expectedMagic)
        {
         errorReason="Stop modification was accepted but the tracked position identity could not be reconfirmed";
         return(false);
        }

      double actualSl=PositionGetDouble(POSITION_SL);
      double actualTp=PositionGetDouble(POSITION_TP);
      double tickSize=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_SIZE);
      double tolerance=MathMax(tickSize*0.51,0.00000001);
      if(tickSize<=0.0 || MathAbs(actualSl-alignedSl)>tolerance ||
         MathAbs(actualTp-alignedTp)>tolerance)
        {
         errorReason="Broker accepted stop modification but confirmed levels differ from requested levels";
         return(false);
        }
      errorReason="";
      return(true);
     }

   // Ticket-specific full close. An uncertain server response is never retried,
   // and another same-symbol position can never be selected as a substitute.
   bool              ClosePositionByTicket(const string symbol,const ulong positionTicket,
                                            const ulong expectedPositionId,const ulong expectedMagic,
                                            string &errorReason,bool &outcomeUncertain)
     {
      outcomeUncertain=false;
      if(positionTicket==0 || expectedPositionId==0 || expectedMagic==0 ||
         !PositionSelectByTicket(positionTicket))
        { errorReason="Tracked position ticket is unavailable"; return(false); }
      if(PositionGetString(POSITION_SYMBOL)!=symbol ||
         (ulong)PositionGetInteger(POSITION_IDENTIFIER)!=expectedPositionId ||
         (ulong)PositionGetInteger(POSITION_MAGIC)!=expectedMagic)
        { errorReason="Tracked position identity changed before close"; return(false); }

      bool ok=m_trade.PositionClose(positionTicket);
      uint retcode=m_trade.ResultRetcode();
      bool accepted=(retcode==TRADE_RETCODE_DONE || retcode==TRADE_RETCODE_DONE_PARTIAL);
      if(!ok || !accepted)
        {
         if(retcode==TRADE_RETCODE_TIMEOUT || retcode==TRADE_RETCODE_CONNECTION)
           {
            outcomeUncertain=true;
            errorReason="Ticket close outcome uncertain; broker reconciliation required";
            return(false);
           }
         errorReason=StringFormat("Ticket close failed: %u %s",
                                  retcode,m_trade.ResultRetcodeDescription());
         return(false);
        }

      if(PositionSelectByTicket(positionTicket))
        {
         if((ulong)PositionGetInteger(POSITION_IDENTIFIER)!=expectedPositionId ||
            PositionGetString(POSITION_SYMBOL)!=symbol ||
            (ulong)PositionGetInteger(POSITION_MAGIC)!=expectedMagic)
           {
            errorReason="Original ticket remains selectable but its identity changed";
            return(false);
           }
         errorReason="Broker accepted ticket close but the tracked position remains open";
         return(false);
        }

      errorReason="";
      return(true);
     }

   //--- pending stop entry (spec section 19: "OPTIONAL BUY STOP / OPTIONAL SELL STOP"). Confirms   ---
   //--- the order genuinely exists in the terminal's order list afterward via OrderSelect - a       ---
   //--- successful CTrade send() result alone is never trusted, same discipline as OpenMarket. ---
   bool              OpenPendingStop(const string symbol,const ENUM_AX_DIR dir,const double lots,
                                      const double triggerPrice,const double slPrice,const double tpPrice,
                                      const string comment,ulong &ticketOut,string &errorReason)
     {
      if(dir==AX_DIR_NONE || lots<=0 || triggerPrice<=0)
        { errorReason="Invalid direction/lots/trigger price"; return(false); }

      bool ok=false;
      for(int attempt=0; attempt<=m_maxRetries; attempt++)
        {
         if(attempt>0) Sleep(m_retryDelayMs);

         if(dir==AX_DIR_BUY)
            ok = m_trade.BuyStop(lots,triggerPrice,symbol,slPrice,tpPrice,ORDER_TIME_GTC,0,comment);
         else
            ok = m_trade.SellStop(lots,triggerPrice,symbol,slPrice,tpPrice,ORDER_TIME_GTC,0,comment);

         if(ok)
           {
            ulong ticket = m_trade.ResultOrder();
            //--- write ticketOut even on the unconfirmed branch below - the broker may well have   ---
            //--- accepted the order (ticket>0) while the terminal's local order cache just hasn't   ---
            //--- synced yet; leaving ticketOut unset would strand the caller with no handle to later ---
            //--- verify or cancel an order that could actually be live (code-review finding). ---
            if(ticket>0) ticketOut=ticket;
            if(ticket>0 && OrderSelect(ticket))
              {
               errorReason=""; return(true);
              }
            errorReason="Pending order send reported success but order did not confirm in the order list";
            return(false);
           }

         uint retcode = m_trade.ResultRetcode();
         errorReason = StringFormat("Pending order send failed: %u %s",retcode,m_trade.ResultRetcodeDescription());
         if(!RetryableRetcode(retcode)) return(false);
        }
      return(false);
     }

   //--- cancels a pending order; treats an already-gone order (triggered, expired, manually removed) ---
   //--- as a successful outcome rather than an error - the caller's INTENT (no pending order should ---
   //--- remain) is satisfied either way. ---
   bool              CancelPendingOrder(const ulong ticket,string &errorReason)
     {
      bool ok=false;
      for(int attempt=0; attempt<=m_maxRetries; attempt++)
        {
         if(attempt>0) Sleep(m_retryDelayMs);
         if(!OrderSelect(ticket)) { errorReason=""; return(true); } // already gone - intent satisfied

         ok = m_trade.OrderDelete(ticket);
         if(ok) { errorReason=""; return(true); }

         uint retcode = m_trade.ResultRetcode();
         errorReason = StringFormat("Pending order delete failed: %u %s",retcode,m_trade.ResultRetcodeDescription());
         if(!RetryableRetcode(retcode)) return(false);
        }
      return(false);
     }

   CTrade*           TradeObject(void) { return(GetPointer(m_trade)); }
  };
//+------------------------------------------------------------------+
#endif // AX_EXECUTIONENGINE_MQH
