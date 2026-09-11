//+------------------------------------------------------------------+
//| PositionManager.mqh                                                 |
//| Manages every open AutopsyX position through its structural       |
//| phases: prove itself, take partials, reduce risk, trail by        |
//| structure, realize the final objective. Breakeven and trailing    |
//| are earned by structure/probability, never triggered by a fixed   |
//| pip count.                                                        |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_EXECUTION_POSITIONMANAGER_MQH
#define AX_EXECUTION_POSITIONMANAGER_MQH
#include "../core/Types.mqh"
#include "../core/MarketState.mqh"
#include "../core/StructureEngine.mqh"
#include "ExecutionEngine.mqh"
#include "BrokerAdapter.mqh"

class CPositionManager
  {
private:
   AXTradeThesis     m_theses[];
   CMarketState     *m_market;
   CStructureEngine *m_structure;
   CExecutionEngine *m_execution;
   CBrokerAdapter   *m_broker;
   string            m_symbol;
   long              m_magic;
   double            m_partialPct1;
   double            m_partialPct2;

   int FindIndex(ulong ticket) const
     {
      for(int i=0;i<ArraySize(m_theses);i++)
         if(m_theses[i].ticket==ticket) return i;
      return -1;
     }

public:
   void Init(CMarketState *market, CStructureEngine *structure, CExecutionEngine *execution,
             CBrokerAdapter *broker, const string symbol, long magic,
             double partialPct1=33.0, double partialPct2=33.0)
     {
      m_market=market; m_structure=structure; m_execution=execution; m_broker=broker;
      m_symbol=symbol; m_magic=magic;
      m_partialPct1 = MathMax(0.0, MathMin(90.0, partialPct1))/100.0;
      m_partialPct2 = MathMax(0.0, MathMin(90.0, partialPct2))/100.0;
      ArrayResize(m_theses,0);
     }

   void AddThesis(const AXTradeThesis &t)
     {
      int n=ArraySize(m_theses); ArrayResize(m_theses,n+1); m_theses[n]=t;
     }

   int Count() const { return ArraySize(m_theses); }
   AXTradeThesis GetThesis(int i) const { return m_theses[i]; }
   bool HasThesis(ulong ticket) const { return FindIndex(ticket)>=0; }

   void RemoveThesis(ulong ticket)
     {
      int idx = FindIndex(ticket);
      if(idx<0) return;
      int n=ArraySize(m_theses);
      for(int i=idx;i<n-1;i++) m_theses[i]=m_theses[i+1];
      ArrayResize(m_theses,n-1);
     }

   //--- reconstruct a minimal thesis for a position found open at OnInit (terminal/EA restart recovery)
   AXTradeThesis ReconstructThesis(ulong ticket) const
     {
      AXTradeThesis t;
      PositionSelectByTicket(ticket);
      t.ticket = ticket;
      long type = PositionGetInteger(POSITION_TYPE);
      t.direction = (type==POSITION_TYPE_BUY) ? 1 : -1;
      t.entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      t.stopLoss = PositionGetDouble(POSITION_SL);
      t.tp1 = t.tp2 = t.tpFinal = PositionGetDouble(POSITION_TP);
      t.initialStopDistance = MathAbs(t.entryPrice-t.stopLoss);
      t.volumeOriginal = t.volumeRemaining = PositionGetDouble(POSITION_VOLUME);
      t.initialRiskMoney = m_broker.RiskMoneyForStop(t.initialStopDistance, t.volumeOriginal);
      t.equityAtEntry = AccountInfoDouble(ACCOUNT_EQUITY); // true entry-time equity is unknowable after a restart
      t.openTime = (datetime)PositionGetInteger(POSITION_TIME);
      t.phase = PHASE_1_INITIAL;
      t.partial1Done=false; t.partial2Done=false; t.movedToBreakeven=false;
      t.mfe=0.0; t.mae=0.0;
      t.highestPrice=t.entryPrice; t.lowestPrice=t.entryPrice;
      t.whyNow="Reconstructed after restart - original thesis text unavailable.";
      t.whyHere="Recovered from broker position state.";
      t.macroContext="Unknown (restart recovery)";
      t.regime=REGIME_TRANSITIONAL;
      t.confidence=50.0;
      t.setup=SETUP_NONE;
      t.quality=QUALITY_B;
      t.expectedR=0.0;
      t.liquidityTarget=t.tpFinal;
      t.structuralInvalidation=t.stopLoss;
      t.expectedHoldingBars=0;
      return t;
     }

   //--- called every tick per open position: updates MFE/MAE and advances the management phase
   void Update(ulong ticket)
     {
      int idx = FindIndex(ticket);
      if(idx<0) return;
      if(!PositionSelectByTicket(ticket)) return;

      AXTradeThesis t = m_theses[idx];
      double price = PositionGetDouble(POSITION_PRICE_CURRENT);
      if(t.direction>0) { t.highestPrice=MathMax(t.highestPrice,price); t.lowestPrice=MathMin(t.lowestPrice,price); }
      else               { t.highestPrice=MathMax(t.highestPrice,price); t.lowestPrice=MathMin(t.lowestPrice,price); }

      double riskDist = t.initialStopDistance>0.0 ? t.initialStopDistance : m_broker.point;
      double favorableExtreme = (t.direction>0) ? (t.highestPrice-t.entryPrice) : (t.entryPrice-t.lowestPrice);
      double adverseExtreme   = (t.direction>0) ? (t.entryPrice-t.lowestPrice)  : (t.highestPrice-t.entryPrice);
      t.mfe = MathMax(t.mfe, favorableExtreme/riskDist);
      t.mae = MathMax(t.mae, adverseExtreme/riskDist);

      double currentR = (t.direction>0 ? (price-t.entryPrice) : (t.entryPrice-price)) / riskDist;

      AXStructureSnapshot h1 = m_structure.GetSnapshot(PERIOD_H1);
      bool structureInvalidated = (t.direction>0 && (h1.lastEvent==STRUCT_CHOCH_BEAR || h1.lastEvent==STRUCT_MSS_BEAR)) ||
                                   (t.direction<0 && (h1.lastEvent==STRUCT_CHOCH_BULL || h1.lastEvent==STRUCT_MSS_BULL));

      if(structureInvalidated && t.phase<=PHASE_2_PROVEN)
        {
         m_execution.CloseFull(ticket);
         m_theses[idx]=t;
         return; // main EA detects the close via position-vanished check and journals EXIT_THESIS_INVALID
        }

      switch(t.phase)
        {
         case PHASE_1_INITIAL:
           {
            bool proven = currentR >= 1.0 &&
                          ((t.direction>0 && h1.lastSwingLow>t.entryPrice-riskDist*0.3) ||
                           (t.direction<0 && h1.lastSwingHigh<t.entryPrice+riskDist*0.3));
            if(proven) t.phase = PHASE_2_PROVEN;
            break;
           }
         case PHASE_2_PROVEN:
           {
            bool tp1Hit = (t.direction>0 && price>=t.tp1) || (t.direction<0 && price<=t.tp1);
            if(tp1Hit && !t.partial1Done)
              {
               double closeVol = m_broker.NormalizeVolume(t.volumeOriginal*m_partialPct1);
               if(closeVol>0.0 && closeVol<t.volumeRemaining)
                 {
                  if(m_execution.ClosePartial(ticket, closeVol))
                    {
                     t.volumeRemaining -= closeVol;
                     t.partial1Done = true;
                     t.phase = PHASE_4_PARTIAL;
                     // breakeven is earned now: partial realized AND structure still intact
                     double be = t.direction>0 ? t.entryPrice+m_broker.point*2 : t.entryPrice-m_broker.point*2;
                     m_execution.ModifyStops(ticket, be, PositionGetDouble(POSITION_TP));
                     t.movedToBreakeven = true;
                     t.phase = PHASE_3_RISK_REDUCED;
                    }
                 }
              }
            break;
           }
         case PHASE_3_RISK_REDUCED:
           {
            bool tp2Hit = (t.direction>0 && price>=t.tp2) || (t.direction<0 && price<=t.tp2);
            if(tp2Hit && !t.partial2Done)
              {
               double closeVol = m_broker.NormalizeVolume(t.volumeOriginal*m_partialPct2);
               if(closeVol>0.0 && closeVol<t.volumeRemaining)
                 {
                  if(m_execution.ClosePartial(ticket, closeVol))
                    {
                     t.volumeRemaining -= closeVol;
                     t.partial2Done = true;
                     t.phase = PHASE_5_TRAILING;
                    }
                 }
              }
            break;
           }
         case PHASE_4_PARTIAL:
            t.phase = PHASE_3_RISK_REDUCED; // safety fallthrough if breakeven step above didn't fire this tick
            break;
         case PHASE_5_TRAILING:
           {
            double newStop = t.direction>0 ? h1.lastSwingLow : h1.lastSwingHigh;
            bool improves = t.direction>0 ? (newStop>PositionGetDouble(POSITION_SL)) : (newStop<PositionGetDouble(POSITION_SL));
            if(improves && newStop!=0.0)
               m_execution.ModifyStops(ticket, newStop, PositionGetDouble(POSITION_TP));

            bool finalHit = (t.direction>0 && price>=t.tpFinal) || (t.direction<0 && price<=t.tpFinal);
            if(finalHit) { t.phase = PHASE_6_FINAL; m_execution.CloseFull(ticket); }
            break;
           }
         case PHASE_6_FINAL:
            break;
        }

      m_theses[idx]=t;
     }

   //--- build the forensic record for a position that has just vanished from PositionsTotal()
   AXAutopsy BuildAutopsy(ulong ticket, ENUM_AX_EXIT_REASON exitReason) const
     {
      AXAutopsy rec;
      int idx = FindIndex(ticket);
      AXTradeThesis t = (idx>=0) ? m_theses[idx] : ReconstructThesis(ticket);

      rec.ticket=ticket;
      rec.setupType = AXSetupToString(t.setup);
      rec.regime = AXRegimeToString(t.regime);
      rec.htfBias = AXBiasToString(t.direction>0?BIAS_BULLISH:BIAS_BEARISH);
      rec.liquidityObjective = DoubleToString(t.liquidityTarget,_Digits);
      rec.poi = t.whyHere;
      rec.entryTF = "H1";
      rec.entryPrice=t.entryPrice; rec.stopLoss=t.stopLoss; rec.tp1=t.tp1; rec.tp2=t.tp2; rec.tpFinal=t.tpFinal;
      rec.riskPercent = (t.equityAtEntry>0.0) ? (t.initialRiskMoney/t.equityAtEntry*100.0) : 0.0;
      rec.mfeR=t.mfe; rec.maeR=t.mae;

      double closePrice=0.0, profit=0.0, commission=0.0, swapTotal=0.0;
      datetime closeTime=TimeCurrent();
      if(HistorySelectByPosition((long)ticket))
        {
         int deals = HistoryDealsTotal();
         for(int i=0;i<deals;i++)
           {
            ulong dealTicket = HistoryDealGetTicket(i);
            if(dealTicket==0) continue;
            profit     += HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
            commission += HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
            swapTotal  += HistoryDealGetDouble(dealTicket, DEAL_SWAP);
            if(HistoryDealGetInteger(dealTicket, DEAL_ENTRY)==DEAL_ENTRY_OUT)
              {
               closePrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
               closeTime  = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
              }
           }
        }
      rec.netProfit = profit+commission+swapTotal;
      rec.commission = commission;
      rec.swapTotal = swapTotal;
      rec.openTime = t.openTime;
      rec.closeTime = closeTime;
      rec.holdingSeconds = (long)(rec.closeTime-rec.openTime);
      rec.rMultiple = (t.initialStopDistance>0.0) ? ((t.direction>0? (closePrice-t.entryPrice) : (t.entryPrice-closePrice))/t.initialStopDistance) : 0.0;
      rec.spreadAtEntry = 0.0;
      rec.slippagePoints = 0.0;
      rec.newsEnvironment = "";
      rec.macroContext = t.macroContext;
      rec.correlationNote = "";
      rec.executionQuality = "";
      rec.exitReason = exitReason;
      rec.outcome = ClassifyOutcome(t, rec, exitReason);
      return rec;
     }

private:
   ENUM_AX_OUTCOME ClassifyOutcome(const AXTradeThesis &t, const AXAutopsy &rec, ENUM_AX_EXIT_REASON exitReason) const
     {
      bool win = rec.netProfit>0.0;
      if(exitReason==EXIT_STRUCTURAL_FAILURE) return OUT_STRUCTURAL_FAILURE;
      if(exitReason==EXIT_THESIS_INVALID)     return win? OUT_A_WIN : OUT_STRUCTURAL_FAILURE;
      if(exitReason==EXIT_TIME_STOP)          return win? OUT_LATE_EXIT : OUT_PREMATURE_EXIT;
      if(win)
        {
         if(t.quality==QUALITY_A_PLUS) return OUT_APLUS_WIN;
         if(t.quality==QUALITY_A) return OUT_A_WIN;
         return OUT_B_WIN;
        }
      if(t.quality==QUALITY_A_PLUS) return OUT_APLUS_LOSS;
      return OUT_A_LOSS;
     }
  };
#endif // AX_EXECUTION_POSITIONMANAGER_MQH
