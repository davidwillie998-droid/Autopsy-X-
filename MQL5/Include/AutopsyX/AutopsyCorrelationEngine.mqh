//+------------------------------------------------------------------+
//| AutopsyCorrelationEngine.mqh                                        |
//| AGGREGATE_NASDAQ_EXPOSURE - scans every open position on the       |
//| account, across EVERY magic number (not just the bot this engine  |
//| is attached to), so several bots trading QQQ/TQQQ/NQ/MNQ/US100/   |
//| tech names simultaneously are seen as one synthetic Nasdaq         |
//| position rather than several independent ones.                    |
//+------------------------------------------------------------------+
#property strict
#ifndef AUTOPSYX_CORRELATIONENGINE_MQH
#define AUTOPSYX_CORRELATIONENGINE_MQH
#include "AutopsyTypes.mqh"

class CAutopsyCorrelationEngine
  {
private:
   string m_correlatedSymbols[];
   double m_correlatedWeights[]; // per-symbol beta/correlation weight vs Nasdaq, default 1.0
   double m_maxAggregateExposurePct;

   //--- accepts "SYMBOL:weight,SYMBOL2:weight2,..." or plain "SYMBOL,SYMBOL2" (weight defaults to 1.0) -
   //--- e.g. "QQQ,TQQQ:3.0,NQ:1.0,MNQ:1.0,US100:1.0" to reflect TQQQ's real ~3x beta to the index
   void ParseList(const string csv)
     {
      ArrayResize(m_correlatedSymbols,0);
      ArrayResize(m_correlatedWeights,0);
      string parts[];
      int n = StringSplit(csv, ',', parts);
      for(int i=0;i<n;i++)
        {
         string s = parts[i];
         StringTrimLeft(s); StringTrimRight(s);
         if(s=="") continue;
         double w = 1.0;
         int colon = StringFind(s, ":");
         if(colon>=0)
           {
            w = StringToDouble(StringSubstr(s, colon+1));
            if(w<=0.0) w = 1.0;
            s = StringSubstr(s, 0, colon);
           }
         int k = ArraySize(m_correlatedSymbols);
         ArrayResize(m_correlatedSymbols, k+1); ArrayResize(m_correlatedWeights, k+1);
         m_correlatedSymbols[k]=s; m_correlatedWeights[k]=w;
        }
     }

   int FindIndex(const string sym) const
     {
      for(int i=0;i<ArraySize(m_correlatedSymbols);i++)
         if(m_correlatedSymbols[i]==sym) return i;
      return -1;
     }

public:
   void Init(const string correlatedListCsv, double maxAggregateExposurePct=8.0)
     {
      ParseList(correlatedListCsv);
      m_maxAggregateExposurePct = MathMax(0.0, maxAggregateExposurePct);
     }

   int ConfiguredSymbolCount() const { return ArraySize(m_correlatedSymbols); }
   double MaxAggregateExposurePct() const { return m_maxAggregateExposurePct; }

   //--- % of account equity currently at risk across every matching open position, weighted by each
   //--- symbol's configured beta. Uses SL-based risk when a stop exists (this codebase's usual risk-%
   //--- convention); a position with NO stop falls back to a conservative 2%-of-notional estimate
   //--- rather than silently excluding an unprotected position from the tally - documented approximation,
   //--- since this engine cannot know a foreign bot's actual intended risk on an unstopped position.
   double ComputeAggregateExposurePct() const
     {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity<=0.0 || ArraySize(m_correlatedSymbols)==0) return 0.0;

      double totalRiskMoney = 0.0;
      int total = PositionsTotal();
      for(int i=0;i<total;i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
         string sym = PositionGetString(POSITION_SYMBOL);
         int idx = FindIndex(sym);
         if(idx<0) continue;

         double volume = PositionGetDouble(POSITION_VOLUME);
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double sl = PositionGetDouble(POSITION_SL);
         double point = SymbolInfoDouble(sym, SYMBOL_POINT);
         double tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
         double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);

         double riskMoney = 0.0;
         if(sl>0.0 && point>0.0 && tickSize>0.0)
           {
            double pointValue = tickValue*(point/tickSize);
            double stopDist = MathAbs(openPrice-sl);
            riskMoney = (stopDist/point)*pointValue*volume;
           }
         else
           {
            double contractSize = SymbolInfoDouble(sym, SYMBOL_TRADE_CONTRACT_SIZE);
            double price = SymbolInfoDouble(sym, SYMBOL_BID);
            if(contractSize>0.0 && price>0.0)
               riskMoney = contractSize*volume*price*0.02; // conservative notional proxy, see comment above
           }

         totalRiskMoney += riskMoney * m_correlatedWeights[idx];
        }

      return (totalRiskMoney/equity)*100.0;
     }

   bool ExceedsLimit(double &currentExposurePctOut) const
     {
      currentExposurePctOut = ComputeAggregateExposurePct();
      return currentExposurePctOut > m_maxAggregateExposurePct;
     }
  };
#endif // AUTOPSYX_CORRELATIONENGINE_MQH
