//+------------------------------------------------------------------+
//| AdvancedTrendSuite.mqh                                           |
//| AlphaTrend, MFI, EMA 38/62 Slingshot, Chandelier, Ultimate Alpha,|
//| adaptive regime posture and execution feedback.                  |
//| All outputs are observational. No order, sizing or risk authority.|
//+------------------------------------------------------------------+
#property strict
#ifndef AX_ADVANCEDTRENDSUITE_MQH
#define AX_ADVANCEDTRENDSUITE_MQH
#include "Defs.mqh"
#include "RegimeClassifierEngine.mqh"

struct SAxAdvancedReading
  {
   bool available;
   datetime barTime;
   double value;
   ENUM_AX_DIR direction;
   string state;
  };

struct SAxAdaptiveRegimePosture
  {
   bool available;
   ENUM_AX_REGIME_CLASS regime;
   double confidence;
   double researchMultiplier;
   bool trendContinuation;
   bool defensive;
   string label;
  };

struct SAxUltimateTrendAlpha
  {
   bool available;
   ENUM_AX_DIR direction;
   double buyScore;
   double sellScore;
   double confidence;
   string explanation;
  };

class CMFIEngine
  {
private:
   string m_symbol;
   ENUM_TIMEFRAMES m_tf;
   int m_period;
   int m_handle;
   datetime m_lastBar;
   SAxAdvancedReading m_read;
public:
   CMFIEngine(void) { m_handle=INVALID_HANDLE; m_lastBar=0; Reset(); }
   void Reset(void) { m_read.available=false; m_read.barTime=0; m_read.value=EMPTY_VALUE; m_read.direction=AX_DIR_NONE; m_read.state="UNAVAILABLE"; }
   bool Init(const string symbol,const ENUM_TIMEFRAMES tf,const int period=14)
     {
      Deinit(); m_symbol=symbol; m_tf=tf; m_period=MathMax(2,period);
      m_handle=iMFI(m_symbol,m_tf,m_period,VOLUME_TICK);
      Reset(); return(m_handle!=INVALID_HANDLE);
     }
   void Deinit(void) { if(m_handle!=INVALID_HANDLE) IndicatorRelease(m_handle); m_handle=INVALID_HANDLE; }
   bool Update(const bool force=false)
     {
      if(m_handle==INVALID_HANDLE) return(false);
      datetime bar=iTime(m_symbol,m_tf,1);
      if(bar<=0 || (!force && bar==m_lastBar)) return(false);
      double b[]; ArraySetAsSeries(b,true);
      if(CopyBuffer(m_handle,0,1,1,b)!=1 || !MathIsValidNumber(b[0]) || b[0]<0.0 || b[0]>100.0)
        { Reset(); return(false); }
      m_lastBar=bar; m_read.available=true; m_read.barTime=bar; m_read.value=b[0];
      m_read.direction=(b[0]>50.0)?AX_DIR_BUY:(b[0]<50.0)?AX_DIR_SELL:AX_DIR_NONE;
      m_read.state=(b[0]>50.0)?"BULLISH":(b[0]<50.0)?"BEARISH":"NEUTRAL";
      return(true);
     }
   SAxAdvancedReading Read(void) const { return(m_read); }
  };

