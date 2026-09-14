//+------------------------------------------------------------------+
//| PositionManager.mqh                                                   |
//| Layer 14 — POSITION-MANAGEMENT ENGINE. Covers Section 30 (Dynamic     |
//| Exit Engine), Section 29 (Swing Holding Engine), Section 21           |
//| (Pyramiding Engine) and enforces Section 20/21's absolute rules:      |
//| no martingale, no averaging into a loser, adds only to positions      |
//| that are ALREADY profitable and only with fresh structural            |
//| confirmation.                                                          |
//+------------------------------------------------------------------+
#ifndef AXF_POSITIONMANAGER_MQH
#define AXF_POSITIONMANAGER_MQH

#include "../Common/Defines.mqh"
#include "ExecutionEngine.mqh"

class CAxfPositionManager
  {
private:
   ulong             m_magic;
   bool              m_pyramiding_enabled;
   int               m_max_adds;

public:
   void              Init(const ulong magic,const bool pyramiding_enabled,const int max_adds)
     {
      m_magic = magic;
      m_pyramiding_enabled = pyramiding_enabled;
      m_max_adds = MathMax(0,max_adds);
     }

   //--- moves SL to break-even once price has travelled >= 1R, then trails
   //--- behind the more recent structural swing as it develops further —
   //--- never an arbitrary fixed-pip trail (spec section 30).
   void              ManagePosition(CAxfExecutionEngine &exec,const ulong ticket,
                                     const double last_swing_high,const double last_swing_low,
                                     const double atr)
     {
      if(!PositionSelectByTicket(ticket)) return;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=m_magic) return;

      string symbol = PositionGetString(POSITION_SYMBOL);
      long type      = PositionGetInteger(POSITION_TYPE);
      double op      = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl      = PositionGetDouble(POSITION_SL);
      double tp      = PositionGetDouble(POSITION_TP);
      double price   = (type==POSITION_TYPE_BUY) ? SymbolInfoDouble(symbol,SYMBOL_BID)
                                                  : SymbolInfoDouble(symbol,SYMBOL_ASK);
      double point   = SymbolInfoDouble(symbol,SYMBOL_POINT);
      if(sl<=0 || point<=0) return; // a position without a stop is never managed into more risk here

      double risk_dist = MathAbs(op-sl);
      if(risk_dist<=0) return;
      double r_now = (type==POSITION_TYPE_BUY) ? (price-op)/risk_dist : (op-price)/risk_dist;

      double new_sl = sl;
      string reason="";

      if(r_now >= 1.0)
        {
         double breakeven = op; // break-even, not "op minus a buffer that risks BE stop-outs into loss"
         if(type==POSITION_TYPE_BUY && breakeven>sl) new_sl = breakeven;
         if(type==POSITION_TYPE_SELL && breakeven<sl) new_sl = breakeven;
        }

      if(r_now >= 1.5 && atr>0)
        {
         // trail behind the last confirmed swing, buffered by a fraction of ATR
         double buffer = atr*0.25;
         if(type==POSITION_TYPE_BUY && last_swing_low>0)
           {
            double candidate = last_swing_low - buffer;
            if(candidate > new_sl) new_sl = candidate;
           }
         if(type==POSITION_TYPE_SELL && last_swing_high>0)
           {
            double candidate = last_swing_high + buffer;
            if(candidate < new_sl || new_sl<=0) new_sl = candidate;
           }
        }

      new_sl = NormalizeDouble(new_sl,(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS));
      bool improves = (type==POSITION_TYPE_BUY) ? (new_sl>sl+point) : (new_sl<sl-point || sl<=0);
      if(improves)
         exec.ModifySLTP(ticket,new_sl,tp,reason);
     }

   //--- partial profit at target1: closes half the remaining position and lets
   //--- the runner ride toward target_final under the trailing logic above.
   void              TakePartialAtTarget1(CAxfExecutionEngine &exec,const ulong ticket,const double target1)
     {
      if(!PositionSelectByTicket(ticket)) return;
      string symbol = PositionGetString(POSITION_SYMBOL);
      long type = PositionGetInteger(POSITION_TYPE);
      double price = (type==POSITION_TYPE_BUY) ? SymbolInfoDouble(symbol,SYMBOL_BID)
                                                : SymbolInfoDouble(symbol,SYMBOL_ASK);
      bool hit = (type==POSITION_TYPE_BUY) ? (price>=target1) : (price<=target1);
      if(!hit) return;

      double vol = PositionGetDouble(POSITION_VOLUME);
      double vol_step = SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
      double vol_min = SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
      double half = MathFloor((vol/2.0)/vol_step)*vol_step;
      if(half < vol_min || (vol-half) < vol_min) return; // would leave a runt on either side, skip

      string reason;
      exec.PartialClose(ticket,half,reason);
     }

   //--- exit when the structural thesis is invalidated, regardless of SL
   //--- distance (spec section 29/30: "do not hold a position simply because
   //--- its SL has not been reached").
   bool              ThesisInvalidated(const ENUM_AXF_DIRECTION position_dir,const SAxfStructure &fresh_structure)
     {
      if(!fresh_structure.valid) return false;
      if(position_dir==DIR_LONG && fresh_structure.choch_confirmed && fresh_structure.bias==DIR_SHORT)
         return true;
      if(position_dir==DIR_SHORT && fresh_structure.choch_confirmed && fresh_structure.bias==DIR_LONG)
         return true;
      return false;
     }

   //+---------------------------------------------------------------+
   //| PYRAMIDING — Section 21. Hard rules enforced structurally:      |
   //|  1. only ever adds to a position that is CURRENTLY profitable   |
   //|  2. requires a fresh SAxfOpportunity in the SAME direction       |
   //|  3. respects m_max_adds                                         |
   //|  4. caller must separately re-check portfolio/ruin limits with  |
   //|     the ADD's own size before calling this — it does not bypass |
   //|     the RiskEngine/ExposureEngine gates.                        |
   //+---------------------------------------------------------------+
   bool              CanPyramid(const ulong ticket,const int existing_adds,const SAxfOpportunity &fresh_opportunity)
     {
      if(!m_pyramiding_enabled) return false;
      if(existing_adds >= m_max_adds) return false;
      if(!fresh_opportunity.valid) return false;
      if(!PositionSelectByTicket(ticket)) return false;

      long type = PositionGetInteger(POSITION_TYPE);
      ENUM_AXF_DIRECTION pos_dir = (type==POSITION_TYPE_BUY) ? DIR_LONG : DIR_SHORT;
      if(fresh_opportunity.direction != pos_dir) return false; // never add opposite/into a loser

      double profit = PositionGetDouble(POSITION_PROFIT);
      if(profit <= 0) return false; // Rule #1, absolute: never add to a position at a loss

      if(!fresh_opportunity.is_aplus) return false; // adds require fresh A+ confirmation, not "price moved"

      return true;
     }
  };

#endif // AXF_POSITIONMANAGER_MQH
