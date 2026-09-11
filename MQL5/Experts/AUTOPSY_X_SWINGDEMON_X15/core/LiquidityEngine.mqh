//+------------------------------------------------------------------+
//| LiquidityEngine.mqh                                               |
//| Maps resting liquidity (PDH/PDL/PWH/PWL/monthly/equal highs-lows) |
//| and classifies it as swept/protected/vulnerable. A sweep alone is |
//| never a signal here - it is only ever context for other engines. |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_CORE_LIQUIDITYENGINE_MQH
#define AX_CORE_LIQUIDITYENGINE_MQH
#include "Types.mqh"
#include "MarketState.mqh"
#include "StructureEngine.mqh"

class CLiquidityEngine
  {
private:
   CMarketState    *m_market;
   CStructureEngine *m_structure;
   string           m_symbol;

   void AddLevel(AXLiquidityLevel &arr[], double price, ENUM_AX_LIQ_TYPE t, string label, datetime formed) const
     {
      if(price<=0.0) return;
      AXLiquidityLevel lv;
      lv.price=price; lv.ltype=t; lv.label=label; lv.formedTime=formed;
      lv.swept=false; lv.sweptTime=0;
      EvaluateSweep(lv);
      int n=ArraySize(arr); ArrayResize(arr,n+1); arr[n]=lv;
     }

   //--- a level is "swept" if price has wicked through it and closed back on the origin side
   void EvaluateSweep(AXLiquidityLevel &lv) const
     {
      bool isHighLevel = (StringFind(lv.label,"High")>=0) || (StringFind(lv.label,"EQH")>=0);
      int bars = MathMin(m_market.Bars(PERIOD_H1), 200);
      for(int i=0;i<bars;i++)
        {
         double hi = m_market.High(PERIOD_H1,i), lo = m_market.Low(PERIOD_H1,i), cl = m_market.Close(PERIOD_H1,i);
         if(isHighLevel && hi>lv.price && cl<lv.price)
           { lv.swept=true; lv.sweptTime=m_market.Time(PERIOD_H1,i); return; }
         if(!isHighLevel && lo<lv.price && cl>lv.price)
           { lv.swept=true; lv.sweptTime=m_market.Time(PERIOD_H1,i); return; }
        }
     }

public:
   void Init(CMarketState *market, CStructureEngine *structure, const string symbol)
     {
      m_market=market; m_structure=structure; m_symbol=symbol;
     }

   //--- full liquidity map, most structurally significant first
   int GetLevels(AXLiquidityLevel &out[]) const
     {
      ArrayResize(out, 0);

      double pdh = iHigh(m_symbol, PERIOD_D1, 1);
      double pdl = iLow(m_symbol, PERIOD_D1, 1);
      double pwh = iHigh(m_symbol, PERIOD_W1, 1);
      double pwl = iLow(m_symbol, PERIOD_W1, 1);
      double pmh = iHigh(m_symbol, PERIOD_MN1, 1);
      double pml = iLow(m_symbol, PERIOD_MN1, 1);

      AddLevel(out, pdh, LIQ_EXTERNAL, "PDH - Previous Day High", iTime(m_symbol,PERIOD_D1,1));
      AddLevel(out, pdl, LIQ_EXTERNAL, "PDL - Previous Day Low",  iTime(m_symbol,PERIOD_D1,1));
      AddLevel(out, pwh, LIQ_EXTERNAL, "PWH - Previous Week High",iTime(m_symbol,PERIOD_W1,1));
      AddLevel(out, pwl, LIQ_EXTERNAL, "PWL - Previous Week Low", iTime(m_symbol,PERIOD_W1,1));
      AddLevel(out, pmh, LIQ_EXTERNAL, "Monthly High",            iTime(m_symbol,PERIOD_MN1,1));
      AddLevel(out, pml, LIQ_EXTERNAL, "Monthly Low",             iTime(m_symbol,PERIOD_MN1,1));

      AddEqualLevels(out, PERIOD_H1);
      AddEqualLevels(out, PERIOD_H4);

      return ArraySize(out);
     }

   //--- cluster recent swing highs/lows within tolerance -> equal highs/lows (internal, engineered liquidity)
   void AddEqualLevels(AXLiquidityLevel &out[], ENUM_TIMEFRAMES tf) const
     {
      AXSwingPoint swings[];
      m_structure.GetSwings(tf, swings, 20);
      double atr = m_market.ATR(tf, 0);
      if(atr<=0.0) return;
      double tolerance = atr*0.15;

      for(int i=0;i<ArraySize(swings);i++)
        {
         int clusterCount=1;
         for(int j=i+1;j<ArraySize(swings);j++)
           {
            if(swings[j].isHigh!=swings[i].isHigh) continue;
            if(MathAbs(swings[j].price-swings[i].price)<=tolerance) clusterCount++;
           }
         if(clusterCount>=2)
           {
            string label = swings[i].isHigh ? "EQH - Equal Highs" : "EQL - Equal Lows";
            AXLiquidityLevel lv;
            lv.price=swings[i].price;
            lv.ltype = LIQ_INTERNAL;
            lv.label=label; lv.formedTime=swings[i].time; lv.swept=false; lv.sweptTime=0;
            EvaluateSweep(lv);
            // avoid near-duplicate entries already captured
            bool dup=false;
            for(int k=0;k<ArraySize(out);k++)
               if(MathAbs(out[k].price-lv.price)<=tolerance) { dup=true; break; }
            if(!dup) { int n=ArraySize(out); ArrayResize(out,n+1); out[n]=lv; }
           }
        }
     }

   //--- most probable liquidity draw given a directional bias: nearest unswept level in that direction
   bool GetProbableDraw(int direction, const AXLiquidityLevel &levels[], AXLiquidityLevel &result) const
     {
      double price = m_market.Mid();
      bool found=false;
      double bestDist = DBL_MAX;
      for(int i=0;i<ArraySize(levels);i++)
        {
         if(levels[i].swept) continue;
         double dist = direction>0 ? (levels[i].price-price) : (price-levels[i].price);
         if(dist<=0.0) continue; // must be ahead of price in the trade direction
         if(dist<bestDist) { bestDist=dist; result=levels[i]; found=true; }
        }
      return found;
     }

   ENUM_AX_LIQ_TYPE ClassifyVulnerability(const AXLiquidityLevel &lv, int direction) const
     {
      if(lv.swept) return LIQ_PROTECTED; // already taken, unlikely to be revisited soon
      double price = m_market.Mid();
      double atr = m_market.ATR(PERIOD_H1,0);
      if(atr<=0.0) return LIQ_RESTING;
      double dist = MathAbs(lv.price-price);
      if(dist < atr*1.5) return LIQ_VULNERABLE; // close enough to be a realistic near-term draw
      return LIQ_RESTING;
     }
  };
#endif // AX_CORE_LIQUIDITYENGINE_MQH
