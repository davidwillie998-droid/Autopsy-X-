//+------------------------------------------------------------------+
//| ConfidenceEngine.mqh                                              |
//| Weighted scoring engine. Combines microstructure, liquidity and   |
//| momentum evidence into independent BUY / SELL scores, adjusts     |
//| weighting by market regime, and only ever recommends a trade when |
//| the winning side clears both an absolute threshold and a minimum  |
//| edge over the opposing side. Default behaviour is NO TRADE.       |
//+------------------------------------------------------------------+
#pragma once
#include <AutopsyX/Defines.mqh>
#include <AutopsyX/SymbolProfile.mqh>
#include <AutopsyX/MicrostructureEngine.mqh>
#include <AutopsyX/LiquidityEngine.mqh>
#include <AutopsyX/MomentumEngine.mqh>
#include <AutopsyX/RegimeEngine.mqh>

class CAXConfidence
{
private:
   const CAXSymbolProfile *m_profile;
   const CAXMicrostructure *m_micro;
   const CAXLiquidity      *m_liq;
   const CAXMomentum       *m_mom;
   const CAXRegime         *m_regime;

   double m_entryThreshold;   // winning score must be >= this to trade
   double m_minGap;           // winning score must beat the other side by this much
   double m_maxSpreadPoints;
   double m_maxSpreadExpansion;
   double m_minAtrPoints;

   // factor weights, sum should be ~100
   double m_wTickImbalance;
   double m_wConsecutive;
   double m_wVelocity;
   double m_wStructure;
   double m_wMicroBreak;
   double m_wLiquidityFlip;
   double m_wDisplacement;

   double m_buyScore, m_sellScore;
   ENUM_AX_CONFIDENCE m_confidence;
   ENUM_AX_DIRECTION  m_direction;
   string m_blockReason;

public:
   CAXConfidence(void) : m_profile(NULL), m_micro(NULL), m_liq(NULL), m_mom(NULL), m_regime(NULL),
      m_entryThreshold(65.0), m_minGap(15.0), m_maxSpreadPoints(30.0), m_maxSpreadExpansion(2.0),
      m_minAtrPoints(5.0), m_wTickImbalance(10.0), m_wConsecutive(8.0), m_wVelocity(7.0),
      m_wStructure(15.0), m_wMicroBreak(15.0), m_wLiquidityFlip(25.0), m_wDisplacement(20.0),
      m_buyScore(0), m_sellScore(0), m_confidence(AX_CONF_NONE), m_direction(AX_DIR_NONE) {}

   void BindEngines(const CAXSymbolProfile &profile, const CAXMicrostructure &micro,
                     const CAXLiquidity &liq, const CAXMomentum &mom, const CAXRegime &regime)
   {
      m_profile = GetPointer(profile);
      m_micro   = GetPointer(micro);
      m_liq     = GetPointer(liq);
      m_mom     = GetPointer(mom);
      m_regime  = GetPointer(regime);
   }

   void SetThresholds(const double entryThreshold, const double minGap,
                       const double maxSpreadPoints, const double maxSpreadExpansion,
                       const double minAtrPoints)
   {
      m_entryThreshold      = AXClamp(entryThreshold, AX_ADAPT_ENTRY_THRESH_MIN, AX_ADAPT_ENTRY_THRESH_MAX);
      m_minGap              = MathMax(1.0, minGap);
      m_maxSpreadPoints      = MathMax(0.1, maxSpreadPoints);
      m_maxSpreadExpansion   = MathMax(1.0, maxSpreadExpansion);
      m_minAtrPoints         = MathMax(0.0, minAtrPoints);
   }

   double EntryThreshold(void) const { return m_entryThreshold; }
   void   SetEntryThreshold(const double v) { m_entryThreshold = AXClamp(v, AX_ADAPT_ENTRY_THRESH_MIN, AX_ADAPT_ENTRY_THRESH_MAX); }