class CAlphaTrendEngine
  {
private:
   string m_symbol; ENUM_TIMEFRAMES m_tf; int m_period; double m_multiplier;
   int m_atrHandle; int m_mfiHandle; datetime m_lastBar; double m_alpha;
   bool m_seeded; SAxAdvancedReading m_read;
public:
   CAlphaTrendEngine(void) { m_atrHandle=INVALID_HANDLE; m_mfiHandle=INVALID_HANDLE; m_lastBar=0; m_alpha=0; m_seeded=false; Reset(); }
   void Reset(void) { m_read.available=false; m_read.barTime=0; m_read.value=0; m_read.direction=AX_DIR_NONE; m_read.state="UNAVAILABLE"; }
   bool Init(const string symbol,const ENUM_TIMEFRAMES tf,const int period=14,const double multiplier=1.0)
     {
      Deinit(); m_symbol=symbol; m_tf=tf; m_period=MathMax(2,period); m_multiplier=MathMax(0.1,multiplier);
      m_atrHandle=iATR(m_symbol,m_tf,m_period);
      m_mfiHandle=iMFI(m_symbol,m_tf,m_period,VOLUME_TICK);
      m_lastBar=0; m_alpha=0; m_seeded=false; Reset();
      return(m_atrHandle!=INVALID_HANDLE && m_mfiHandle!=INVALID_HANDLE);
     }
   void Deinit(void)
     {
      if(m_atrHandle!=INVALID_HANDLE) IndicatorRelease(m_atrHandle);
      if(m_mfiHandle!=INVALID_HANDLE) IndicatorRelease(m_mfiHandle);
      m_atrHandle=INVALID_HANDLE; m_mfiHandle=INVALID_HANDLE;
     }
   bool Update(const bool force=false)
     {
      if(m_atrHandle==INVALID_HANDLE || m_mfiHandle==INVALID_HANDLE) return(false);
      datetime bar=iTime(m_symbol,m_tf,1);
      if(bar<=0 || (!force && bar==m_lastBar)) return(false);
      MqlRates rates[]; ArraySetAsSeries(rates,true);
      double atr[],mfi[]; ArraySetAsSeries(atr,true); ArraySetAsSeries(mfi,true);
      if(CopyRates(m_symbol,m_tf,1,1,rates)!=1 ||
         CopyBuffer(m_atrHandle,0,1,1,atr)!=1 ||
         CopyBuffer(m_mfiHandle,0,1,1,mfi)!=1 ||
         !MathIsValidNumber(atr[0]) || atr[0]<=0 ||
         !MathIsValidNumber(mfi[0]) || rates[0].close<=0)
        { m_seeded=false; m_alpha=0.0; Reset(); return(false); }
      double lower=rates[0].low-atr[0]*m_multiplier;
      double upper=rates[0].high+atr[0]*m_multiplier;
      if(!m_seeded) { m_alpha=(mfi[0]>=50.0)?lower:upper; m_seeded=true; }
      else if(mfi[0]>=50.0) m_alpha=MathMax(lower,m_alpha);
      else m_alpha=MathMin(upper,m_alpha);
      if(!MathIsValidNumber(m_alpha) || m_alpha<=0) { m_seeded=false; m_alpha=0.0; Reset(); return(false); }
      m_lastBar=bar; m_read.available=true; m_read.barTime=bar; m_read.value=m_alpha;
      m_read.direction=(rates[0].close>m_alpha)?AX_DIR_BUY:(rates[0].close<m_alpha)?AX_DIR_SELL:AX_DIR_NONE;
      m_read.state=(m_read.direction==AX_DIR_BUY)?"BULLISH":(m_read.direction==AX_DIR_SELL)?"BEARISH":"NEUTRAL";
      return(true);
     }
   SAxAdvancedReading Read(void) const { return(m_read); }
  };

