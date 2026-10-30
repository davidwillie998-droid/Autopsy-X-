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
#define AX_ACC_BUFFER_SIZE     512
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
   double netWinSum;           // sum of net (post-cost) profit on winning trades
   double netLossSum;          // sum of net (post-cost) profit on losing trades (<=0)
   double profitFactor;        // net win sum / |net loss sum| - the honest, after-cost figure
   double grossWinSum;         // sum of gross (pre-cost) profit on trades that were net winners
   double grossLossSum;        // sum of gross (pre-cost) profit on trades that were net losers
   double grossProfitFactor;   // gross win sum / |gross loss sum| - before-cost figure only,
                                // used to distinguish the profitability gate's WEAK case
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
      s.netWinSum=0; s.netLossSum=0; s.profitFactor=0;
      s.grossWinSum=0; s.grossLossSum=0; s.grossProfitFactor=0;
      s.netExpectancy=0; s.grossExpectancy=0; s.avgWin=0; s.avgLoss=0;
      s.maxDrawdownCurrency=0; s.maxDrawdownPercent=0; s.avgHoldSeconds=0;
      s.entryAccuracyPct=0; s.exitEfficiencyPct=0; s.dailyPnL=0; s.netProfitTotal=0;

      int n = autopsy.Count();
      if(n<=0) return(s);

      double equity = startingEquity;
      double peak = startingEquity;
      double maxDd = 0;
      double sumHold=0, sumNetFull=0, sumGrossFull=0;
      int entryOk=0;
      double exitEffSum=0; int exitEffCount=0;
      double netProfitAll=0;

      for(int i=0;i<n;i++)
        {
         SAxTradeRecord r;
         if(!autopsy.GetRecord(i,r)) continue;

         // every record moves real money - reflected in net P&L and the drawdown curve
         // regardless of whether it's a full close or a scale-out slice
         netProfitAll += r.netProfit;
         equity += r.netProfit;
         if(equity>peak) peak = equity;
         double dd = peak-equity;
         if(dd>maxDd) maxDd = dd;

         // a partial is a banked slice of an still-open position, not a standalone trade
         // outcome - it never counts toward win/loss, expectancy, or accuracy statistics
         if(r.isPartial) continue;

         s.totalTrades++;
         sumNetFull   += r.netProfit;
         sumGrossFull += r.grossProfit;
         sumHold      += r.holdSeconds;

         // win/loss classification is always by net (post-cost) outcome; the gross sums
         // track the same trades' pre-cost P&L so a true before/after-cost comparison is possible
         if(r.netProfit>0)
           {
            s.wins++;
            s.netWinSum   += r.netProfit;
            s.grossWinSum += r.grossProfit;
           }
         else if(r.netProfit<0)
           {
            s.losses++;
            s.netLossSum   += r.netProfit;
            s.grossLossSum += r.grossProfit;
           }

         if(r.mfe > MathAbs(r.mae)) entryOk++;

         if(r.netProfit>0 && r.mfe>0)
           {
            exitEffSum += AxClampD(r.netProfit/r.mfe,0.0,1.0);
            exitEffCount++;
           }
        }

      s.netProfitTotal   = netProfitAll;
      s.winRate           = (s.totalTrades>0)? 100.0*s.wins/s.totalTrades : 0;
      s.profitFactor       = (MathAbs(s.netLossSum)>1e-8)? s.netWinSum/MathAbs(s.netLossSum) : ((s.netWinSum>0)?999.0:0.0);
      s.grossProfitFactor   = (MathAbs(s.grossLossSum)>1e-8)? s.grossWinSum/MathAbs(s.grossLossSum) : ((s.grossWinSum>0)?999.0:0.0);
      s.netExpectancy       = (s.totalTrades>0)? sumNetFull/s.totalTrades : 0;
      s.grossExpectancy      = (s.totalTrades>0)? sumGrossFull/s.totalTrades : 0;
      s.avgWin               = (s.wins>0)? s.netWinSum/s.wins : 0;
      s.avgLoss               = (s.losses>0)? s.netLossSum/s.losses : 0;
      s.maxDrawdownCurrency     = maxDd;
      s.maxDrawdownPercent      = (peak>0)? 100.0*maxDd/peak : 0;
      s.avgHoldSeconds           = (s.totalTrades>0)? sumHold/s.totalTrades : 0;
      s.entryAccuracyPct          = (s.totalTrades>0)? 100.0*entryOk/s.totalTrades : 0;
      s.exitEfficiencyPct          = (exitEffCount>0)? 100.0*exitEffSum/exitEffCount : 0;
      s.dailyPnL = netProfitAll;
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