   // recompute buy/sell/confidence/direction; call once per tick (cheap - O(1))
   void Update(void)
   {
      m_buyScore = 0.0;
      m_sellScore = 0.0;
      m_blockReason = "";

      if(m_micro == NULL || m_liq == NULL || m_mom == NULL || m_regime == NULL || !m_regime.IsValid())
      {
         m_confidence = AX_CONF_NONE;
         m_direction = AX_DIR_NONE;
         m_blockReason = "engines not ready";
         return;
      }

      ENUM_AX_REGIME regime = m_regime.CurrentRegime();

      //--- hard gates: unsafe/chaotic regime or abnormal execution conditions => no evidence at all
      if(regime == AX_REGIME_UNSAFE || regime == AX_REGIME_CHAOTIC)
      {
         m_confidence = AX_CONF_NONE;
         m_direction = AX_DIR_NONE;
         m_blockReason = "regime unsafe/chaotic";
         return;
      }
      if(m_micro.SpreadCurrentPts() > m_maxSpreadPoints || m_micro.SpreadExpansionRatio() > m_maxSpreadExpansion)
      {
         m_confidence = AX_CONF_NONE;
         m_direction = AX_DIR_NONE;
         m_blockReason = "spread abnormal";
         return;
      }

      //--- regime-based per-factor multipliers ---------------------------
      double mulStructure = 1.0, mulLiquidity = 1.0, mulDisplacement = 1.0, mulOverall = 1.0;
      switch(regime)
      {
         case AX_REGIME_TRENDING: mulStructure = 1.3; break;
         case AX_REGIME_BREAKOUT: mulDisplacement = 1.4; break;
         case AX_REGIME_RANGE:    mulLiquidity = 1.3; mulStructure = 0.8; break;
         case AX_REGIME_MEANREV:  mulLiquidity = 1.15; break;
         case AX_REGIME_HIGHVOL:  mulOverall = 0.85; break;
         case AX_REGIME_LOWVOL:
            mulOverall = 0.6;
            if(m_regime.AtrPts() < m_minAtrPoints) { m_confidence = AX_CONF_NONE; m_direction = AX_DIR_NONE; m_blockReason = "volatility insufficient"; return; }
            break;
         default: break;
      }

      //--- factor 1: tick imbalance --------------------------------------
      Accumulate(m_micro.TickImbalance(), m_wTickImbalance);

      //--- factor 2: consecutive directional ticks ------------------------
      double consecVal = AXClamp(m_micro.ConsecutiveDirectionalTicks() / 8.0, -1.0, 1.0);
      Accumulate(consecVal, m_wConsecutive);

      //--- factor 3: tick velocity / acceleration -------------------------
      double velVal = 0.0;
      if(m_micro.TickAcceleration() > 0.0)
         velVal = (double)m_micro.TickDirection() * AXClamp(MathAbs(m_micro.TickAcceleration()) / 3.0, 0.0, 1.0);
      Accumulate(velVal, m_wVelocity);

      //--- factor 4: short-term structure bias ----------------------------
      double structVal = (double)m_mom.StructureBias();
      Accumulate(structVal, m_wStructure * mulStructure);

      //--- factor 5: break of micro resistance/support --------------------
      double breakVal = 0.0;
      if(m_mom.BrokeMicroResistance()) breakVal = 1.0;
      else if(m_mom.BrokeMicroSupport()) breakVal = -1.0;
      Accumulate(breakVal, m_wMicroBreak);

      //--- factor 6: liquidity sweep -> rejection -> displacement flip ----
      double liqVal = 0.0;
      if(m_liq.LiquidityFlipSignal() == AX_DIR_BUY) liqVal = 1.0;
      else if(m_liq.LiquidityFlipSignal() == AX_DIR_SELL) liqVal = -1.0;
      Accumulate(liqVal, m_wLiquidityFlip * mulLiquidity);

      //--- factor 7: displacement strength (structure + microstructure) --
      double dirSign = (m_micro.PriceDisplacementPts() > 0) ? 1.0 : (m_micro.PriceDisplacementPts() < 0 ? -1.0 : 0.0);
      double dispVal = dirSign * AXClamp(m_mom.DisplacementStrength(), 0.0, 1.5) / 1.5;
      Accumulate(dispVal, m_wDisplacement * mulDisplacement);

      m_buyScore  = AXClamp(m_buyScore  * mulOverall, 0.0, 100.0);
      m_sellScore = AXClamp(m_sellScore * mulOverall, 0.0, 100.0);

      //--- final decision --------------------------------------------------
      double winner = MathMax(m_buyScore, m_sellScore);
      double gap    = MathAbs(m_buyScore - m_sellScore);

      if(winner < m_entryThreshold || gap < m_minGap)
      {
         m_confidence = AX_CONF_NONE;
         m_direction = AX_DIR_NONE;
         if(m_blockReason == "") m_blockReason = "edge unclear";
         return;
      }

      m_direction = (m_buyScore > m_sellScore) ? AX_DIR_BUY : AX_DIR_SELL;
      if(winner >= 80.0 && gap >= 30.0) m_confidence = AX_CONF_HIGH;
      else if(winner >= m_entryThreshold + 8.0) m_confidence = AX_CONF_MEDIUM;
      else m_confidence = AX_CONF_LOW;
   }

   double BuyScore(void)  const { return m_buyScore; }
   double SellScore(void) const { return m_sellScore; }
   ENUM_AX_CONFIDENCE Confidence(void) const { return m_confidence; }
   ENUM_AX_DIRECTION  Direction(void)  const { return m_direction; }
   string BlockReason(void) const { return m_blockReason; }

   AXSignalSnapshot Snapshot(void) const
   {
      AXSignalSnapshot s;
      s.time = TimeTradeServer();
      s.buy_score = m_buyScore;
      s.sell_score = m_sellScore;
      s.confidence = m_confidence;
      s.regime = (m_regime != NULL) ? m_regime.CurrentRegime() : AX_REGIME_UNSAFE;
      s.direction = m_direction;
      s.spread_points = (m_micro != NULL) ? m_micro.SpreadCurrentPts() : 0.0;
      s.tick_velocity = (m_micro != NULL) ? m_micro.TickVelocity() : 0.0;
      s.momentum_value = (m_mom != NULL) ? m_mom.MomentumMagnitude() : 0.0;
      s.momentum_bias = (m_mom != NULL) ? m_mom.MomentumBias() : 0;
      return s;
   }

private:
   void Accumulate(const double signedValue, const double weight)
   {
      if(signedValue > 0.0) m_buyScore  += weight * signedValue;
      else if(signedValue < 0.0) m_sellScore += weight * (-signedValue);
   }
};
