//+------------------------------------------------------------------+
//|                                           HedgingPositionManager.mqh |
//| Broker-confirmed, ticket-by-ticket snapshot for multi-position EA |
//| This phase observes and validates positions. It does not trade.   |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_HEDGINGPOSITIONMANAGER_MQH
#define AX_HEDGINGPOSITIONMANAGER_MQH

#include "Defs.mqh"

struct SAxManagedPosition
  {
   ulong       ticket;              // refreshed broker ticket, may change after service actions
   ulong       positionIdentifier;  // stable broker identity, primary key
   string      symbol;
   ulong       magic;
   ENUM_AX_DIR direction;
   double      volume;
   double      openPrice;
   double      stopLoss;
   double      takeProfit;
   double      floatingProfit;      // POSITION_PROFIT + POSITION_SWAP
   datetime    openTime;
   bool        hasValidBrokerStop;
  };

class CHedgingPositionManager
  {
private:
   SAxManagedPosition m_positions[];
   int                m_count;
   bool               m_complete;
   bool               m_allProtected;
   bool               m_duplicateIdentity;
   string             m_failureReason;

   bool ValidNumber(const double value) const
     {
      return(MathIsValidNumber(value) && value!=EMPTY_VALUE);
     }

public:
   CHedgingPositionManager(void)
     {
      Reset();
     }

   void Reset(void)
     {
      m_count=0;
      m_complete=false;
      m_allProtected=true;
      m_duplicateIdentity=false;
      ArrayResize(m_positions,0);
      m_failureReason="";
     }

   // Enumerate every position owned by this EA on the requested symbol.
   // PositionGetTicket selects the row; PositionSelectByTicket refreshes it
   // before any properties are trusted. No request-side data is accepted.
   bool Refresh(const string symbol,const ulong magic)
     {
      Reset();
      if(StringLen(symbol)==0 || magic==0)
        {
         m_failureReason="INVALID_SYMBOL_OR_MAGIC";
         return(false);
        }

      int total=PositionsTotal();
      for(int i=0;i<total;i++)
        {
         ulong ticket=PositionGetTicket(i);
         if(ticket==0)
           {
            m_failureReason="BROKER_POSITION_ENUMERATION_FAILED";
            return(false);
           }
         if(!PositionSelectByTicket(ticket))
           {
            m_failureReason="BROKER_POSITION_REFRESH_FAILED";
            return(false);
           }

         if(PositionGetString(POSITION_SYMBOL)!=symbol ||
            (ulong)PositionGetInteger(POSITION_MAGIC)!=magic)
            continue;

         SAxManagedPosition p;
         p.ticket=(ulong)PositionGetInteger(POSITION_TICKET);
         p.positionIdentifier=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
         p.symbol=PositionGetString(POSITION_SYMBOL);
         p.magic=(ulong)PositionGetInteger(POSITION_MAGIC);
         long type=PositionGetInteger(POSITION_TYPE);
         p.direction=(type==POSITION_TYPE_BUY)?AX_DIR_BUY:
                     (type==POSITION_TYPE_SELL)?AX_DIR_SELL:AX_DIR_NONE;
         p.volume=PositionGetDouble(POSITION_VOLUME);
         p.openPrice=PositionGetDouble(POSITION_PRICE_OPEN);
         p.stopLoss=PositionGetDouble(POSITION_SL);
         p.takeProfit=PositionGetDouble(POSITION_TP);
         p.floatingProfit=PositionGetDouble(POSITION_PROFIT)+
                          PositionGetDouble(POSITION_SWAP);
         p.openTime=(datetime)PositionGetInteger(POSITION_TIME);

         if(p.ticket==0 || p.positionIdentifier==0 || p.direction==AX_DIR_NONE ||
            !ValidNumber(p.volume) || p.volume<=0.0 ||
            !ValidNumber(p.openPrice) || p.openPrice<=0.0 ||
            !ValidNumber(p.floatingProfit) || p.openTime<=0)
           {
            m_failureReason="INVALID_BROKER_POSITION_DATA";
            return(false);
           }

         // A protective stop remains valid after break-even or trailing has
         // moved it beyond entry. Validate against the current executable side,
         // not the historical entry price.
         MqlTick positionTick;
         bool quoteValid=SymbolInfoTick(p.symbol,positionTick) &&
                         positionTick.bid>0.0 && positionTick.ask>=positionTick.bid;
         p.hasValidBrokerStop=(quoteValid && p.stopLoss>0.0 &&
            ((p.direction==AX_DIR_BUY && p.stopLoss<positionTick.bid) ||
             (p.direction==AX_DIR_SELL && p.stopLoss>positionTick.ask)));
         if(!p.hasValidBrokerStop) m_allProtected=false;

         for(int j=0;j<m_count;j++)
            if(m_positions[j].positionIdentifier==p.positionIdentifier)
              {
               m_duplicateIdentity=true;
               m_failureReason="DUPLICATE_POSITION_IDENTIFIER";
               return(false);
              }

         int nextCount=m_count+1;
         if(ArrayResize(m_positions,nextCount)!=nextCount)
           {
            m_failureReason="POSITION_SNAPSHOT_ALLOCATION_FAILED";
            return(false);
           }
         m_positions[m_count]=p;
         m_count++;
        }

      m_complete=true;
      if(!m_allProtected && m_failureReason=="")
         m_failureReason="ONE_OR_MORE_POSITIONS_LACK_VALID_BROKER_STOP";
      return(true);
     }

   int Count(void) const { return(m_count); }
   bool IsComplete(void) const { return(m_complete); }
   bool AllProtected(void) const { return(m_allProtected); }
   bool HasDuplicateIdentity(void) const { return(m_duplicateIdentity); }
   string FailureReason(void) const { return(m_failureReason); }
   bool HasMultiplePositions(void) const { return(m_count>1); }

   bool GetAt(const int index,SAxManagedPosition &out) const
     {
      if(!m_complete || index<0 || index>=m_count) return(false);
      out=m_positions[index];
      return(true);
     }

   bool FindByIdentifier(const ulong positionIdentifier,SAxManagedPosition &out) const
     {
      if(!m_complete || positionIdentifier==0) return(false);
      for(int i=0;i<m_count;i++)
         if(m_positions[i].positionIdentifier==positionIdentifier)
           {
            out=m_positions[i];
            return(true);
           }
      return(false);
     }
  };

#endif // AX_HEDGINGPOSITIONMANAGER_MQH
