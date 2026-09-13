//+------------------------------------------------------------------+
//| Defines.mqh                                                      |
//| AUTOPSY X HFT FLIP ENGINE - shared enums, structs, constants     |
//+------------------------------------------------------------------+
#pragma once

//--- direction / regime / confidence enums -------------------------
enum ENUM_AX_DIRECTION
{
   AX_DIR_NONE = 0,
   AX_DIR_BUY  = 1,
   AX_DIR_SELL = -1
};

enum ENUM_AX_REGIME
{
   AX_REGIME_TRENDING,
   AX_REGIME_BREAKOUT,
   AX_REGIME_MEANREV,
   AX_REGIME_RANGE,
   AX_REGIME_HIGHVOL,
   AX_REGIME_LOWVOL,
   AX_REGIME_CHAOTIC,
   AX_REGIME_UNSAFE
};

enum ENUM_AX_CONFIDENCE
{
   AX_CONF_NONE = 0,
   AX_CONF_LOW,
   AX_CONF_MEDIUM,
   AX_CONF_HIGH
};

enum ENUM_AX_STATUS
{
   AX_STATUS_ACTIVE,
   AX_STATUS_PAUSED,
   AX_STATUS_LOCKED,
   AX_STATUS_CALIBRATING
};

enum ENUM_AX_EXIT_REASON
{
   AX_EXIT_NONE,
   AX_EXIT_TAKE_PROFIT,
   AX_EXIT_STOP_LOSS,
   AX_EXIT_TRAIL,
   AX_EXIT_BREAKEVEN,
   AX_EXIT_TIME,
   AX_EXIT_MOMENTUM,
   AX_EXIT_OPPOSITE_SIGNAL,
   AX_EXIT_SPREAD_ABNORMAL,
   AX_EXIT_RISK_SHUTDOWN,
   AX_EXIT_MANUAL
};

enum ENUM_AX_AUTOPSY_TAG
{
   AX_TAG_CORRECT_READ,
   AX_TAG_LATE_ENTRY,
   AX_TAG_FALSE_BREAKOUT,
   AX_TAG_LIQUIDITY_TRAP,
   AX_TAG_MOMENTUM_FAILURE,
   AX_TAG_SPREAD_FAILURE,
   AX_TAG_SLIPPAGE_FAILURE,
   AX_TAG_PREMATURE_EXIT,
   AX_TAG_CORRECT_EXIT,
   AX_TAG_STOP_LOSS,
   AX_TAG_TAKE_PROFIT,
   AX_TAG_OPPOSITE_SIGNAL,
   AX_TAG_RISK_SHUTDOWN
};

//--- adaptive parameter hard boundaries (never crossed by self-tuning) --
#define AX_ADAPT_ENTRY_THRESH_MIN     55.0
#define AX_ADAPT_ENTRY_THRESH_MAX     90.0
#define AX_ADAPT_EXIT_THRESH_MIN      40.0
#define AX_ADAPT_EXIT_THRESH_MAX      75.0
#define AX_ADAPT_COOLDOWN_MIN_SEC     3
#define AX_ADAPT_COOLDOWN_MAX_SEC     180
#define AX_ADAPT_TICKWINDOW_MIN       20
#define AX_ADAPT_TICKWINDOW_MAX       400
#define AX_ADAPT_HOLDTIME_MIN_SEC     10
#define AX_ADAPT_HOLDTIME_MAX_SEC     1800
#define AX_ADAPT_TRAIL_MIN_POINTS     20.0
#define AX_ADAPT_TRAIL_MAX_POINTS     1000.0
#define AX_ADAPT_MAXFLIPS_MIN         1
#define AX_ADAPT_MAXFLIPS_MAX         20

//--- misc constants --------------------------------------------------
#define AX_TICK_BUFFER_CAPACITY       512
#define AX_BAR_STRUCT_LOOKBACK        60

//--- snapshot of the signal engine at a point in time -----------------
struct AXSignalSnapshot
{
   datetime time;
   double   buy_score;
   double   sell_score;
   ENUM_AX_CONFIDENCE confidence;
   ENUM_AX_REGIME     regime;
   ENUM_AX_DIRECTION  direction;
   double   spread_points;
   double   tick_velocity;
   double   momentum_value;
   int      momentum_bias;      // -1,0,1
};

//--- one completed trade, used by the autopsy / analytics engine ------
struct AXTradeRecord
{
   ulong    ticket;
   datetime open_time;
   datetime close_time;
   ENUM_AX_DIRECTION direction;
   double   requested_price;
   double   filled_price;
   double   exit_price;
   double   slippage_points;
   double   spread_at_entry;
   double   lots;
   double   profit;
   int      holding_seconds;
   ENUM_AX_EXIT_REASON exit_reason;
   ENUM_AX_AUTOPSY_TAG autopsy_tag;
   double   buy_score_at_entry;
   double   sell_score_at_entry;
   ENUM_AX_REGIME regime_at_entry;
   ulong    signal_to_order_ms;
   ulong    order_to_fill_ms;
};

