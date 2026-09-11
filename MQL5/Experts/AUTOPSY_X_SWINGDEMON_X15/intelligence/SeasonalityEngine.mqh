//+------------------------------------------------------------------+
//| SeasonalityEngine.mqh                                              |
//| Historical seasonal tendency by month and day-of-week, built from |
//| this EA's own closed-trade record (fed by TradeJournal at start-  |
//| up and on every close). Context only - it can never override a    |
//| structurally-derived signal, and it stays silent below a minimum  |
//| sample size instead of pretending to know something it doesn't.   |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_INTELLIGENCE_SEASONALITYENGINE_MQH
#define AX_INTELLIGENCE_SEASONALITYENGINE_MQH
#include "../core/Types.mqh"

#define AX_MIN_SEASONAL_SAMPLE 8

class CSeasonalityEngine
  {
private:
   double m_monthSumR[12];
   int    m_monthCount[12];
   double m_dowSumR[7];
   int    m_dowCount[7];

public:
   void Init()
     {
      ArrayInitialize(m_monthSumR, 0.0);
      ArrayInitialize(m_monthCount, 0);
      ArrayInitialize(m_dowSumR, 0.0);
      ArrayInitialize(m_dowCount, 0);
     }

   void Record(datetime openTime, double rMultiple)
     {
      MqlDateTime dt; TimeToStruct(openTime, dt);
      int m = dt.mon-1, d = dt.day_of_week;
      if(m>=0 && m<12) { m_monthSumR[m]+=rMultiple; m_monthCount[m]++; }
      if(d>=0 && d<7)  { m_dowSumR[d]+=rMultiple;   m_dowCount[d]++; }
     }

   //--- expectancy in R for the given month; returns false (no opinion) below the minimum sample
   bool MonthExpectancy(int monthIndex0based, double &expectancyR) const
     {
      if(monthIndex0based<0 || monthIndex0based>=12) { expectancyR=0.0; return false; }
      if(m_monthCount[monthIndex0based] < AX_MIN_SEASONAL_SAMPLE) { expectancyR=0.0; return false; }
      expectancyR = m_monthSumR[monthIndex0based]/m_monthCount[monthIndex0based];
      return true;
     }

   bool DayOfWeekExpectancy(int dow, double &expectancyR) const
     {
      if(dow<0 || dow>=7) { expectancyR=0.0; return false; }
      if(m_dowCount[dow] < AX_MIN_SEASONAL_SAMPLE) { expectancyR=0.0; return false; }
      expectancyR = m_dowSumR[dow]/m_dowCount[dow];
      return true;
     }

   //--- small, capped confidence nudge - context, never a trigger
   double ConfidenceModifierNow() const
     {
      MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
      double monthExp=0.0, dowExp=0.0;
      bool haveMonth = MonthExpectancy(dt.mon-1, monthExp);
      bool haveDow   = DayOfWeekExpectancy(dt.day_of_week, dowExp);
      double modifier = 0.0;
      if(haveMonth) modifier += MathMax(-5.0, MathMin(5.0, monthExp*2.0));
      if(haveDow)   modifier += MathMax(-3.0, MathMin(3.0, dowExp*2.0));
      return modifier;
     }
  };
#endif // AX_INTELLIGENCE_SEASONALITYENGINE_MQH