class CSlingshotEMAEngine
  {
private:
   string m_symbol; ENUM_TIMEFRAMES m_tf; int m_fastPeriod; int m_slowPeriod;
   int m_fastHandle; int m_slowHandle; datetime m_lastBar; SAxAdvancedReading m_read;
public:
   CSlingshotEMAEngine(void) { m_fastHandle=INVALID_HANDLE; m_slowHandle=INVALID_HANDLE; m_lastBar=0; Reset(); }
   void Reset(void) { m_read.available=false; m_read.barTime=0; m_read.value=0; m_read.direction=AX_DIR_NONE; m_read.state="UNAVAILABLE"; }
   bool Init(const string symbol,const ENUM_TIMEFRAMES tf,const int fastPeriod=38,const int slowPeriod=62)
     {
      Deinit(); m_symbol=symbol; m_tf=tf; m_fastPeriod=MathMax(2,fastPeriod); m_slowPeriod=MathMax(m_fastPeriod+1,slowPeriod);
      m_fastHandle=iMA(m_symbol,m_tf,m_fastPeriod,0,MODE_EMA,PRICE_CLOSE);
      m_slowHandle=iMA(m_symbol,m_tf,m_slowPeriod,0,MODE_EMA,PRICE_CLOSE);
      m_lastBar=0; Reset(); return(m_fastHandle!=INVALID_HANDLE && m_slowHandle!=INVALID_HANDLE);
     }
   void Deinit(void)
     {
      if(m_fastHandle!=INVALID_HANDLE) IndicatorRelease(m_fastHandle);
      if(m_slowHandle!=INVALID_HANDLE) IndicatorRelease(m_slowHandle);
      m_fastHandle=INVALID_HANDLE; m_slowHandle=INVALID_HANDLE;
     }
   bool Update(const bool force=false)
     {
      if(m_fastHandle==INVALID_HANDLE || m_slowHandle==INVALID_HANDLE) return(false);
      datetime bar=iTime(m_symbol,m_tf,1);
      if(bar<=0 || (!force && bar==m_lastBar)) return(false);
      double f[],s[]; ArraySetAsSeries(f,true); ArraySetAsSeries(s,true);
      MqlRates r[]; ArraySetAsSeries(r,true);
      if(CopyBuffer(m_fastHandle,0,1,1,f)!=1 || CopyBuffer(m_slowHandle,0,1,1,s)!=1 ||
         CopyRates(m_symbol,m_tf,1,1,r)!=1 ||
         !MathIsValidNumber(f[0]) || !MathIsValidNumber(s[0]) || r[0].close<=0)
        { Reset(); return(false); }
      bool bull=f[0]>s[0] && r[0].low<=f[0] && r[0].close>f[0];
      bool bear=f[0]<s[0] && r[0].high>=f[0] && r[0].close<f[0];
      m_lastBar=bar; m_read.available=true; m_read.barTime=bar; m_read.value=f[0]-s[0];
      m_read.direction=bull?AX_DIR_BUY:bear?AX_DIR_SELL:AX_DIR_NONE;
      m_read.state=bull?"BULLISH_PULLBACK_RECLAIM":bear?"BEARISH_PULLBACK_RECLAIM":"NO_TRIGGER";
      return(true);
     }
   SAxAdvancedReading Read(void) const { return(m_read); }
  };

class CChandelierExitEngine
  {
private:
   string m_symbol; ENUM_TIMEFRAMES m_tf; int m_period; int m_atrPeriod; double m_multiplier;
   int m_atrHandle; datetime m_lastBar; ENUM_AX_DIR m_direction; double m_stop;
public:
   CChandelierExitEngine(void) { m_atrHandle=INVALID_HANDLE; m_lastBar=0; m_direction=AX_DIR_NONE; m_stop=0; }
   bool Init(const string symbol,const ENUM_TIMEFRAMES tf,const int period=22,const int atrPeriod=22,const double multiplier=3.0)
     {
      Deinit(); m_symbol=symbol; m_tf=tf; m_period=MathMax(2,period); m_atrPeriod=MathMax(2,atrPeriod); m_multiplier=MathMax(0.1,multiplier);
      m_atrHandle=iATR(m_symbol,m_tf,m_atrPeriod); m_lastBar=0; m_direction=AX_DIR_NONE; m_stop=0;
      return(m_atrHandle!=INVALID_HANDLE);
     }
   void Deinit(void) { if(m_atrHandle!=INVALID_HANDLE) IndicatorRelease(m_atrHandle); m_atrHandle=INVALID_HANDLE; }
   bool Update(const ENUM_AX_DIR direction,const bool force=false)
     {
      if(m_atrHandle==INVALID_HANDLE || (direction!=AX_DIR_BUY && direction!=AX_DIR_SELL)) return(false);
      datetime bar=iTime(m_symbol,m_tf,1);
      if(bar<=0 || (!force && bar==m_lastBar && direction==m_direction)) return(false);
      MqlRates rates[]; ArraySetAsSeries(rates,true); double atr[]; ArraySetAsSeries(atr,true);
      if(CopyRates(m_symbol,m_tf,1,m_period,rates)<m_period ||
         CopyBuffer(m_atrHandle,0,1,1,atr)!=1 || !MathIsValidNumber(atr[0]) || atr[0]<=0)
         return(false);
      double extreme=(direction==AX_DIR_BUY)?rates[0].high:rates[0].low;
      for(int i=1;i<m_period;i++)
        {
         if(direction==AX_DIR_BUY) extreme=MathMax(extreme,rates[i].high);
         else extreme=MathMin(extreme,rates[i].low);
        }
      double candidate=(direction==AX_DIR_BUY)?extreme-atr[0]*m_multiplier:extreme+atr[0]*m_multiplier;
      if(!MathIsValidNumber(candidate) || candidate<=0) return(false);
      if(direction!=m_direction) m_stop=candidate;
      else if(direction==AX_DIR_BUY) m_stop=MathMax(m_stop,candidate);
      else m_stop=MathMin(m_stop,candidate);
      m_direction=direction; m_lastBar=bar; return(true);
     }
   bool Stop(const ENUM_AX_DIR direction,double &value) const
     {
      value=0;
      datetime latestClosedBar=iTime(m_symbol,m_tf,1);
      if(direction!=m_direction || m_stop<=0 || !MathIsValidNumber(m_stop) ||
         latestClosedBar<=0 || latestClosedBar!=m_lastBar) return(false);
      value=m_stop; return(true);
     }
  };

