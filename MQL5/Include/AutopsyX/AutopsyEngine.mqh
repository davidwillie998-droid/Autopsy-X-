//+------------------------------------------------------------------+
//| AutopsyEngine.mqh                                                 |
//| Post-trade classification + a running analytics journal so        |
//| recurring weaknesses (late entries, spread failures, momentum     |
//| failures...) are visible instead of buried in P/L alone.          |
//+------------------------------------------------------------------+
#pragma once
#include <AutopsyX/Defines.mqh>

class CAXAutopsy
{
private:
   int      m_fileHandle;
   double   m_slippageFailurePts;
   double   m_spreadFailurePts;

   int      m_totalTrades, m_wins, m_losses;
   double   m_grossProfit, m_grossLoss;
   long     m_sumHoldSec;
   double   m_sumSlippagePts, m_sumSpreadPts;
   int      m_curConsecLosses, m_maxConsecLosses;
   double   m_cumProfit, m_peakCum, m_maxDrawdown;
   datetime m_firstTradeTime, m_lastTradeTime;
   int      m_tagCounts[13];

public:
   CAXAutopsy(void) : m_fileHandle(INVALID_HANDLE), m_slippageFailurePts(8.0), m_spreadFailurePts(35.0),
      m_totalTrades(0), m_wins(0), m_losses(0), m_grossProfit(0), m_grossLoss(0), m_sumHoldSec(0),
      m_sumSlippagePts(0), m_sumSpreadPts(0), m_curConsecLosses(0), m_maxConsecLosses(0),
      m_cumProfit(0), m_peakCum(0), m_maxDrawdown(0), m_firstTradeTime(0), m_lastTradeTime(0)
   {
      ArrayInitialize(m_tagCounts, 0);
   }

   void Init(const string filename, const double slippageFailurePts, const double spreadFailurePts)
   {
      m_slippageFailurePts = slippageFailurePts;
      m_spreadFailurePts   = spreadFailurePts;

      bool exists = FileIsExist(filename);
      m_fileHandle = FileOpen(filename, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ, ",");
      if(m_fileHandle == INVALID_HANDLE) return;

      FileSeek(m_fileHandle, 0, SEEK_END);
      if(!exists || FileSize(m_fileHandle) == 0)
      {
         FileWrite(m_fileHandle, "ticket", "open_time", "close_time", "direction", "requested_price",
                    "filled_price", "exit_price", "slippage_pts", "spread_pts", "lots", "profit",
                    "holding_sec", "exit_reason", "autopsy_tag", "buy_score", "sell_score", "regime",
                    "signal_to_order_ms", "order_to_fill_ms");
      }
   }

   void Deinit(void)
   {
      if(m_fileHandle != INVALID_HANDLE) FileClose(m_fileHandle);
   }

   ENUM_AX_AUTOPSY_TAG Classify(const AXTradeRecord &rec) const
   {
      if(rec.exit_reason == AX_EXIT_RISK_SHUTDOWN) return AX_TAG_RISK_SHUTDOWN;
      if(rec.slippage_points > m_slippageFailurePts) return AX_TAG_SLIPPAGE_FAILURE;
      if(rec.spread_at_entry > m_spreadFailurePts) return AX_TAG_SPREAD_FAILURE;

      switch(rec.exit_reason)
      {
         case AX_EXIT_TAKE_PROFIT: return rec.profit > 0 ? AX_TAG_TAKE_PROFIT : AX_TAG_FALSE_BREAKOUT;
         case AX_EXIT_STOP_LOSS:   return AX_TAG_STOP_LOSS;
         case AX_EXIT_OPPOSITE_SIGNAL: return rec.profit > 0 ? AX_TAG_CORRECT_EXIT : AX_TAG_OPPOSITE_SIGNAL;
         case AX_EXIT_MOMENTUM:    return rec.profit > 0 ? AX_TAG_CORRECT_EXIT : AX_TAG_MOMENTUM_FAILURE;
         case AX_EXIT_TIME:
         case AX_EXIT_TRAIL:
         case AX_EXIT_BREAKEVEN:   return rec.profit > 0 ? AX_TAG_CORRECT_EXIT : AX_TAG_PREMATURE_EXIT;
         case AX_EXIT_SPREAD_ABNORMAL: return AX_TAG_SPREAD_FAILURE;
         default: return rec.profit > 0 ? AX_TAG_CORRECT_READ : AX_TAG_LATE_ENTRY;
      }
   }

