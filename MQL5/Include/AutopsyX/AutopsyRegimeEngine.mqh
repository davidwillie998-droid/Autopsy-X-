//+------------------------------------------------------------------+
//| AutopsyRegimeEngine.mqh                                             |
//| Top-level facade - the ONLY file an existing EA needs to include. |
//| It never touches the caller's orders: it only ever answers        |
//| "what regime, which direction, how much risk, can I trade." All   |
//| classification runs on the reference symbol's daily bars (matching|
//| the spec's own EMA20/50/200, 20-day-breakout, daily-trend-        |
//| efficiency design) and is recomputed once per new reference-      |
//| timeframe bar; the safety-critical layers (economic-event         |
//| governor, correlation governor, drawdown governor) are re-checked |
//| on every call to UpdateMarketState() regardless of bar state, so  |
//| a news release or a drawdown breach never waits for tomorrow's    |
//| bar to take effect.                                                |
//+------------------------------------------------------------------+
#property strict
#ifndef AUTOPSYX_REGIMEENGINE_MQH
#define AUTOPSYX_REGIMEENGINE_MQH
#include "AutopsyTypes.mqh"
#include "AutopsyDirectionEngine.mqh"
#include "AutopsyVolatilityEngine.mqh"
#include "AutopsyMacroEngine.mqh"
#include "AutopsyBreadthLiquidityEngine.mqh"
#include "AutopsyCorrelationEngine.mqh"
#include "AutopsyEventFilter.mqh"
#include "AutopsyRiskGovernor.mqh"
#include "AutopsyLogger.mqh"

