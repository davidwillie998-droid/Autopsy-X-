//+------------------------------------------------------------------+
//| ExecutionEngine.mqh                                                 |
//| Every order goes through: normalize -> send -> verify broker      |
//| response -> verify actual position state. Nothing is assumed      |
//| filled just because SendOrder returned without an error code.     |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_EXECUTION_EXECUTIONENGINE_MQH
#define AX_EXECUTION_EXECUTIONENGINE_MQH
#include <Trade/Trade.mqh>
#include "../core/Types.mqh"
#include "BrokerAdapter.mqh"

struct AXExecutionResult
  {
   bool     success;
   ulong    ticket;
   double   requestedPrice;
   double   executedPrice;
   double   slippagePoints;
   int      retcode;
   string   comment;
   int      retriesUsed;
  };

struct AXExecutionQualityStats
  {
   double avgSlippagePoints;
   int    rejections;
   int    requotes;
   int    sampleSize;
  };

class CExecutionEngine
  {
private:
   CTrade            m_trade;
   CBrokerAdapter    *m_broker;
   string             m_symbol;
   long               m_magic;
   int                m_maxRetries;
   int                m_deviationPoints;

   double m_slippageHistory[]; // ring-ish log for execution-quality tracking
   int    m_rejectionCount;
   int    m_requoteCount;

public:
   void Init(CBrokerAdapter *broker, const string symbol, long magic, int deviationPoints=20, int maxRetries=3)
     {
      m_broker = broker; m_symbol = symbol; m_magic = magic;
      m_deviationPoints = deviationPoints; m_maxRetries = maxRetries;
      m_trade.SetExpertMagicNumber((ulong)magic);
      m_trade.SetDeviationInPoints(deviationPoints);
      m_trade.SetTypeFillingBySymbol(symbol);
      m_trade.SetAsyncMode(false);
      ArrayResize(m_slippageHistory, 0);
      m_rejectionCount=0; m_requoteCount=0;
     }

   //--- market entry with full normalization, retry-on-requote policy, and post-send state verification
   AXExecutionResult OpenMarket(int direction, double volume, double sl, double tp, string comment)
     {
      AXExecutionResult res;
      res.success=false; res.ticket=0; res.executedPrice=0.0; res.slippagePoints=0.0; res.retcode=0; res.retriesUsed=0;

      volume = m_broker.NormalizeVolume(volume);
      if(volume < m_broker.volumeMin) { res.comment="Volume below broker minimum after normalization"; return res; }
      if(!m_broker.tradeAllowed)      { res.comment="Symbol trading not fully enabled by broker"; return res; }

      double requestedPrice = direction>0 ? m_broker.Ask() : m_broker.Bid();
      res.requestedPrice = requestedPrice;
      double slN = m_broker.NormalizePrice(sl);
      double tpN = m_broker.NormalizePrice(tp);

      if(!ValidateStopDistance(direction, requestedPrice, slN)) { res.comment="Stop violates broker minimum distance"; return res; }

      for(int attempt=0; attempt<=m_maxRetries; attempt++)
        {
         res.retriesUsed = attempt;
         bool sent = (direction>0) ? m_trade.Buy(volume, m_symbol, 0.0, slN, tpN, comment)
                                    : m_trade.Sell(volume, m_symbol, 0.0, slN, tpN, comment);
         uint retcode = m_trade.ResultRetcode();
         res.retcode = (int)retcode;

         if(sent && (retcode==TRADE_RETCODE_DONE || retcode==TRADE_RETCODE_DONE_PARTIAL))
           {
            res.executedPrice = m_trade.ResultPrice();
            if(res.executedPrice<=0.0) res.executedPrice = requestedPrice;
            res.slippagePoints = MathAbs(res.executedPrice-requestedPrice)/m_broker.point;
            LogSlippage(res.slippagePoints);

            // never trust the order/deal ticket as the position identifier - look the position up for real
            ulong verifiedTicket = 0;
            if(!VerifyPositionOpened(direction, volume, verifiedTicket))
              { res.success=false; res.comment="Broker reported success but position state did not verify"; return res; }

            res.ticket = verifiedTicket;
            res.success = true; res.comment="OK";
            return res;
           }

         if(retcode==TRADE_RETCODE_REQUOTE || retcode==TRADE_RETCODE_PRICE_CHANGED)
           {
            m_requoteCount++;
            requestedPrice = direction>0 ? m_broker.Ask() : m_broker.Bid();
            res.requestedPrice = requestedPrice;
            continue; // re-price and retry
           }

         m_rejectionCount++;
         res.comment = StringFormat("Order rejected, retcode=%d", retcode);
         break;
        }
      return res;
     }

   bool ModifyStops(ulong ticket, double newSL, double newTP)
     {
      if(!PositionSelectByTicket(ticket)) return false;
      double slN = m_broker.NormalizePrice(newSL);
      double tpN = newTP>0.0 ? m_broker.NormalizePrice(newTP) : PositionGetDouble(POSITION_TP);
      bool ok = m_trade.PositionModify(ticket, slN, tpN);
      if(!ok) return false;
      if(!PositionSelectByTicket(ticket)) return false;
      return MathAbs(PositionGetDouble(POSITION_SL)-slN) < m_broker.point*2.0;
     }

   bool ClosePartial(ulong ticket, double volume)
     {
      volume = m_broker.NormalizeVolume(volume);
      if(volume<=0.0) return false;
      if(!m_trade.PositionClosePartial(ticket, volume)) return false;
      return true; // caller re-checks remaining volume against PositionSelectByTicket
     }

   bool CloseFull(ulong ticket)
     {
      if(!m_trade.PositionClose(ticket)) return false;
      return !PositionSelectByTicket(ticket);
     }

   AXExecutionQualityStats QualityStats() const
     {
      AXExecutionQualityStats s;
      s.sampleSize = ArraySize(m_slippageHistory);
      double sum=0.0;
      for(int i=0;i<s.sampleSize;i++) sum+=m_slippageHistory[i];
      s.avgSlippagePoints = s.sampleSize>0 ? sum/s.sampleSize : 0.0;
      s.rejections = m_rejectionCount;
      s.requotes = m_requoteCount;
      return s;
     }

private:
   bool ValidateStopDistance(int direction, double price, double sl) const
     {
      double minDist = m_broker.MinStopDistance();
      if(minDist<=0.0) return true;
      double dist = MathAbs(price-sl);
      return dist >= minDist;
     }

   //--- confirm a position matching direction/approx-volume actually exists after a "successful" send,
   //--- and return its real position ticket rather than assuming it equals the order/deal ticket
   bool VerifyPositionOpened(int direction, double expectedVolume, ulong &foundTicket) const
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
         long type = PositionGetInteger(POSITION_TYPE);
         int posDir = (type==POSITION_TYPE_BUY) ? 1 : -1;
         if(posDir!=direction) continue;
         double vol = PositionGetDouble(POSITION_VOLUME);
         if(MathAbs(vol-expectedVolume) > m_broker.volumeStep) continue;
         // when several matches exist (pyramided same-direction positions), the freshest one is the one we just sent
         datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
         if(openTime >= bestTime) { bestTime = openTime; foundTicket = ticket; }
        }
      return foundTicket!=0;
     }

   void LogSlippage(double points)
     {
      int n=ArraySize(m_slippageHistory);
      if(n>=200) ArrayRemove(m_slippageHistory,0,1);
      n=ArraySize(m_slippageHistory);
      ArrayResize(m_slippageHistory,n+1);
      m_slippageHistory[n]=points;
     }
  };
#endif // AX_EXECUTION_EXECUTIONENGINE_MQH
