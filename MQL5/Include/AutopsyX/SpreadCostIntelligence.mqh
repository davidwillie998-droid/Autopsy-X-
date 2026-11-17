//+------------------------------------------------------------------+
//|                                      SpreadCostIntelligence.mqh  |
//|  Rolling spread statistics and fail-closed trade-cost assessment |
//|  Analysis module only: this class never sends, modifies, or closes|
//|  orders and does not replace RiskEngine's hard spread ceiling.   |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_SPREADCOSTINTELLIGENCE_MQH
#define AX_SPREADCOSTINTELLIGENCE_MQH

#define AX_SCI_BUFFER_SIZE 512

enum ENUM_AX_SCI_STATUS
  {
   AX_SCI_READY = 0,
   AX_SCI_INSUFFICIENT_SAMPLES,
   AX_SCI_INVALID_MARKET_DATA,
   AX_SCI_INVALID_COST_INPUT,
   AX_SCI_COST_TOO_HIGH
  };

struct SAxSpreadCostAssessment
  {
   ENUM_AX_SCI_STATUS status;
   double currentSpreadPts;
   double medianSpreadPts;
   double percentileRank;
   double spreadToAtr;
   double effectiveSlippagePerSidePts;
   int    empiricalSlippageSamples;
   bool   usedEmpiricalSlippage;
   double estimatedRoundTripCost;
   double expectedGrossProfit;
   double costToGrossRatio;
   string reason;
  };

