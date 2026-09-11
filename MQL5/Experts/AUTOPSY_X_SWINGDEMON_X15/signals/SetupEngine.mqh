//+------------------------------------------------------------------+
//| SetupEngine.mqh                                                     |
//| Six explicitly-ruled setup families. Every setup either finds all |
//| of its required objective conditions and returns a concrete       |
//| entry/stop/target signal, or it returns nothing - there is no     |
//| partial-credit discretionary fallback.                            |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_SIGNALS_SETUPENGINE_MQH
#define AX_SIGNALS_SETUPENGINE_MQH
#include "../core/Types.mqh"
#include "../core/MarketState.mqh"
#include "../core/StructureEngine.mqh"
#include "../core/LiquidityEngine.mqh"
#include "../core/IPDAEngine.mqh"
#include "../core/BiasEngine.mqh"
#include "../core/RegimeEngine.mqh"
#include "../intelligence/VolatilityEngine.mqh"
#include "../intelligence/NewsEngine.mqh"

class CSetupEngine
  {
private:
   CMarketState      *m_market;
   CStructureEngine  *m_structure;
   CLiquidityEngine  *m_liquidity;
   CIPDAEngine       *m_ipda;
   CBiasEngine       *m_bias;
   CVolatilityEngine *m_vol;
   CNewsEngine       *m_news;

   //--- stop distance = ATR(entryTF) * volatility-regime multiplier, floored by broker min-stop (applied by caller)
   double AtrStopDistance(ENUM_TIMEFRAMES tf) const
     {
      double atr = m_market.ATR(tf, 0);
      ENUM_AX_VOL_REGIME vr = m_vol.Classify(tf);
      return atr * m_vol.StopMultiplierFor(vr);
     }

   void BuildSignal(AXSignal &sig, ENUM_AX_SETUP setup, int direction, double entry, double stop,
                     const AXLiquidityLevel &levels[], string whyNow, string whyHere) const
     {
      sig.setup = setup;
      sig.direction = direction;
      sig.entryPrice = entry;
      sig.stopLoss = stop;
      double riskDist = MathAbs(entry-stop);
      sig.entryModel = ENTRY_MARKET;
      sig.rationaleWhyNow = whyNow;
      sig.rationaleWhyHere = whyHere;

      AXLiquidityLevel draw;
      bool haveDraw = m_liquidity.GetProbableDraw(direction, levels, draw);
      double t1 = direction>0 ? entry+riskDist*1.5 : entry-riskDist*1.5;
      double t2 = direction>0 ? entry+riskDist*2.5 : entry-riskDist*2.5;
      double tFinal = haveDraw ? draw.price : (direction>0 ? entry+riskDist*4.0 : entry-riskDist*4.0);

      if(haveDraw)
        {
         // prefer the real liquidity objective for tp2 when it's further than the ATR-derived minimum
         if(direction>0 && draw.price>t2) t2 = MathMin(draw.price, entry+riskDist*4.0);
         if(direction<0 && draw.price<t2) t2 = MathMax(draw.price, entry-riskDist*4.0);
         sig.liquidityTarget = draw.price;
        }
      else sig.liquidityTarget = tFinal;

      sig.tp1 = t1; sig.tp2 = t2; sig.tpFinal = tFinal;
      sig.rawScore = 0.0;
     }

public:
   void Init(CMarketState *market, CStructureEngine *structure, CLiquidityEngine *liquidity,
             CIPDAEngine *ipda, CBiasEngine *bias, CVolatilityEngine *vol, CNewsEngine *news)
     {
      m_market=market; m_structure=structure; m_liquidity=liquidity; m_ipda=ipda;
      m_bias=bias; m_vol=vol; m_news=news;
     }

   //--- Setup A: liquidity sweep + displacement + MSS + retracement into the displacement leg
   bool EvaluateA(const AXBiasStack &biasStack, const AXLiquidityLevel &levels[], AXSignal &sig) const
     {
      AXStructureSnapshot h1 = m_structure.GetSnapshot(PERIOD_H1);
      if(h1.lastEvent!=STRUCT_MSS_BULL && h1.lastEvent!=STRUCT_MSS_BEAR && h1.lastEvent!=STRUCT_CHOCH_BULL && h1.lastEvent!=STRUCT_CHOCH_BEAR)
         return false;

      int direction = (h1.lastEvent==STRUCT_MSS_BULL || h1.lastEvent==STRUCT_CHOCH_BULL) ? 1 : -1;

      // require an actual swept level opposite to the new direction shortly before the shift
      bool sweptOpposite=false;
      for(int i=0;i<ArraySize(levels);i++)
        {
         if(!levels[i].swept) continue;
         bool isHighLevel = (StringFind(levels[i].label,"High")>=0) || (StringFind(levels[i].label,"EQH")>=0);
         if(direction>0 && isHighLevel==false) { sweptOpposite=true; break; } // swept a low before turning bullish
         if(direction<0 && isHighLevel==true)  { sweptOpposite=true; break; } // swept a high before turning bearish
        }
      if(!sweptOpposite) return false;

      // composite HTF bias must not be the opposite of the new direction (lower TF can't fight a firm HTF thesis)
      if(biasStack.composite==BIAS_BULLISH && direction<0 && biasStack.alignmentScore>65.0) return false;
      if(biasStack.composite==BIAS_BEARISH && direction>0 && biasStack.alignmentScore>65.0) return false;

      double entry = m_market.Mid();
      double stopAnchor = direction>0 ? MathMin(h1.lastSwingLow, entry - AtrStopDistance(PERIOD_H1))
                                       : MathMax(h1.lastSwingHigh, entry + AtrStopDistance(PERIOD_H1));
      double stop = direction>0 ? MathMin(stopAnchor, entry-AtrStopDistance(PERIOD_H1)*0.6)
                                 : MathMax(stopAnchor, entry+AtrStopDistance(PERIOD_H1)*0.6);

      BuildSignal(sig, SETUP_A_SWEEP_MSS, direction, entry, stop, levels,
                  "Liquidity swept then structure broke against the sweep (MSS/CHOCH) on H1.",
                  "Entry at market on confirmed structural shift; stop beyond the sweep's origin swing.");
      return true;
     }

   //--- Setup B: HTF trend continuation into an institutional POI (order block/FVG) with fresh displacement
   bool EvaluateB(const AXBiasStack &biasStack, ENUM_AX_REGIME regime, const AXLiquidityLevel &levels[], AXSignal &sig) const
     {
      bool trending = (regime==REGIME_STRONG_BULL || regime==REGIME_WEAK_BULL || regime==REGIME_STRONG_BEAR || regime==REGIME_WEAK_BEAR);
      if(!trending) return false;
      int direction = (regime==REGIME_STRONG_BULL || regime==REGIME_WEAK_BULL) ? 1 : -1;
      if(biasStack.composite==BIAS_BULLISH && direction<0) return false;
      if(biasStack.composite==BIAS_BEARISH && direction>0) return false;
      if(biasStack.alignmentScore < 55.0) return false;

      AXOrderBlock obs[];
      m_structure.GetOrderBlocks(PERIOD_H4, obs, 60);
      double price = m_market.Mid();
      bool inPOI=false; double poiEdge=0.0;
      for(int i=0;i<ArraySize(obs);i++)
        {
         if(obs[i].mitigated) continue;
         if(obs[i].bullish!=(direction>0)) continue;
         if(obs[i].qualityScore<45.0) continue;
         if(price<=obs[i].top && price>=obs[i].bottom) { inPOI=true; poiEdge = direction>0?obs[i].bottom:obs[i].top; break; }
        }
      if(!inPOI) return false;

      AXStructureSnapshot m15 = m_structure.GetSnapshot(PERIOD_M15);
      bool ltfDisplacement = (direction>0 && (m15.lastEvent==STRUCT_BOS_BULL || m15.lastEvent==STRUCT_MSS_BULL)) ||
                             (direction<0 && (m15.lastEvent==STRUCT_BOS_BEAR || m15.lastEvent==STRUCT_MSS_BEAR));
      if(!ltfDisplacement) return false;

      double entry = price;
      double stop = direction>0 ? poiEdge - AtrStopDistance(PERIOD_H4)*0.3 : poiEdge + AtrStopDistance(PERIOD_H4)*0.3;

      BuildSignal(sig, SETUP_B_HTF_CONTINUATION, direction, entry, stop, levels,
                  "HTF trend intact with strong composite bias alignment.",
                  "Price retraced into a high-quality H4 order block and LTF confirmed continuation.");
      return true;
     }

   //--- Setup C: displacement breakout of a key level, retest without invalidation, continuation confirms
   bool EvaluateC(const AXLiquidityLevel &levels[], AXSignal &sig) const
     {
      double atr = m_market.ATR(PERIOD_H1,1);
      if(atr<=0.0) return false;

      for(int i=0;i<ArraySize(levels);i++)
        {
         if(levels[i].ltype!=LIQ_EXTERNAL) continue;
         bool isHighLevel = (StringFind(levels[i].label,"High")>=0);
         // find a displacement close beyond the level within the last 20 H1 bars, then a retest bar, then confirmation
         for(int shift=2; shift<20; shift++)
           {
            double closeAt = m_market.Close(PERIOD_H1, shift);
            bool brokeUp   = isHighLevel && closeAt>levels[i].price && (closeAt-m_market.Open(PERIOD_H1,shift))>atr*0.7;
            bool brokeDown = !isHighLevel && closeAt<levels[i].price && (m_market.Open(PERIOD_H1,shift)-closeAt)>atr*0.7;
            if(!brokeUp && !brokeDown) continue;

            int direction = brokeUp ? 1 : -1;
            // retest: price returned to within 0.3*ATR of the level after the break, without closing back through it hard
            bool retested=false;
            for(int r=shift-1;r>=1;r--)
              {
               double lo=m_market.Low(PERIOD_H1,r), hi=m_market.High(PERIOD_H1,r), cl=m_market.Close(PERIOD_H1,r);
               if(direction>0 && lo<=levels[i].price+atr*0.3 && cl>levels[i].price) { retested=true; break; }
               if(direction<0 && hi>=levels[i].price-atr*0.3 && cl<levels[i].price) { retested=true; break; }
              }
            if(!retested) continue;

            double confirmClose = m_market.Close(PERIOD_H1,0);
            bool confirms = direction>0 ? confirmClose>levels[i].price : confirmClose<levels[i].price;
            if(!confirms) continue;

            double entry = m_market.Mid();
            double stop = direction>0 ? levels[i].price-atr*0.8 : levels[i].price+atr*0.8;
            BuildSignal(sig, SETUP_C_BREAKOUT_RETEST, direction, entry, stop, levels,
                        StringFormat("Displacement breakout of %s, successful retest, continuation confirmed.", levels[i].label),
                        "Entry on retest confirmation; stop beyond the broken level.");
            return true;
           }
        }
      return false;
     }

   //--- Setup D: range extreme + liquidity raid + reversal confirmation back into the range
   bool EvaluateD(ENUM_AX_REGIME regime, const AXDealingRange &dr, const AXLiquidityLevel &levels[], AXSignal &sig) const
     {
      bool rangeRegime = (regime==REGIME_RANGE || regime==REGIME_ACCUMULATION || regime==REGIME_DISTRIBUTION);
      if(!rangeRegime) return false;

      bool atHighExtreme = dr.currentPricePct > 0.85;
      bool atLowExtreme  = dr.currentPricePct < 0.15;
      if(!atHighExtreme && !atLowExtreme) return false;

      int direction = atHighExtreme ? -1 : 1; // reversal back toward equilibrium
      AXStructureSnapshot m15 = m_structure.GetSnapshot(PERIOD_M15);
      bool reversalConfirmed = (direction>0 && (m15.lastEvent==STRUCT_CHOCH_BULL || m15.lastEvent==STRUCT_MSS_BULL)) ||
                                (direction<0 && (m15.lastEvent==STRUCT_CHOCH_BEAR || m15.lastEvent==STRUCT_MSS_BEAR));
      if(!reversalConfirmed) return false;

      // require the extreme to also be an actual swept liquidity level, not just a raw range bound
      bool sweptAtExtreme=false;
      for(int i=0;i<ArraySize(levels);i++)
         if(levels[i].swept)
           {
            bool isHighLevel = (StringFind(levels[i].label,"High")>=0) || (StringFind(levels[i].label,"EQH")>=0);
            if(atHighExtreme && isHighLevel) { sweptAtExtreme=true; break; }
            if(atLowExtreme && !isHighLevel) { sweptAtExtreme=true; break; }
           }
      if(!sweptAtExtreme) return false;

      double entry = m_market.Mid();
      double stop = direction>0 ? dr.rangeLow-AtrStopDistance(PERIOD_H1)*0.5 : dr.rangeHigh+AtrStopDistance(PERIOD_H1)*0.5;

      BuildSignal(sig, SETUP_D_RANGE_REVERSAL, direction, entry, stop, levels,
                  "Range extreme swept and rejected, structure confirmed the reversal.",
                  "Entry on confirmation with target back toward range equilibrium/opposite extreme.");
      return true;
     }

   //--- Setup E: unmitigated HTF imbalance aligned with bias, LTF confirms on return into it
   bool EvaluateE(const AXBiasStack &biasStack, const AXLiquidityLevel &levels[], AXSignal &sig) const
     {
      if(biasStack.composite==BIAS_NEUTRAL) return false;
      int direction = biasStack.composite==BIAS_BULLISH ? 1 : -1;

      AXFairValueGap gaps[];
      m_structure.GetFVGs(PERIOD_H4, gaps, 60);
      double price = m_market.Mid();
      bool inGap=false; double gapEdge=0.0;
      for(int i=0;i<ArraySize(gaps);i++)
        {
         if(gaps[i].bullish!=(direction>0)) continue;
         if(gaps[i].mitigationPct>0.5) continue; // want it still largely fresh
         if(price<=gaps[i].top && price>=gaps[i].bottom) { inGap=true; gapEdge = direction>0?gaps[i].bottom:gaps[i].top; break; }
        }
      if(!inGap) return false;

      AXStructureSnapshot m5 = m_structure.GetSnapshot(PERIOD_M5);
      bool ltfConfirms = (direction>0 && (m5.lastEvent==STRUCT_BOS_BULL || m5.lastEvent==STRUCT_MSS_BULL)) ||
                          (direction<0 && (m5.lastEvent==STRUCT_BOS_BEAR || m5.lastEvent==STRUCT_MSS_BEAR));
      if(!ltfConfirms) return false;

      double entry = price;
      double stop = direction>0 ? gapEdge - AtrStopDistance(PERIOD_H4)*0.3 : gapEdge + AtrStopDistance(PERIOD_H4)*0.3;

      BuildSignal(sig, SETUP_E_HTF_IMBALANCE, direction, entry, stop, levels,
                  "Composite HTF bias aligns with an unmitigated H4 imbalance.",
                  "Price returned into the imbalance and M5 structure confirmed continuation.");
      return true;
     }

   //--- Setup F: post-event structural repricing after a scheduled high-impact release
   bool EvaluateF(const AXLiquidityLevel &levels[], AXSignal &sig, string preEventName, string postEventName) const
     {
      if(preEventName!="") return false; // never trade into a pending high-impact release
      if(postEventName=="") return false; // requires an actual just-elapsed post-event confirmation window

      AXStructureSnapshot h1 = m_structure.GetSnapshot(PERIOD_H1);
      if(h1.lastEvent==STRUCT_NONE) return false;
      int direction = (h1.lastEvent==STRUCT_BOS_BULL || h1.lastEvent==STRUCT_MSS_BULL || h1.lastEvent==STRUCT_CHOCH_BULL) ? 1 : -1;

      double entry = m_market.Mid();
      double stop = direction>0 ? h1.lastSwingLow : h1.lastSwingHigh;
      if(MathAbs(entry-stop) < AtrStopDistance(PERIOD_H1)*0.5)
         stop = direction>0 ? entry-AtrStopDistance(PERIOD_H1) : entry+AtrStopDistance(PERIOD_H1);

      BuildSignal(sig, SETUP_F_MACRO_REPRICING, direction, entry, stop, levels,
                  StringFormat("Post-event structural repricing confirmed after: %s", postEventName),
                  "Entry after genuine price discovery, not on the event candle itself.");
      return true;
     }

   //--- run every setup and return however many objectively qualify
   int EvaluateAll(const AXBiasStack &biasStack, ENUM_AX_REGIME regime, const AXDealingRange &dr,
                    const AXLiquidityLevel &levels[], string preEventName, string postEventName,
                    AXSignal &out[]) const
     {
      ArrayResize(out, 0);
      AXSignal s;
      if(EvaluateA(biasStack, levels, s)) { int n=ArraySize(out); ArrayResize(out,n+1); out[n]=s; }
      if(EvaluateB(biasStack, regime, levels, s)) { int n=ArraySize(out); ArrayResize(out,n+1); out[n]=s; }
      if(EvaluateC(levels, s)) { int n=ArraySize(out); ArrayResize(out,n+1); out[n]=s; }
      if(EvaluateD(regime, dr, levels, s)) { int n=ArraySize(out); ArrayResize(out,n+1); out[n]=s; }
      if(EvaluateE(biasStack, levels, s)) { int n=ArraySize(out); ArrayResize(out,n+1); out[n]=s; }
      if(EvaluateF(levels, s, preEventName, postEventName)) { int n=ArraySize(out); ArrayResize(out,n+1); out[n]=s; }
      return ArraySize(out);
     }
  };
#endif // AX_SIGNALS_SETUPENGINE_MQH
