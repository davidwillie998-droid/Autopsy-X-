//+------------------------------------------------------------------+
//| BrokerUniverse.mqh                                               |
//| Broker-adaptive symbol discovery and conservative classification |
//| Discovery only: this module does not place or authorize trades.   |
//+------------------------------------------------------------------+
#ifndef AUTOPSYX_BROKER_UNIVERSE_MQH
#define AUTOPSYX_BROKER_UNIVERSE_MQH

enum ENUM_AX_MARKET_FAMILY
  {
   AX_FAMILY_UNKNOWN=0,
   AX_FAMILY_FX,
   AX_FAMILY_GOLD,
   AX_FAMILY_SYNTH_VOLATILITY,
   AX_FAMILY_SYNTH_BOOM_CRASH,
   AX_FAMILY_SYNTH_JUMP,
   AX_FAMILY_SYNTH_STEP,
   AX_FAMILY_SYNTH_RANGE_BREAK,
   AX_FAMILY_SYNTH_DRIFT_SWITCH,
   AX_FAMILY_SYNTH_HYBRID,
   AX_FAMILY_SYNTH_OTHER,
   AX_FAMILY_OTHER
  };

struct SAxBrokerSymbol
  {
   string                name;
   ENUM_AX_MARKET_FAMILY family;
   bool                  selected;
   bool                  tradeable;
   double                point;
   double                tick_size;
   double                tick_value;
   double                volume_min;
   double                volume_max;
   double                volume_step;
   long                  trade_mode;
  };

class CBrokerUniverse
  {
private:
   SAxBrokerSymbol m_items[];
   int             m_count;

   bool ContainsAny(const string value,const string token_list) const
     {
      string tokens[];
      int n=StringSplit(token_list,',',tokens);
      for(int i=0;i<n;i++)
         if(StringFind(value,tokens[i])>=0) return(true);
      return(false);
     }

   bool IsCurrencyCode(const string code) const
     {
      return(code=="USD" || code=="EUR" || code=="GBP" ||
             code=="JPY" || code=="CHF" || code=="CAD" ||
             code=="AUD" || code=="NZD" || code=="CNY" ||
             code=="CNH" || code=="SGD" || code=="HKD" ||
             code=="NOK" || code=="SEK" || code=="MXN" ||
             code=="ZAR" || code=="TRY" || code=="PLN" ||
             code=="HUF" || code=="CZK");
     }

   ENUM_AX_MARKET_FAMILY Classify(const string symbol_name) const
     {
      string s=symbol_name;
      StringToUpper(s);

      // Specific families first so e.g. VOLATILITY 75 is not classified as FX.
      if(ContainsAny(s,"RANGEBREAK,RANGE BREAK,RANGE_BREAK"))
         return(AX_FAMILY_SYNTH_RANGE_BREAK);
      if(ContainsAny(s,"BOOM,CRASH"))
         return(AX_FAMILY_SYNTH_BOOM_CRASH);
      if(ContainsAny(s,"JUMP"))
         return(AX_FAMILY_SYNTH_JUMP);
      if(ContainsAny(s,"STEP"))
         return(AX_FAMILY_SYNTH_STEP);
      if(ContainsAny(s,"DRIFT,SWITCHING"))
         return(AX_FAMILY_SYNTH_DRIFT_SWITCH);
      if(ContainsAny(s,"HYBRID"))
         return(AX_FAMILY_SYNTH_HYBRID);
      if(ContainsAny(s,"VOLATILITY,VOL "))
         return(AX_FAMILY_SYNTH_VOLATILITY);
      if(ContainsAny(s,"TREK,SKEW,DEX,MULTI STEP,DAILY RESET"))
         return(AX_FAMILY_SYNTH_OTHER);

      if(ContainsAny(s,"XAU,GOLD"))
         return(AX_FAMILY_GOLD);

      // FX classification is deliberately conservative: strip common separators,
      // then require two recognised three-letter currency codes at the start.
      string compact=s;
      StringReplace(compact,"/","");
      StringReplace(compact,"_","");
      StringReplace(compact,".","");
      StringReplace(compact,"-","");
      if(StringLen(compact)>=6)
        {
         string base=StringSubstr(compact,0,3);
         string quote=StringSubstr(compact,3,3);
         if(IsCurrencyCode(base) && IsCurrencyCode(quote) && base!=quote)
            return(AX_FAMILY_FX);
        }
      if(ContainsAny(s,"SYNTH"))
         return(AX_FAMILY_SYNTH_OTHER);
      if(ContainsAny(s,"INDEX,INDICES"))
         return(AX_FAMILY_OTHER);
      return(AX_FAMILY_UNKNOWN);
     }

   bool ReadOne(const string symbol_name,SAxBrokerSymbol &out) const
     {
      out.name=symbol_name;
      out.family=Classify(symbol_name);
      out.selected=(bool)SymbolInfoInteger(symbol_name,SYMBOL_SELECT);
      out.trade_mode=SymbolInfoInteger(symbol_name,SYMBOL_TRADE_MODE);
      out.tradeable=(out.trade_mode!=SYMBOL_TRADE_MODE_DISABLED);
      out.point=SymbolInfoDouble(symbol_name,SYMBOL_POINT);
      out.tick_size=SymbolInfoDouble(symbol_name,SYMBOL_TRADE_TICK_SIZE);
      out.tick_value=SymbolInfoDouble(symbol_name,SYMBOL_TRADE_TICK_VALUE);
      out.volume_min=SymbolInfoDouble(symbol_name,SYMBOL_VOLUME_MIN);
      out.volume_max=SymbolInfoDouble(symbol_name,SYMBOL_VOLUME_MAX);
      out.volume_step=SymbolInfoDouble(symbol_name,SYMBOL_VOLUME_STEP);

      // Missing contract metadata is not considered safe for downstream execution.
      if(out.point<=0.0 || out.tick_size<=0.0 ||
         out.volume_min<=0.0 || out.volume_max<out.volume_min ||
         out.volume_step<=0.0)
         out.tradeable=false;
      return(true);
     }

public:
                     CBrokerUniverse(void) { m_count=0; }
   int               Count(void) const { return(m_count); }

   bool              Refresh(const bool select_all=false)
     {
      ArrayResize(m_items,0);
      m_count=0;
      int total=SymbolsTotal(false);
      if(total<=0) return(false);
      for(int i=0;i<total;i++)
        {
         string name=SymbolName(i,false);
         if(name=="") continue;
         if(select_all && !SymbolSelect(name,true)) continue;
         SAxBrokerSymbol item;
         if(!ReadOne(name,item)) continue;
         int next=ArrayResize(m_items,m_count+1);
         if(next!=m_count+1) return(false);
         m_items[m_count]=item;
         m_count++;
        }
      return(m_count>0);
     }

   bool              Get(const int index,SAxBrokerSymbol &out) const
     {
      if(index<0 || index>=m_count) return(false);
      out=m_items[index];
      return(true);
     }

   int               CountFamily(const ENUM_AX_MARKET_FAMILY family,
                                 const bool tradeable_only=true) const
     {
      int found=0;
      for(int i=0;i<m_count;i++)
         if(m_items[i].family==family && (!tradeable_only || m_items[i].tradeable))
            found++;
      return(found);
     }
  };

#endif // AUTOPSYX_BROKER_UNIVERSE_MQH
