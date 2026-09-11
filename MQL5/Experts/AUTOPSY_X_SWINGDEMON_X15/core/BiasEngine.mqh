//+------------------------------------------------------------------+
//| BiasEngine.mqh                                                     |
//| Builds the hierarchical directional bias: Macro (MN1/W1) sets the |
//| ceiling, Primary (D1/H4) sets the thesis, Setup (H1/M15) refines  |
//| timing. A lower timeframe can never flip the composite bias on    |
//| its own - it can only request a re-evaluation once HTF structure  |
//| itself has actually shifted (that shift is StructureEngine's job).|
//+------------------------------------------------------------------+
#property strict
#ifndef AX_CORE_BIASENGINE_MQH
#define AX_CORE_BIASENGINE_MQH
#include "Types.mqh"
#include "MarketState.mqh"
#include "StructureEngine.mqh"

struct AXBiasStack
  {
   ENUM_AX_BIAS monthly, weekly, daily, h4, h1, m15;
   ENUM_AX_BIAS composite;
   double        alignmentScore; // 0..100, how many timeframes agree with the composite
  };

class CBiasEngine
  {
private:
   CMarketState     *m_market;
   CStructureEngine *m_structure;
   int               m_emaHandle[8];
   ENUM_TIMEFRAMES   m_emaTfs[8];
   int               m_emaCount;

   int EmaHandleFor(ENUM_TIMEFRAMES tf)
     {
      for(int i=0;i<m_emaCount;i++)
         if(m_emaTfs[i]==tf) return m_emaHandle[i];
      if(m_emaCount<8)
        {
         int h = iMA(m_market.Symbol(), tf, 50, 0, MODE_EMA, PRICE_CLOSE);
         m_emaTfs[m_emaCount]=tf; m_emaHandle[m_emaCount]=h; m_emaCount++;
         return h;
        }
      return INVALID_HANDLE;
     }

   double EmaSlope(ENUM_TIMEFRAMES tf, int lookback=5)
     {
      int handle = EmaHandleFor(tf);
      if(handle==INVALID_HANDLE) return 0.0;
      double buf[];
      ArraySetAsSeries(buf, true);
      if(CopyBuffer(handle, 0, 0, lookback+1, buf) <= 0) return 0.0;
      if(ArraySize(buf) < lookback+1) return 0.0;
      return buf[0]-buf[lookback];
     }

public:
   void Init(CMarketState *market, CStructureEngine *structure)
     {
      m_market=market; m_structure=structure; m_emaCount=0;
     }

   void Deinit()
     {
      for(int i=0;i<m_emaCount;i++)
         if(m_emaHandle[i]!=INVALID_HANDLE) IndicatorRelease(m_emaHandle[i]);
     }

   //--- bias for one timeframe = agreement of structure direction and EMA(50) slope; disagreement -> neutral
   ENUM_AX_BIAS BiasForTimeframe(ENUM_TIMEFRAMES tf)
     {
      AXStructureSnapshot snap = m_structure.GetSnapshot(tf);
      double slope = EmaSlope(tf);
      bool structBull = snap.bullishStructure;
      bool slopeBull  = slope > 0.0;
      bool slopeBear  = slope < 0.0;
      if(structBull && slopeBull) return BIAS_BULLISH;
      if(!structBull && slopeBear) return BIAS_BEARISH;
      return BIAS_NEUTRAL;
     }

   AXBiasStack GetBiasStack()
     {
      AXBiasStack s;
      s.monthly = BiasForTimeframe(PERIOD_MN1);
      s.weekly  = BiasForTimeframe(PERIOD_W1);
      s.daily   = BiasForTimeframe(PERIOD_D1);
      s.h4      = BiasForTimeframe(PERIOD_H4);
      s.h1      = BiasForTimeframe(PERIOD_H1);
      s.m15     = BiasForTimeframe(PERIOD_M15);

      // weighted vote: macro timeframes count more heavily than setup timeframes
      double bullWeight=0.0, bearWeight=0.0, totalWeight=0.0;
      AccumulateVote(s.monthly, 3.0, bullWeight, bearWeight, totalWeight);
      AccumulateVote(s.weekly,  3.0, bullWeight, bearWeight, totalWeight);
      AccumulateVote(s.daily,   2.5, bullWeight, bearWeight, totalWeight);
      AccumulateVote(s.h4,      2.0, bullWeight, bearWeight, totalWeight);
      AccumulateVote(s.h1,      1.0, bullWeight, bearWeight, totalWeight);
      AccumulateVote(s.m15,     0.5, bullWeight, bearWeight, totalWeight);

      if(bullWeight > bearWeight*1.3) s.composite = BIAS_BULLISH;
      else if(bearWeight > bullWeight*1.3) s.composite = BIAS_BEARISH;
      else s.composite = BIAS_NEUTRAL;

      double agreeWeight = (s.composite==BIAS_BULLISH) ? bullWeight : (s.composite==BIAS_BEARISH ? bearWeight : MathMax(bullWeight,bearWeight));
      s.alignmentScore = totalWeight>0.0 ? (agreeWeight/totalWeight)*100.0 : 0.0;

      return s;
     }

   //--- macro/fundamental context must adjust CONFIDENCE, never flip a structurally-derived direction outright
   double ApplyMacroModifier(double baseConfidence, ENUM_AX_BIAS structuralBias, ENUM_AX_BIAS macroBias, double macroReliability) const
     {
      if(structuralBias==BIAS_NEUTRAL || macroBias==BIAS_NEUTRAL) return baseConfidence;
      double adj = 12.0 * macroReliability; // macroReliability in [0,1]; 0 when macro data unavailable
      if(structuralBias==macroBias) return MathMin(100.0, baseConfidence + adj);
      return MathMax(0.0, baseConfidence - adj);
     }

private:
   void AccumulateVote(ENUM_AX_BIAS b, double weight, double &bullW, double &bearW, double &totalW) const
     {
      totalW += weight;
      if(b==BIAS_BULLISH) bullW += weight;
      else if(b==BIAS_BEARISH) bearW += weight;
     }
  };
#endif // AX_CORE_BIASENGINE_MQH
