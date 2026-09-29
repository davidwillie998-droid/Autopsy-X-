//+------------------------------------------------------------------+
//|                                                   MacroRegime.mqh |
//|  Layer 1: Macro / Cross-Asset Regime (institutional engine        |
//|  upgrade) - ENGINEERING DESIGN, not paper-sourced. The source      |
//|  paper (Malhotra, SSRN 3306817) discusses liquidity/volatility as |
//|  macro risk indicators in general terms; it does not specify a    |
//|  cross-asset monitoring implementation.                           |
//|                                                                    |
//|  HONEST SCOPE: this engine reads whatever ADDITIONAL SYMBOLS are   |
//|  actually available in the broker's Market Watch and configured    |
//|  by input - nothing more. It does NOT fabricate US Treasury         |
//|  yields, real yields, or any other data a standard MT5 feed does   |
//|  not provide. If no cross-asset symbol is configured, or the       |
//|  configured symbol isn't selectable on this broker, every read     |
//|  reports AX_MACRO_DATA_UNAVAILABLE - never a guess dressed up as   |
//|  a reading.                                                        |
//|                                                                    |
//|  Every reading carries SOURCE -> TIMESTAMP -> FRESHNESS ->         |
//|  CONFIDENCE (spec's own phrasing) - confidence decays exponentially|
//|  with staleness rather than a stale price being silently treated  |
//|  as current.                                                       |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_MACROREGIME_MQH
#define AX_MACROREGIME_MQH
#include "Defs.mqh"

