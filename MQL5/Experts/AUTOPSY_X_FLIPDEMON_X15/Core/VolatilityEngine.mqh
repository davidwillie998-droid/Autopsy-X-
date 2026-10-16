//+------------------------------------------------------------------+
//| VolatilityEngine.mqh                                               |
//| Layer 02 — VOLATILITY ENGINE.                                      |
//| ATR, realized volatility (stdev of log returns), range expansion,  |
//| and the VERY LOW..EXTREME classification. Also flags whether       |
//| expansion looks directional or chaotic (Hidden Mechanic #6),       |
//| which the Regime/Opportunity engines use to decide press vs stand  |
//| down.                                                               |
//+------------------------------------------------------------------+
#ifndef AXF_VOLATILITYENGINE_MQH
#define AXF_VOLATILITYENGINE_MQH

#include "../Common/Defines.mqh"
#include "MarketEngine.mqh"

class CAxfVolatilityEngine
  {
private:
   int               m_atr_handle;
   ENUM_TIMEFRAMES   m_tf;
   int               m_period;
   int               m_lookback;

   double            StdDevLogReturns(const string symbol,const ENUM_TIMEFRAMES tf,const int bars)
     {
      MqlRates r[];
      ArraySetAsSeries(r,true);
      int n = CopyRates(symbol,tf,1,bars+1,r);
      if(n<10) return 0.0;
      double rets[]; ArrayResize(rets,n-1);
      double sum=0;
      for(int i=0;i<n-1;i++)
        {
         double c0=r[i].close, c1=r[i+1].close;
         if(c0<=0||c1<=0) { rets[i]=0; continue; }
         rets[i]=MathLog(c0/c1);
         sum+=rets[i];
        }
      double mean=sum/(n-1);
      double ss=0;
      for(int i=0;i<n-1;i++) ss += (rets[i]-mean)*(rets[i]-mean);
      double var = ss/MathMax(1,n-2);
      return MathSqrt(var);
     }

public:
                     CAxfVolatilityEngine(void) { m_atr_handle=INVALID_HANDLE; }
                    ~CAxfVolatilityEngine(void) { if(m_atr_handle!=INVALID_HANDLE) IndicatorRelease(m_atr_handle); }

   bool              Init(const string symbol,const ENUM_TIMEFRAMES tf,const int period,const int lookback)
     {
      m_tf=tf; m_period=period; m_lookback=lookback;
      m_atr_handle = iATR(symbol,tf,period);
      return (m_atr_handle!=INVALID_HANDLE);
     }

   //--- computes a fresh snapshot for 'symbol'. Returns valid=false rather than
   //--- fabricating a classification when there isn't enough history.
   SAxfVolatility    Compute(const string symbol)
     {
      SAxfVolatility v; ZeroMemory(v);
      v.valid=false;

      if(m_atr_handle==INVALID_HANDLE) return v;

      double atr_buf[];
      ArraySetAsSeries(atr_buf,true);
      int copied = CopyBuffer(m_atr_handle,0,1,MathMax(m_lookback,20),atr_buf);
      if(copied<20) return v;

      double price = SymbolInfoDouble(symbol,SYMBOL_BID);
      if(price<=0) return v;

      v.atr = atr_buf[0];
      v.atr_pct = (price>0) ? (v.atr/price)*100.0 : 0.0;

      // distribution of ATR over the lookback window, to rank "now" against "normal for this symbol"
      int n = MathMin(copied,m_lookback);
      double sum=0; for(int i=0;i<n;i++) sum+=atr_buf[i];
      double avg = sum/n;
      double ssq=0; for(int i=0;i<n;i++) ssq += (atr_buf[i]-avg)*(atr_buf[i]-avg);
      double sd = MathSqrt(ssq/MathMax(1,n-1));

      double z = (sd>0) ? (v.atr-avg)/sd : 0.0;

      if(z <= -1.25)      v.classification = VOL_VERY_LOW;
      else if(z <= -0.4)  v.classification = VOL_LOW;
      else if(z <  0.75)  v.classification = VOL_NORMAL;
      else if(z <  1.75)  v.classification = VOL_HIGH;
      else                v.classification = VOL_EXTREME;

      // range expansion: current bar's true range vs average ATR
      MqlRates r[]; ArraySetAsSeries(r,true);
      int rc = CopyRates(symbol,m_tf,1,3,r);
      if(rc>=2)
        {
         double tr = MathMax(r[0].high,r[1].close) - MathMin(r[0].low,r[1].close);
         v.range_expansion = (avg>0) ? tr/avg : 1.0;
        }
      else v.range_expansion = 1.0;

      v.realized_vol = StdDevLogReturns(symbol,m_tf,MathMax(30,m_lookback/2));

      // directional vs chaotic: does displacement persist same-direction, or churn?
      int same_dir=0, total=0;
      MqlRates rr[]; ArraySetAsSeries(rr,true);
      int rrc = CopyRates(symbol,m_tf,1,10,rr);
      if(rrc>=6)
        {
         int last_sign=0;
         for(int i=rrc-2;i>=0;i--)
           {
            double body = rr[i].close-rr[i].open;
            int sign = (body>0)?1:(body<0?-1:0);
            if(sign!=0)
              {
               if(last_sign!=0 && sign==last_sign) same_dir++;
               last_sign=sign; total++;
              }
           }
        }
      double persistence = (total>1) ? (double)same_dir/(total-1) : 0.5;

      if(v.classification==VOL_HIGH || v.classification==VOL_EXTREME)
         v.character = (persistence>=0.55) ? VOLCHAR_DIRECTIONAL : VOLCHAR_CHAOTIC;
      else
         v.character = VOLCHAR_UNKNOWN;

      v.valid=true;
      return v;
     }
  };

#endif // AXF_VOLATILITYENGINE_MQH