//--- state of the (single) currently managed position ------------------
struct AXPositionState
{
   bool     active;
   ulong    ticket;
   ENUM_AX_DIRECTION direction;
   double   entry_price;
   double   lots;
   double   sl;
   double   tp;
   double   requested_price;
   double   spread_at_entry;
   datetime open_time;
   bool     breakeven_done;
   double   trail_level;
   AXSignalSnapshot entry_snapshot;
   ulong    signal_time_msc;
   ulong    order_submit_msc;
   ulong    order_fill_msc;
};

//--- clamp helper -------------------------------------------------------
double AXClamp(const double value, const double lo, const double hi)
{
   if(value < lo) return lo;
   if(value > hi) return hi;
   return value;
}

int AXClampInt(const int value, const int lo, const int hi)
{
   if(value < lo) return lo;
   if(value > hi) return hi;
   return value;
}

string AXDirToString(const ENUM_AX_DIRECTION dir)
{
   if(dir == AX_DIR_BUY)  return "BUY";
   if(dir == AX_DIR_SELL) return "SELL";
   return "NONE";
}

string AXRegimeToString(const ENUM_AX_REGIME regime)
{
   switch(regime)
   {
      case AX_REGIME_TRENDING: return "TRENDING";
      case AX_REGIME_BREAKOUT: return "BREAKOUT";
      case AX_REGIME_MEANREV:  return "MEAN REVERSION";
      case AX_REGIME_RANGE:    return "RANGE";
      case AX_REGIME_HIGHVOL:  return "HIGH VOLATILITY";
      case AX_REGIME_LOWVOL:   return "LOW VOLATILITY";
      case AX_REGIME_CHAOTIC:  return "CHAOTIC";
      case AX_REGIME_UNSAFE:   return "UNSAFE";
   }
   return "UNKNOWN";
}

string AXConfidenceToString(const ENUM_AX_CONFIDENCE c)
{
   switch(c)
   {
      case AX_CONF_HIGH:   return "HIGH";
      case AX_CONF_MEDIUM: return "MEDIUM";
      case AX_CONF_LOW:    return "LOW";
      default:             return "NONE";
   }
}

string AXExitReasonToString(const ENUM_AX_EXIT_REASON r)
{
   switch(r)
   {
      case AX_EXIT_TAKE_PROFIT:     return "TAKE_PROFIT";
      case AX_EXIT_STOP_LOSS:       return "STOP_LOSS";
      case AX_EXIT_TRAIL:           return "TRAIL";
      case AX_EXIT_BREAKEVEN:       return "BREAKEVEN";
      case AX_EXIT_TIME:            return "TIME";
      case AX_EXIT_MOMENTUM:        return "MOMENTUM";
      case AX_EXIT_OPPOSITE_SIGNAL: return "OPPOSITE_SIGNAL";
      case AX_EXIT_SPREAD_ABNORMAL: return "SPREAD_ABNORMAL";
      case AX_EXIT_RISK_SHUTDOWN:   return "RISK_SHUTDOWN";
      case AX_EXIT_MANUAL:          return "MANUAL";
      default:                      return "NONE";
   }
}

string AXAutopsyTagToString(const ENUM_AX_AUTOPSY_TAG t)
{
   switch(t)
   {
      case AX_TAG_CORRECT_READ:     return "CORRECT_READ";
      case AX_TAG_LATE_ENTRY:       return "LATE_ENTRY";
      case AX_TAG_FALSE_BREAKOUT:   return "FALSE_BREAKOUT";
      case AX_TAG_LIQUIDITY_TRAP:   return "LIQUIDITY_TRAP";
      case AX_TAG_MOMENTUM_FAILURE: return "MOMENTUM_FAILURE";
      case AX_TAG_SPREAD_FAILURE:   return "SPREAD_FAILURE";
      case AX_TAG_SLIPPAGE_FAILURE: return "SLIPPAGE_FAILURE";
      case AX_TAG_PREMATURE_EXIT:   return "PREMATURE_EXIT";
      case AX_TAG_CORRECT_EXIT:     return "CORRECT_EXIT";
      case AX_TAG_STOP_LOSS:        return "STOP_LOSS";
      case AX_TAG_TAKE_PROFIT:      return "TAKE_PROFIT";
      case AX_TAG_OPPOSITE_SIGNAL:  return "OPPOSITE_SIGNAL";
      case AX_TAG_RISK_SHUTDOWN:    return "RISK_SHUTDOWN";
   }
   return "UNKNOWN";
}
