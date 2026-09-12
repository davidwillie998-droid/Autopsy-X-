//+------------------------------------------------------------------+
//| Defines.mqh                                                       |
//| AUTOPSY X FLIPDEMON X15 — shared enums, structs, constants.       |
//| Every other module includes this file. No trading logic lives     |
//| here — this is the vocabulary the rest of the system shares.      |
//+------------------------------------------------------------------+
#ifndef AXF_DEFINES_MQH
#define AXF_DEFINES_MQH

#define AXF_VERSION        "1.0.0"
#define AXF_NAME           "AUTOPSY X FLIPDEMON X15"

//--- hard, non-configurable ceilings. No multiplier chain, no bug,
//--- no "adaptive" input may ever push realised risk past these.
#define AXF_HARD_MAX_RISK_PCT        5.0     // absolute ceiling on any single trade, % equity
#define AXF_HARD_MAX_PORTFOLIO_RISK  12.0    // absolute ceiling on combined open risk, % equity
#define AXF_HARD_MAX_RISK_MULT       3.0     // adaptive multiplier ceiling
#define AXF_HARD_MIN_RISK_MULT       0.0     // multiplier may go to zero (no trade) but never negative

//+------------------------------------------------------------------+
//| Market regime                                                     |
//+------------------------------------------------------------------+
enum ENUM_AXF_REGIME
  {
   REGIME_UNKNOWN = 0,
   REGIME_TREND_BULL,
   REGIME_TREND_BEAR,
   REGIME_STRONG_TREND_BULL,
   REGIME_STRONG_TREND_BEAR,
   REGIME_RANGE,
   REGIME_EXPANSION,
   REGIME_CONTRACTION,
   REGIME_REVERSAL,
   REGIME_CHAOS
  };

enum ENUM_AXF_VOLATILITY
  {
   VOL_UNKNOWN = 0,
   VOL_VERY_LOW,
   VOL_LOW,
   VOL_NORMAL,
   VOL_HIGH,
   VOL_EXTREME
  };

enum ENUM_AXF_VOL_CHARACTER
  {
   VOLCHAR_UNKNOWN = 0,
   VOLCHAR_DIRECTIONAL,   // expansion with displacement in one direction
   VOLCHAR_CHAOTIC        // expansion without directional persistence
  };

enum ENUM_AXF_RUIN_STATE
  {
   RUIN_LOW = 0,
   RUIN_NORMAL,
   RUIN_ELEVATED,
   RUIN_DEFENSIVE,
   RUIN_HALT
  };

enum ENUM_AXF_GROWTH_MODE
  {
   MODE_SURVIVAL = 0,
   MODE_NORMAL,
   MODE_AGGRESSIVE,
   MODE_FLIP
  };

enum ENUM_AXF_DIRECTION
  {
   DIR_NONE = 0,
   DIR_LONG,
   DIR_SHORT
  };

enum ENUM_AXF_STATE
  {
   STATE_INITIALIZING = 0,
   STATE_DATA_VALIDATION,
   STATE_MARKET_ANALYSIS,
   STATE_OPPORTUNITY_SCAN,
   STATE_RISK_APPROVAL,
   STATE_ORDER_PREPARATION,
   STATE_EXECUTION,
   STATE_POSITION_VERIFICATION,
   STATE_POSITION_MANAGEMENT,
   STATE_AUTOPSY,
   STATE_COOLDOWN,
   STATE_ERROR,
   STATE_SAFE_MODE,
   STATE_RECOVERY
  };

enum ENUM_AXF_AUTOPSY_TAG
  {
   AUTOPSY_NONE = 0,
   AUTOPSY_APLUS_WIN,
   AUTOPSY_A_WIN,
   AUTOPSY_B_WIN,
   AUTOPSY_APLUS_LOSS,
   AUTOPSY_A_LOSS,
   AUTOPSY_STRUCTURAL_FAILURE,
   AUTOPSY_LIQUIDITY_FAILURE,
   AUTOPSY_MACRO_FAILURE,
   AUTOPSY_EXECUTION_FAILURE,
   AUTOPSY_REGIME_FAILURE,
   AUTOPSY_PREMATURE_EXIT,
   AUTOPSY_LATE_EXIT
  };

