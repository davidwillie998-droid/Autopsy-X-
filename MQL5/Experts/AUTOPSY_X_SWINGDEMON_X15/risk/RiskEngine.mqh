//+------------------------------------------------------------------+
//| RiskEngine.mqh                                                     |
//| Turns a validated setup into a position size, from real account   |
//| equity and real broker specs. Never doubles down after a loss.    |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_RISK_RISKENGINE_MQH
#define AX_RISK_RISKENGINE_MQH
#include "../core/Types.mqh"
#include "../execution/BrokerAdapter.mqh"

class CRiskEngine
  {
private:
   double m_riskPercentDefault;
   double m_maxRiskPercentPerTrade;
   double m_maxTotalOpenRiskPercent;
   int    m_maxOpenPositions;

public:
   void Init(double riskPercentDefault, double maxRiskPerTrade, double maxTotalOpenRisk, int maxPositions)
     {
      m_riskPercentDefault      = riskPercentDefault;
      m_maxRiskPercentPerTrade  = maxRiskPerTrade;
      m_maxTotalOpenRiskPercent = maxTotalOpenRisk;
      m_maxOpenPositions        = maxPositions;
     }

   double AccountEquity() const { return AccountInfoDouble(ACCOUNT_EQUITY); }

   //--- risk % for this trade: base risk, scaled by setup quality and volatility, but NEVER raised after a loss
   double RiskPercentForTrade(ENUM_AX_QUALITY quality, double volSizeMultiplier, int consecutiveLosses) const
     {
      double base = m_riskPercentDefault;
      double qualityMult = 1.0;
      switch(quality)
        {
         case QUALITY_A_PLUS: qualityMult = 1.0;  break;
         case QUALITY_A:      qualityMult = 0.85; break;
         case QUALITY_B:      qualityMult = 0.6;  break;
         default:             qualityMult = 0.0;  break; // C/D never sized - NO TRADE
        }
      double streakMult = 1.0;
      if(consecutiveLosses>=2) streakMult = 0.75; // de-risk into a losing streak, never re-risk
      if(consecutiveLosses>=4) streakMult = 0.5;

      double riskPct = base * qualityMult * volSizeMultiplier * streakMult;
      return MathMin(riskPct, m_maxRiskPercentPerTrade);
     }

   //--- final lot size: risk money / broker-derived money-per-point, normalized to lot step and clamped
   double ComputeVolume(const CBrokerAdapter &broker, double riskPercent, double stopDistancePrice) const
     {
      if(riskPercent<=0.0 || stopDistancePrice<=0.0) return 0.0;
      double riskMoney = AccountEquity() * (riskPercent/100.0);
      return broker.VolumeForRisk(riskMoney, stopDistancePrice);
     }

   //--- current total open risk across all AutopsyX positions, as % of equity
   double CurrentOpenRiskPercent(long magic) const
     {
      double totalRiskMoney = 0.0;
      double equity = AccountEquity();
      if(equity<=0.0) return 0.0;
      int total = PositionsTotal();
      for(int i=0;i<total;i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket==0) continue;
         if(!PositionSelectByTicket(ticket)) continue;
         if(PositionGetInteger(POSITION_MAGIC)!=magic) continue;
         double sl = PositionGetDouble(POSITION_SL);
         double open = PositionGetDouble(POSITION_PRICE_OPEN);
         double volume = PositionGetDouble(POSITION_VOLUME);
         string sym = PositionGetString(POSITION_SYMBOL);
         if(sl<=0.0) continue;
         double point = SymbolInfoDouble(sym, SYMBOL_POINT);
         double tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
         double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
         if(point<=0.0 || tickSize<=0.0) continue;
         double pointValue = tickValue*(point/tickSize);
         double stopDist = MathAbs(open-sl);
         double points = stopDist/point;
         totalRiskMoney += points*pointValue*volume;
        }
      return (totalRiskMoney/equity)*100.0;
     }

   bool WouldExceedOpenRiskCap(long magic, double additionalRiskPercent) const
     {
      return (CurrentOpenRiskPercent(magic) + additionalRiskPercent) > m_maxTotalOpenRiskPercent;
     }

   bool WouldExceedMaxPositions(long magic) const
     {
      int count=0;
      int total=PositionsTotal();
      for(int i=0;i<total;i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket==0) continue;
         if(!PositionSelectByTicket(ticket)) continue;
         if(PositionGetInteger(POSITION_MAGIC)==magic) count++;
        }
      return count>=m_maxOpenPositions;
     }
  };
#endif // AX_RISK_RISKENGINE_MQH
