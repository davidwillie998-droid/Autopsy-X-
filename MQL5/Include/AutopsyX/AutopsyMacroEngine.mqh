//+------------------------------------------------------------------+
//| AutopsyMacroEngine.mqh                                              |
//| MACRO_SCORE (-100..100), confirmation-only per the spec - it never |
//| independently dictates a trade, only nudges confidence.           |
//|                                                                    |
//| Honesty first: MT5 has no native feed for real yields, Fed-funds-  |
//| futures-implied expectations, or COT. Those are NEVER fabricated - |
//| real yields and Fed expectations always contribute zero (documented|
//| as unavailable) unless the user configures a genuine proxy symbol  |
//| their broker actually offers. DXY/2Y/10Y are optional configurable |
//| proxy symbols and degrade the exact same way when left blank or    |
//| when the broker doesn't carry them. The one genuinely real,        |
//| non-proxied input here is the MT5 Economic Calendar's own          |
//| actual-vs-forecast values for a curated set of high-impact USD     |
//| releases (CPI/PCE/NFP/GDP/Fed Funds) - CalendarValueHistory is a   |
//| real MT5 API, not a guess.                                        |
//+------------------------------------------------------------------+
#property strict
#ifndef AUTOPSYX_MACROENGINE_MQH
#define AUTOPSYX_MACROENGINE_MQH
#include "AutopsyTypes.mqh"

