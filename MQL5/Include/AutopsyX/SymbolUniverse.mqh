//+------------------------------------------------------------------+
//|                                                SymbolUniverse.mqh |
//| Broker-aware symbol registry / discovery preflight                |
//| This registry does NOT make the chart-bound trading engines       |
//| multi-symbol. It is the first isolated layer for that refactor.   |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_SYMBOLUNIVERSE_MQH
#define AX_SYMBOLUNIVERSE_MQH

#define AX_MAX_UNIVERSE_SYMBOLS 64

class CAxSymbolUniverse
  {
private:
   string m_symbols[AX_MAX_UNIVERSE_SYMBOLS];
   int    m_count;
   int    m_maxQuoteAgeSeconds;

   bool IsRegistered(const string symbol) const
     {
      for(int i=0;i<m_count;i++)
         if(m_symbols[i]==symbol) return(true);
      return(false);
     }

   // Exact match wins. Prefix/suffix matching is accepted only when unique;
   // ambiguous broker aliases are rejected rather than guessed.
   string Resolve(const string requested) const
     {
      if(StringLen(requested)==0) return("");
      if(SymbolInfoInteger(requested,SYMBOL_EXIST))
         return(requested);

      string match="";
      int matches=0;
      int total=SymbolsTotal(false);
      for(int i=0;i<total;i++)
        {
         string candidate=SymbolName(i,false);
         int reqLen=StringLen(requested);
         int canLen=StringLen(candidate);
         if(canLen<reqLen) continue;

         bool prefix=(StringSubstr(candidate,0,reqLen)==requested);
         bool suffix=(StringSubstr(candidate,canLen-reqLen,reqLen)==requested);
         if(prefix || suffix)
           {
            match=candidate;
            matches++;
           }
        }
      if(matches==1) return(match);
      if(matches>1)
         PrintFormat("AX SymbolUniverse: '%s' is ambiguous across %d broker symbols; skipped.",
                     requested,matches);
      return("");
     }

public:
                     CAxSymbolUniverse(void)
     {
      m_count=0;
      m_maxQuoteAgeSeconds=60;
      for(int i=0;i<AX_MAX_UNIVERSE_SYMBOLS;i++) m_symbols[i]="";
     }

   void              Configure(const int maxQuoteAgeSeconds)
     {
      m_maxQuoteAgeSeconds=(int)MathMax(1,maxQuoteAgeSeconds);
     }

   bool              Add(const string requested,const bool requireTradeable,string &reason)
     {
      string resolved=Resolve(requested);
      if(resolved=="")
        {
         reason="symbol not found or broker alias is ambiguous";
         return(false);
        }
      if(IsRegistered(resolved))
        {
         reason="already registered";
         return(true);
        }
      if(m_count>=AX_MAX_UNIVERSE_SYMBOLS)
        {
         reason="universe capacity reached";
         return(false);
        }
      if(!SymbolSelect(resolved,true))
        {
         reason="terminal refused symbol selection";
         return(false);
        }

      MqlTick tick;
      if(!SymbolInfoTick(resolved,tick) || tick.bid<=0.0 || tick.ask<=0.0 ||
         tick.ask<tick.bid || tick.time<=0)
        {
         reason="no valid bid/ask quote";
         return(false);
        }
      int quoteAge=(int)(TimeCurrent()-tick.time);
      if(quoteAge<0 || quoteAge>m_maxQuoteAgeSeconds)
        {
         reason=StringFormat("quote stale (%d seconds)",quoteAge);
         return(false);
        }

      long mode=SymbolInfoInteger(resolved,SYMBOL_TRADE_MODE);
      if(requireTradeable && (mode==SYMBOL_TRADE_MODE_DISABLED ||
                              mode==SYMBOL_TRADE_MODE_CLOSEONLY))
        {
         reason="symbol trade mode does not allow new positions";
         return(false);
        }

      double point=SymbolInfoDouble(resolved,SYMBOL_POINT);
      double tickSize=SymbolInfoDouble(resolved,SYMBOL_TRADE_TICK_SIZE);
      double volMin=SymbolInfoDouble(resolved,SYMBOL_VOLUME_MIN);
      double volMax=SymbolInfoDouble(resolved,SYMBOL_VOLUME_MAX);
      double volStep=SymbolInfoDouble(resolved,SYMBOL_VOLUME_STEP);
      if(point<=0.0 || tickSize<=0.0 || volMin<=0.0 || volMax<volMin || volStep<=0.0)
        {
         reason="invalid broker symbol specifications";
         return(false);
        }

      m_symbols[m_count]=resolved;
      m_count++;
      reason="";
      PrintFormat("AX SymbolUniverse: registered %s | digits=%d point=%g tickSize=%g "
                  "volume[min=%g max=%g step=%g] quoteAge=%ds",
                  resolved,(int)SymbolInfoInteger(resolved,SYMBOL_DIGITS),point,tickSize,
                  volMin,volMax,volStep,quoteAge);
      return(true);
     }

   int               Build(const string csvSymbols,const string chartSymbol,
                           const int maxQuoteAgeSeconds,const bool requireTradeable)
     {
      m_count=0;
      Configure(maxQuoteAgeSeconds);

      string chartReason="";
      if(!Add(chartSymbol,requireTradeable,chartReason))
         PrintFormat("AX SymbolUniverse: chart symbol %s failed preflight: %s",
                     chartSymbol,chartReason);

      string tokens[];
      ushort separator=StringGetCharacter(",",0);
      int tokenCount=StringSplit(csvSymbols,separator,tokens);
      for(int i=0;i<tokenCount;i++)
        {
         string requested=tokens[i];
         StringTrimLeft(requested);
         StringTrimRight(requested);
         if(requested=="") continue;
         string reason="";
         if(!Add(requested,requireTradeable,reason))
            PrintFormat("AX SymbolUniverse: skipped '%s': %s",requested,reason);
        }
      return(m_count);
     }

   int               Count(void) const { return(m_count); }

   string            At(const int index) const
     {
      if(index<0 || index>=m_count) return("");
      return(m_symbols[index]);
     }
  };

#endif // AX_SYMBOLUNIVERSE_MQH
