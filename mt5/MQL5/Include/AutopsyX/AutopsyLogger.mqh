//+------------------------------------------------------------------+
//|                                              AutopsyLogger.mqh   |
//|  AUTOPSY X — Decision Logging                                    |
//|  Spec section 23.                                                |
//|                                                                    |
//|  One CSV row per UpdateMarketState() call — the audit trail that |
//|  section 24's backtest/out-of-sample validation actually runs    |
//|  against (see tools/autopsyx_backtest_stats.py).                 |
//+------------------------------------------------------------------+
#property strict
#include "AutopsyTypes.mqh"

class CAxLogger
  {
private:
   int    m_handle;
   string m_filename;

public:
   CAxLogger() { m_handle = INVALID_HANDLE; }
   ~CAxLogger() { Close(); }

   //+---------------------------------------------------------------+
   //| files/ subfolder inside the terminal's MQL5/Files — opens for |
   //| append, writing a header only if the file is new/empty.        |
   //+---------------------------------------------------------------+
   bool Init(const string filename = "AutopsyX_Log.csv")
     {
      m_filename = filename;
      m_handle = FileOpen(m_filename, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ, ',');
      if(m_handle == INVALID_HANDLE) return false;

      const bool is_new = (FileSize(m_handle) == 0);
      FileSeek(m_handle, 0, SEEK_END);
      if(is_new)
        {
         FileWrite(m_handle,
                    "time", "regime", "bias", "confidence", "trend_efficiency", "vix_state",
                    "macro_score", "breadth_score", "liquidity_score", "risk_multiplier",
                    "regime_multiplier", "correlation_multiplier", "drawdown_multiplier",
                    "long_permission", "short_permission", "aggressive_mode", "shock_mode",
                    "data_status", "decision", "note");
         FileFlush(m_handle);
        }
      return true;
     }

   void LogSnapshot(const AxSnapshot &snap)
     {
      if(m_handle == INVALID_HANDLE) return;
      FileWrite(m_handle,
                 TimeToString(snap.time, TIME_DATE | TIME_MINUTES | TIME_SECONDS),
                 AxRegimeToString(snap.regime),
                 AxBiasToString(snap.bias),
                 DoubleToString(snap.confidence_score, 1),
                 DoubleToString(snap.trend_efficiency, 3),
                 AxVolStateToString(snap.vol_state),
                 DoubleToString(snap.macro_score, 1),
                 DoubleToString(snap.breadth_score, 1),
                 DoubleToString(snap.liquidity_score, 1),
                 DoubleToString(snap.risk_multiplier, 4),
                 DoubleToString(snap.regime_multiplier, 3),
                 DoubleToString(snap.correlation_multiplier, 3),
                 DoubleToString(snap.drawdown_multiplier, 3),
                 (snap.allow_long  ? "TRUE" : "FALSE"),
                 (snap.allow_short ? "TRUE" : "FALSE"),
                 (snap.aggressive_mode ? "TRUE" : "FALSE"),
                 (snap.shock_mode      ? "TRUE" : "FALSE"),
                 AxDataStatusToString(snap.data_status),
                 AxDecisionToString(snap.decision),
                 snap.decision_note);
      FileFlush(m_handle);
     }

   void Close()
     {
      if(m_handle != INVALID_HANDLE) { FileClose(m_handle); m_handle = INVALID_HANDLE; }
     }
  };
