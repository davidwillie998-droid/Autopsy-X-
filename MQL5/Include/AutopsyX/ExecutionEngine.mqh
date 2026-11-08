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
   ulong             m_magic;
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
         if(slChanged && oldSl>0.0 && MathAbs(reference-oldSl)<=freezeDistance)
           { reason="STOP_MODIFICATION_INSIDE_BROKER_FREEZE_LEVEL"; return(false); }
         if(tpChanged && oldTp>0.0 && MathAbs(reference-oldTp)<=freezeDistance)
           { reason="TP_MODIFICATION_INSIDE_BROKER_FREEZE_LEVEL"; return(false); }
         if(slChanged && sl>0.0 && MathAbs(reference-sl)<=freezeDistance)
           { reason="STOP_MODIFICATION_INSIDE_BROKER_FREEZE_LEVEL"; return(false); }
         if(tpChanged && tp>0.0 && MathAbs(reference-tp)<=freezeDistance)
           { reason="TP_MODIFICATION_INSIDE_BROKER_FREEZE_LEVEL"; return(false); }
        }
      return(true);
     }

   //--- brokers differ on supported order-filling modes (spec section 14) - never hard-code one ---
   bool              DetectFillingMode(const string symbol,ENUM_ORDER_TYPE_FILLING &mode) const
     {
      int filling=(int)SymbolInfoInteger(symbol,SYMBOL_FILLING_MODE);
      long execution=SymbolInfoInteger(symbol,SYMBOL_TRADE_EXEMODE);
      // IOC permits a broker-confirmed partial fill; prefer it when available.
      if((filling & SYMBOL_FILLING_IOC)!=0)
        { mode=ORDER_FILLING_IOC; return(true); }
      if((filling & SYMBOL_FILLING_FOK)!=0)
        { mode=ORDER_FILLING_FOK; return(true); }
      // RETURN is not legal under Market Execution.
      if(execution!=SYMBOL_TRADE_EXECUTION_MARKET)
        { mode=ORDER_FILLING_RETURN; return(true); }
      return(false);
     }

