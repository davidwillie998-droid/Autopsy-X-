//+------------------------------------------------------------------+
//| VWAPEngine.mqh                                                     |
//| Real intraday session VWAP (Volume Weighted Average Price), per   |
//| Zarattini & Aziz, "VWAP: The Holy Grail for Day Trading Systems"  |
//| (SSRN 4631351, 2023): VWAP = Sum(HLC3*Volume) / Sum(Volume) from  |
//| the session's start, and a directional signal is only trusted     |
//| when a completed candle CLOSES beyond it - a wick through VWAP is |
//| explicitly not a signal in the paper, and isn't one here either.  |
//|                                                                    |
//| "Volume" is this broker's tick_volume unless real exchange volume |
//| is available (SYMBOL_VOLUME_REAL) - same honest distinction the   |
//| rest of this codebase draws for order flow.                       |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_INTELLIGENCE_VWAPENGINE_MQH
#define AX_INTELLIGENCE_VWAPENGINE_MQH
#include "../core/Types.mqh"

class CVWAPEngine
  {
private:
   string   m_symbol;
   int      m_sessionStartHour; // server-time hour the session resets at
   datetime m_sessionStart;
   double   m_vwap;
   double   m_sumPV, m_sumV;
   int      m_completedBars;    // M1 bars fully accumulated since session start
   bool     m_dataValid;
   bool     m_usedRealVolume;
   datetime m_lastRecompute;

   datetime SessionStartFor(datetime t) const
     {
      MqlDateTime dt; TimeToStruct(t, dt);
      dt.hour = m_sessionStartHour; dt.min = 0; dt.sec = 0;
      datetime candidate = StructToTime(dt);
      if(candidate > t) candidate -= 86400; // the session that's currently active started yesterday-server-date
      return candidate;
     }

public:
   void Init(const string symbol, int sessionStartHour=0)
     {
      m_symbol = symbol;
      m_sessionStartHour = MathMax(0, MathMin(23, sessionStartHour));
      m_sessionStart = 0; m_vwap = 0.0; m_sumPV = 0.0; m_sumV = 0.0;
      m_completedBars = 0; m_dataValid = false; m_usedRealVolume = false; m_lastRecompute = 0;
     }

   //--- call every tick; internally only recomputes on a new M1 bar or a session rollover
   void Refresh()
     {
      datetime nowBarTime = iTime(m_symbol, PERIOD_M1, 0);
      if(nowBarTime==m_lastRecompute) return;
      m_lastRecompute = nowBarTime;

      datetime newSessionStart = SessionStartFor(TimeCurrent());
      if(newSessionStart != m_sessionStart)
        {
         m_sessionStart = newSessionStart;
        }
      Recompute();
     }

   bool     IsDataValid() const     { return m_dataValid; }
   bool     UsedRealVolume() const  { return m_usedRealVolume; }
   double   CurrentVWAP() const     { return m_vwap; }
   int      CompletedBars() const   { return m_completedBars; }
   datetime SessionStart() const    { return m_sessionStart; }
   int      MinutesSinceSessionStart() const { return m_sessionStart>0 ? (int)((TimeCurrent()-m_sessionStart)/60) : 0; }

   bool IsAboveVWAP(double price) const { return m_dataValid && price > m_vwap; }
   bool IsBelowVWAP(double price) const { return m_dataValid && price < m_vwap; }

   //--- the paper's actual trigger: did the most recently COMPLETED M1 candle close beyond VWAP?
   //--- (a wick through VWAP intrabar does not count - only a confirmed close does)
   bool LastCompletedBarClosedAbove() const
     {
      if(!m_dataValid || m_completedBars<1) return false;
      return iClose(m_symbol, PERIOD_M1, 1) > m_vwap;
     }

   bool LastCompletedBarClosedBelow() const
     {
      if(!m_dataValid || m_completedBars<1) return false;
      return iClose(m_symbol, PERIOD_M1, 1) < m_vwap;
     }

private:
   void Recompute()
     {
      if(m_sessionStart<=0) { m_dataValid=false; return; }

      MqlRates rates[];
      int copied = CopyRates(m_symbol, PERIOD_M1, m_sessionStart, TimeCurrent(), rates);
      if(copied<=1) { m_dataValid=false; m_completedBars=0; return; } // need at least one COMPLETED bar

      ArraySetAsSeries(rates, true); // index 0 = most recent (still-forming) bar

      double sumPV=0.0, sumV=0.0; bool sawRealVolume=false;
      int completed=0;
      for(int i=1;i<copied;i++) // exclude index 0: the still-forming current bar has no confirmed HLC/volume yet
        {
         double hlc3 = (rates[i].high+rates[i].low+rates[i].close)/3.0;
         double vol = rates[i].real_volume>0 ? (double)rates[i].real_volume : (double)rates[i].tick_volume;
         if(rates[i].real_volume>0) sawRealVolume=true;
         if(vol<=0.0) vol=1.0; // never let a zero-volume bar erase itself from the average entirely
         sumPV += hlc3*vol;
         sumV  += vol;
         completed++;
        }
      if(sumV<=0.0) { m_dataValid=false; m_completedBars=0; return; }

      m_sumPV=sumPV; m_sumV=sumV; m_vwap=sumPV/sumV;
      m_completedBars=completed; m_usedRealVolume=sawRealVolume; m_dataValid=true;
     }
  };
#endif // AX_INTELLIGENCE_VWAPENGINE_MQH
