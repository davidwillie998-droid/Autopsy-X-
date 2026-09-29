//+------------------------------------------------------------------+
//|                                                     ExitEngine.mqh|
//|  Exit Engine (spec section 9) + Profit Management (spec section 10)|
//|  Fast exits; protects profit in stages; cuts failed theses quickly.|
//+------------------------------------------------------------------+
#property strict
#ifndef AX_EXITENGINE_MQH
#define AX_EXITENGINE_MQH
#include "Defs.mqh"
#include "MarketData.mqh"
#include "Momentum.mqh"
#include "Microstructure.mqh"

class CExitEngine
  {
private:
   double            m_emergencySlPts;
   double            m_dynamicTpRR;         // reward:risk multiple applied to emergency SL distance
   double            m_breakEvenTriggerPts;
   double            m_breakEvenLockPts;
   double            m_trailStartPts;
   double            m_trailDistancePts;
   int               m_maxHoldSeconds;
   double            m_maxHoldExtensionMultiplier; // how far past m_maxHoldSeconds a still-favorable,
                                                    // still-trending position may run before the
                                                    // unconditional hard backstop fires regardless
   double            m_spreadAbnormalMult;
   double            m_opposingExitConfidence;
   bool              m_useAtrStops;
   double            m_atrMultiplier;

public:
                     CExitEngine(void)
     {
      m_emergencySlPts=300; m_dynamicTpRR=1.6;
      m_breakEvenTriggerPts=150; m_breakEvenLockPts=20;
      m_trailStartPts=220; m_trailDistancePts=120;
      m_maxHoldSeconds=900; m_maxHoldExtensionMultiplier=1.0; m_spreadAbnormalMult=2.2;
      m_opposingExitConfidence=55.0;
      m_useAtrStops=true; m_atrMultiplier=1.8;
     }

   void              Configure(const double emergencySlPts,const double dynamicTpRR,
                                const double breakEvenTriggerPts,const double breakEvenLockPts,
                                const double trailStartPts,const double trailDistancePts,
                                const int maxHoldSeconds,const double spreadAbnormalMult,
                                const double opposingExitConfidence,const bool useAtrStops,
                                const double atrMultiplier,const double maxHoldExtensionMultiplier=1.0)
     {
      m_emergencySlPts=emergencySlPts; m_dynamicTpRR=dynamicTpRR;
      m_breakEvenTriggerPts=breakEvenTriggerPts; m_breakEvenLockPts=breakEvenLockPts;
      m_trailStartPts=trailStartPts; m_trailDistancePts=trailDistancePts;
      m_maxHoldSeconds=maxHoldSeconds; m_spreadAbnormalMult=spreadAbnormalMult;
      m_opposingExitConfidence=opposingExitConfidence;
      m_useAtrStops=useAtrStops; m_atrMultiplier=atrMultiplier;
      m_maxHoldExtensionMultiplier=MathMax(1.0,maxHoldExtensionMultiplier);
     }

   //--- initial protective stops placed at entry - always present, never "unlimited risk". ---
   //--- ATR (when enabled) only ever WIDENS the stop beyond the fixed floor, never tightens ---
   //--- it - RiskEngine sizes the position off the resulting distance, so dollar risk stays  ---
   //--- pinned to the configured risk percent regardless of how wide the stop ends up.        ---
   void              ComputeInitialStops(const CMarketData &md,const ENUM_AX_DIR dir,const double entryPrice,
                                          const double currentAtr,double &slPriceOut,double &tpPriceOut) const
     {
      double point = md.Point();
      double slDist = m_emergencySlPts*point;
      if(m_useAtrStops && currentAtr>0)
        {
         double atrDist = currentAtr*m_atrMultiplier;
         if(atrDist>slDist) slDist = atrDist;
        }
      double tpDist = slDist*m_dynamicTpRR;
      int minStop = md.MinStopDistancePts();
      if(slDist < minStop*point) slDist = minStop*point;

      if(dir==AX_DIR_BUY)
        {
         slPriceOut = md.NormalizePrice(entryPrice-slDist);
         tpPriceOut = md.NormalizePrice(entryPrice+tpDist);
        }
      else
        {
         slPriceOut = md.NormalizePrice(entryPrice+slDist);
         tpPriceOut = md.NormalizePrice(entryPrice-tpDist);
        }
     }

   //--- update running MFE/MAE in account currency (profit-management stage 1) ---
   void              UpdateExcursion(SAxPositionState &st,const double currentBid,const double currentAsk,
                                      const double tickValue,const double tickSize) const
     {
      if(tickSize<=0) return;
      double price = (st.dir==AX_DIR_BUY) ? currentBid : currentAsk; // exit-side price
      double favorablePts = (st.dir==AX_DIR_BUY) ? (price-st.entryPrice) : (st.entryPrice-price);
      double currency = (favorablePts/tickSize)*tickValue*st.lots;

      if(currency>st.mfeCurrency) st.mfeCurrency = currency;
      if(currency<st.maeCurrency) st.maeCurrency = currency;

      bool improved = (st.dir==AX_DIR_BUY) ? (price>st.bestFavorablePrice) : (price<st.bestFavorablePrice);
      if(st.bestFavorablePrice==0 || improved) st.bestFavorablePrice = price;
     }

   //--- profit-management stage 2: move to break-even once triggered, only ever tightens ---
   //--- does NOT mutate st.breakEvenDone - caller sets it only after the broker confirms the modify ---
   bool              CheckBreakEven(const SAxPositionState &st,const CMarketData &md,const double currentPrice,
                                     double &newSlOut) const
     {
      if(st.breakEvenDone) return(false);
      double point = md.Point();
      double favorablePts = (st.dir==AX_DIR_BUY) ? (currentPrice-st.entryPrice)/point : (st.entryPrice-currentPrice)/point;
      if(favorablePts < m_breakEvenTriggerPts) return(false);

      double lockDist = m_breakEvenLockPts*point;
      double candidate = (st.dir==AX_DIR_BUY) ? st.entryPrice+lockDist : st.entryPrice-lockDist;

      bool improvesOnCurrent = (st.dir==AX_DIR_BUY) ? (candidate>st.initialSlPrice) : (candidate<st.initialSlPrice);
      if(!improvesOnCurrent) return(false);

      newSlOut = md.NormalizePrice(candidate);
      return(true);
     }

   //--- profit-management stage 3: momentum-adaptive trailing, only ever tightens ---
   bool              CheckTrailing(const SAxPositionState &st,const CMarketData &md,const double currentPrice,
                                    const double currentSl,const CMomentumEngine &mom,double &newSlOut) const
     {
      double point = md.Point();
      double favorablePts = (st.dir==AX_DIR_BUY) ? (currentPrice-st.entryPrice)/point : (st.entryPrice-currentPrice)/point;
      if(favorablePts < m_trailStartPts) return(false);

      double dist = m_trailDistancePts;
      if(mom.IsExhausted()) dist *= 0.55; // tighten aggressively once momentum is fading

      double candidate = (st.dir==AX_DIR_BUY) ? currentPrice-dist*point : currentPrice+dist*point;

      bool improvesOnCurrent = (st.dir==AX_DIR_BUY) ? (candidate>currentSl) : (candidate<currentSl);
      if(!improvesOnCurrent) return(false);

      int minStop = md.MinStopDistancePts();
      double distFromPrice = MathAbs(currentPrice-candidate)/point;
      if(distFromPrice < minStop) return(false);

      newSlOut = md.NormalizePrice(candidate);
      return(true);
     }

   //--- optional scale-out: bank part of the position once it reaches triggerRR times the      ---
   //--- ORIGINAL stop distance, letting the remainder ride under normal exit/trailing logic.    ---
   //--- Fires once per position (caller tracks that via st.partialTaken / lastAccountedDealTicket). ---
   bool              CheckPartialTakeProfit(const SAxPositionState &st,const CMarketData &md,
                                             const double currentPrice,const double triggerRR,
                                             const double closePercent,double &volumeToCloseOut) const
     {
      if(st.partialTaken) return(false);
      double slDist = MathAbs(st.entryPrice-st.originalSlPrice);
      if(slDist<=0) return(false);

      double favorable = (st.dir==AX_DIR_BUY) ? (currentPrice-st.entryPrice) : (st.entryPrice-currentPrice);
      if(favorable < slDist*triggerRR) return(false);

      // floor to a valid volume step WITHOUT letting NormalizeVolume's own clamp-up-to-minimum
      // silently inflate a too-small request into closing a disproportionate share of the
      // position (e.g. 20% of a 0.03-lot position floors to 0 lots, not "round up to 0.01")
      double step = md.VolumeStep();
      if(step<=0) step=0.01;
      double minVol = md.VolumeMin();
      double rawVol = st.lots*(closePercent/100.0);
      double vol = MathFloor(rawVol/step)*step;
      if(vol<minVol) return(false); // requested percentage is too small to express as a valid partial
      // never close so much that the remainder drops below the broker's minimum lot
      if((st.lots-vol)<minVol) return(false);

      volumeToCloseOut = md.NormalizeVolume(vol); // vol already >= minVol, this only rounds digits
      return(true);
     }

   //--- fast defensive exits: profit-management stage 4 + spec section 9 ---
   //--- vwapExitCheckDue/vwapValueAtCheck/lastClosedBarClose: passed by the caller only once per new ---
   //--- bar close (see main.mq5) - this is the ONE input to this whole function that, when it fires, ---
   //--- is never skippable by anything else in here. See the check itself for why that matters. ---
   SAxExitDecision   Evaluate(const SAxPositionState &st,const CMarketData &md,const CMomentumEngine &mom,
                               const CMicrostructureEngine &micro,const SAxScore &score,
                               const double maxSpreadPts,
                               const ENUM_AX_VWAP_EXIT_MODE vwapExitMode,
                               const bool vwapExitCheckDue,const double vwapValueAtCheck,
                               const double lastClosedBarClose,const double currentPrice=0.0,
                               const bool structureConfirmsReversal=false) const
     {
      SAxExitDecision d; d.shouldExit=false; d.reason=AX_EXIT_NONE;

      //--- VWAP mechanical exit (Zarattini & Aziz 2023, adapted for 24-hour markets - see           ---
      //--- VWAPEngine.mqh). This is deliberately the FIRST check in this function and returns        ---
      //--- immediately: no other condition below it, and no caller-side flag (not "unless a flip is  ---
      //--- also confirming", not "unless the setup score is high"), may skip it once it fires. That's ---
      //--- not stylistic - it's the entire basis for CAdaptiveFlipEngine's VWAP alignment sizing      ---
      //--- bonus being legitimate at all: aggressive sizing is only defensible because this exit is   ---
      //--- real and honored whenever the CONFIGURED mode says it should fire, exactly the source      ---
      //--- paper's own finding. st.vwapAlignedAtEntry being true already encodes that VWAP exit was   ---
      //--- on and this position agreed with VWAP at entry, so no separate enabled-flag is needed here ---
      //--- beyond that plus the mode itself.                                                          ---
      //--- Modes (spec section 9 - "do not make a single VWAP cross an unconditional full exit"):     ---
      //--- OFF: never fires. IMMEDIATE: any tick the LIVE price is on the wrong side. CONFIRMED_CROSS: ---
      //--- requires a closed bar on the wrong side (the original, default behavior - also the only    ---
      //--- mode that respects VWAPEngine's ATR deadband, since that's built into vwapValueAtCheck's    ---
      //--- classification upstream). CONFIRMED_CROSS_PLUS_STRUCTURE: the same closed-bar confirmation, ---
      //--- but ALSO requires the caller to report the structure engine agrees a reversal is genuinely  ---
      //--- underway - the strictest mode, avoiding an exit on a VWAP cross that structure itself does  ---
      //--- not corroborate.                                                                            ---
      //--- One honest interaction worth naming: if a full FLIP confirmation fires on the very same    ---
      //--- tick, main.mq5's flip branch closes the position under AX_EXIT_FLIP before this function   ---
      //--- is even called that tick - the position is still always closed either way, just possibly   ---
      //--- labeled FLIP instead of VWAP_TREND_FLIP on that one tick. That is flip's own unconditional ---
      //--- closure acting first, not a bypass of this rule. ---
      if(st.vwapAlignedAtEntry && vwapExitMode!=AX_VWAP_EXIT_OFF)
        {
         bool triggered=false;

         if(vwapExitMode==AX_VWAP_EXIT_IMMEDIATE && currentPrice>0 && vwapValueAtCheck>0)
           {
            triggered = (st.dir==AX_DIR_BUY) ? (currentPrice<vwapValueAtCheck) : (currentPrice>vwapValueAtCheck);
           }
         else if(vwapExitCheckDue && vwapValueAtCheck>0 &&
                 (vwapExitMode==AX_VWAP_EXIT_CONFIRMED_CROSS || vwapExitMode==AX_VWAP_EXIT_CONFIRMED_CROSS_PLUS_STRUCTURE))
           {
            bool closedWrongSide = (st.dir==AX_DIR_BUY) ? (lastClosedBarClose<vwapValueAtCheck)
                                                          : (lastClosedBarClose>vwapValueAtCheck);
            triggered = closedWrongSide;
            if(triggered && vwapExitMode==AX_VWAP_EXIT_CONFIRMED_CROSS_PLUS_STRUCTURE)
               triggered = triggered && structureConfirmsReversal;
           }

         if(triggered) { d.shouldExit=true; d.reason=AX_EXIT_VWAP_TREND_FLIP; return(d); }
        }

      //--- maximum holding time - Patnaik & Thomas (2004) find momentum profits RISE with holding ---
      //--- period once formation is short (their Table 6: profits at a 250-day hold run 3-4x those ---
      //--- at a 25-day hold, for the same short formation window this EA's tick-level lookback      ---
      //--- mirrors). An unconditional clock cutoff throws away exactly the trades that finding says ---
      //--- are worth holding. So: a SOFT cutoff at m_maxHoldSeconds is skippable, but only while the ---
      //--- position is both currently in profit AND momentum is still persistent/not exhausted in   ---
      //--- its own direction - every other defensive check below (momentum collapse, micro reversal,---
      //--- opposing signal, abnormal spread) stays fully active regardless, so a position that's     ---
      //--- actually turning still gets cut fast. A HARD backstop at                                  ---
      //--- m_maxHoldSeconds*m_maxHoldExtensionMultiplier fires unconditionally no matter what, so    ---
      //--- this can never become an unbounded hold - m_maxHoldExtensionMultiplier=1.0 (the default)  ---
      //--- collapses soft==hard and restores the exact prior unconditional-cutoff behavior. ---
      int heldSec = (int)(TimeCurrent()-st.entryTime);
      int hardHoldCutoff = (int)((double)m_maxHoldSeconds*m_maxHoldExtensionMultiplier);
      if(heldSec>=hardHoldCutoff) { d.shouldExit=true; d.reason=AX_EXIT_MAX_HOLD_TIME; return(d); }
      if(heldSec>=m_maxHoldSeconds)
        {
         double curPrice = (st.dir==AX_DIR_BUY) ? md.CurrentBid() : md.CurrentAsk();
         bool inProfit = (st.dir==AX_DIR_BUY) ? (curPrice>st.entryPrice) : (curPrice<st.entryPrice);
         bool stillTrending = (st.dir==AX_DIR_BUY) ? (mom.PersistentBull() && !mom.IsExhausted())
                                                    : (mom.PersistentBear() && !mom.IsExhausted());
         if(!(inProfit && stillTrending)) { d.shouldExit=true; d.reason=AX_EXIT_MAX_HOLD_TIME; return(d); }
         // else: still favorable and still trending - fall through to every check below unchanged
        }

      //--- abnormal spread: preserve capital, don't trade through bad liquidity ---
      double avgSpread = MathMax(micro.AvgSpreadPts(),1.0);
      if(md.CurrentSpreadPts() > MathMax(maxSpreadPts,avgSpread*m_spreadAbnormalMult))
        { d.shouldExit=true; d.reason=AX_EXIT_SPREAD_ABNORMAL; return(d); }

      //--- momentum collapse against the held direction ---
      bool momentumAgainst = (st.dir==AX_DIR_BUY) ? (mom.PersistentBear() && mom.DisplacementPts()<0)
                                                    : (mom.PersistentBull() && mom.DisplacementPts()>0);
      if(momentumAgainst) { d.shouldExit=true; d.reason=AX_EXIT_MOMENTUM_COLLAPSE; return(d); }

      //--- microstructure reversal: tick imbalance flips hard against the position ---
      bool microAgainst = (st.dir==AX_DIR_BUY) ? (micro.TickImbalance()<-0.35)
                                                 : (micro.TickImbalance()>0.35);
      if(microAgainst) { d.shouldExit=true; d.reason=AX_EXIT_MICROSTRUCTURE_REVERSAL; return(d); }

      //--- single strong opposite reading (short of full flip confirmation) - cut, don't hope ---
      ENUM_AX_DIR opposite = (st.dir==AX_DIR_BUY) ? AX_DIR_SELL : AX_DIR_BUY;
      if(score.action==opposite && score.confidence>=m_opposingExitConfidence)
        { d.shouldExit=true; d.reason=AX_EXIT_OPPOSITE_SIGNAL; return(d); }

      return(d);
     }
  };
//+------------------------------------------------------------------+
#endif // AX_EXITENGINE_MQH