class CMacroRegimeEngine
  {
private:
   double   m_confidenceHalfLifeSeconds; // confidence halves every this many seconds of staleness
   double   m_minConfidenceToUse;        // below this, treat the reading as unavailable for bias purposes
   int      m_biasLookbackBars;
   ENUM_TIMEFRAMES m_biasTimeframe;
   double   m_biasThresholdPts;          // minimum move (in points of the macro symbol) to call a bias

   string   m_selectedSymbol;            // tracks which symbol (if any) this engine has already
                                          // called SymbolSelect(...,true) on, so ReadSymbol() only
                                          // mutates Market Watch once per distinct symbol, not every
                                          // tick (code-review finding), and Deinit() knows what to
                                          // release

public:
                     CMacroRegimeEngine(void)
     {
      m_confidenceHalfLifeSeconds=60.0; m_minConfidenceToUse=40.0;
      m_biasLookbackBars=20; m_biasTimeframe=PERIOD_M5; m_biasThresholdPts=50.0;
      m_selectedSymbol="";
     }

   //--- releases the macro symbol from Market Watch if this engine was the one that added it - call ---
   //--- from the EA's own OnDeinit(), mirroring how every other engine's Deinit() is already called ---
   void              Deinit(void)
     {
      if(StringLen(m_selectedSymbol)>0)
        {
         SymbolSelect(m_selectedSymbol,false);
         m_selectedSymbol="";
        }
     }

   void              Configure(const double confidenceHalfLifeSeconds,const double minConfidenceToUse,
                                const int biasLookbackBars,const ENUM_TIMEFRAMES biasTimeframe,
                                const double biasThresholdPts)
     {
      m_confidenceHalfLifeSeconds = MathMax(1.0,confidenceHalfLifeSeconds);
      m_minConfidenceToUse        = AxClampD(minConfidenceToUse,0.0,100.0);
      m_biasLookbackBars          = MathMax(2,biasLookbackBars);
      m_biasTimeframe             = biasTimeframe;
      m_biasThresholdPts          = MathMax(0.0,biasThresholdPts);
     }

   //--- real read only - never fabricates a value for a symbol that doesn't exist/isn't selectable ---
   SAxMacroInput     ReadSymbol(const string symbol) const
     {
      SAxMacroInput out;
      out.source=symbol; out.value=0; out.timestamp=0; out.freshnessSeconds=0;
      out.confidence=0; out.available=false;

      if(StringLen(symbol)==0) return(out); // not configured - nothing to read, not an error

      //--- only call SymbolSelect (a terminal-mutating operation) once per distinct symbol, not on   ---
      //--- every tick - SymbolSelect's own return value already tells us whether the symbol exists,  ---
      //--- so re-checking existence doesn't require re-adding it to Market Watch every call ---
      if(m_selectedSymbol!=symbol)
        {
         if(!SymbolSelect(symbol,true)) return(out); // doesn't exist / can't be selected on this broker
         m_selectedSymbol = symbol;
        }
      else if(!SymbolInfoInteger(symbol,SYMBOL_SELECT))
        {
         // was selected before but something (another EA, manual Market Watch edit) removed it since -
         // re-select rather than silently reading a symbol no longer actually in Market Watch
         if(!SymbolSelect(symbol,true)) return(out);
        }

      double bid = SymbolInfoDouble(symbol,SYMBOL_BID);
      datetime t = (datetime)SymbolInfoInteger(symbol,SYMBOL_TIME);
      if(bid<=0 || t<=0) return(out); // no real quote yet

      out.available = true;
      out.value = bid;
      out.timestamp = t;
      out.freshnessSeconds = (double)(TimeCurrent()-t);
      //--- exponential decay: 100 at freshness=0, halves every m_confidenceHalfLifeSeconds - a       ---
      //--- reading from 5 minutes ago on a fast-moving symbol is not "still current", and this        ---
      //--- makes that explicit as a number rather than a binary fresh/stale flag ---
      out.confidence = AxClampD(100.0*MathPow(0.5,out.freshnessSeconds/m_confidenceHalfLifeSeconds),0.0,100.0);
      return(out);
     }

   //--- short-term directional bias of a macro symbol, from real bar data only. Returns             ---
   //--- DATA_UNAVAILABLE if the symbol can't be read, if confidence has decayed below the usable      ---
   //--- floor, or if there isn't enough real bar history yet - never guesses. ---
   ENUM_AX_MACRO_BIAS Bias(const string symbol,string &reasonOut) const
     {
      SAxMacroInput input = ReadSymbol(symbol);
      if(!input.available)
        { reasonOut=StringFormat("Macro symbol '%s' unavailable",symbol); return(AX_MACRO_DATA_UNAVAILABLE); }
      if(input.confidence<m_minConfidenceToUse)
        {
         reasonOut=StringFormat("Macro symbol '%s' confidence %.0f%% below usable floor %.0f%% (stale %.0fs)",
                                 symbol,input.confidence,m_minConfidenceToUse,input.freshnessSeconds);
         return(AX_MACRO_DATA_UNAVAILABLE);
        }

      double closes[];
      ArraySetAsSeries(closes,true);
      int copied = CopyClose(symbol,m_biasTimeframe,1,m_biasLookbackBars,closes); // shift=1: closed bars only
      if(copied<m_biasLookbackBars)
        { reasonOut=StringFormat("Insufficient bar history for '%s'",symbol); return(AX_MACRO_DATA_UNAVAILABLE); }

      double point = SymbolInfoDouble(symbol,SYMBOL_POINT);
      if(point<=0)
        { reasonOut=StringFormat("Invalid point size for '%s'",symbol); return(AX_MACRO_DATA_UNAVAILABLE); }

      double movePts = (closes[0]-closes[copied-1])/point;
      reasonOut=StringFormat("%s moved %.1f pts over %d bars (confidence %.0f%%)",
                              symbol,movePts,m_biasLookbackBars,input.confidence);
      if(movePts>m_biasThresholdPts)  return(AX_MACRO_BULLISH);
      if(movePts<-m_biasThresholdPts) return(AX_MACRO_BEARISH);
      return(AX_MACRO_NEUTRAL);
     }
  };
//+------------------------------------------------------------------+
#endif // AX_MACROREGIME_MQH