enum ENUM_AXF_DECISION
  {
   DECISION_APPROVE = 0,
   DECISION_REJECT_ACCOUNT_SURVIVAL,
   DECISION_REJECT_BROKER_SAFETY,
   DECISION_REJECT_DATA_QUALITY,
   DECISION_REJECT_REGIME,
   DECISION_REJECT_HTF_BIAS,
   DECISION_REJECT_LIQUIDITY,
   DECISION_REJECT_STRUCTURE,
   DECISION_REJECT_VOLATILITY,
   DECISION_REJECT_MAGNITUDE,
   DECISION_REJECT_PROBABILITY,
   DECISION_REJECT_EXPECTED_VALUE,
   DECISION_REJECT_ASYMMETRY,
   DECISION_REJECT_RISK_OF_RUIN,
   DECISION_REJECT_POSITION_SIZE,
   DECISION_REJECT_EXECUTION
  };

//+------------------------------------------------------------------+
//| Structs — one per engine's public output. Kept POD (no methods    |
//| that allocate) so they can be copied/logged/serialised cheaply.   |
//+------------------------------------------------------------------+
struct SAxfVolatility
  {
   double            atr;
   double            atr_pct;          // ATR as % of price
   double            realized_vol;     // stdev of log returns, annualised-ish proxy
   double            range_expansion;  // current range vs average range
   ENUM_AXF_VOLATILITY classification;
   ENUM_AXF_VOL_CHARACTER character;
   bool              valid;
  };

struct SAxfRegime
  {
   ENUM_AXF_REGIME   regime;
   double            trend_strength;   // ADX-like, 0..100
   double            slope;            // normalised HTF slope
   bool              valid;
  };

struct SAxfLiquidityLevel
  {
   double            price;
   string            label;
   bool              swept;
   datetime          time;
  };

struct SAxfLiquidityMap
  {
   double            prev_day_high, prev_day_low;
   double            prev_week_high, prev_week_low;
   double            session_high, session_low;
   double            nearest_liquidity_above, nearest_liquidity_below;
   bool              sweeping_highs, sweeping_lows;
   bool              accepted_above, accepted_below;
   bool              valid;
  };

struct SAxfStructure
  {
   ENUM_AXF_DIRECTION bias;
   bool              bos_confirmed;
   bool              choch_confirmed;
   bool              displacement;
   double            last_swing_high;
   double            last_swing_low;
   double            ob_price_high;    // most relevant order block zone
   double            ob_price_low;
   double            fvg_high;
   double            fvg_low;
   bool              in_premium;
   bool              in_discount;
   double            quality;          // 0..100, freshness/context weighted
   bool              valid;
  };

struct SAxfOpportunity
  {
   ENUM_AXF_DIRECTION direction;
   double            entry;
   double            stop;
   double            target1;
   double            target2;
   double            target_final;
   double            expected_move_price;
   double            risk_price_distance;
   double            reward_price_distance;
   double            r_multiple_potential;
   bool              is_aplus;
   double            quality_score; // 0..100
   bool              valid;
  };

struct SAxfProbability
  {
   double            p_tp1, p_tp2, p_tp3, p_sl;
   int               sample_size;
   double            confidence;       // 0..1, discounts small samples
   bool              valid;
  };

struct SAxfExpectedValue
  {
   double            gross_expected_r;
   double            cost_r;           // spread+commission+swap+slippage expressed in R
   double            net_expected_r;
   bool              positive;
   bool              valid;
  };

struct SAxfFlipScore
  {
   double            regime_c, structure_c, liquidity_c, volatility_c,
                     momentum_c, ev_c, asymmetry_c, execution_c,
                     account_health_c, ruin_penalty;
   double            total; // 0..100
   string            grade; // ELITE / A+ / A / B / NO TRADE
  };

