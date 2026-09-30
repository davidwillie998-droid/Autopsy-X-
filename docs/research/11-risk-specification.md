# 11. Risk Specification

Implemented in `risk/engine.py`. All limits are fractions of current equity unless stated, all configurable under `[risk]`.

## Limits

| Limit | Default | Effect when hit |
|---|---|---|
| Max risk per position | 0.5% of equity | caps size so loss at invalidation (plus stressed exit slippage) stays within budget |
| Max portfolio exposure | 25% | caps new notional to remaining room |
| Max narrative exposure | 10% per narrative | across all open positions sharing a specific narrative (`meme` excluded as the universe tag) |
| Max chain exposure | 20% | per chain |
| Max daily loss | 2% | refuses all new entries for the UTC day |
| Max consecutive losses | 4 | refuses entries until a win or a manual reset |
| Max slippage | 2% | position shrunk until estimated entry slippage fits; refused if nothing fits |
| Min liquidity | $50,000 | refused below |
| Max pool share | 1% of pool liquidity | caps notional |
| Exit slippage multiplier | 2x | exits budgeted at twice modelled entry slippage |

## Sizing

```
stop_frac      = 1 - invalidation_price / price
risk_notional  = max_risk_per_position * equity / (stop_frac + max_slippage * exit_multiplier)
size           = min(risk_notional, pool_share_cap, portfolio_room, chain_room, narrative_room)
while slippage(size) > max_slippage: size *= 0.8
```

The binding limit is reported with every approval. The stop distance includes expected exit slippage because in thin memecoin pools the stop price is where the exit starts, not where it ends.

## Refusal rules

The engine refuses, and says why, when:

* execution is unavailable (no price at fill time, venue down, chain congested)
* the daily loss or consecutive-loss limit is hit
* liquidity is unobservable or below minimum
* no invalidation exists below the current price (a trade that cannot be sized cannot be taken)
* no size fits the slippage limit
* the size left after all caps is below a meaningful minimum ($10)

Refusals are logged with the proposal and count as failed executions in backtests and paper trading.

## Execution conditions at fill time

Signals and risk approvals are made on data at decision time; fills happen later. The backtest runs every liquidity-dependent check again at fill time, and the paper trader (Phase 12) must do the same. If conditions deteriorated in between, the trade fails rather than executing at a size the approval never saw.

## Kill switch

Paper and live modes (not yet built) must carry an operator kill switch that closes nothing automatically but blocks all new entries. Automatic liquidation on kill is deliberately absent: dumping every position into thin pools at once is itself a risk event.