class CAutopsyMacroEngine
  {
private:
   string m_dxySymbol, m_y2Symbol, m_y10Symbol, m_realYieldSymbol;
   int    m_trendLookbackDays;
   int    m_calendarLookbackHours;
   double m_wDxy, m_w2y, m_w10y, m_wRealYield, m_wCalendar;
   bool   m_hadRecentSurprise;

   bool SymbolAvailable(const string sym) const
     {
      if(sym=="") return false;
      if(!SymbolSelect(sym, true)) return false;
      return SymbolInfoDouble(sym, SYMBOL_BID) > 0.0;
     }

   //--- -100..100: a trendLookbackDays% move saturates at +/-100 once it reaches +/-10% (scale x10)
   double SymbolTrendScore(const string sym) const
     {
      double now  = iClose(sym, PERIOD_D1, 1);
      double past = iClose(sym, PERIOD_D1, 1+m_trendLookbackDays);
      if(now<=0.0 || past<=0.0) return 0.0;
      double pct = (now-past)/past*100.0;
      return MathMax(-100.0, MathMin(100.0, pct*10.0));
     }

   double DecodeCalValue(long raw, int digits) const
     {
      return (double)raw / MathPow(10.0, MathMax(0,digits));
     }

   //--- sign convention (documented, deliberately simplified - real market reaction is context
   //--- dependent): hotter CPI/PCE or a more-hawkish rate decision = bearish for risk assets; a GDP
   //--- beat = bullish; a payrolls beat is genuinely ambiguous (growth-positive but hawkish-Fed-risk)
   //--- so it gets both a smaller weight below and a damped sign here.
   double EventSign(const string name) const
     {
      if(StringFind(name,"GDP")>=0) return 1.0;
      if(StringFind(name,"CPI")>=0 || StringFind(name,"PCE")>=0) return -1.0;
      if(StringFind(name,"Non-Farm")>=0 || StringFind(name,"Nonfarm")>=0 || StringFind(name,"Payrolls")>=0) return -0.5;
      if(StringFind(name,"Fed Funds")>=0 || StringFind(name,"Interest Rate")>=0) return -1.0;
      return 0.0;
     }

   //--- the surprise (actual-forecast) magnitude, in the event's own natural units, that saturates
   //--- the contribution at +/-100 - configurable-in-spirit but kept as documented constants here to
   //--- avoid an unmanageable input list; adjust in code if your broker's calendar units differ
   double EventSaturation(const string name) const
     {
      if(StringFind(name,"GDP")>=0) return 0.5;
      if(StringFind(name,"CPI")>=0 || StringFind(name,"PCE")>=0) return 0.3;
      if(StringFind(name,"Non-Farm")>=0 || StringFind(name,"Nonfarm")>=0 || StringFind(name,"Payrolls")>=0) return 150.0;
      if(StringFind(name,"Fed Funds")>=0 || StringFind(name,"Interest Rate")>=0) return 0.25;
      return 1.0;
     }

   double ComputeCalendarSurpriseScore()
     {
      m_hadRecentSurprise = false;
      datetime from = TimeCurrent() - (datetime)m_calendarLookbackHours*3600;
      datetime to   = TimeCurrent();
      MqlCalendarValue values[];
      if(!CalendarValueHistory(values, from, to, "US")) return 0.0;

      double sum=0.0; int n=0;
      for(int i=0;i<ArraySize(values);i++)
        {
         if(values[i].time > TimeCurrent()) continue; // not released yet
         MqlCalendarEvent ev;
         if(!CalendarEventById(values[i].event_id, ev)) continue;
         if(ev.importance != CALENDAR_IMPORTANCE_HIGH) continue;

         double sign = EventSign(ev.name);
         if(sign==0.0) continue; // not one of the curated event types this engine scores

         double actual   = DecodeCalValue(values[i].actual_value, ev.digits);
         double forecast = DecodeCalValue(values[i].forecast_value, ev.digits);
         if(actual==0.0 && forecast==0.0) continue; // can't distinguish "no surprise" from "not released"

         double saturation = EventSaturation(ev.name);
         double surprise = MathMax(-1.0, MathMin(1.0, (actual-forecast)/saturation));
         sum += sign*surprise*100.0;
         n++;
        }

      if(n==0) return 0.0;
      m_hadRecentSurprise = true;
      return sum/n;
     }

public:
   void Init(const string dxySymbol="", const string y2Symbol="", const string y10Symbol="", const string realYieldSymbol="",
             int trendLookbackDays=10, int calendarLookbackHours=48,
             double wDxy=25.0, double w2y=25.0, double w10y=15.0, double wRealYield=20.0, double wCalendar=15.0)
     {
      m_dxySymbol=dxySymbol; m_y2Symbol=y2Symbol; m_y10Symbol=y10Symbol; m_realYieldSymbol=realYieldSymbol;
      m_trendLookbackDays = MathMax(2, trendLookbackDays);
      m_calendarLookbackHours = MathMax(1, calendarLookbackHours);
      m_wDxy=wDxy; m_w2y=w2y; m_w10y=w10y; m_wRealYield=wRealYield; m_wCalendar=wCalendar;
      m_hadRecentSurprise = false;
      if(m_dxySymbol!="") SymbolSelect(m_dxySymbol, true);
      if(m_y2Symbol!="") SymbolSelect(m_y2Symbol, true);
      if(m_y10Symbol!="") SymbolSelect(m_y10Symbol, true);
      if(m_realYieldSymbol!="") SymbolSelect(m_realYieldSymbol, true);
     }

   //--- MACRO_SCORE, plus reliabilityOut (0..1) = fraction of configured weight that was actually
   //--- backed by real, resolvable data this call - the caller (RegimeEngine) treats low reliability
   //--- as a reason to trust this score less, never as a reason to invent one.
   double ComputeScore(double &reliabilityOut)
     {
      double totalWeight=0.0, weightedSum=0.0;

      if(SymbolAvailable(m_dxySymbol))
        { weightedSum += -SymbolTrendScore(m_dxySymbol)*m_wDxy; totalWeight+=m_wDxy; }
      if(SymbolAvailable(m_y2Symbol))
        { weightedSum += -SymbolTrendScore(m_y2Symbol)*m_w2y; totalWeight+=m_w2y; }
      if(SymbolAvailable(m_y10Symbol))
        { weightedSum += -SymbolTrendScore(m_y10Symbol)*m_w10y*0.6; totalWeight+=m_w10y*0.6; } // damped: rising 10Y is growth-vs-inflation ambiguous
      if(SymbolAvailable(m_realYieldSymbol))
        { weightedSum += -SymbolTrendScore(m_realYieldSymbol)*m_wRealYield; totalWeight+=m_wRealYield; }

      double calScore = ComputeCalendarSurpriseScore();
      if(m_hadRecentSurprise)
        { weightedSum += calScore*m_wCalendar; totalWeight += m_wCalendar; }

      // Fed-expectations: no real MT5 data source exists - always neutral, never fabricated

      double maxPossibleWeight = m_wDxy+m_w2y+m_w10y*0.6+m_wRealYield+m_wCalendar;
      reliabilityOut = maxPossibleWeight>0.0 ? MathMax(0.0, MathMin(1.0, totalWeight/maxPossibleWeight)) : 0.0;

      if(totalWeight<=0.0) return 0.0;
      return MathMax(-100.0, MathMin(100.0, weightedSum/totalWeight));
     }
  };
#endif // AUTOPSYX_MACROENGINE_MQH
