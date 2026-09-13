//+------------------------------------------------------------------+
//| ExecutionEngine.mqh                                                 |
//| Every order goes through: margin pre-check -> normalize -> send  |
//| -> verify broker response -> verify actual position state.       |
//| Nothing is assumed filled just because SendOrder returned without |
//| an error code, and nothing here assumes a live broker behaves     |
//| like a demo server: filling-mode rejection, partial fills, and    |
//| variable slippage are all handled as first-class outcomes.        |
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
   double   requestedVolume;
   double   filledVolume;
   bool     partialFill;
   long     latencyMs;
   int      retcode;
   string   comment;
   int      retriesUsed;
  };

struct AXExecutionQualityStats
  {
   double avgSlippagePoints;
   double avgLatencyMs;
   int    rejections;
   int    requotes;
   int    partialFills;
   int    fillingModeFallbacks;
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

   double m_slippageHistory[]; // rolling execution-quality log - this account's own real fills, not a guess
   long   m_latencyHistory[];
   int    m_rejectionCount;
   int    m_requoteCount;
   int    m_partialFillCount;
   int    m_fillingFallbackCount;

public:
   void Init(CBrokerAdapter *broker, const string symbol, long magic, int deviationPoints=20, int maxRetries=3)
     {
      m_broker = broker; m_symbol = symbol; m_magic = magic;
      m_deviationPoints = deviationPoints; m_maxRetries = maxRetries;
      m_trade.SetExpertMagicNumber((ulong)magic);
      m_trade.SetAsyncMode(false);
      ArrayResize(m_slippageHistory, 0);
      ArrayResize(m_latencyHistory, 0);
      m_rejectionCount=0; m_requoteCount=0; m_partialFillCount=0; m_fillingFallbackCount=0;
     }

   //--- market entry: margin-checked, filling-mode-fallback, requote-retried, and state-verified on real fill volume
   AXExecutionResult OpenMarket(int direction, double volume, double sl, double tp, string comment)
     {
      AXExecutionResult res;
      res.success=false; res.ticket=0; res.executedPrice=0.0; res.slippagePoints=0.0; res.retcode=0;
      res.retriesUsed=0; res.filledVolume=0.0; res.partialFill=false; res.latencyMs=0;

      volume = m_broker.NormalizeVolume(volume);
      res.requestedVolume = volume;
      if(volume < m_broker.volumeMin) { res.comment="Volume below broker minimum after normalization"; return res; }
      if(!m_broker.tradeAllowed)      { res.comment="Symbol trading not fully enabled by broker"; return res; }

      double requestedPrice = direction>0 ? m_broker.Ask() : m_broker.Bid();
      res.requestedPrice = requestedPrice;
      double slN = m_broker.NormalizePrice(sl);
      double tpN = m_broker.NormalizePrice(tp);

      if(!ValidateStopDistance(direction, requestedPrice, slN)) { res.comment="Stop violates broker minimum distance"; return res; }

      string marginReason;
      if(!HasSufficientMargin(direction, volume, requestedPrice, marginReason))
        { res.comment=marginReason; return res; }

      if(m_broker.volumeLimit>0.0 && (TotalSymbolVolume()+volume) > m_broker.volumeLimit)
        { res.comment=StringFormat("Would exceed broker's aggregate volume limit (%.2f) on this symbol", m_broker.volumeLimit); return res; }

      // live spreads run wider than demo and move between quote and send - a fixed tight deviation
      // just manufactures rejections/requotes on a real server, so scale it to what's actually quoted now
      int deviation = (int)MathMax(m_deviationPoints, MathMin(m_broker.SpreadPoints()*1.5, m_deviationPoints*5));
      m_trade.SetDeviationInPoints(deviation);

      int fillingIdx = 0;
      m_trade.SetTypeFilling((ENUM_ORDER_TYPE_FILLING)m_broker.FillingModeAt(fillingIdx));

      for(int attempt=0; attempt<=m_maxRetries; attempt++)
        {
         res.retriesUsed = attempt;
         ulong t0 = GetMicrosecondCount();
         bool sent = (direction>0) ? m_trade.Buy(volume, m_symbol, 0.0, slN, tpN, comment)
                                    : m_trade.Sell(volume, m_symbol, 0.0, slN, tpN, comment);
         ulong t1 = GetMicrosecondCount();
         uint retcode = m_trade.ResultRetcode();
         res.retcode = (int)retcode;

         if(sent && (retcode==TRADE_RETCODE_DONE || retcode==TRADE_RETCODE_DONE_PARTIAL))
           {
            res.latencyMs = (long)((t1-t0)/1000);
            LogLatency(res.latencyMs);

            double filled = m_trade.ResultVolume();
            if(filled<=0.0) filled = volume; // some brokers omit this on the return struct; don't fabricate a shortfall
            res.filledVolume = filled;
            res.partialFill = (retcode==TRADE_RETCODE_DONE_PARTIAL) || (volume-filled > m_broker.volumeStep);
            if(res.partialFill) m_partialFillCount++;

            res.executedPrice = m_trade.ResultPrice();
            if(res.executedPrice<=0.0) res.executedPrice = requestedPrice;
            res.slippagePoints = MathAbs(res.executedPrice-requestedPrice)/m_broker.point;
            LogSlippage(res.slippagePoints);

            // never trust the order/deal ticket as the position identifier - and verify against the
            // ACTUAL filled volume, not the originally requested one, or a genuine partial fill on a
            // live broker gets misreported as "failed to verify" while a real position sits unmanaged
            ulong verifiedTicket = 0;
            if(!VerifyPositionOpened(direction, filled, verifiedTicket))
              { res.success=false; res.comment="Broker reported success but position state did not verify"; return res; }

            res.ticket = verifiedTicket;
            res.success = true;
            res.comment = res.partialFill ? StringFormat("Partial fill: %.2f of %.2f", filled, volume) : "OK";
            return res;
           }

         if(retcode==TRADE_RETCODE_REQUOTE || retcode==TRADE_RETCODE_PRICE_CHANGED)
           {
            m_requoteCount++;
            requestedPrice = direction>0 ? m_broker.Ask() : m_broker.Bid();
            res.requestedPrice = requestedPrice;
            continue; // re-price and retry, same filling mode
           }

         if(retcode==TRADE_RETCODE_INVALID_FILL && fillingIdx+1 < m_broker.FillingModeCount())
           {
            // this is a live-only failure mode in practice: many demo servers accept any filling type,
            // ECN/STP live venues often don't, and the broker's advertised support flags aren't always right
            fillingIdx++;
            m_fillingFallbackCount++;
            m_trade.SetTypeFilling((ENUM_ORDER_TYPE_FILLING)m_broker.FillingModeAt(fillingIdx));
            attempt--; // don't burn a requote-retry slot on a fill-mode swap
            continue;
           }

         m_rejectionCount++;
         res.comment = StringFormat("Order rejected, retcode=%d", retcode);
         break;
        }
      return res;
     }

   //--- sniper entry: a resting limit order at a precise price, not a market chase. Same margin/volume-limit/
   //--- stop-distance discipline as OpenMarket, evaluated against the LIMIT price since that's where it fills.
   AXExecutionResult OpenLimit(int direction, double volume, double limitPrice, double sl, double tp, string comment, ulong &orderTicket)
     {
      AXExecutionResult res;
      res.success=false; res.ticket=0; res.executedPrice=0.0; res.slippagePoints=0.0; res.retcode=0;
      res.retriesUsed=0; res.filledVolume=0.0; res.partialFill=false; res.latencyMs=0;
      orderTicket = 0;

      volume = m_broker.NormalizeVolume(volume);
      res.requestedVolume = volume;
      if(volume < m_broker.volumeMin) { res.comment="Volume below broker minimum after normalization"; return res; }
      if(!m_broker.tradeAllowed)      { res.comment="Symbol trading not fully enabled by broker"; return res; }

      double priceN = m_broker.NormalizePrice(limitPrice);
      double slN = m_broker.NormalizePrice(sl);
      double tpN = m_broker.NormalizePrice(tp);
      res.requestedPrice = priceN;

      // a buy limit must sit below current ask, a sell limit above current bid - reject a limit price that
      // would fill immediately (that's not a resting sniper order, that's a market order in disguise)
      if(direction>0 && priceN >= m_broker.Ask()) { res.comment="Buy limit at/above market - not a resting order"; return res; }
      if(direction<0 && priceN <= m_broker.Bid()) { res.comment="Sell limit at/below market - not a resting order"; return res; }

      if(!ValidateStopDistance(direction, priceN, slN)) { res.comment="Stop violates broker minimum distance"; return res; }

      string marginReason;
      if(!HasSufficientMargin(direction, volume, priceN, marginReason))
        { res.comment=marginReason; return res; }

      if(m_broker.volumeLimit>0.0 && (TotalSymbolVolume()+volume) > m_broker.volumeLimit)
        { res.comment=StringFormat("Would exceed broker's aggregate volume limit (%.2f) on this symbol", m_broker.volumeLimit); return res; }

      int fillingIdx = 0;
      m_trade.SetTypeFilling((ENUM_ORDER_TYPE_FILLING)m_broker.FillingModeAt(fillingIdx));

      for(int attempt=0; attempt<=m_maxRetries; attempt++)
        {
         res.retriesUsed = attempt;
         bool sent = (direction>0) ? m_trade.BuyLimit(volume, priceN, m_symbol, slN, tpN, ORDER_TIME_GTC, 0, comment)
                                    : m_trade.SellLimit(volume, priceN, m_symbol, slN, tpN, ORDER_TIME_GTC, 0, comment);
         uint retcode = m_trade.ResultRetcode();
         res.retcode = (int)retcode;

         if(sent && retcode==TRADE_RETCODE_DONE)
           {
            orderTicket = m_trade.ResultOrder();
            res.ticket = orderTicket;
            res.success = (orderTicket!=0);
            res.comment = res.success ? "Sniper limit order placed" : "Broker accepted but returned no order ticket";
            return res;
           }

         if(retcode==TRADE_RETCODE_INVALID_FILL && fillingIdx+1 < m_broker.FillingModeCount())
           {
            fillingIdx++;
            m_fillingFallbackCount++;
            m_trade.SetTypeFilling((ENUM_ORDER_TYPE_FILLING)m_broker.FillingModeAt(fillingIdx));
            attempt--;
            continue;
           }

         m_rejectionCount++;
         res.comment = StringFormat("Limit order rejected, retcode=%d", retcode);
         break;
        }
      return res;
     }

   //--- pull a resting sniper order - either it's stale (expired) or the setup's own invalidation fired
   bool CancelOrder(ulong orderTicket)
     {
      if(!OrderSelect(orderTicket)) return true; // already gone (filled or removed) - nothing to cancel
      return m_trade.OrderDelete(orderTicket);
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

      int latN = ArraySize(m_latencyHistory);
      long latSum=0;
      for(int i=0;i<latN;i++) latSum+=m_latencyHistory[i];
      s.avgLatencyMs = latN>0 ? (double)latSum/latN : 0.0;

      s.rejections = m_rejectionCount;
      s.requotes = m_requoteCount;
      s.partialFills = m_partialFillCount;
      s.fillingModeFallbacks = m_fillingFallbackCount;
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

   //--- sum of this symbol's own open position volume (SYMBOL_VOLUME_LIMIT is a per-symbol aggregate cap
   //--- some brokers enforce - commonly on indices/commodities - that demo servers often don't bother with)
   double TotalSymbolVolume() const
     {
      double total = 0.0;
      int positions = PositionsTotal();
      for(int i=0;i<positions;i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
         if(PositionGetString(POSITION_SYMBOL)!=m_symbol) continue;
         total += PositionGetDouble(POSITION_VOLUME);
        }
      return total;
     }

   //--- real broker margin check before sending - a live account's free margin is what it is, never assumed
   bool HasSufficientMargin(int direction, double volume, double price, string &reason) const
     {
      ENUM_ORDER_TYPE orderType = direction>0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double requiredMargin = 0.0;
      if(!OrderCalcMargin(orderType, m_symbol, volume, price, requiredMargin))
        { reason = "Could not calculate required margin - refusing to trade blind"; return false; }
      double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(requiredMargin > freeMargin*0.95) // small buffer - never spend right up to the edge of a margin call
        {
         reason = StringFormat("Insufficient margin: needs %.2f, free %.2f", requiredMargin, freeMargin);
         return false;
        }
      reason = "";
      return true;
     }

   //--- confirm a position matching direction/actual-filled-volume exists after a "successful" send,
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

   void LogLatency(long ms)
     {
      int n=ArraySize(m_latencyHistory);
      if(n>=200) ArrayRemove(m_latencyHistory,0,1);
      n=ArraySize(m_latencyHistory);
      ArrayResize(m_latencyHistory,n+1);
      m_latencyHistory[n]=ms;
     }
  };
#endif // AX_EXECUTION_EXECUTIONENGINE_MQH
