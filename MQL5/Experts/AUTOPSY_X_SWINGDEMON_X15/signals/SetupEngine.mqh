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
#include "../intelligence/VWAPEngine.mqh"

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
   double             m_oteFibNear; // shallower retracement bound (e.g. 0.62) - the default sniper limit price
   double             m_oteFibFar;  // deeper retracement bound (e.g. 0.79) - past this, the setup is too extended to chase

   //--- stop distance = ATR(entryTF) * volatility-regime multiplier, floored by broker min-stop (applied by caller)
   double AtrStopDistance(ENUM_TIMEFRAMES tf) const
     {
      double atr = m_market.ATR(tf, 0);
      ENUM_AX_VOL_REGIME vr = m_vol.Classify(tf);
      return atr * m_vol.StopMultiplierFor(vr);
     }

   void BuildSignal(AXSignal &sig, ENUM_AX_SETUP setup, int direction, double entry, double stop,
                     const AXLiquidityLevel &levels[], string whyNow, string whyHere,
                     ENUM_AX_ENTRY_MODEL entryModel=ENTRY_MARKET, double invalidationPrice=0.0,
                     bool poiConfluence=false, double precisionScore=55.0) const
     {
      sig.setup = setup;
      sig.direction = direction;
      sig.entryPrice = entry;
      sig.stopLoss = stop;
      double riskDist = MathAbs(entry-stop);
      sig.entryModel = entryModel;
      sig.rationaleWhyNow = whyNow;
      sig.rationaleWhyHere = whyHere;
      sig.invalidationPrice = (invalidationPrice!=0.0) ? invalidationPrice : stop;
      sig.poiConfluence = poiConfluence;
      sig.precisionScore = precisionScore;

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

   //--- does an unmitigated same-direction order block or FVG overlap this OTE band? A confluent sniper
   //--- entry (Fib + real structure agreeing) is a materially better shot than a bare Fibonacci guess.
   bool CheckOTEConfluence(ENUM_TIMEFRAMES tf, int direction, double zoneLow, double zoneHigh, double &snapPrice) const
     {
      AXOrderBlock obs[];
      m_structure.GetOrderBlocks(tf, obs, 60);
      for(int i=0;i<ArraySize(obs);i++)
        {
         if(obs[i].mitigated || obs[i].bullish!=(direction>0)) continue;
         if(obs[i].top<zoneLow || obs[i].bottom>zoneHigh) continue; // no overlap with the OTE band
         snapPrice = direction>0 ? MathMax(obs[i].bottom,zoneLow) : MathMin(obs[i].top,zoneHigh);
         return true;
        }
      AXFairValueGap gaps[];
      m_structure.GetFVGs(tf, gaps, 60);
      for(int i=0;i<ArraySize(gaps);i++)
        {
         if(gaps[i].mitigationPct>0.5 || gaps[i].bullish!=(direction>0)) continue;
         if(gaps[i].top<zoneLow || gaps[i].bottom>zoneHigh) continue;
         snapPrice = direction>0 ? MathMax(gaps[i].bottom,zoneLow) : MathMin(gaps[i].top,zoneHigh);
         return true;
        }
      return false;
     }

public:
   void Init(CMarketState *market, CStructureEngine *structure, CLiquidityEngine *liquidity,
             CIPDAEngine *ipda, CBiasEngine *bias, CVolatilityEngine *vol, CNewsEngine *news,
             double oteFibNear=0.62, double oteFibFar=0.79)
     {
      m_market=market; m_structure=structure; m_liquidity=liquidity; m_ipda=ipda;
      m_bias=bias; m_vol=vol; m_news=news;
      m_oteFibNear = MathMin(oteFibNear, oteFibFar);
      m_oteFibFar  = MathMax(oteFibNear, oteFibFar);
     }

   //--- Setup A: liquidity sweep + displacement + MSS + sniper retracement into the impulse leg's OTE zone.
   //--- This is the flagship precision setup: no chasing the break, only the retrace back into 62-79% of it -
   //--- with a resting limit order if price hasn't arrived yet, and the whole thing cancelled outright if
   //--- price trades back through the sweep's own origin before ever tapping in.
   bool EvaluateA(const AXBiasStack &biasStack, const AXLiquidityLevel &levels[], AXSignal &sig) const
     {
      AXStructureSnapshot h1 = m_structure.GetSnapshot(PERIOD_H1);
      if(h1.lastEvent!=STRUCT_MSS_BULL && h1.lastEvent!=STRUCT_MSS_BEAR && h1.lastEvent!=STRUCT_CHOCH_BULL && h1.lastEvent!=STRUCT_CHOCH_BEAR)
         return false;

      int direction = (h1.lastEvent==STRUCT_MSS_BULL || h1.lastEvent==STRUCT_CHOCH_BULL) ? 1 : -1;
      bool bullishBreak = direction>0;

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

      double legOrigin, legExtreme; datetime originTime;
      if(!m_structure.GetImpulseLeg(PERIOD_H1, bullishBreak, legOrigin, legExtreme, originTime)) return false;
      double legRange = MathAbs(legExtreme-legOrigin);
      if(legRange<=0.0) return false;

      double oteNear = bullishBreak ? legExtreme-legRange*m_oteFibNear : legExtreme+legRange*m_oteFibNear;
      double oteFar   = bullishBreak ? legExtreme-legRange*m_oteFibFar  : legExtreme+legRange*m_oteFibFar;
      double current = m_market.Mid();

      double entry; ENUM_AX_ENTRY_MODEL mode;
      if(bullishBreak)
        {
         if(current > oteNear)      { mode=ENTRY_LIMIT;  entry=oteNear; }
         else if(current >= oteFar) { mode=ENTRY_MARKET; entry=current; } // price is already sitting in the OTE zone right now
         else return false; // already blown through the zone toward invalidation - this is chasing, not sniping
        }
      else
        {
         if(current < oteNear)      { mode=ENTRY_LIMIT;  entry=oteNear; }
         else if(current <= oteFar) { mode=ENTRY_MARKET; entry=current; }
         else return false;
        }

      // confluence: does a real order block or FVG sit inside the OTE band? If so, snap the limit to its
      // edge instead of the bare Fib number - structure agreeing with math is the whole point of a sniper entry
      double zoneLow = MathMin(oteNear, oteFar), zoneHigh = MathMax(oteNear, oteFar);
      double snapPrice; bool confluence = false;
      if(mode==ENTRY_LIMIT && CheckOTEConfluence(PERIOD_H1, direction, zoneLow, zoneHigh, snapPrice))
        { entry = snapPrice; confluence = true; }
      else if(mode==ENTRY_MARKET)
        {
         double dummy;
         confluence = CheckOTEConfluence(PERIOD_H1, direction, zoneLow, zoneHigh, dummy);
        }

      double buffer = AtrStopDistance(PERIOD_H1)*0.4;
      double stop = bullishBreak ? legOrigin-buffer : legOrigin+buffer;
      double invalidation = legOrigin; // tighter than the stop - pull the resting order the instant the origin itself breaks

      BuildSignal(sig, SETUP_A_SWEEP_MSS, direction, entry, stop, levels,
                  "Liquidity swept then structure broke against the sweep (MSS/CHOCH) on H1.",
                  mode==ENTRY_LIMIT
                     ? StringFormat("Sniper limit at the %.1f%% OTE retracement of the impulse leg%s.", m_oteFibNear*100.0, confluence?" (confluent with a real OB/FVG)":"")
                     : "Price is already inside the OTE zone - entering at market rather than a resting order.",
                  mode, invalidation, confluence, confluence?92.0:68.0);
      return true;
     }

   //--- Setup B: HTF trend continuation into an institutional POI (order block/FVG) with fresh displacement.
   //--- Sniper version: once the block is proven live (LTF displacement confirms it's holding), the entry
   //--- sits back at the block's own far edge rather than wherever price happens to be after the confirming
   //--- move - a limit order angling for the best price the zone can give, not the price after it already ran.
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
      bool inPOI=false; double poiTop=0.0, poiBottom=0.0; double quality=0.0;
      for(int i=0;i<ArraySize(obs);i++)
        {
         if(obs[i].mitigated) continue;
         if(obs[i].bullish!=(direction>0)) continue;
         if(obs[i].qualityScore<45.0) continue;
         if(price<=obs[i].top && price>=obs[i].bottom) { inPOI=true; poiTop=obs[i].top; poiBottom=obs[i].bottom; quality=obs[i].qualityScore; break; }
        }
      if(!inPOI) return false;

      AXStructureSnapshot m15 = m_structure.GetSnapshot(PERIOD_M15);
      bool ltfDisplacement = (direction>0 && (m15.lastEvent==STRUCT_BOS_BULL || m15.lastEvent==STRUCT_MSS_BULL)) ||
                             (direction<0 && (m15.lastEvent==STRUCT_BOS_BEAR || m15.lastEvent==STRUCT_MSS_BEAR));
      if(!ltfDisplacement) return false;

      // the far (deep) edge is the best realistic price the block can offer without asking for full mitigation
      double farEdge = direction>0 ? poiBottom : poiTop;
      double entry; ENUM_AX_ENTRY_MODEL mode;
      if(direction>0) { if(price>farEdge) { mode=ENTRY_LIMIT; entry=farEdge; } else { mode=ENTRY_MARKET; entry=price; } }
      else             { if(price<farEdge) { mode=ENTRY_LIMIT; entry=farEdge; } else { mode=ENTRY_MARKET; entry=price; } }

      double stop = direction>0 ? poiBottom - AtrStopDistance(PERIOD_H4)*0.3 : poiTop + AtrStopDistance(PERIOD_H4)*0.3;
      double invalidation = direction>0 ? poiBottom : poiTop; // full mitigation of the block kills the thesis

      BuildSignal(sig, SETUP_B_HTF_CONTINUATION, direction, entry, stop, levels,
                  "HTF trend intact with strong composite bias alignment.",
                  mode==ENTRY_LIMIT
                     ? "Limit order at the order block's far edge - the best price this POI can realistically offer."
                     : "Price is already at the block's far edge - entering at market rather than a resting order.",
                  mode, invalidation, true, MathMax(70.0, quality));
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

   //--- Setup E: unmitigated HTF imbalance aligned with bias, LTF confirms on return into it. Sniper version:
   //--- entry sits at the gap's own far edge (the most efficient, least-mitigated price in the imbalance),
   //--- not the price LTF confirmation happened to print at.
   bool EvaluateE(const AXBiasStack &biasStack, const AXLiquidityLevel &levels[], AXSignal &sig) const
     {
      if(biasStack.composite==BIAS_NEUTRAL) return false;
      int direction = biasStack.composite==BIAS_BULLISH ? 1 : -1;

      AXFairValueGap gaps[];
      m_structure.GetFVGs(PERIOD_H4, gaps, 60);
      double price = m_market.Mid();
      bool inGap=false; double gapTop=0.0, gapBottom=0.0;
      for(int i=0;i<ArraySize(gaps);i++)
        {
         if(gaps[i].bullish!=(direction>0)) continue;
         if(gaps[i].mitigationPct>0.5) continue; // want it still largely fresh
         if(price<=gaps[i].top && price>=gaps[i].bottom) { inGap=true; gapTop=gaps[i].top; gapBottom=gaps[i].bottom; break; }
        }
      if(!inGap) return false;

      AXStructureSnapshot m5 = m_structure.GetSnapshot(PERIOD_M5);
      bool ltfConfirms = (direction>0 && (m5.lastEvent==STRUCT_BOS_BULL || m5.lastEvent==STRUCT_MSS_BULL)) ||
                          (direction<0 && (m5.lastEvent==STRUCT_BOS_BEAR || m5.lastEvent==STRUCT_MSS_BEAR));
      if(!ltfConfirms) return false;

      double farEdge = direction>0 ? gapBottom : gapTop;
      double entry; ENUM_AX_ENTRY_MODEL mode;
      if(direction>0) { if(price>farEdge) { mode=ENTRY_LIMIT; entry=farEdge; } else { mode=ENTRY_MARKET; entry=price; } }
      else             { if(price<farEdge) { mode=ENTRY_LIMIT; entry=farEdge; } else { mode=ENTRY_MARKET; entry=price; } }

      double stop = direction>0 ? gapBottom - AtrStopDistance(PERIOD_H4)*0.3 : gapTop + AtrStopDistance(PERIOD_H4)*0.3;
      double invalidation = direction>0 ? gapBottom : gapTop; // full mitigation kills the imbalance thesis

      BuildSignal(sig, SETUP_E_HTF_IMBALANCE, direction, entry, stop, levels,
                  "Composite HTF bias aligns with an unmitigated H4 imbalance.",
                  mode==ENTRY_LIMIT
                     ? "Limit order at the imbalance's far edge - the most efficient price left in the gap."
                     : "Price is already at the gap's far edge - entering at market rather than a resting order.",
                  mode, invalidation, true, 85.0);
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

   //--- Setup G: VWAP trend/flip (Zarattini & Aziz, "VWAP: The Holy Grail for Day Trading Systems",
   //--- SSRN 4631351). Cadence and exit semantics are fundamentally different from A-F: M1-driven,
   //--- always resolves to a direction once the session VWAP is valid, and the real exit is a
   //--- close-confirmed recross of VWAP or the session close - not a fixed TP - so this is deliberately
   //--- NOT part of EvaluateAll()'s shared H1 pipeline; the caller evaluates it on its own M1 cadence.
   //--- Stop is sized off distance to VWAP itself (the level whose loss invalidates the thesis), and
   //--- position sizing still goes through the same RiskEngine as every other setup here - the paper's
   //--- own 100%-equity backtest sizing is deliberately NOT reproduced; capital preservation comes first.
   bool EvaluateVWAPFlip(const CVWAPEngine &vwap, AXSignal &sig) const
     {
      if(!vwap.IsDataValid() || vwap.CompletedBars()<5) return false; // let the session average stabilize first

      bool closedAbove = vwap.LastCompletedBarClosedAbove();
      bool closedBelow = vwap.LastCompletedBarClosedBelow();
      if(!closedAbove && !closedBelow) return false; // straddling VWAP intrabar - no confirmed close, no signal

      int direction = closedAbove ? 1 : -1;
      double entry = m_market.Mid();
      double vwapLevel = vwap.CurrentVWAP();

      // stop sits at VWAP itself plus a small ATR buffer so ordinary noise doesn't stop it out the instant
      // it fires - the paper's real invalidation (a confirmed CLOSE back through VWAP) is enforced by the
      // caller's position management on the M1 cadence; this stop is only the hard broker-side backstop.
      double buffer = AtrStopDistance(PERIOD_M15)*0.15;
      double stop = direction>0 ? vwapLevel-buffer : vwapLevel+buffer;
      double riskDist = MathAbs(entry-stop);
      if(riskDist<=0.0) return false;

      sig.setup = SETUP_G_VWAP_TREND;
      sig.direction = direction;
      sig.entryPrice = entry;
      sig.stopLoss = stop;
      sig.entryModel = ENTRY_MARKET;
      sig.invalidationPrice = vwapLevel;
      sig.poiConfluence = false;
      sig.precisionScore = 60.0;
      sig.rationaleWhyNow = closedAbove
                               ? "Last completed M1 candle closed above session VWAP."
                               : "Last completed M1 candle closed below session VWAP.";
      sig.rationaleWhyHere = "Market entry - trades the confirmed side of the session volume-weighted average, not a resting zone.";
      // no fixed take-profit by design - real exit is a close-confirmed VWAP recross or session flatten,
      // handled by position management; these are wide placeholders never expected to actually fill.
      sig.tp1 = direction>0 ? entry+riskDist*20.0 : entry-riskDist*20.0;
      sig.tp2 = sig.tp1; sig.tpFinal = sig.tp1;
      sig.liquidityTarget = sig.tpFinal;
      sig.rawScore = 0.0;
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