class CUltimateTrendAlphaEngine
  {
private:
   SAxUltimateTrendAlpha m_last;
public:
   CUltimateTrendAlphaEngine(void) { Reset(); }
   void Reset(void) { m_last.available=false; m_last.direction=AX_DIR_NONE; m_last.buyScore=0; m_last.sellScore=0; m_last.confidence=0; m_last.explanation="UNAVAILABLE"; }
   // Weekly and daily permissions are hard authorities. Indicators only grade a direction
   // that both institutional engines already permit. This result is advisory, never an order.
   SAxUltimateTrendAlpha Evaluate(const bool w1Buy,const bool w1Sell,const bool d1Buy,const bool d1Sell,
                                  const ENUM_AX_DIR h4Bias,const SAxAdvancedReading &alpha,
                                  const SAxAdvancedReading &mfi,const SAxAdvancedReading &slingshot,
                                  const int shadowDirection)
     {
      Reset();
      bool buyAuthority=w1Buy && d1Buy;
      bool sellAuthority=w1Sell && d1Sell;
      if(!buyAuthority && !sellAuthority) return(m_last);
      double buy=0,sell=0;
      if(alpha.available) { if(alpha.direction==AX_DIR_BUY) buy+=25; else if(alpha.direction==AX_DIR_SELL) sell+=25; }
      if(mfi.available) { if(mfi.direction==AX_DIR_BUY) buy+=15; else if(mfi.direction==AX_DIR_SELL) sell+=15; }
      if(slingshot.available) { if(slingshot.direction==AX_DIR_BUY) buy+=25; else if(slingshot.direction==AX_DIR_SELL) sell+=25; }
      if(shadowDirection>0) buy+=15; else if(shadowDirection<0) sell+=15;
      if(h4Bias==AX_DIR_BUY) buy+=20; else if(h4Bias==AX_DIR_SELL) sell+=20;
      m_last.available=true; m_last.buyScore=buy; m_last.sellScore=sell;
      m_last.direction=buyAuthority?AX_DIR_BUY:AX_DIR_SELL;
      double selected=buyAuthority?buy:sell;
      double opposing=buyAuthority?sell:buy;
      m_last.confidence=AxClampD(selected-opposing,0.0,100.0);
      m_last.explanation=StringFormat("W1/D1 authority=%s; AlphaTrend=%s; MFI=%s; EMA38/62=%s; ShadowRiver=%d; H4=%s",
        buyAuthority?"BUY":"SELL",alpha.state,mfi.state,slingshot.state,shadowDirection,
        h4Bias==AX_DIR_BUY?"BUY":h4Bias==AX_DIR_SELL?"SELL":"NEUTRAL");
      return(m_last);
     }
   SAxUltimateTrendAlpha Last(void) const { return(m_last); }
  };