   void OnTradeClosed(AXTradeRecord &rec)
   {
      rec.autopsy_tag = Classify(rec);

      if(m_fileHandle != INVALID_HANDLE)
      {
         FileWrite(m_fileHandle, rec.ticket, TimeToString(rec.open_time, TIME_DATE | TIME_SECONDS),
                    TimeToString(rec.close_time, TIME_DATE | TIME_SECONDS), AXDirToString(rec.direction),
                    DoubleToString(rec.requested_price, 8), DoubleToString(rec.filled_price, 8),
                    DoubleToString(rec.exit_price, 8), DoubleToString(rec.slippage_points, 2),
                    DoubleToString(rec.spread_at_entry, 2), DoubleToString(rec.lots, 2),
                    DoubleToString(rec.profit, 2), rec.holding_seconds,
                    AXExitReasonToString(rec.exit_reason), AXAutopsyTagToString(rec.autopsy_tag),
                    DoubleToString(rec.buy_score_at_entry, 1), DoubleToString(rec.sell_score_at_entry, 1),
                    AXRegimeToString(rec.regime_at_entry), rec.signal_to_order_ms, rec.order_to_fill_ms);
         FileFlush(m_fileHandle);
      }

      //--- aggregates for the analytics report --------------------------
      m_totalTrades++;
      m_sumHoldSec += rec.holding_seconds;
      m_sumSlippagePts += rec.slippage_points;
      m_sumSpreadPts += rec.spread_at_entry;
      if(m_firstTradeTime == 0) m_firstTradeTime = rec.open_time;
      m_lastTradeTime = rec.close_time;

      if(rec.profit >= 0)
      {
         m_wins++;
         m_grossProfit += rec.profit;
         m_curConsecLosses = 0;
      }
      else
      {
         m_losses++;
         m_grossLoss += -rec.profit;
         m_curConsecLosses++;
         if(m_curConsecLosses > m_maxConsecLosses) m_maxConsecLosses = m_curConsecLosses;
      }

      m_cumProfit += rec.profit;
      if(m_cumProfit > m_peakCum) m_peakCum = m_cumProfit;
      double dd = m_peakCum - m_cumProfit;
      if(dd > m_maxDrawdown) m_maxDrawdown = dd;

      int idx = (int)rec.autopsy_tag;
      if(idx >= 0 && idx < 13) m_tagCounts[idx]++;
   }

   string GenerateReport(void) const
   {
      double winRate = (m_totalTrades > 0) ? (100.0 * m_wins / m_totalTrades) : 0.0;
      double avgWin  = (m_wins > 0) ? (m_grossProfit / m_wins) : 0.0;
      double avgLoss = (m_losses > 0) ? (m_grossLoss / m_losses) : 0.0;
      double profitFactor = (m_grossLoss > 0.0) ? (m_grossProfit / m_grossLoss) : (m_grossProfit > 0 ? 999.0 : 0.0);
      double netProfit = m_grossProfit - m_grossLoss;
      double expectedValue = (m_totalTrades > 0) ? (netProfit / m_totalTrades) : 0.0;
      double avgHoldSec = (m_totalTrades > 0) ? ((double)m_sumHoldSec / m_totalTrades) : 0.0;
      double avgSlippage = (m_totalTrades > 0) ? (m_sumSlippagePts / m_totalTrades) : 0.0;
      double avgSpread = (m_totalTrades > 0) ? (m_sumSpreadPts / m_totalTrades) : 0.0;
      double hours = (m_lastTradeTime > m_firstTradeTime) ? (double)(m_lastTradeTime - m_firstTradeTime) / 3600.0 : 0.0;
      double freqPerHour = (hours > 0.0) ? (m_totalTrades / hours) : 0.0;

      string s = "";
      s += "===== AUTOPSY X - PERFORMANCE REPORT =====\n";
      s += StringFormat("Total Trades: %d\n", m_totalTrades);
      s += StringFormat("Net Profit: %.2f\n", netProfit);
      s += StringFormat("Profit Factor: %.2f\n", profitFactor);
      s += StringFormat("Win Rate: %.1f%%\n", winRate);
      s += StringFormat("Average Win: %.2f\n", avgWin);
      s += StringFormat("Average Loss: %.2f\n", avgLoss);
      s += StringFormat("Max Drawdown (closed-trade equity): %.2f\n", m_maxDrawdown);
      s += StringFormat("Max Consecutive Losses: %d\n", m_maxConsecLosses);
      s += StringFormat("Trade Frequency: %.2f trades/hour\n", freqPerHour);
      s += StringFormat("Average Holding Time: %.1f sec\n", avgHoldSec);
      s += StringFormat("Expected Value / Trade: %.2f\n", expectedValue);
      s += StringFormat("Average Slippage: %.2f pts\n", avgSlippage);
      s += StringFormat("Average Spread at Entry: %.2f pts\n", avgSpread);
      s += "--- Autopsy Tag Breakdown ---\n";
      for(int i = 0; i < 13; i++)
         if(m_tagCounts[i] > 0)
            s += StringFormat("  %s: %d\n", AXAutopsyTagToString((ENUM_AX_AUTOPSY_TAG)i), m_tagCounts[i]);
      return s;
   }

   int    TotalTrades(void)   const { return m_totalTrades; }
   int    Wins(void)          const { return m_wins; }
   int    Losses(void)        const { return m_losses; }
   double WinRatePct(void)    const { return (m_totalTrades > 0) ? (100.0 * m_wins / m_totalTrades) : 0.0; }
};
