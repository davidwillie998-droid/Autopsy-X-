//+------------------------------------------------------------------+
//| ExpectedValue.mqh                                                   |
//| EV = weighted expected profit - weighted expected loss - real     |
//| trading costs, all expressed in R multiples of the trade's own    |
//| initial risk. A beautiful setup with EV <= 0 is still NO TRADE.   |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_SIGNALS_EXPECTEDVALUE_MQH
#define AX_SIGNALS_EXPECTEDVALUE_MQH
#include "../core/Types.mqh"
#include "../execution/BrokerAdapter.mqh"

class CExpectedValue
  {
private:
   double m_wTp1, m_wTp2, m_wFinal; // partial-close weighting, must sum to 1.0

public:
   void Init(double wTp1=0.33, double wTp2=0.33, double wFinal=0.34)
     {
      double sum = wTp1+wTp2+wFinal;
      if(sum<=0.0) { m_wTp1=0.33; m_wTp2=0.33; m_wFinal=0.34; return; }
      m_wTp1=wTp1/sum; m_wTp2=wTp2/sum; m_wFinal=wFinal/sum;
     }

   //--- real round-trip cost of the trade, expressed in R (fraction of the initial risk it eats)
   double CostInR(const CBrokerAdapter &broker, double spreadPoints, double commissionMoney,
                   double estimatedSlippagePoints, double volume, double stopDistancePrice) const
     {
      double pointValue = broker.PointValuePerLot();
      double spreadMoney = spreadPoints * pointValue * volume;
      double slippageMoney = estimatedSlippagePoints * pointValue * volume;
      double riskMoney = broker.RiskMoneyForStop(stopDistancePrice, volume);
      if(riskMoney<=0.0) return 1.0; // degenerate stop -> treat as maximally costly, forces rejection
      return (spreadMoney + commissionMoney + slippageMoney) / riskMoney;
     }

   //--- expected R: probability-weighted target contribution, minus stop-out probability, minus real costs
   double ComputeExpectedR(double r1, double r2, double rFinal, double p1, double p2, double pFinal, double costInR) const
     {
      double targetContribution = m_wTp1*p1*r1 + m_wTp2*p2*r2 + m_wFinal*pFinal*rFinal;
      double stopProbability = MathMax(0.0, 1.0 - p1); // trades that never even reach TP1 are treated as full-stop outcomes
      double lossContribution = stopProbability * 1.0;
      return targetContribution - lossContribution - costInR;
     }

   bool PassesMinimumEV(double expectedR, double minimumRequiredR) const
     {
      return expectedR >= minimumRequiredR;
     }
  };
#endif // AX_SIGNALS_EXPECTEDVALUE_MQH