class CAdaptiveMarketRegimeEngine
  {
private:
   SAxAdaptiveRegimePosture m_posture;
public:
   CAdaptiveMarketRegimeEngine(void) { Reset(); }
   void Reset(void)
     {
      m_posture.available=false; m_posture.regime=AX_RC_UNAVAILABLE; m_posture.confidence=0;
      m_posture.researchMultiplier=0; m_posture.trendContinuation=false; m_posture.defensive=true;
      m_posture.label="UNAVAILABLE";
     }
   SAxAdaptiveRegimePosture Update(const SAxRegimeClassification &classification)
     {
      Reset();
      if(!classification.dataQualityOk || classification.regime==AX_RC_UNAVAILABLE) return(m_posture);
      m_posture.available=true; m_posture.regime=classification.regime;
      m_posture.confidence=AxClampD(classification.regimeConfidence,0,100);
      switch(classification.regime)
        {
         case AX_RC_PERSISTENT_BULLISH_TREND:
         case AX_RC_PERSISTENT_BEARISH_TREND:
            m_posture.researchMultiplier=1.0; m_posture.trendContinuation=true; m_posture.defensive=false; m_posture.label="PERSISTENT_TREND"; break;
         case AX_RC_BULLISH_UNSTABLE:
         case AX_RC_BEARISH_TRANSITION:
            m_posture.researchMultiplier=0.70; m_posture.label="TRANSITION"; break;
         case AX_RC_RANGE_CHOP:
            m_posture.researchMultiplier=0.50; m_posture.label="RANGE_CHOP"; break;
         case AX_RC_VOLATILITY_SHOCK:
         case AX_RC_STRUCTURAL_BREAK:
            m_posture.researchMultiplier=0.0; m_posture.label="DEFENSIVE_SHOCK"; break;
         case AX_RC_INFORMATION_CONFLICT:
            m_posture.researchMultiplier=0.25; m_posture.label="INFORMATION_CONFLICT"; break;
         default: Reset(); break;
        }
      return(m_posture);
     }
   SAxAdaptiveRegimePosture Read(void) const { return(m_posture); }
  };

class CExecutionFeedbackEngine
  {
private:
   bool m_hasSlippage; bool m_hasMarkout; double m_slippageEwma; double m_markoutEwma;
   double m_adverseRateEwma; ulong m_fillSamples; ulong m_markoutSamples; double m_alpha;
public:
   CExecutionFeedbackEngine(void) { Reset(); m_alpha=0.10; }
   void Reset(void)
     {
      m_hasSlippage=false; m_hasMarkout=false; m_slippageEwma=0; m_markoutEwma=0;
      m_adverseRateEwma=0; m_fillSamples=0; m_markoutSamples=0;
     }
   void Configure(const double smoothing) { m_alpha=AxClampD(smoothing,0.01,1.0); }
   bool RecordFill(const double adverseSlippagePoints)
     {
      if(!MathIsValidNumber(adverseSlippagePoints) || adverseSlippagePoints<0) return(false);
      m_slippageEwma=m_hasSlippage?(m_alpha*adverseSlippagePoints+(1.0-m_alpha)*m_slippageEwma):adverseSlippagePoints;
      m_hasSlippage=true; m_fillSamples++; return(true);
     }
   bool RecordMarkout(const double markoutPoints)
     {
      if(!MathIsValidNumber(markoutPoints)) return(false);
      m_markoutEwma=m_hasMarkout?(m_alpha*markoutPoints+(1.0-m_alpha)*m_markoutEwma):markoutPoints;
      double adverse=(markoutPoints<0.0)?1.0:0.0;
      m_adverseRateEwma=(m_markoutSamples>0)?(m_alpha*adverse+(1.0-m_alpha)*m_adverseRateEwma):adverse;
      m_hasMarkout=true; m_markoutSamples++; return(true);
     }
   bool HasSlippage(void) const { return(m_hasSlippage); }
   bool HasMarkout(void) const { return(m_hasMarkout); }
   double AverageAdverseSlippagePoints(void) const { return(m_hasSlippage?m_slippageEwma:0.0); }
   double AverageMarkoutPoints(void) const { return(m_hasMarkout?m_markoutEwma:0.0); }
   double AdverseMarkoutRate(void) const { return(m_hasMarkout?m_adverseRateEwma:0.0); }
   ulong FillSamples(void) const { return(m_fillSamples); }
   ulong MarkoutSamples(void) const { return(m_markoutSamples); }
  };

#endif // AX_ADVANCEDTRENDSUITE_MQH
