//+------------------------------------------------------------------+
//|                                    AutopsyCorrelationEngine.mqh   |
//|  AUTOPSY X — Correlation Protection (spec section 15)              |
//|                                                                     |
//|  Sums Nasdaq-equivalent net exposure across EVERY open position    |
//|  on the account — not just the calling EA's own trades — because   |
//|  the whole point is catching several bots on the same account      |
//|  unknowingly stacking one giant synthetic Nasdaq position. That    |
//|  only works if they share an account; a bot on a different account |
//|  is invisible to this engine by construction, and that's a real    |
//|  limitation worth knowing about, not a bug.                        |
//|                                                                     |
//|  Symbol names below are common defaults, not guarantees — verify   |
//|  them against your actual broker's Market Watch before relying on  |
//|  this engine; an unmatched symbol simply isn't counted.            |
//+------------------------------------------------------------------+
#property strict
#include "AutopsyXCommon.mqh"

struct AxCorrelatedInstrument
  {
   string symbol;
   double nasdaqBeta;   // net Nasdaq-equivalent sensitivity per 1x notional, e.g. TQQQ=3.0, SQQQ=-3.0
  };

struct AxCorrelationState
  {
   double netExposureRatio;   // net Nasdaq-equivalent notional / account equity, signed
   double grossExposureRatio; // sum of |contribution|, unsigned — how much is "in play" regardless of direction
   bool   limitBreached;
   double correlationMultiplier; // 1.0 normal .. 0.0 fully throttled, feeds the leverage model directly
  };

class CAxCorrelationEngine
  {
private:
   AxCorrelatedInstrument m_table[];
   double                 m_maxAggregateExposure; // as a multiple of equity, e.g. 2.0 = 200%

   int FindInTable(string symbol)
     {
      for(int i = 0; i < ArraySize(m_table); i++)
         if(m_table[i].symbol == symbol)
            return i;
      return -1;
     }

public:
   CAxCorrelationEngine()
     {
      m_maxAggregateExposure = 2.0;
     }

   void SetMaxAggregateExposure(double maxAsMultipleOfEquity) { m_maxAggregateExposure = MathMax(0.01, maxAsMultipleOfEquity); }

   void ClearTable() { ArrayFree(m_table); }

   void AddInstrument(string symbol, double nasdaqBeta)
     {
      int idx = FindInTable(symbol);
      if(idx >= 0) { m_table[idx].nasdaqBeta = nasdaqBeta; return; }
      int n = ArraySize(m_table);
      ArrayResize(m_table, n + 1);
      m_table[n].symbol = symbol;
      m_table[n].nasdaqBeta = nasdaqBeta;
     }

   //--- A reasonable starting point — confirm every one of these symbol
   //    names actually matches your broker before trusting the output.
   void LoadDefaultWatchlist()
     {
      AddInstrument("QQQ",     1.0);
      AddInstrument("TQQQ",    3.0);
      AddInstrument("SQQQ",   -3.0);
      AddInstrument("US100",   1.0);
      AddInstrument("USTEC",   1.0);
      AddInstrument("NAS100",  1.0);
      AddInstrument("NQ",      1.0);
      AddInstrument("MNQ",     1.0);
     }

   //--- Iterates every open position on the account, sums beta-weighted
   //    notional for anything matching the watchlist, and derives a
   //    throttle multiplier that tapers to zero as exposure nears the limit.
   AxCorrelationState Update()
     {
      AxCorrelationState s;
      s.netExposureRatio = 0.0; s.grossExposureRatio = 0.0;
      s.limitBreached = false; s.correlationMultiplier = 1.0;

      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity <= 0.0 || ArraySize(m_table) == 0)
         return s;

      double netNotional = 0.0, grossNotional = 0.0;
      int total = PositionsTotal();
      for(int i = 0; i < total; i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(!PositionSelectByTicket(ticket)) continue;

         string sym = PositionGetString(POSITION_SYMBOL);
         int idx = FindInTable(sym);
         if(idx < 0) continue;

         double volume = PositionGetDouble(POSITION_VOLUME);
         long   type   = PositionGetInteger(POSITION_TYPE);
         double contractSize = SymbolInfoDouble(sym, SYMBOL_TRADE_CONTRACT_SIZE);
         double price        = SymbolInfoDouble(sym, SYMBOL_BID);
         if(contractSize <= 0.0) contractSize = 1.0;
         if(price <= 0.0) continue;

         double notional = volume * contractSize * price;
         double sign = (type == POSITION_TYPE_BUY) ? 1.0 : -1.0;
         double contribution = sign * notional * m_table[idx].nasdaqBeta;

         netNotional   += contribution;
         grossNotional += MathAbs(contribution);
        }

      s.netExposureRatio   = netNotional / equity;
      s.grossExposureRatio = grossNotional / equity;

      double ratio = MathAbs(s.netExposureRatio) / m_maxAggregateExposure;
      s.limitBreached = (ratio >= 1.0);

      //--- smooth taper: full-size below 75% of the limit, down to zero by 125% of it
      if(ratio <= 0.75)
         s.correlationMultiplier = 1.0;
      else
         s.correlationMultiplier = AxClamp(1.0 - (ratio - 0.75) / 0.5, 0.0, 1.0);

      return s;
     }
  };