class CAutopsyRegimeEngine
  {
private:
   AXRConfig                     m_cfg;
   CAutopsyDirectionEngine       m_direction;
   CAutopsyVolatilityEngine      m_volatility;
   CAutopsyMacroEngine           m_macro;
   CAutopsyBreadthLiquidityEngine m_breadth;
   CAutopsyCorrelationEngine     m_correlation;
   CAutopsyEventFilter           m_eventFilter;
   CAutopsyRiskGovernor          m_riskGovernor;
   CAutopsyLogger                m_logger;

   datetime        m_lastBarTime;
   bool            m_initialized;

   //--- cached slow (per-bar) state
   double             m_directionScore;
   ENUM_AXR_BIAS      m_bias;
   double             m_trendEfficiency;
   double             m_volatilityScore;
   ENUM_AXR_VOL_STATE m_volState;
   bool               m_isShock;
   string             m_shockReason;
   double             m_macroScore, m_macroReliability;
   double             m_breadthScore, m_breadthReliability;
   double             m_liquidityScore; bool m_liquidityAvailable;
   double             m_confidence;
   ENUM_AXR_REGIME    m_regime;
   ENUM_AXR_DATA_STATUS m_dataStatus;

   AXRPermission      m_lastPermission;

   //--- section 5: ABS(net change) / SUM(ABS(daily changes)) over the configured lookback, on fully
   //--- confirmed bars only
   double ComputeTrendEfficiency() const
     {
      MqlRates rates[];
      int copied = CopyRates(m_cfg.referenceSymbol, m_cfg.referenceTf, 1, m_cfg.trendEfficiencyLookback+1, rates);
      if(copied < m_cfg.trendEfficiencyLookback+1) return 0.0;
      ArraySetAsSeries(rates, true);

      double netChange = MathAbs(rates[0].close - rates[copied-1].close);
      double sumAbs = 0.0;
      for(int i=0;i<copied-1;i++) sumAbs += MathAbs(rates[i].close - rates[i+1].close);
      if(sumAbs<=0.0) return 0.0;
      return MathMax(0.0, MathMin(1.0, netChange/sumAbs));
     }

   //--- 0..100: how strongly `score` (-100..100) supports `bias`, direction-aware. Neutral bias or an
   //--- unreliable input both fall back to 50 (no opinion) rather than penalizing or rewarding blindly.
   double DirectedComponent(double score, ENUM_AXR_BIAS bias) const
     {
      if(bias==AXR_BIAS_NEUTRAL) return 50.0;
      double signedForBias = (bias==AXR_BIAS_BULLISH) ? score : -score;
      return MathMax(0.0, MathMin(100.0, 50.0 + signedForBias/2.0));
     }

   ENUM_AXR_REGIME ClassifyRegime() const
     {
      if(m_isShock) return AXR_R6_VOLATILITY_SHOCK;

      double d = m_directionScore;
      bool macroConflict = (m_macroReliability>=0.3) &&
                            ((d>0 && m_macroScore<-m_cfg.macroConflictThresh) || (d<0 && m_macroScore>m_cfg.macroConflictThresh));
      bool breadthAgainst = (m_breadthReliability>=m_cfg.minBreadthReliability) &&
                             (m_breadthScore*d < 0) && MathAbs(m_breadthScore)>10.0;
      bool volOkForBull = (m_volState==AXR_VOL_LOW || m_volState==AXR_VOL_NORMAL);
      bool volOkForBear = (m_volState==AXR_VOL_LOW || m_volState==AXR_VOL_NORMAL || m_volState==AXR_VOL_ELEVATED);

      if(MathAbs(d) < m_cfg.neutralDirectionBand && m_trendEfficiency < m_cfg.lowEfficiencyThresh)
         return AXR_R3_RANGE_CHOP;

      if(d >= m_cfg.strongDirectionThresh)
        {
         if(m_trendEfficiency>=m_cfg.highEfficiencyThresh && volOkForBull && !macroConflict && !breadthAgainst)
            return AXR_R1_PERSISTENT_BULLISH;
         return AXR_R2_BULLISH_UNSTABLE;
        }
      if(d > m_cfg.neutralDirectionBand) return AXR_R2_BULLISH_UNSTABLE;

      if(d <= -m_cfg.strongDirectionThresh)
        {
         if(m_trendEfficiency>=m_cfg.highEfficiencyThresh && volOkForBear && !macroConflict && !breadthAgainst)
            return AXR_R5_PERSISTENT_BEARISH;
         return AXR_R4_BEARISH_TRANSITION;
        }
      if(d < -m_cfg.neutralDirectionBand) return AXR_R4_BEARISH_TRANSITION;

      return AXR_R3_RANGE_CHOP;
     }

   //--- the expensive, once-per-bar path: direction/trend-efficiency/volatility/macro/breadth/liquidity,
   //--- composite confidence, and the regime classification itself
   void RecomputeRegimeState()
     {
      m_directionScore = m_direction.Compute(m_bias);
      m_trendEfficiency = ComputeTrendEfficiency();
      m_volatilityScore = m_volatility.ComputeScore();
      m_volState = m_volatility.ClassifyFromScore(m_volatilityScore);
      m_isShock = m_volatility.IsVolatilityShock(m_shockReason);
      m_macroScore = m_macro.ComputeScore(m_macroReliability);
      m_breadthScore = m_breadth.ComputeBreadthScore(m_breadthReliability);
      m_liquidityScore = m_breadth.ComputeLiquidityScore(m_liquidityAvailable);

      double dirConf     = MathAbs(m_directionScore);
      double effConf     = m_trendEfficiency*100.0;
      double volConf     = 100.0-m_volatilityScore;
      double macroConf   = m_macroReliability>0.0 ? DirectedComponent(m_macroScore, m_bias) : 50.0;
      double breadthConf = m_breadthReliability>0.0 ? DirectedComponent(m_breadthScore, m_bias) : 50.0;
      double liquidConf  = m_liquidityAvailable ? m_liquidityScore : 50.0;

      double wSum = m_cfg.wConfDirection+m_cfg.wConfTrendEff+m_cfg.wConfVolatility+
                    m_cfg.wConfMacro+m_cfg.wConfBreadth+m_cfg.wConfLiquidity;
      if(wSum<=0.0) wSum=100.0;
      m_confidence = (dirConf*m_cfg.wConfDirection + effConf*m_cfg.wConfTrendEff + volConf*m_cfg.wConfVolatility +
                      macroConf*m_cfg.wConfMacro + breadthConf*m_cfg.wConfBreadth + liquidConf*m_cfg.wConfLiquidity) / wSum;
      m_confidence = MathMax(0.0, MathMin(100.0, m_confidence));

      m_regime = ClassifyRegime();

      bool essentialOk = m_direction.IsDataValid() && m_volatility.IsDataValid();
      bool optionalMissing = (m_macroReliability<0.3) || (m_breadthReliability<m_cfg.minBreadthReliability) ||
                              (!m_volatility.VixAvailable()) || (!m_liquidityAvailable);
      if(!essentialOk)          m_dataStatus = AXR_DATA_CRITICAL;
      else if(optionalMissing)  m_dataStatus = AXR_DATA_DEGRADED;
      else                      m_dataStatus = AXR_DATA_OK;
     }

   //--- the cheap, every-call path: event/correlation/drawdown governors and the final permission
   void RecomputeFastState()
     {
      m_riskGovernor.Update();

      bool preEventMode, inEventBlock, waitForReprice; string eventName;
      m_eventFilter.Evaluate(preEventMode, inEventBlock, waitForReprice, eventName);

      double aggExposure = m_correlation.ComputeAggregateExposurePct();
      bool exceedsCorr = aggExposure >= m_correlation.MaxAggregateExposurePct();
      double corrMult = 1.0;
      if(exceedsCorr) corrMult = 0.0;
      else if(aggExposure >= m_correlation.MaxAggregateExposurePct()*0.7) corrMult = 0.5;

      double regimeMultLow=0.0, regimeMultHigh=0.0;
      bool allowLong=false, allowShort=false, aggressive=false, allowTradeBase=true;
      switch(m_regime)
        {
         case AXR_R1_PERSISTENT_BULLISH: regimeMultLow=1.00; regimeMultHigh=1.50; allowLong=true;  aggressive=true;  break;
         case AXR_R2_BULLISH_UNSTABLE:   regimeMultLow=0.50; regimeMultHigh=0.75; allowLong=true;  aggressive=false; break;
         case AXR_R3_RANGE_CHOP:
            if(m_cfg.hasDedicatedRangeStrategy)
              { regimeMultLow=0.25; regimeMultHigh=0.25; allowLong=true; allowShort=true; }
            else
               allowTradeBase=false;
            break;
         case AXR_R4_BEARISH_TRANSITION: regimeMultLow=0.25; regimeMultHigh=0.50; allowShort=true; aggressive=false; break;
         case AXR_R5_PERSISTENT_BEARISH: regimeMultLow=1.00; regimeMultHigh=1.50; allowShort=true; aggressive=true;  break;
         case AXR_R6_VOLATILITY_SHOCK:    allowTradeBase=false; break;
        }

      double regimeMult = regimeMultLow + (regimeMultHigh-regimeMultLow)*(m_confidence/100.0);
      double confidenceMult = m_confidence/100.0;
      double volMult = MathMax(0.25, 1.0 - m_volatilityScore/100.0*0.75);

      double finalRiskPercent = m_riskGovernor.ComposeFinalRiskPercent(
                                    m_cfg.baseRiskPercent, regimeMult, confidenceMult, volMult, corrMult,
                                    m_cfg.maxRiskPercentPerTrade);
      double riskMultiplier = m_cfg.baseRiskPercent>0.0 ? finalRiskPercent/m_cfg.baseRiskPercent : 0.0;

      bool blockedByCritical = (m_dataStatus==AXR_DATA_CRITICAL);
      bool halted = m_riskGovernor.IsHalted();

      // Step 1: decide the actual allow/risk VALUES first - every blocker independently forces its
      // own outcome, none of them can be silently undone by whichever branch happens to run last
      bool allowNewTrade = allowTradeBase && !exceedsCorr && !inEventBlock && !waitForReprice && !halted && !blockedByCritical;
      if(blockedByCritical || halted) { riskMultiplier=0.0; finalRiskPercent=0.0; }
      else if(m_dataStatus==AXR_DATA_DEGRADED)
        { riskMultiplier=MathMin(riskMultiplier,0.25); finalRiskPercent=MathMin(finalRiskPercent,m_cfg.baseRiskPercent*0.25); }
      if(preEventMode && !inEventBlock && !waitForReprice && !blockedByCritical && !halted)
        {
         riskMultiplier = MathMin(riskMultiplier, m_eventFilter.PreEventRiskMultiplier());
         finalRiskPercent = MathMin(finalRiskPercent, m_cfg.baseRiskPercent*m_eventFilter.PreEventRiskMultiplier());
        }

      // Step 2: THEN pick the single best explanation, in one priority-ordered chain, so the most
      // fundamental blocker always wins the audit-trail reason instead of getting overwritten by a
      // later, less-restrictive branch that also happened to be syntactically reachable
      string reason;
      if(blockedByCritical)
         reason = "CRITICAL data missing (reference symbol EMA/ATR unavailable) - new trades blocked";
      else if(halted)
         reason = "Drawdown governor HALTED - call ResetRiskGovernor() to resume";
      else if(inEventBlock)
         reason = StringFormat("In-event block: %s", eventName);
      else if(waitForReprice)
         reason = StringFormat("Post-event WAIT_FOR_REPRICE: %s", eventName);
      else if(exceedsCorr)
         reason = StringFormat("Aggregate Nasdaq exposure %.2f%% >= limit %.2f%%", aggExposure, m_correlation.MaxAggregateExposurePct());
      else if(preEventMode)
         reason = StringFormat("PRE_EVENT_MODE: %s", eventName);
      else if(m_isShock)
         reason = "R6 VOLATILITY SHOCK: "+m_shockReason;
      else if(!allowTradeBase)
         reason = (m_regime==AXR_R3_RANGE_CHOP) ? "R3 range/chop - no dedicated range strategy configured" : "Trading not permitted in current regime";
      else
         reason = StringFormat("%s, confidence %.0f", AXRRegimeToString(m_regime), m_confidence);
      if(m_dataStatus==AXR_DATA_DEGRADED && !blockedByCritical) reason += " [DEGRADED DATA - risk capped at 0.25x]";

      bool finalAggressive = aggressive && allowNewTrade && !exceedsCorr && m_dataStatus==AXR_DATA_OK && !preEventMode;

      m_lastPermission.regime = m_regime;
      m_lastPermission.bias = m_bias;
      m_lastPermission.confidence = m_confidence;
      m_lastPermission.directionScore = m_directionScore;
      m_lastPermission.trendEfficiency = m_trendEfficiency;
      m_lastPermission.volState = m_volState;
      m_lastPermission.volatilityScore = m_volatilityScore;
      m_lastPermission.macroScore = m_macroScore;
      m_lastPermission.macroReliability = m_macroReliability;
      m_lastPermission.breadthScore = m_breadthScore;
      m_lastPermission.liquidityScore = m_liquidityScore;
      m_lastPermission.aggregateExposurePct = aggExposure;
      m_lastPermission.allowLong = allowNewTrade && allowLong;
      m_lastPermission.allowShort = allowNewTrade && allowShort;
      m_lastPermission.allowNewTrade = allowNewTrade;
      m_lastPermission.riskMultiplier = riskMultiplier;
      m_lastPermission.finalRiskPercent = finalRiskPercent;
      m_lastPermission.aggressiveMode = finalAggressive;
      m_lastPermission.shockMode = m_isShock;
      m_lastPermission.preEventMode = preEventMode;
      m_lastPermission.waitForReprice = waitForReprice;
      m_lastPermission.dataStatus = m_dataStatus;
      m_lastPermission.reason = reason;
     }

public:
   void Init(const AXRConfig &cfg)
     {
      m_cfg = cfg;
      m_lastBarTime = 0; m_initialized = false;

      m_direction.Init(m_cfg.referenceSymbol, m_cfg.referenceTf, m_cfg.emaFast, m_cfg.emaMed, m_cfg.emaSlow,
                        m_cfg.breakoutLookback, m_cfg.momentumLookback, m_cfg.swingLookback, m_cfg.fractalWing);
      m_volatility.Init(m_cfg.referenceSymbol, m_cfg.referenceTf, m_cfg.vixSymbol,
                         m_cfg.atrPeriod, m_cfg.percentileLookback, m_cfg.realizedVolLookback,
                         m_cfg.volLowThresh, m_cfg.volNormalThresh, m_cfg.volElevatedThresh, m_cfg.volHighThresh,
                         m_cfg.vixLowRef, m_cfg.vixHighRef,
                         m_cfg.shockVixChangePct, m_cfg.shockRvolPercentile, m_cfg.shockDailyMovePct,
                         m_cfg.shockAtrExpansionRatio, m_cfg.shockVolumeRatio, m_cfg.shockMinConditions);
      m_macro.Init(m_cfg.dxySymbol, m_cfg.y2Symbol, m_cfg.y10Symbol, m_cfg.realYieldSymbol,
                   m_cfg.macroTrendLookbackDays, m_cfg.macroCalendarLookbackHours,
                   m_cfg.wMacroDxy, m_cfg.wMacro2y, m_cfg.wMacro10y, m_cfg.wMacroRealYield, m_cfg.wMacroCalendar);
      m_breadth.Init(m_cfg.qqqSymbol, m_cfg.breadthBasketCsv, m_cfg.breadthMaPeriod);
      m_correlation.Init(m_cfg.correlatedListCsv, m_cfg.maxAggregateExposurePct);
      m_eventFilter.Init(m_cfg.preEventBlackoutMinutes, m_cfg.inEventBlockMinutes, m_cfg.postEventRepriceMinutes,
                          m_cfg.preEventRiskMultiplier);
      m_riskGovernor.Init(m_cfg.idPrefix, m_cfg.ddThresh1, m_cfg.ddThresh2, m_cfg.ddThresh3, m_cfg.ddThresh4,
                           m_cfg.ddMult1, m_cfg.ddMult2, m_cfg.ddMult3, m_cfg.ddMult4);
      m_logger.Init(m_cfg.idPrefix);
     }

   void Deinit()
     {
      m_direction.Deinit();
      m_volatility.Deinit();
      m_breadth.Deinit();
     }

   //--- call every tick or every bar - internally throttles the expensive regime classification to
   //--- once per new bar of the reference timeframe, while event/correlation/drawdown governors are
   //--- re-checked every call
   void UpdateMarketState()
     {
      datetime barTime = iTime(m_cfg.referenceSymbol, m_cfg.referenceTf, 0);
      if(barTime != m_lastBarTime || !m_initialized)
        {
         m_lastBarTime = barTime;
         m_initialized = true;
         RecomputeRegimeState();
        }
      RecomputeFastState();
     }

   //--- logs the current permission snapshot; call once per decision point (e.g. whenever the caller's
   //--- own strategy actually asks "can I trade"), not necessarily every tick, to keep the audit trail readable
   void LogDecision(const string decision) { m_logger.Log(m_lastPermission, decision); }

   AXRPermission GetPermission() const { return m_lastPermission; }

   ENUM_AXR_REGIME    GetRegime() const       { return m_lastPermission.regime; }
   ENUM_AXR_BIAS      GetDirection() const    { return m_lastPermission.bias; }
   double             GetConfidence() const   { return m_lastPermission.confidence; }
   double             GetTrendEfficiency() const { return m_lastPermission.trendEfficiency; }
   ENUM_AXR_VOL_STATE GetVolatilityState() const { return m_lastPermission.volState; }
   double             GetRiskMultiplier() const  { return m_lastPermission.riskMultiplier; }
   double             GetFinalRiskPercent() const{ return m_lastPermission.finalRiskPercent; }
   bool               AllowLong() const  { return m_lastPermission.allowLong; }
   bool               AllowShort() const { return m_lastPermission.allowShort; }
   bool               AllowNewTrade() const { return m_lastPermission.allowNewTrade; }
   bool               IsVolatilityShock() const { return m_lastPermission.shockMode; }
   double             GetAggregateExposure() const { return m_lastPermission.aggregateExposurePct; }
   bool               IsAggressiveModePermitted() const { return m_lastPermission.aggressiveMode; }
   ENUM_AXR_DATA_STATUS GetDataStatus() const { return m_lastPermission.dataStatus; }

   void ResetRiskGovernor() { m_riskGovernor.ResetRiskGovernor(); }
  };
#endif // AUTOPSYX_REGIMEENGINE_MQH