public:
                     CExecutionEngine(void) { m_magic=0; m_maxRetries=2; m_retryDelayMs=200; }

   bool              Init(const string symbol,const ulong magic,const int deviationPts,const int maxRetries=2)
     {
      ENUM_ORDER_TYPE_FILLING fillingMode;
      if(!DetectFillingMode(symbol,fillingMode))
        {
         PrintFormat("FLIPDEMON EXECUTION BLOCK: no supported filling policy for %s under Market Execution.",symbol);
         return(false);
        }
      m_symbol = symbol;
      m_magic = magic;
      m_trade.SetExpertMagicNumber(magic);
      m_trade.SetDeviationInPoints(deviationPts);
      m_trade.SetTypeFilling(fillingMode);
      m_trade.SetAsyncMode(false);
      m_maxRetries = maxRetries;
      return(true);
     }

   //--- live spread can widen well beyond what a demo feed ever shows; a fixed deviation either
   //--- rejects good fills during normal spread widening or lets slippage run unchecked during
   //--- a real spike. Called with a spread-scaled value right before sending an order. ---
   void              SetDeviationPoints(const int deviationPts)
     {
      m_trade.SetDeviationInPoints(deviationPts);
     }

   // Verify broker-retained protection after the exact fill is confirmed.
   // If repair cannot be confirmed, submit one ticket-specific emergency close.
   // Every failure remains uncertain until the caller reconciles broker state.
   bool              EnsurePostFillProtection(const string symbol,const ENUM_AX_DIR expectedDir,
                                               const ulong positionTicket,const double expectedSl,
                                               const double expectedTp,bool &outcomeUncertain,
                                               string &errorReason)
     {
      outcomeUncertain=false;
      errorReason="";
      if(positionTicket==0)
        {
         outcomeUncertain=true;
         errorReason="POST_FILL_POSITION_TICKET_INVALID";
         return(false);
        }
      if(!PositionSelectByTicket(positionTicket))
        {
         outcomeUncertain=true;
         errorReason="POST_FILL_POSITION_NOT_VISIBLE_FOR_PROTECTION_CHECK";
         return(false);
        }

      ulong positionId=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
      ulong positionMagic=(ulong)PositionGetInteger(POSITION_MAGIC);
      long positionType=PositionGetInteger(POSITION_TYPE);
      if(positionType!=POSITION_TYPE_BUY && positionType!=POSITION_TYPE_SELL)
        {
         outcomeUncertain=true;
         errorReason="POST_FILL_POSITION_TYPE_INVALID";
         return(false);
        }
      ENUM_AX_DIR liveDir=(positionType==POSITION_TYPE_BUY)?AX_DIR_BUY:AX_DIR_SELL;
      if(PositionGetString(POSITION_SYMBOL)!=symbol || positionId==0 ||
         positionMagic!=m_magic || liveDir!=expectedDir)
        {
         outcomeUncertain=true;
         errorReason="POST_FILL_POSITION_IDENTITY_MISMATCH";
         return(false);
        }

      double volumeBeforeClose=PositionGetDouble(POSITION_VOLUME);
      double actualSl=PositionGetDouble(POSITION_SL);
      double actualTp=PositionGetDouble(POSITION_TP);
      double tickSize=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_SIZE);
      if(volumeBeforeClose<=0.0)
        {
         outcomeUncertain=true;
         errorReason="POST_FILL_POSITION_VOLUME_INVALID";
         return(false);
        }

      string repairReason="";
      bool expectedProtectionValid=(expectedSl>0.0 && MathIsValidNumber(expectedSl) &&
                                    MathIsValidNumber(expectedTp));
      if(!expectedProtectionValid)
         repairReason="EXPECTED_PROTECTION_INPUT_INVALID";
      else if(tickSize<=0.0)
         repairReason="BROKER_TICK_SIZE_INVALID";
      double tolerance=(tickSize>0.0)?MathMax(tickSize*0.51,0.00000001):0.0;
      if(expectedProtectionValid && tickSize>0.0 &&
         MathAbs(actualSl-expectedSl)<=tolerance &&
         MathAbs(actualTp-expectedTp)<=tolerance)
         return(true);

      double repairSl=expectedSl;
      double repairTp=expectedTp;
      bool repairPrepared=(expectedProtectionValid && tickSize>0.0 &&
         PrepareProtectionPrices(symbol,expectedDir,repairSl,repairTp,
                                  true,actualSl,actualTp,repairReason));
      bool repairSent=false;
      uint repairRetcode=0;
      int repairTerminalError=0;
      if(repairPrepared)
        {
         ResetLastError();
         repairSent=m_trade.PositionModify(positionTicket,repairSl,repairTp);
         repairTerminalError=GetLastError();
         repairRetcode=m_trade.ResultRetcode();
        }
      else
         repairReason="PROTECTION_REPAIR_PREFLIGHT_FAILED: "+repairReason;

      if(repairSent && repairRetcode==TRADE_RETCODE_DONE &&
         PositionSelectByTicket(positionTicket) &&
         PositionGetString(POSITION_SYMBOL)==symbol &&
         (ulong)PositionGetInteger(POSITION_IDENTIFIER)==positionId &&
         (ulong)PositionGetInteger(POSITION_MAGIC)==m_magic)
        {
         double verifiedSl=PositionGetDouble(POSITION_SL);
         double verifiedTp=PositionGetDouble(POSITION_TP);
         if(MathAbs(verifiedSl-repairSl)<=tolerance &&
            MathAbs(verifiedTp-repairTp)<=tolerance)
           {
            PrintFormat("FLIPDEMON PROTECTION REPAIRED: ticket=%I64u positionId=%I64u SL=%.10f TP=%.10f.",
                        positionTicket,positionId,verifiedSl,verifiedTp);
            return(true);
           }
         repairReason="BROKER_REPAIR_LEVELS_DID_NOT_MATCH_REQUEST";
        }
      else if(repairPrepared)
         repairReason=StringFormat("PROTECTION_REPAIR_FAILED retcode=%u terminalError=%d %s",
                                   repairRetcode,repairTerminalError,
                                   m_trade.ResultRetcodeDescription());

      // A filled position without the approved protection is not allowed to remain
      // unmanaged. Close only the exact ticket and verify the exact close deal.
      ResetLastError();
      bool closeSent=m_trade.PositionClose(positionTicket);
      int closeTerminalError=GetLastError();
      uint closeRetcode=m_trade.ResultRetcode();
      ulong closeOrder=m_trade.ResultOrder();
      ulong closeDeal=m_trade.ResultDeal();
      bool closeDealValid=false;
      double closedVolume=0.0;
      if(closeOrder>0 && closeDeal>0 && HistoryDealSelect(closeDeal) &&
         (ulong)HistoryDealGetInteger(closeDeal,DEAL_ORDER)==closeOrder &&
         HistoryDealGetString(closeDeal,DEAL_SYMBOL)==symbol &&
         (ulong)HistoryDealGetInteger(closeDeal,DEAL_MAGIC)==m_magic &&
         (ulong)HistoryDealGetInteger(closeDeal,DEAL_POSITION_ID)==positionId)
        {
         long resultEntry=HistoryDealGetInteger(closeDeal,DEAL_ENTRY);
         closeDealValid=(resultEntry==DEAL_ENTRY_OUT || resultEntry==DEAL_ENTRY_OUT_BY);
         if(closeDealValid && HistorySelectByPosition((long)positionId))
           {
            int historyCount=HistoryDealsTotal();
            for(int i=0;i<historyCount;i++)
              {
               ulong dealTicket=HistoryDealGetTicket(i);
               if(dealTicket==0 ||
                  (ulong)HistoryDealGetInteger(dealTicket,DEAL_ORDER)!=closeOrder ||
                  HistoryDealGetString(dealTicket,DEAL_SYMBOL)!=symbol ||
                  (ulong)HistoryDealGetInteger(dealTicket,DEAL_MAGIC)!=m_magic ||
                  (ulong)HistoryDealGetInteger(dealTicket,DEAL_POSITION_ID)!=positionId)
                  continue;
               long entry=HistoryDealGetInteger(dealTicket,DEAL_ENTRY);
               if(entry!=DEAL_ENTRY_OUT && entry!=DEAL_ENTRY_OUT_BY) continue;
               double dealVolume=HistoryDealGetDouble(dealTicket,DEAL_VOLUME);
               if(dealVolume<=0.0 || !MathIsValidNumber(dealVolume))
                 {
                  closeDealValid=false;
                  break;
                 }
               closedVolume+=dealVolume;
              }
           }
         else
            closeDealValid=false;
        }
      double volumeStep=SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
      double volumeTolerance=MathMax(volumeStep*0.51,0.00000001);
      bool positionFlat=!PositionSelectByTicket(positionTicket);
      bool closeConfirmed=(closeSent || closeRetcode==TRADE_RETCODE_DONE ||
                           closeRetcode==TRADE_RETCODE_DONE_PARTIAL) &&
                          closeDealValid && positionFlat && volumeStep>0.0 &&
                          closedVolume+volumeTolerance>=volumeBeforeClose;

      outcomeUncertain=true;
      errorReason=StringFormat("POST_FILL_PROTECTION_UNVERIFIED; repair=%s; emergencyClose=%s; closeRetcode=%u terminalError=%d closeOrder=%I64u closeDeal=%I64u closedVolume=%.8f expectedVolume=%.8f",
                               repairReason,closeConfirmed?"CONFIRMED":"UNCONFIRMED",
                               closeRetcode,closeTerminalError,closeOrder,closeDeal,
                               closedVolume,volumeBeforeClose);
      PrintFormat("FLIPDEMON CRITICAL: %s",errorReason);
      return(false);
     }

   //--- confirm a fresh entry from its exact broker order and entry deals.
   //--- Symbol-level aggregate volume is not fill evidence: it can include another
   //--- position, a pre-existing net position, or unrelated same-symbol activity.
   bool              ConfirmMarketOrder(const string symbol,const ENUM_AX_DIR expectedDir,
                                         const double requestedLots,const ulong orderTicket,
                                         ulong &ticketOut,double &fillPriceOut,
                                         double &actualLotsOut) const
     {
      ticketOut=0;
      fillPriceOut=0.0;
      actualLotsOut=0.0;
      if(orderTicket==0) return(false);

      ulong resultDeal=m_trade.ResultDeal();
      if(resultDeal==0 || !HistoryDealSelect(resultDeal)) return(false);
      // The CTrade result ticket itself must belong to this exact order and
      // expected entry. Never use a stale or unrelated last-deal identifier.
      if((ulong)HistoryDealGetInteger(resultDeal,DEAL_ORDER)!=orderTicket ||
         HistoryDealGetString(resultDeal,DEAL_SYMBOL)!=symbol ||
         (ulong)HistoryDealGetInteger(resultDeal,DEAL_MAGIC)!=m_magic ||
         HistoryDealGetInteger(resultDeal,DEAL_ENTRY)!=DEAL_ENTRY_IN)
         return(false);
      long resultType=HistoryDealGetInteger(resultDeal,DEAL_TYPE);
      if((expectedDir==AX_DIR_BUY && resultType!=DEAL_TYPE_BUY) ||
         (expectedDir==AX_DIR_SELL && resultType!=DEAL_TYPE_SELL))
         return(false);
      ulong positionId=(ulong)HistoryDealGetInteger(resultDeal,DEAL_POSITION_ID);
      if(positionId==0 || !HistorySelectByPosition((long)positionId)) return(false);

      double dealVolume=0.0;
      double dealPriceValue=0.0;
      int dealCount=HistoryDealsTotal();
      for(int i=0;i<dealCount;i++)
        {
         ulong deal=HistoryDealGetTicket(i);
         if(deal==0 || (ulong)HistoryDealGetInteger(deal,DEAL_ORDER)!=orderTicket)
            continue;
         if(HistoryDealGetInteger(deal,DEAL_ENTRY)!=DEAL_ENTRY_IN ||
            HistoryDealGetString(deal,DEAL_SYMBOL)!=symbol ||
            (ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)!=m_magic ||
            (ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID)!=positionId)
            continue;
         long dealType=HistoryDealGetInteger(deal,DEAL_TYPE);
         if((expectedDir==AX_DIR_BUY && dealType!=DEAL_TYPE_BUY) ||
            (expectedDir==AX_DIR_SELL && dealType!=DEAL_TYPE_SELL))
            continue;
         double volume=HistoryDealGetDouble(deal,DEAL_VOLUME);
         double price=HistoryDealGetDouble(deal,DEAL_PRICE);
         if(volume<=0.0 || price<=0.0 ||
            !MathIsValidNumber(volume) || !MathIsValidNumber(price))
            return(false);
         dealVolume+=volume;
         dealPriceValue+=volume*price;
        }

      double step=SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
      double tolerance=MathMax(step*0.51,0.00000001);
      if(dealVolume<=0.0 || dealVolume>requestedLots+tolerance || step<=0.0)
         return(false);

      // Locate the exact broker position by stable identifier. This works on both
      // netting and hedging accounts and never adopts another same-symbol position.
      for(int index=PositionsTotal()-1;index>=0;index--)
        {
         ulong ticket=PositionGetTicket(index);
         if(ticket==0 || !PositionSelectByTicket(ticket))
            continue;
         if((ulong)PositionGetInteger(POSITION_IDENTIFIER)!=positionId ||
            PositionGetString(POSITION_SYMBOL)!=symbol ||
            (ulong)PositionGetInteger(POSITION_MAGIC)!=m_magic)
            continue;
         long positionType=PositionGetInteger(POSITION_TYPE);
         bool directionOk=(expectedDir==AX_DIR_BUY && positionType==POSITION_TYPE_BUY) ||
                          (expectedDir==AX_DIR_SELL && positionType==POSITION_TYPE_SELL);
         double liveVolume=PositionGetDouble(POSITION_VOLUME);
         // A fresh entry must account for the complete live position. If another
         // transaction changed it during confirmation, leave the outcome unresolved.
         if(!directionOk || liveVolume<=0.0 ||
            MathAbs(liveVolume-dealVolume)>tolerance)
            return(false);
         ticketOut=ticket;
         actualLotsOut=dealVolume;
         fillPriceOut=dealPriceValue/dealVolume;
         return(true);
        }
      return(false);
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
      uint startTick=GetTickCount();
      latencyMsOut=0;
      actualLotsOut=0.0;
      ticketOut=0;
      fillPriceOut=0.0;
      outcomeUncertain=false;
      if((dir!=AX_DIR_BUY && dir!=AX_DIR_SELL) || lots<=0.0 ||
         !MathIsValidNumber(lots))
        { errorReason="Invalid direction/lots"; return(false); }
      // This is a fresh-entry API. Do not merge into or accidentally adopt an
      // existing same-symbol position, regardless of account margin mode.
      if(PositionSelect(symbol))
        { errorReason="Fresh entry blocked: a same-symbol position already exists"; return(false); }

      for(int attempt=0;attempt<=m_maxRetries;attempt++)
        {
         if(attempt>0) Sleep(m_retryDelayMs);
         if(PositionSelect(symbol))
           {
            outcomeUncertain=true;
            errorReason="Same-symbol position appeared before retry; broker reconciliation required";
            latencyMsOut=(int)(GetTickCount()-startTick);
            return(false);
           }

         double freshBid=SymbolInfoDouble(symbol,SYMBOL_BID);
         double freshAsk=SymbolInfoDouble(symbol,SYMBOL_ASK);
         if(freshBid<=0.0 || freshAsk<=0.0)
           { errorReason="Invalid quote on retry"; continue; }
         double alignedSl=slPrice,alignedTp=tpPrice;
         if(!PrepareProtectionPrices(symbol,dir,alignedSl,alignedTp,false,0.0,0.0,errorReason))
            return(false);

         bool sent=(dir==AX_DIR_BUY)
                   ?m_trade.Buy(lots,symbol,0.0,alignedSl,alignedTp,comment)
                   :m_trade.Sell(lots,symbol,0.0,alignedSl,alignedTp,comment);
         uint retcode=m_trade.ResultRetcode();
         ulong orderTicket=m_trade.ResultOrder();
         latencyMsOut=(int)(GetTickCount()-startTick);

         // CTrade's bool is only the local request/result-structure status. The
         // exact order's entry deals and resulting broker position are authoritative.
         if(ConfirmMarketOrder(symbol,dir,lots,orderTicket,ticketOut,
                               fillPriceOut,actualLotsOut))
           {
            if(!EnsurePostFillProtection(symbol,dir,ticketOut,alignedSl,alignedTp,
                                         outcomeUncertain,errorReason))
              {
               outcomeUncertain=true;
               latencyMsOut=(int)(GetTickCount()-startTick);
               return(false);
              }
            errorReason="";
            return(true); // confirmed fill and broker-retained protection; IOC partial fills are valid
           }

         bool acceptedOrUnresolved=(sent ||
             retcode==TRADE_RETCODE_DONE ||
             retcode==TRADE_RETCODE_DONE_PARTIAL ||
             retcode==TRADE_RETCODE_PLACED ||
             AmbiguousRetcode(retcode));
         if(acceptedOrUnresolved)
           {
            outcomeUncertain=true;
            errorReason=StringFormat("Market order outcome not fully reconciled: order=%I64u retcode=%u %s",
                                     orderTicket,retcode,m_trade.ResultRetcodeDescription());
            return(false); // never resend an accepted or ambiguous market request
           }

         errorReason=StringFormat("OrderSend failed: %u %s",
                                  retcode,m_trade.ResultRetcodeDescription());
         if(!RetryableRetcode(retcode))
            return(false);
        }
      latencyMsOut=(int)(GetTickCount()-startTick);
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
      if(!PrepareProtectionPrices(symbol,dir,beforeSl,beforeTp,false,0.0,0.0,errorReason))
         return(false);

      // One submission only. Even a failed return can be ambiguous at the transport layer.
      bool sent=(dir==AX_DIR_BUY)
                ?m_trade.Buy(requestedLots,symbol,0.0,beforeSl,beforeTp,comment)
                :m_trade.Sell(requestedLots,symbol,0.0,beforeSl,beforeTp,comment);
      uint retcode=m_trade.ResultRetcode();
      orderTicketOut=m_trade.ResultOrder();

      if(!sent)
        {
         outcomeUncertain=(retcode==TRADE_RETCODE_DONE ||
                           retcode==TRADE_RETCODE_DONE_PARTIAL ||
                           retcode==TRADE_RETCODE_TIMEOUT ||
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

   //--- close one exact broker position and reconcile the exact close order/deals ---
   bool              ClosePosition(const string symbol,const ulong positionTicket,
                                   const ulong expectedPositionId,const ulong expectedMagic,
                                   string &errorReason,bool &outcomeUncertain)
     {
      outcomeUncertain=false;
      if(positionTicket==0 || expectedPositionId==0 || expectedMagic==0 ||
         !PositionSelectByTicket(positionTicket))
        { errorReason="Tracked position unavailable before full close"; return(false); }
      if(PositionGetString(POSITION_SYMBOL)!=symbol ||
         (ulong)PositionGetInteger(POSITION_IDENTIFIER)!=expectedPositionId ||
         (ulong)PositionGetInteger(POSITION_MAGIC)!=expectedMagic)
        { errorReason="Tracked position identity/magic mismatch before full close"; return(false); }
      double beforeVolume=PositionGetDouble(POSITION_VOLUME);
      long positionType=PositionGetInteger(POSITION_TYPE);
      if(beforeVolume<=0.0 || (positionType!=POSITION_TYPE_BUY && positionType!=POSITION_TYPE_SELL))
        { errorReason="Invalid broker position snapshot before full close"; return(false); }

      // Submit once. Partial IOC fills and lost acknowledgements must be reconciled,
      // never blindly retried as a second full close.
      bool sent=m_trade.PositionClose(positionTicket);
      uint retcode=m_trade.ResultRetcode();
      ulong orderTicket=m_trade.ResultOrder();
      ulong resultDeal=m_trade.ResultDeal();
      bool accepted=(retcode==TRADE_RETCODE_DONE || retcode==TRADE_RETCODE_DONE_PARTIAL ||
                     retcode==TRADE_RETCODE_PLACED);
      if(!accepted && !sent)
        {
         errorReason=StringFormat("Full close rejected: %u %s",retcode,m_trade.ResultRetcodeDescription());
         outcomeUncertain=(retcode==TRADE_RETCODE_TIMEOUT || retcode==TRADE_RETCODE_CONNECTION ||
                           retcode==TRADE_RETCODE_PLACED || retcode==TRADE_RETCODE_DONE_PARTIAL);
         return(false);
        }
      if(orderTicket==0 || resultDeal==0 || !HistoryDealSelect(resultDeal) ||
         (ulong)HistoryDealGetInteger(resultDeal,DEAL_ORDER)!=orderTicket ||
         HistoryDealGetString(resultDeal,DEAL_SYMBOL)!=symbol ||
         (ulong)HistoryDealGetInteger(resultDeal,DEAL_MAGIC)!=expectedMagic ||
         (ulong)HistoryDealGetInteger(resultDeal,DEAL_POSITION_ID)!=expectedPositionId)
        {
         outcomeUncertain=true;
         errorReason="Full close accepted but exact result deal identity is unavailable";
         return(false);
        }
      if(!HistorySelectByPosition((long)expectedPositionId))
        {
         outcomeUncertain=true;
         errorReason="Full close accepted but position deal history is unavailable";
         return(false);
        }
      double closedVolume=0.0;
      for(int i=0;i<HistoryDealsTotal();i++)
        {
         ulong deal=HistoryDealGetTicket(i);
         if(deal==0 || (ulong)HistoryDealGetInteger(deal,DEAL_ORDER)!=orderTicket)
            continue;
         if(HistoryDealGetString(deal,DEAL_SYMBOL)!=symbol ||
            (ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)!=expectedMagic ||
            (ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID)!=expectedPositionId)
            continue;
         long entry=HistoryDealGetInteger(deal,DEAL_ENTRY);
         if(entry!=DEAL_ENTRY_OUT && entry!=DEAL_ENTRY_OUT_BY) continue;
         long dealType=HistoryDealGetInteger(deal,DEAL_TYPE);
         if((positionType==POSITION_TYPE_BUY && dealType!=DEAL_TYPE_SELL) ||
            (positionType==POSITION_TYPE_SELL && dealType!=DEAL_TYPE_BUY))
            continue;
         double volume=HistoryDealGetDouble(deal,DEAL_VOLUME);
         if(volume<=0.0 || !MathIsValidNumber(volume))
           {
            outcomeUncertain=true;
            errorReason="Full close deal contains invalid volume";
            return(false);
           }
         closedVolume+=volume;
        }
      double step=SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
      double tolerance=MathMax(step*0.51,0.0000001);
      if(!PositionSelectByTicket(positionTicket))
        {
         if(closedVolume+tolerance<beforeVolume)
           {
            outcomeUncertain=true;
            errorReason=StringFormat("Flat position but close deals account for %.8f of %.8f lots",closedVolume,beforeVolume);
            return(false);
           }
         errorReason="";
         return(true);
        }
      if((ulong)PositionGetInteger(POSITION_IDENTIFIER)!=expectedPositionId ||
         (ulong)PositionGetInteger(POSITION_MAGIC)!=expectedMagic)
        {
         outcomeUncertain=true;
         errorReason="Full close accepted but tracked position identity changed";
         return(false);
        }
      double afterVolume=PositionGetDouble(POSITION_VOLUME);
      double observedClosed=beforeVolume-afterVolume;
      if(observedClosed>tolerance || closedVolume>tolerance)
        {
         outcomeUncertain=true;
         errorReason=StringFormat("Full close partially executed: broker reduction %.8f, exact close deals %.8f; no retry sent",
                                  observedClosed,closedVolume);
         return(false);
        }
      outcomeUncertain=true;
      errorReason=StringFormat("Full close response not reflected in broker state: %u %s",
                               retcode,m_trade.ResultRetcodeDescription());
      return(false);
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
         ulong orderTicket=m_trade.ResultOrder();
         ulong resultDeal=m_trade.ResultDeal();
         bool serverAccepted=(retcode==TRADE_RETCODE_DONE || retcode==TRADE_RETCODE_DONE_PARTIAL);
         if(ok && serverAccepted)
           {
            if(orderTicket==0 || resultDeal==0 || !HistoryDealSelect(resultDeal) ||
               (ulong)HistoryDealGetInteger(resultDeal,DEAL_ORDER)!=orderTicket ||
               HistoryDealGetString(resultDeal,DEAL_SYMBOL)!=symbol ||
               (ulong)HistoryDealGetInteger(resultDeal,DEAL_MAGIC)!=expectedMagic ||
               (ulong)HistoryDealGetInteger(resultDeal,DEAL_POSITION_ID)!=expectedPositionId)
              {
               outcomeUncertain=true;
               errorReason="Partial close accepted but exact result deal identity is unavailable";
               return(false);
              }
            long expectedCloseType=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)
                                   ?DEAL_TYPE_SELL:DEAL_TYPE_BUY;
            if(HistoryDealGetInteger(resultDeal,DEAL_ENTRY)!=DEAL_ENTRY_OUT &&
               HistoryDealGetInteger(resultDeal,DEAL_ENTRY)!=DEAL_ENTRY_OUT_BY)
              {
               outcomeUncertain=true;
               errorReason="Partial close result is not an exit deal";
               return(false);
              }
            if(HistoryDealGetInteger(resultDeal,DEAL_TYPE)!=expectedCloseType)
              {
               outcomeUncertain=true;
               errorReason="Partial close deal direction does not reduce tracked position";
               return(false);
              }
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
            if(!HistorySelectByPosition((long)expectedPositionId))
              {
               outcomeUncertain=true;
               errorReason="Partial close position history is unavailable";
               return(false);
              }
            double exactOrderClosed=0.0;
            for(int dealIndex=0;dealIndex<HistoryDealsTotal();dealIndex++)
              {
               ulong closeDeal=HistoryDealGetTicket(dealIndex);
               if(closeDeal==0 || (ulong)HistoryDealGetInteger(closeDeal,DEAL_ORDER)!=orderTicket)
                  continue;
               if(HistoryDealGetString(closeDeal,DEAL_SYMBOL)!=symbol ||
                  (ulong)HistoryDealGetInteger(closeDeal,DEAL_MAGIC)!=expectedMagic ||
                  (ulong)HistoryDealGetInteger(closeDeal,DEAL_POSITION_ID)!=expectedPositionId)
                  continue;
               long closeEntry=HistoryDealGetInteger(closeDeal,DEAL_ENTRY);
               if(closeEntry!=DEAL_ENTRY_OUT && closeEntry!=DEAL_ENTRY_OUT_BY) continue;
               exactOrderClosed+=HistoryDealGetDouble(closeDeal,DEAL_VOLUME);
              }
            if(MathAbs(exactOrderClosed-actualClosed)>volumeTolerance)
              {
               outcomeUncertain=true;
               errorReason=StringFormat("Partial close deal/position mismatch: order deals %.8f, broker volume reduction %.8f",
                                        exactOrderClosed,actualClosed);
               return(false);
              }
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

         if(serverAccepted || retcode==TRADE_RETCODE_PLACED)
           {
            outcomeUncertain=true;
            errorReason=StringFormat("Partial close server response is accepted/placed but CTrade did not confirm completion: %u %s; no retry sent",
                                     retcode,m_trade.ResultRetcodeDescription());
            return(false);
           }

         errorReason=StringFormat("Partial close failed: %u %s",retcode,m_trade.ResultRetcodeDescription());
         // A timeout or lost connection does not prove rejection. Never resend blindly.
         if(retcode==TRADE_RETCODE_TIMEOUT || retcode==TRADE_RETCODE_CONNECTION ||
            retcode==TRADE_RETCODE_PLACED)
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
   bool              Flip(const string symbol,const ulong oldPositionTicket,
                           const ulong oldPositionId,const ulong oldMagic,
                           const ENUM_AX_DIR newDir,const double lots,
                           const double slPrice,const double tpPrice,const string comment,
                           ulong &ticketOut,double &fillPriceOut,string &errorReason,
                           bool &outcomeUncertain)
     {
      outcomeUncertain=false;
      if(!ClosePosition(symbol,oldPositionTicket,oldPositionId,oldMagic,
                        errorReason,outcomeUncertain))
         return(false);
      int latencyMs;
      double actualLots;
      bool openOutcomeUncertain=false;
      bool opened=OpenMarket(symbol,newDir,lots,slPrice,tpPrice,comment,ticketOut,fillPriceOut,
                             errorReason,latencyMs,actualLots,openOutcomeUncertain);
      outcomeUncertain=openOutcomeUncertain;
      return(opened);
     }

   bool              ModifyStops(const string symbol,const double slPrice,const double tpPrice,string &errorReason)
     {
      if(!PositionSelect(symbol)) { errorReason="No position to modify"; return(false); }
      ulong ticket=(ulong)PositionGetInteger(POSITION_TICKET);
      ulong positionId=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
      ulong magic=(ulong)PositionGetInteger(POSITION_MAGIC);
      return(ModifyStopsByTicket(symbol,ticket,positionId,magic,slPrice,tpPrice,errorReason));
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
