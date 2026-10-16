//+------------------------------------------------------------------+
//| ExitEngine.mqh                                                    |
//| More important than the entry engine. Prefers fast realization of |
//| small edges over holding: momentum reversal, opposing-score       |
//| dominance, spread blowout, max holding time, or hard SL/TP all    |
//| trigger an immediate exit. Also drives breakeven + micro trailing.|
//+------------------------------------------------------------------+
#pragma once
#include <AutopsyX/Defines.mqh>
#include <AutopsyX/SymbolProfile.mqh>

class CAXExit
{
private:
   int      m_maxHoldingSec;
   double   m_trailStartPoints;
   double   m_trailDistancePoints;
   double   m_breakevenTriggerPoints;
   double   m_breakevenLockPoints;
   double   m_exitThreshold;
   double   m_exitSpreadMultiplier;
   bool     m_momentumExitEnabled;
   bool     m_oppositeSignalExitEnabled;

public:
   CAXExit(void) : m_maxHoldingSec(300), m_trailStartPoints(40.0), m_trailDistancePoints(25.0),
      m_breakevenTriggerPoints(30.0), m_breakevenLockPoints(5.0), m_exitThreshold(50.0),
      m_exitSpreadMultiplier(1.8), m_momentumExitEnabled(true), m_oppositeSignalExitEnabled(true) {}

   void Init(const int maxHoldingSec, const double trailStartPoints, const double trailDistancePoints,
             const double breakevenTriggerPoints, const double breakevenLockPoints,
             const double exitThreshold, const double exitSpreadMultiplier,
             const bool momentumExitEnabled, const bool oppositeSignalExitEnabled)
   {
      m_maxHoldingSec             = maxHoldingSec;
      m_trailStartPoints           = trailStartPoints;
      m_trailDistancePoints        = trailDistancePoints;
      m_breakevenTriggerPoints     = breakevenTriggerPoints;
      m_breakevenLockPoints        = breakevenLockPoints;
      m_exitThreshold              = AXClamp(exitThreshold, AX_ADAPT_EXIT_THRESH_MIN, AX_ADAPT_EXIT_THRESH_MAX);
      m_exitSpreadMultiplier       = exitSpreadMultiplier;
      m_momentumExitEnabled        = momentumExitEnabled;
      m_oppositeSignalExitEnabled  = oppositeSignalExitEnabled;
   }

   void SetExitThreshold(const double v) { m_exitThreshold = AXClamp(v, AX_ADAPT_EXIT_THRESH_MIN, AX_ADAPT_EXIT_THRESH_MAX); }
   double ExitThreshold(void) const { return m_exitThreshold; }

   ENUM_AX_EXIT_REASON Evaluate(const AXPositionState &pos, const double spreadPts, const double maxSpreadPts,
                                 const double buyScore, const double sellScore, const int momentumBias,
                                 const bool microExhausted) const
   {
      if(!pos.active) return AX_EXIT_NONE;

      //--- spread abnormal ---------------------------------------------
      if(spreadPts > maxSpreadPts * m_exitSpreadMultiplier)
         return AX_EXIT_SPREAD_ABNORMAL;

      //--- max holding time ----------------------------------------------
      int heldSec = (int)(TimeTradeServer() - pos.open_time);
      if(heldSec >= m_maxHoldingSec)
         return AX_EXIT_TIME;

      //--- opposing score becomes dominant --------------------------------
      if(m_oppositeSignalExitEnabled)
      {
         if(pos.direction == AX_DIR_BUY && sellScore >= m_exitThreshold && sellScore > buyScore)
            return AX_EXIT_OPPOSITE_SIGNAL;
         if(pos.direction == AX_DIR_SELL && buyScore >= m_exitThreshold && buyScore > sellScore)
            return AX_EXIT_OPPOSITE_SIGNAL;
      }

      //--- momentum reversal / exhaustion ----------------------------------
      if(m_momentumExitEnabled)
      {
         if(pos.direction == AX_DIR_BUY && (momentumBias < 0 || microExhausted))
            return AX_EXIT_MOMENTUM;
         if(pos.direction == AX_DIR_SELL && (momentumBias > 0 || microExhausted))
            return AX_EXIT_MOMENTUM;
      }

      return AX_EXIT_NONE;
   }

   // computes initial SL/TP prices, respecting broker stop/freeze distance
   void InitialStops(const CAXSymbolProfile &profile, const ENUM_AX_DIRECTION direction, const double entryPrice,
                      const double slPoints, const double tpPoints, double &sl, double &tp) const
   {
      double minDist = profile.MinStopDistancePrice();
      double slDist = MathMax(profile.PointsToPrice(slPoints), minDist + profile.point);
      double tpDist = MathMax(profile.PointsToPrice(tpPoints), minDist + profile.point);

      if(direction == AX_DIR_BUY)
      {
         sl = profile.NormalizePrice(entryPrice - slDist);
         tp = profile.NormalizePrice(entryPrice + tpDist);
      }
      else
      {
         sl = profile.NormalizePrice(entryPrice + slDist);
         tp = profile.NormalizePrice(entryPrice - tpDist);
      }
   }

   // returns true and fills newSL if breakeven should be (re)applied
   bool CheckBreakeven(const CAXSymbolProfile &profile, const AXPositionState &pos, const double currentPrice,
                        double &newSL) const
   {
      if(pos.breakeven_done) return false;
      double movePts = (pos.direction == AX_DIR_BUY) ? profile.PriceToPoints(currentPrice - pos.entry_price)
                                                       : profile.PriceToPoints(pos.entry_price - currentPrice);
      if(movePts < m_breakevenTriggerPoints) return false;

      double lockDist = profile.PointsToPrice(m_breakevenLockPoints);
      newSL = (pos.direction == AX_DIR_BUY) ? profile.NormalizePrice(pos.entry_price + lockDist)
                                             : profile.NormalizePrice(pos.entry_price - lockDist);
      return true;
   }

   // returns true and fills newSL if the trailing stop should be tightened
   // (never loosens an existing stop)
   bool CheckTrailing(const CAXSymbolProfile &profile, const AXPositionState &pos, const double currentPrice,
                       double &newSL) const
   {
      double movePts = (pos.direction == AX_DIR_BUY) ? profile.PriceToPoints(currentPrice - pos.entry_price)
                                                       : profile.PriceToPoints(pos.entry_price - currentPrice);
      if(movePts < m_trailStartPoints) return false;

      double trailDist = profile.PointsToPrice(m_trailDistancePoints);
      double candidate = (pos.direction == AX_DIR_BUY) ? profile.NormalizePrice(currentPrice - trailDist)
                                                          : profile.NormalizePrice(currentPrice + trailDist);

      bool improves = (pos.direction == AX_DIR_BUY) ? (candidate > pos.sl) : (candidate < pos.sl);
      if(!improves) return false;

      newSL = candidate;
      return true;
   }
};
