"""Backtest performance metrics, tail-risk first."""
from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Sequence


@dataclass
class Trade:
    token: str
    entry_ts: int
    exit_ts: int
    entry_price: float
    exit_price: float
    notional_usd: float
    fees_usd: float
    slippage_usd: float
    exit_reason: str
    regime: str
    failed_exit: bool = False  # exit could not fill at modelled size (liquidity gone)

    @property
    def pnl_usd(self) -> float:
        return self.notional_usd * (self.exit_price / self.entry_price - 1) - self.fees_usd - self.slippage_usd

    @property
    def ret(self) -> float:
        return self.pnl_usd / self.notional_usd if self.notional_usd else 0.0


def max_drawdown(equity: Sequence[float]) -> float:
    peak, mdd = -math.inf, 0.0
    for e in equity:
        peak = max(peak, e)
        if peak > 0:
            mdd = min(mdd, e / peak - 1)
    return mdd


def worst_sequence(rets: Sequence[float]) -> float:
    """Worst cumulative return over any run of consecutive trades."""
    worst, cur = 0.0, 0.0
    for r in rets:
        cur = min(0.0, cur + r)
        worst = min(worst, cur)
    return worst


MIN_TRADES_FOR_RATIOS = 30
MIN_DAYS_FOR_ANNUALIZATION = 30


def summarize(trades: Sequence[Trade], start_equity: float, period_days: float, attempts: int,
              failed_entries: int) -> dict:
    """Ratios that need a sample (Sharpe, Sortino, tail quantiles) are None
    below minimum sample sizes. An annualised Sharpe from a handful of trades
    over a few hours is a number, not a measurement."""
    pnl = [t.pnl_usd for t in trades]
    rets = [t.ret for t in trades]
    equity = [start_equity]
    for p in pnl:
        equity.append(equity[-1] + p)
    wins = [r for r in rets if r > 0]
    losses = [r for r in rets if r <= 0]
    gross_win = sum(p for p in pnl if p > 0)
    gross_loss = -sum(p for p in pnl if p <= 0)
    total_ret = equity[-1] / start_equity - 1
    per_trade_sd = _sd(rets)
    downside = _sd([min(r, 0.0) for r in rets])
    tpy = len(trades) / period_days * 365 if period_days > 0 else 0
    enough = len(trades) >= MIN_TRADES_FOR_RATIOS and period_days >= MIN_DAYS_FOR_ANNUALIZATION
    by_regime: dict[str, dict] = {}
    for t in trades:
        d = by_regime.setdefault(t.regime, {"trades": 0, "pnl_usd": 0.0, "wins": 0})
        d["trades"] += 1
        d["pnl_usd"] += t.pnl_usd
        d["wins"] += t.pnl_usd > 0
    return {
        "trade_count": len(trades),
        "total_return": total_ret,
        "cagr": ((1 + total_ret) ** (365 / period_days) - 1) if period_days >= 90 and total_ret > -1 else None,
        "max_drawdown": max_drawdown(equity),
        "sharpe_per_trade_annualized": (sum(rets) / len(rets)) / per_trade_sd * math.sqrt(tpy)
        if per_trade_sd and enough else None,
        "sortino_per_trade_annualized": (sum(rets) / len(rets)) / downside * math.sqrt(tpy)
        if downside and enough else None,
        "sample_warning": None if enough else
        f"{len(trades)} trades over {period_days:.2f} days: below {MIN_TRADES_FOR_RATIOS} trades / "
        f"{MIN_DAYS_FOR_ANNUALIZATION} days, ratios withheld",
        "profit_factor": gross_win / gross_loss if gross_loss > 0 else None,
        "win_rate": len(wins) / len(rets) if rets else None,
        "average_win": sum(wins) / len(wins) if wins else None,
        "average_loss": sum(losses) / len(losses) if losses else None,
        "expectancy": sum(rets) / len(rets) if rets else None,
        "turnover_usd": sum(2 * t.notional_usd for t in trades),
        "fees_usd": sum(t.fees_usd for t in trades),
        "slippage_usd": sum(t.slippage_usd for t in trades),
        "failed_execution_rate": failed_entries / attempts if attempts else None,
        "failed_exit_rate": sum(t.failed_exit for t in trades) / len(trades) if trades else None,
        "liquidity_impact_bps": (sum(t.slippage_usd for t in trades) / sum(t.notional_usd for t in trades) * 1e4)
        if trades else None,
        "worst_trade": min(rets) if rets else None,
        "tail_loss_p05": sorted(rets)[max(0, int(0.05 * len(rets)) - 1)] if len(rets) >= 20 else None,
        "worst_sequence": worst_sequence(rets),
        "by_regime": by_regime,
    }


def _sd(xs: Sequence[float]) -> float | None:
    if len(xs) < 2:
        return None
    m = sum(xs) / len(xs)
    v = sum((x - m) ** 2 for x in xs) / (len(xs) - 1)
    return math.sqrt(v) if v > 0 else None
