//+------------------------------------------------------------------+
//| CorrelationEngine.mqh                                              |
//| Real Pearson correlation between the traded symbol and a          |
//| configured watch-list (DXY, yields proxy via bond CFDs, silver,   |
//| USDJPY, indices, BTC), computed from actual price history.        |
//| Degrades gracefully when a symbol isn't offered by the broker.    |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_INTELLIGENCE_CORRELATIONENGINE_MQH
#define AX_INTELLIGENCE_CORRELATIONENGINE_MQH
#include "../core/Types.mqh"

#define AX_MAX_CORR_SYMBOLS 12

class CCorrelationEngine
  {
private:
   string m_watchSymbols[AX_MAX_CORR_SYMBOLS];
   int    m_watchCount;

   bool SymbolUsable(const string sym) const
     {
      if(!SymbolSelect(sym, true)) return false;
      return SymbolInfoInteger(sym, SYMBOL_SELECT)!=0;
     }

   double PearsonCorrelation(const string symA, const string symB, ENUM_TIMEFRAMES tf, int bars) const
     {
      MqlRates ra[], rb[];
      int ca = CopyRates(symA, tf, 0, bars, ra);
      int cb = CopyRates(symB, tf, 0, bars, rb);
      int n = MathMin(ca, cb);
      if(n < 20) return 0.0;

      double retA[]; double retB[];
      ArrayResize(retA, n-1); ArrayResize(retB, n-1);
      ArraySetAsSeries(ra, true); ArraySetAsSeries(rb, true);
      for(int i=0;i<n-1;i++)
        {
         retA[i] = (ra[i].close - ra[i+1].close);
         retB[i] = (rb[i].close - rb[i+1].close);
        }
      double meanA=0.0, meanB=0.0;
      for(int i=0;i<n-1;i++) { meanA+=retA[i]; meanB+=retB[i]; }
      meanA/=(n-1); meanB/=(n-1);

      double cov=0.0, varA=0.0, varB=0.0;
      for(int i=0;i<n-1;i++)
        {
         double da=retA[i]-meanA, db=retB[i]-meanB;
         cov  += da*db;
         varA += da*da;
         varB += db*db;
        }
      if(varA<=0.0 || varB<=0.0) return 0.0;
      return cov / MathSqrt(varA*varB);
     }

public:
   void Init()
     {
      m_watchCount=0;
     }

   //--- add a symbol only if the broker actually offers it; silently skipped otherwise (graceful degradation)
   bool AddWatchSymbol(const string sym)
     {
      if(m_watchCount>=AX_MAX_CORR_SYMBOLS) return false;
      if(!SymbolUsable(sym)) return false;
      m_watchSymbols[m_watchCount] = sym;
      m_watchCount++;
      return true;
     }

   int WatchCount() const { return m_watchCount; }
   string WatchSymbol(int i) const { return (i>=0 && i<m_watchCount) ? m_watchSymbols[i] : ""; }

   double CorrelationWith(const string tradedSymbol, const string otherSymbol, ENUM_TIMEFRAMES tf=PERIOD_D1, int bars=90) const
     {
      if(!SymbolUsable(otherSymbol)) return 0.0;
      return PearsonCorrelation(tradedSymbol, otherSymbol, tf, bars);
     }

   //--- sum |correlation|-weighted open risk across positions on symbols highly correlated to the candidate
   double CorrelatedOpenRiskPercent(const string candidateSymbol, long magic, double corrThreshold=0.6) const
     {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity<=0.0) return 0.0;
      double totalRiskMoney = 0.0;
      int total = PositionsTotal();
      for(int i=0;i<total;i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
         if(PositionGetInteger(POSITION_MAGIC)!=magic) continue;
         string posSymbol = PositionGetString(POSITION_SYMBOL);
         if(posSymbol==candidateSymbol) continue;
         double corr = PearsonCorrelation(candidateSymbol, posSymbol, PERIOD_D1, 90);
         if(MathAbs(corr) < corrThreshold) continue;

         double sl = PositionGetDouble(POSITION_SL), open = PositionGetDouble(POSITION_PRICE_OPEN);
         double volume = PositionGetDouble(POSITION_VOLUME);
         if(sl<=0.0) continue;
         double point = SymbolInfoDouble(posSymbol, SYMBOL_POINT);
         double tickSize = SymbolInfoDouble(posSymbol, SYMBOL_TRADE_TICK_SIZE);
         double tickValue = SymbolInfoDouble(posSymbol, SYMBOL_TRADE_TICK_VALUE);
         if(point<=0.0 || tickSize<=0.0) continue;
         double pointValue = tickValue*(point/tickSize);
         double points = MathAbs(open-sl)/point;
         totalRiskMoney += points*pointValue*volume;
        }
      return (totalRiskMoney/equity)*100.0;
     }
  };
#endif // AX_INTELLIGENCE_CORRELATIONENGINE_MQH
