//+------------------------------------------------------------------+
//|                                                    Statistics.mqh|
//|  Accuracy Engine + performance statistics (spec section 18)      |
//|  Profitability Gate (spec section 20)                            |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_STATISTICS_MQH
#define AX_STATISTICS_MQH
#include "Defs.mqh"
#include "TradeAutopsy.mqh"

#define AX_ACC_HORIZON_COUNT   5
#define AX_ACC_BUFFER_SIZE     300
static const int AxAccHorizonsSec[AX_ACC_HORIZON_COUNT] = {1,3,5,10,30};

//+------------------------------------------------------------------+
//| CAccuracyEngine - directional accuracy over multiple horizons     |
//+------------------------------------------------------------------+
class CAccuracyEngine
  {
private:
   SAxAccuracySnapshot m_buf[AX_ACC_BUFFER_SIZE];
   int                 m_head;
   int                 m_count;
   long                m_hit[AX_ACC_HORIZON_COUNT];
   long                m_total[AX_ACC_HORIZON_COUNT];

   long                m_flipHit;
   long                m_flipTotal;

public:
                     CAccuracyEngine(void)
     {
      m_head=-1; m_count=0;
      ArrayInitialize(m_hit,0); ArrayInitialize(m_total,0);
      m_flipHit=0; m_flipTotal=0;
     }

   void              RegisterSignal(const datetime t,const double price,const ENUM_AX_DIR predicted)
     {
      if(predicted==AX_DIR_NONE) return;
      m_head = (m_head+1)%AX_ACC_BUFFER_SIZE;
      m_buf[m_head].time = t;
      m_buf[m_head].priceAtSignal = price;
      m_buf[m_head].predictedDir  = (int)predicted;
      for(int i=0;i<AX_ACC_HORIZON_COUNT;i++) { m_buf[m_head].done[i]=false; m_buf[m_head].correct[i]=false; }
      if(m_count<AX_ACC_BUFFER_SIZE) m_count++;
     }

   //--- call every tick: resolves any pending snapshot whose horizon has elapsed ---
   void              OnTickUpdate(const double currentPrice)
     {
      datetime now = TimeCurrent();
      for(int i=0;i<m_count;i++)
        {
         int idx = m_head-i; if(idx<0) idx+=AX_ACC_BUFFER_SIZE;
         for(int h=0;h<AX_ACC_HORIZON_COUNT;h++)
           {
            if(m_buf[idx].done[h]) continue;
            if((now-m_buf[idx].time) < AxAccHorizonsSec[h]) continue;
            double move = currentPrice - m_buf[idx].priceAtSignal;
            bool correct = (m_buf[idx].predictedDir>0 && move>0) || (m_buf[idx].predictedDir<0 && move<0);
            m_buf[idx].done[h] = true;
            m_buf[idx].correct[h] = correct;
            m_total[h]++;
            if(correct) m_hit[h]++;
           }
        }
     }

   double            Accuracy(const int horizonIndex) const
     {
      if(horizonIndex<0 || horizonIndex>=AX_ACC_HORIZON_COUNT) return(0);
      if(m_total[horizonIndex]<=0) return(0);
      return(100.0*(double)m_hit[horizonIndex]/(double)m_total[horizonIndex]);
     }

   void              RegisterFlipOutcome(const bool wasCorrect)
     {
      m_flipTotal++;
      if(wasCorrect) m_flipHit++;
     }

   double            FlipAccuracy(void) const
     {
      if(m_flipTotal<=0) return(0);
      return(100.0*(double)m_flipHit/(double)m_flipTotal);
     }
  };

//+------------------------------------------------------------------+
//| SAxStatsSnapshot - aggregated performance metrics (file-scope so  |
//| it can be referenced from other headers without relying on the    |
//| class-nested-type scoping resolution operator)                    |
//+------------------------------------------------------------------+
struct SAxStatsSnapshot
  {
   int    totalTrades;
   int    wins;
   int    losses;
   double winRate;
   double grossProfitSum;
   double grossLossSum;
   double profitFactor;
   double netExpectancy;       // avg net profit per trade (after ALL costs)
   double grossExpectancy;     // avg gross profit per trade (before commission/swap)
   double avgWin;
   double avgLoss;
   double maxDrawdownCurrency;
   double maxDrawdownPercent;
   double avgHoldSeconds;
   double entryAccuracyPct;    // % of trades where favorable excursion exceeded adverse
   double exitEfficiencyPct;   // realized profit / MFE, averaged over winners
   double dailyPnL;
   double netProfitTotal;
  };

