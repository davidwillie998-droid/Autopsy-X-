//+------------------------------------------------------------------+
//| ExposureEngine.mqh                                                 |
//| Portfolio-level exposure gate: refuses a new trade that would     |
//| stack another effectively-identical directional bet on top of     |
//| correlated instruments already at risk.                           |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_RISK_EXPOSUREENGINE_MQH
#define AX_RISK_EXPOSUREENGINE_MQH
#include "../core/Types.mqh"
#include "../intelligence/CorrelationEngine.mqh"

class CExposureEngine
  {
private:
   CCorrelationEngine *m_corr;
   double              m_maxCorrelatedRiskPercent;
   double              m_corrThreshold;

public:
   void Init(CCorrelationEngine *corr, double maxCorrelatedRiskPercent, double corrThreshold=0.6)
     {
      m_corr = corr;
      m_maxCorrelatedRiskPercent = maxCorrelatedRiskPercent;
      m_corrThreshold = corrThreshold;
     }

   bool AllowsNewExposure(const string symbol, long magic, double candidateRiskPercent, string &reason) const
     {
      double existing = m_corr.CorrelatedOpenRiskPercent(symbol, magic, m_corrThreshold);
      if(existing + candidateRiskPercent > m_maxCorrelatedRiskPercent)
        {
         reason = StringFormat("Correlated exposure %.2f%% + new %.2f%% would exceed cap %.2f%%",
                                existing, candidateRiskPercent, m_maxCorrelatedRiskPercent);
         return false;
        }
      reason = "";
      return true;
     }

   //--- true if an opposite-direction position already exists on the same symbol/magic (prevents net hedging noise)
   bool HasOpposingPosition(const string symbol, long magic, int newDirection) const
     {
      int total = PositionsTotal();
      for(int i=0;i<total;i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
         if(PositionGetInteger(POSITION_MAGIC)!=magic) continue;
         if(PositionGetString(POSITION_SYMBOL)!=symbol) continue;
         long type = PositionGetInteger(POSITION_TYPE);
         int existingDir = (type==POSITION_TYPE_BUY) ? 1 : -1;
         if(existingDir != newDirection) return true;
        }
      return false;
     }

   int CountPositions(const string symbol, long magic) const
     {
      int count=0;
      int total = PositionsTotal();
      for(int i=0;i<total;i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
         if(PositionGetInteger(POSITION_MAGIC)!=magic) continue;
         if(PositionGetString(POSITION_SYMBOL)!=symbol) continue;
         count++;
        }
      return count;
     }
  };
#endif // AX_RISK_EXPOSUREENGINE_MQH
