//+------------------------------------------------------------------+
//| PendingOrderManager.mqh                                            |
//| Owns the sniper limit-order lifecycle: place one precise order,    |
//| watch it, pull it the moment the setup's own story dies (price     |
//| trades past the invalidation point) or the window closes (expiry) |
//| without a fill, and report back the real position when it does    |
//| fill - never assuming the order ticket becomes the position ticket|
//| (that assumption was already wrong once for market fills; it's    |
//| just as wrong here).                                              |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_EXECUTION_PENDINGORDERMANAGER_MQH
#define AX_EXECUTION_PENDINGORDERMANAGER_MQH
#include "../core/Types.mqh"
#include "ExecutionEngine.mqh"
#include "BrokerAdapter.mqh"

class CPendingOrderManager
  {
private:
   AXPendingOrder    m_orders[];
   CExecutionEngine *m_exec;
   CBrokerAdapter   *m_broker;
   string            m_symbol;
   long              m_magic;
   int               m_maxConcurrent;

   void RemoveAt(int idx)
     {
      int n = ArraySize(m_orders);
      for(int i=idx;i<n-1;i++) m_orders[i]=m_orders[i+1];
      ArrayResize(m_orders,n-1);
     }

   //--- a triggered pending order is not guaranteed to hand its own ticket number to the resulting
   //--- position, so find it the same defensive way ExecutionEngine verifies a fresh market fill:
   //--- matching symbol/magic/direction/volume, opened no earlier than when this order was placed
   bool FindResultingPosition(const AXPendingOrder &p, ulong &foundTicket) const
     {
      int total = PositionsTotal();
      datetime bestTime = 0;
      foundTicket = 0;
      for(int i=0;i<total;i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
         if(PositionGetString(POSITION_SYMBOL)!=m_symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC)!=m_magic) continue;
         datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
         if(openTime < p.placedTime-5) continue; // must have opened at/after this order was placed
         long type = PositionGetInteger(POSITION_TYPE);
         int posDir = (type==POSITION_TYPE_BUY) ? 1 : -1;
         if(posDir!=p.direction) continue;
         double vol = PositionGetDouble(POSITION_VOLUME);
         if(MathAbs(vol-p.volume) > m_broker.volumeStep*2.0) continue; // allow for a partial fill on trigger
         if(openTime >= bestTime) { bestTime = openTime; foundTicket = ticket; }
        }
      return foundTicket!=0;
     }

public:
   void Init(CExecutionEngine *exec, CBrokerAdapter *broker, const string symbol, long magic, int maxConcurrent=1)
     {
      m_exec=exec; m_broker=broker; m_symbol=symbol; m_magic=magic;
      m_maxConcurrent = MathMax(1, maxConcurrent);
      ArrayResize(m_orders, 0);
     }

   int Count() const { return ArraySize(m_orders); }
   AXPendingOrder GetOrder(int i) const { return m_orders[i]; }
   bool HasRoom() const { return ArraySize(m_orders) < m_maxConcurrent; }

   //--- place one sniper limit order. Returns false without side effects if there's no room or the broker refuses it.
   bool Place(const AXSignal &sig, double confidence, ENUM_AX_QUALITY quality, ENUM_AX_REGIME regime,
              double expectedR, const string macroContext, double volume, int expirySeconds, const string comment,
              string &failReason)
     {
      failReason = "";
      if(!HasRoom()) { failReason="Already have a sniper order working - one shot at a time"; return false; }

      ulong orderTicket = 0;
      AXExecutionResult res = m_exec.OpenLimit(sig.direction, volume, sig.entryPrice, sig.stopLoss, sig.tpFinal, comment, orderTicket);
      if(!res.success) { failReason=res.comment; return false; }

      AXPendingOrder p;
      p.orderTicket=orderTicket; p.setup=sig.setup; p.direction=sig.direction;
      p.entryPrice=sig.entryPrice; p.stopLoss=sig.stopLoss; p.tp1=sig.tp1; p.tp2=sig.tp2; p.tpFinal=sig.tpFinal;
      p.liquidityTarget=sig.liquidityTarget; p.invalidationPrice=sig.invalidationPrice; p.volume=res.requestedVolume;
      p.confidence=confidence; p.quality=quality; p.regime=regime; p.expectedR=expectedR;
      p.macroContext=macroContext; p.whyNow=sig.rationaleWhyNow; p.whyHere=sig.rationaleWhyHere;
      p.placedTime=TimeCurrent(); p.expiryTime=TimeCurrent()+MathMax(60,expirySeconds);

      int n=ArraySize(m_orders); ArrayResize(m_orders,n+1); m_orders[n]=p;
      return true;
     }

   //--- call every tick: cancels dead/stale orders, and returns the ones that just filled (with the real position ticket)
   int UpdateAndCollectFilled(AXPendingOrder &filled[], ulong &filledPositionTickets[])
     {
      ArrayResize(filled,0);
      ArrayResize(filledPositionTickets,0);

      for(int i=ArraySize(m_orders)-1; i>=0; i--)
        {
         AXPendingOrder p = m_orders[i];
         bool stillPending = OrderSelect(p.orderTicket);

         if(!stillPending)
           {
            ulong posTicket=0;
            if(FindResultingPosition(p, posTicket))
              {
               int n=ArraySize(filled); ArrayResize(filled,n+1); filled[n]=p;
               ArrayResize(filledPositionTickets,n+1); filledPositionTickets[n]=posTicket;
              }
            // else: broker cancelled/rejected/expired it server-side without a fill - just drop it, nothing to manage
            RemoveAt(i);
            continue;
           }

         double price = m_broker.Mid();
         bool invalidated = (p.direction>0 && price < p.invalidationPrice) ||
                             (p.direction<0 && price > p.invalidationPrice);
         bool expired = TimeCurrent() >= p.expiryTime;
         if(invalidated || expired)
           {
            m_exec.CancelOrder(p.orderTicket);
            RemoveAt(i);
           }
        }
      return ArraySize(filled);
     }

   //--- pull every resting order unconditionally (emergency stop, shutdown, or a hard drawdown trip)
   void CancelAll()
     {
      for(int i=ArraySize(m_orders)-1; i>=0; i--)
        {
         m_exec.CancelOrder(m_orders[i].orderTicket);
         RemoveAt(i);
        }
     }
  };
#endif // AX_EXECUTION_PENDINGORDERMANAGER_MQH