//+------------------------------------------------------------------+
//| CStatistics - trade-level performance metrics                     |
//+------------------------------------------------------------------+
class CStatistics
  {
public:
   SAxStatsSnapshot  Compute(const CTradeAutopsy &autopsy,const double startingEquity) const
     {
      SAxStatsSnapshot s;
      s.totalTrades=0; s.wins=0; s.losses=0; s.winRate=0;
      s.grossProfitSum=0; s.grossLossSum=0; s.profitFactor=0;
      s.netExpectancy=0; s.grossExpectancy=0; s.avgWin=0; s.avgLoss=0;
      s.maxDrawdownCurrency=0; s.maxDrawdownPercent=0; s.avgHoldSeconds=0;
      s.entryAccuracyPct=0; s.exitEfficiencyPct=0; s.dailyPnL=0; s.netProfitTotal=0;

      int n = autopsy.Count();
      if(n<=0) return(s);

      double equity = startingEquity;
      double peak = startingEquity;
      double maxDd = 0;
      double sumHold=0, sumNet=0, sumGross=0;
      double winSum=0, lossSum=0;
      int entryOk=0;
      double exitEffSum=0; int exitEffCount=0;

      for(int i=0;i<n;i++)
        {
         SAxTradeRecord r;
         if(!autopsy.GetRecord(i,r)) continue;
         s.totalTrades++;
         sumNet   += r.netProfit;
         sumGross += r.grossProfit;
         sumHold  += r.holdSeconds;

         if(r.netProfit>0) { s.wins++; winSum += r.netProfit; s.grossProfitSum += r.netProfit; }
         else if(r.netProfit<0) { s.losses++; lossSum += r.netProfit; s.grossLossSum += r.netProfit; }

         if(r.mfe > MathAbs(r.mae)) entryOk++;

         if(r.netProfit>0 && r.mfe>0)
           {
            exitEffSum += AxClampD(r.netProfit/r.mfe,0.0,1.0);
            exitEffCount++;
           }

         equity += r.netProfit;
         if(equity>peak) peak = equity;
         double dd = peak-equity;
         if(dd>maxDd) maxDd = dd;
        }

      s.netProfitTotal   = sumNet;
      s.winRate           = (s.totalTrades>0)? 100.0*s.wins/s.totalTrades : 0;
      s.profitFactor       = (MathAbs(s.grossLossSum)>1e-8)? s.grossProfitSum/MathAbs(s.grossLossSum) : ((s.grossProfitSum>0)?999.0:0.0);
      s.netExpectancy       = sumNet/s.totalTrades;
      s.grossExpectancy      = sumGross/s.totalTrades;
      s.avgWin               = (s.wins>0)? winSum/s.wins : 0;
      s.avgLoss               = (s.losses>0)? lossSum/s.losses : 0;
      s.maxDrawdownCurrency     = maxDd;
      s.maxDrawdownPercent      = (peak>0)? 100.0*maxDd/peak : 0;
      s.avgHoldSeconds           = sumHold/s.totalTrades;
      s.entryAccuracyPct          = 100.0*entryOk/s.totalTrades;
      s.exitEfficiencyPct          = (exitEffCount>0)? 100.0*exitEffSum/exitEffCount : 0;
      s.dailyPnL = sumNet;
      return(s);
     }

   //--- Profitability Gate (spec section 20). This is a LIVE-SESSION heuristic only -
   //--- it does not replace the multi-phase in-sample/out-of-sample/forward-test
   //--- workflow described in README.md. Never report VALIDATED from this alone. ---
   ENUM_AX_GATE      EvaluateGate(const SAxStatsSnapshot &s,const int minTradesForSignal,
                                   const int minTradesForValidation,const double maxAcceptableDrawdownPct) const
     {
      if(s.totalTrades<minTradesForSignal) return(AX_GATE_INSUFFICIENT_DATA);

      if(s.netExpectancy<=0)
        {
         if(s.grossExpectancy>0) return(AX_GATE_WEAK); // profitable only before costs
         return(AX_GATE_FAIL);
        }

      if(s.totalTrades<minTradesForValidation) return(AX_GATE_PROMISING);
      if(s.maxDrawdownPercent>maxAcceptableDrawdownPct) return(AX_GATE_PROMISING);
      if(s.profitFactor<1.15) return(AX_GATE_PROMISING);

      return(AX_GATE_VALIDATED);
     }
  };
//+------------------------------------------------------------------+
#endif // AX_STATISTICS_MQH