class CSpreadCostIntelligence
  {
private:
   double            m_spreads[AX_SCI_BUFFER_SIZE];
   double            m_fillSlippage[AX_SCI_BUFFER_SIZE];
   int               m_count;
   int               m_head;
   int               m_fillCount;
   int               m_fillHead;
   int               m_minSamples;
   double            m_maxCostToGross;
   double            m_maxSpreadToAtr;

   void              SortValues(double &values[],const int count) const
     {
      // Insertion sort is bounded by the 512-observation ring buffer.
      for(int i=1;i<count;i++)
        {
         double key=values[i];
         int j=i-1;
         while(j>=0 && values[j]>key)
           {
            values[j+1]=values[j];
            j--;
           }
         values[j+1]=key;
        }
     }

   double            MedianOfSorted(const double &values[],const int count) const
     {
      if(count<=0) return(0.0);
      if((count%2)==1) return(values[count/2]);
      return((values[count/2-1]+values[count/2])*0.5);
     }

public:
                     CSpreadCostIntelligence(void)
     {
      Reset();
      m_minSamples=20;
      m_maxCostToGross=0.25;
      m_maxSpreadToAtr=0.15;
     }

   void              Reset(void)
     {
      m_count=0;
      m_head=-1;
      m_fillCount=0;
      m_fillHead=-1;
      for(int i=0;i<AX_SCI_BUFFER_SIZE;i++)
        {
         m_spreads[i]=0.0;
         m_fillSlippage[i]=0.0;
        }
     }

   void              Configure(const int minSamples,
                                const double maxCostToGross,
                                const double maxSpreadToAtr)
     {
      m_minSamples=(int)MathMax(5,MathMin(AX_SCI_BUFFER_SIZE,minSamples));
      m_maxCostToGross=(MathIsValidNumber(maxCostToGross) && maxCostToGross>0.0)
                       ? MathMin(maxCostToGross,1.0) : 0.25;
      m_maxSpreadToAtr=(MathIsValidNumber(maxSpreadToAtr) && maxSpreadToAtr>0.0)
                       ? MathMin(maxSpreadToAtr,1.0) : 0.15;
     }

   // Feed only a valid, current bid/ask observation. Invalid observations are
   // discarded and never enter the baseline.
   bool              Observe(const double bid,const double ask,const double point)
     {
      if(!MathIsValidNumber(bid) || !MathIsValidNumber(ask) ||
         !MathIsValidNumber(point) || bid<=0.0 || ask<bid || point<=0.0)
         return(false);
      double spread=(ask-bid)/point;
      if(!MathIsValidNumber(spread) || spread<0.0) return(false);
      m_head=(m_head+1)%AX_SCI_BUFFER_SIZE;
      m_spreads[m_head]=spread;
      if(m_count<AX_SCI_BUFFER_SIZE) m_count++;
      return(true);
     }

   int               SampleCount(void) const { return(m_count); }

   // Only broker-confirmed fills are admitted. The EA supplies absolute adverse
   // price deviation in points; rejected/ambiguous requests never enter this sample.
   bool              ObserveFillSlippage(const double slippagePts)
     {
      if(!MathIsValidNumber(slippagePts) || slippagePts<0.0) return(false);
      m_fillHead=(m_fillHead+1)%AX_SCI_BUFFER_SIZE;
      m_fillSlippage[m_fillHead]=slippagePts;
      if(m_fillCount<AX_SCI_BUFFER_SIZE) m_fillCount++;
      return(true);
     }

   int               FillSlippageSampleCount(void) const { return(m_fillCount); }

   // Entry-fill observations are used as a conservative per-side proxy for the
   // round trip. Until the configured warm-up sample count is reached, retain
   // the explicit configured allowance rather than claiming a measured baseline.
   bool              FillSlippagePercentile(const double percentile,double &valueOut) const
     {
      valueOut=0.0;
      if(m_fillCount<=0 || !MathIsValidNumber(percentile)) return(false);
      double sorted[];
      if(ArrayResize(sorted,m_fillCount)!=m_fillCount) return(false);
      for(int i=0;i<m_fillCount;i++)
        {
         int idx=m_fillHead-i;
         if(idx<0) idx+=AX_SCI_BUFFER_SIZE;
         sorted[i]=m_fillSlippage[idx];
        }
      SortValues(sorted,m_fillCount);
      double bounded=MathMax(0.0,MathMin(1.0,percentile));
      int index=(int)MathCeil((m_fillCount-1)*bounded);
      index=(int)MathMax(0,MathMin(m_fillCount-1,index));
      valueOut=sorted[index];
      return(MathIsValidNumber(valueOut) && valueOut>=0.0);
     }

   // Estimates full round-trip cost and compares it with a gross target
   // expressed in points. commissionRoundTripPerLot is account-currency
   // commission for opening AND closing one lot, sourced from broker data.
   // Slippage is a conservative per-side points allowance.
   bool              Assess(const double bid,const double ask,const double point,
                            const double atrPoints,const double targetPoints,
                            const double lots,const double tickSize,
                            const double tickValue,
                            const double commissionRoundTripPerLot,
                            const double slippagePerSidePts,
                            SAxSpreadCostAssessment &out) const
     {
      out.status=AX_SCI_INVALID_MARKET_DATA;
      out.currentSpreadPts=0.0;
      out.medianSpreadPts=0.0;
      out.percentileRank=0.0;
      out.spreadToAtr=0.0;
      out.effectiveSlippagePerSidePts=0.0;
      out.empiricalSlippageSamples=m_fillCount;
      out.usedEmpiricalSlippage=false;
      out.estimatedRoundTripCost=0.0;
      out.expectedGrossProfit=0.0;
      out.costToGrossRatio=0.0;
      out.reason="Invalid quote or market metadata";

      if(!MathIsValidNumber(bid) || !MathIsValidNumber(ask) ||
         !MathIsValidNumber(point) || bid<=0.0 || ask<bid || point<=0.0 ||
         !MathIsValidNumber(atrPoints) || atrPoints<=0.0)
         return(false);

      out.currentSpreadPts=(ask-bid)/point;
      out.spreadToAtr=out.currentSpreadPts/atrPoints;

      if(m_count<m_minSamples)
        {
         out.status=AX_SCI_INSUFFICIENT_SAMPLES;
         out.reason="Insufficient valid spread observations; fail closed";
         return(false);
        }

      if(!MathIsValidNumber(targetPoints) || targetPoints<=0.0 ||
         !MathIsValidNumber(lots) || lots<=0.0 ||
         !MathIsValidNumber(tickSize) || tickSize<=0.0 ||
         !MathIsValidNumber(tickValue) || tickValue<=0.0 ||
         !MathIsValidNumber(commissionRoundTripPerLot) ||
         commissionRoundTripPerLot<0.0 ||
         !MathIsValidNumber(slippagePerSidePts) || slippagePerSidePts<0.0)
        {
         out.status=AX_SCI_INVALID_COST_INPUT;
         out.reason="Invalid cost-model input; zero-cost fallback prohibited";
         return(false);
        }

      double sorted[];
      if(ArrayResize(sorted,m_count)!=m_count)
        {
         out.status=AX_SCI_INVALID_COST_INPUT;
         out.reason="Unable to allocate spread-statistics workspace";
         return(false);
        }
      for(int i=0;i<m_count;i++)
        {
         int idx=m_head-i;
         if(idx<0) idx+=AX_SCI_BUFFER_SIZE;
         sorted[i]=m_spreads[idx];
        }
      SortValues(sorted,m_count);
      out.medianSpreadPts=MedianOfSorted(sorted,m_count);

      int belowOrEqual=0;
      for(int i=0;i<m_count;i++)
         if(sorted[i]<=out.currentSpreadPts) belowOrEqual++;
      out.percentileRank=100.0*(double)belowOrEqual/(double)m_count;

      // Use the greater of the configured floor and observed p95 entry slippage.
      // The empirical entry sample is a conservative proxy for each side, not a
      // claim that exit slippage has been independently measured.
      out.effectiveSlippagePerSidePts=slippagePerSidePts;
      if(m_fillCount>=m_minSamples)
        {
         double observedP95=0.0;
         if(!FillSlippagePercentile(0.95,observedP95))
           {
            out.status=AX_SCI_INVALID_COST_INPUT;
            out.reason="Empirical fill-slippage estimate unavailable";
            return(false);
           }
         out.effectiveSlippagePerSidePts=MathMax(slippagePerSidePts,observedP95);
         out.usedEmpiricalSlippage=true;
        }

      // Convert price points into account currency using broker tick metadata.
      double valuePerPointPerLot=(point/tickSize)*tickValue;
      double roundTripPoints=out.currentSpreadPts+(2.0*out.effectiveSlippagePerSidePts);
      out.estimatedRoundTripCost=
         (roundTripPoints*valuePerPointPerLot*lots)+
         (commissionRoundTripPerLot*lots);
      out.expectedGrossProfit=targetPoints*valuePerPointPerLot*lots;

      if(!MathIsValidNumber(valuePerPointPerLot) ||
         !MathIsValidNumber(out.estimatedRoundTripCost) ||
         !MathIsValidNumber(out.expectedGrossProfit) ||
         out.expectedGrossProfit<=0.0)
        {
         out.status=AX_SCI_INVALID_COST_INPUT;
         out.reason="Cost conversion produced invalid account-currency values";
         return(false);
        }

      out.costToGrossRatio=out.estimatedRoundTripCost/out.expectedGrossProfit;
      if(out.costToGrossRatio>m_maxCostToGross ||
         out.spreadToAtr>m_maxSpreadToAtr)
        {
         out.status=AX_SCI_COST_TOO_HIGH;
         out.reason=StringFormat("Cost gate: cost/gross %.3f (limit %.3f), spread/ATR %.3f (limit %.3f)",
                                 out.costToGrossRatio,m_maxCostToGross,
                                 out.spreadToAtr,m_maxSpreadToAtr);
         return(false);
        }

      out.status=AX_SCI_READY;
      out.reason="";
      return(true);
     }
  };

#endif // AX_SPREADCOSTINTELLIGENCE_MQH