struct SAxfRuinEstimate
  {
   double            p_dd10, p_dd20, p_dd30, p_dd50, p_dd75, p_near_total;
   ENUM_AXF_RUIN_STATE state;
   bool              model_estimate; // always true — never presented as certainty
   bool              valid;
  };

struct SAxfAccountState
  {
   double            balance, equity, equity_high, equity_low;
   double            drawdown_pct, daily_dd_pct, weekly_dd_pct;
   double            starting_equity;
   int               consecutive_wins, consecutive_losses;
   double            win_rate, avg_win_r, avg_loss_r, expectancy_r;
   int               closed_trades;
  };

struct SAxfTradeRecord
  {
   ulong             ticket;
   string            symbol;
   ENUM_AXF_DIRECTION direction;
   ENUM_AXF_REGIME   regime;
   datetime          open_time, close_time;
   double            entry, stop, target, exit_price;
   double            risk_pct, r_multiple, mfe_r, mae_r;
   double            spread_cost, commission_cost, swap_cost, slippage_cost;
   ENUM_AXF_GROWTH_MODE mode;
   double            flip_score;
   string            entry_reason, exit_reason;
   ENUM_AXF_AUTOPSY_TAG tag;
  };

//+------------------------------------------------------------------+
//| Small shared helpers                                              |
//+------------------------------------------------------------------+
double AxfClamp(const double v,const double lo,const double hi)
  {
   if(v<lo) return lo;
   if(v>hi) return hi;
   return v;
  }

int AxfClampInt(const int v,const int lo,const int hi)
  {
   if(v<lo) return lo;
   if(v>hi) return hi;
   return v;
  }

string AxfRegimeToString(const ENUM_AXF_REGIME r)
  {
   switch(r)
     {
      case REGIME_TREND_BULL:        return "TREND BULL";
      case REGIME_TREND_BEAR:        return "TREND BEAR";
      case REGIME_STRONG_TREND_BULL: return "STRONG TREND BULL";
      case REGIME_STRONG_TREND_BEAR: return "STRONG TREND BEAR";
      case REGIME_RANGE:             return "RANGE";
      case REGIME_EXPANSION:         return "EXPANSION";
      case REGIME_CONTRACTION:       return "CONTRACTION";
      case REGIME_REVERSAL:          return "REVERSAL";
      case REGIME_CHAOS:             return "CHAOS";
      default:                       return "UNKNOWN";
     }
  }

string AxfVolToString(const ENUM_AXF_VOLATILITY v)
  {
   switch(v)
     {
      case VOL_VERY_LOW: return "VERY LOW";
      case VOL_LOW:      return "LOW";
      case VOL_NORMAL:   return "NORMAL";
      case VOL_HIGH:     return "HIGH";
      case VOL_EXTREME:  return "EXTREME";
      default:           return "UNKNOWN";
     }
  }

string AxfModeToString(const ENUM_AXF_GROWTH_MODE m)
  {
   switch(m)
     {
      case MODE_SURVIVAL:   return "SURVIVAL";
      case MODE_NORMAL:     return "NORMAL";
      case MODE_AGGRESSIVE: return "AGGRESSIVE";
      case MODE_FLIP:       return "FLIP";
      default:              return "?";
     }
  }

string AxfRuinStateToString(const ENUM_AXF_RUIN_STATE s)
  {
   switch(s)
     {
      case RUIN_LOW:       return "LOW RISK OF RUIN";
      case RUIN_NORMAL:    return "NORMAL / AGGRESSIVE";
      case RUIN_ELEVATED:  return "ELEVATED RISK";
      case RUIN_DEFENSIVE: return "DEFENSIVE";
      case RUIN_HALT:      return "TRADING HALT";
      default:             return "?";
     }
  }

#endif // AXF_DEFINES_MQH
