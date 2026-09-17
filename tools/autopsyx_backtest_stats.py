#!/usr/bin/env python3
"""AUTOPSY X backtest/out-of-sample validation stats (spec section 24).

Section 24 says the engine is "not considered validated until its
performance survives out-of-sample testing", and lists a specific metric
set plus a requirement to break performance out by regime, by long vs
short, and by whether a volatility shock was active. MT5's Strategy Tester
doesn't compute most of that out of the box, so this script does it from
two CSVs you already have:

  1. The AutopsyX decision log (AutopsyLogger.mqh writes this as
     MQL5/Files/AutopsyX_Log.csv, or MQL5/Files/AutopsyX_<bot_id>_Log.csv
     for the example EA) — one row per Update() call, carrying REGIME,
     SHOCK_MODE, CONFIDENCE, etc.

  2. An MT5 trade-history export (Terminal "History" tab -> right-click ->
     "Save as Report", or Strategy Tester "Report" export, saved/converted
     to CSV) — one row per closed trade/deal, carrying at least a close
     time, a symbol, a profit, and ideally a direction and a volume.

Column names in MT5's own exports vary by build and language, so this
script matches case-insensitively against a list of common aliases rather
than assuming an exact header. If your export uses something not listed
below, rename the column (or extend ALIASES) rather than hand-editing the
computed stats.

Requires: pandas, numpy. (pip install pandas numpy)

Usage:
    python3 autopsyx_backtest_stats.py \\
        --decision-log AutopsyX_Log.csv \\
        --trades mt5_trade_history.csv \\
        --balance 10000 \\
        --out autopsyx_backtest_report.md
"""

import argparse
import sys
from dataclasses import dataclass, field

import numpy as np
import pandas as pd

ALIASES = {
    "close_time": ["close_time", "time", "date", "close time", "time_close", "closetime"],
    "open_time":  ["open_time", "time_open", "open time", "opentime"],
    "profit":     ["profit", "net_profit", "pnl", "result"],
    "symbol":     ["symbol", "instrument"],
    "type":       ["type", "direction", "side", "order_type"],
    "volume":     ["volume", "lots", "size"],
}


def find_column(df: pd.DataFrame, key: str) -> str | None:
    lower_map = {c.lower().strip(): c for c in df.columns}
    for alias in ALIASES[key]:
        if alias in lower_map:
            return lower_map[alias]
    return None


def load_trades(path: str) -> pd.DataFrame:
    raw = pd.read_csv(path)
    col_close = find_column(raw, "close_time")
    col_profit = find_column(raw, "profit")
    if col_close is None or col_profit is None:
        raise SystemExit(
            f"Could not find a close-time and a profit column in {path}. "
            f"Columns present: {list(raw.columns)}. Rename them or extend ALIASES."
        )

    out = pd.DataFrame()
    out["close_time"] = pd.to_datetime(raw[col_close], errors="coerce")
    out["profit"] = pd.to_numeric(raw[col_profit], errors="coerce")

    col_open = find_column(raw, "open_time")
    out["open_time"] = pd.to_datetime(raw[col_open], errors="coerce") if col_open else pd.NaT

    col_symbol = find_column(raw, "symbol")
    out["symbol"] = raw[col_symbol] if col_symbol else "UNKNOWN"

    col_type = find_column(raw, "type")
    if col_type:
        t = raw[col_type].astype(str).str.lower()
        out["side"] = np.where(t.str.contains("sell") | t.str.contains("short"), "SHORT",
                       np.where(t.str.contains("buy") | t.str.contains("long"), "LONG", "UNKNOWN"))
    else:
        out["side"] = "UNKNOWN"

    out = out.dropna(subset=["close_time", "profit"]).sort_values("close_time").reset_index(drop=True)
    if out.empty:
        raise SystemExit(f"No usable trade rows parsed from {path}.")
    return out


def load_decision_log(path: str) -> pd.DataFrame:
    raw = pd.read_csv(path)
    raw.columns = [c.strip().lower() for c in raw.columns]
    if "time" not in raw.columns:
        raise SystemExit(f"Decision log {path} has no 'time' column — is this an AutopsyLogger CSV?")
    raw["time"] = pd.to_datetime(raw["time"], errors="coerce")
    raw = raw.dropna(subset=["time"]).sort_values("time").reset_index(drop=True)
    for bool_col in ("long_permission", "short_permission", "aggressive_mode", "shock_mode"):
        if bool_col in raw.columns:
            raw[bool_col] = raw[bool_col].astype(str).str.upper().eq("TRUE")
    return raw


def attach_regime(trades: pd.DataFrame, decisions: pd.DataFrame) -> pd.DataFrame:
    """Tag each trade with the most recent AutopsyX snapshot at or before
    its close time — merge_asof requires both frames sorted, which
    load_trades/load_decision_log already guarantee."""
    if decisions.empty:
        trades["regime"] = "UNKNOWN"
        trades["shock_mode"] = False
        return trades
    merged = pd.merge_asof(
        trades, decisions[["time", "regime", "shock_mode"]].rename(columns={"time": "decision_time"}),
        left_on="close_time", right_on="decision_time", direction="backward",
    )
    merged["regime"] = merged["regime"].fillna("UNMATCHED")
    merged["shock_mode"] = merged["shock_mode"].fillna(False)
    return merged


@dataclass
class Metrics:
    label: str
    n_trades: int = 0
    net_profit: float = 0.0
    win_rate: float = float("nan")
    avg_trade: float = float("nan")
    profit_factor: float = float("nan")
    sharpe: float = float("nan")
    sortino: float = float("nan")
    calmar: float = float("nan")
    max_drawdown_pct: float = float("nan")
    tail_loss_5pct: float = float("nan")
    worst_day: float = float("nan")
    worst_week: float = float("nan")
    vol_adjusted_return: float = float("nan")
    time_in_market_days: float = float("nan")
    extra: dict = field(default_factory=dict)


def compute_metrics(trades: pd.DataFrame, starting_balance: float, periods_per_year: int, label: str) -> Metrics:
    m = Metrics(label=label)
    m.n_trades = len(trades)
    if m.n_trades == 0:
        return m

    profits = trades["profit"].to_numpy()
    m.net_profit = float(profits.sum())
    wins = profits[profits > 0]
    losses = profits[profits < 0]
    m.win_rate = 100.0 * len(wins) / m.n_trades
    m.avg_trade = float(profits.mean())

    gross_profit = wins.sum() if len(wins) else 0.0
    gross_loss = -losses.sum() if len(losses) else 0.0
    m.profit_factor = (gross_profit / gross_loss) if gross_loss > 0 else float("inf")

    # Per-trade returns as a fraction of starting balance — a simplification
    # (it ignores intra-run compounding) but stable and comparable across
    # regimes/subsets, which matters more here than compounding precision.
    returns = profits / starting_balance if starting_balance > 0 else profits
    mean_ret = returns.mean()
    std_ret = returns.std(ddof=1) if len(returns) > 1 else 0.0
    downside = returns[returns < 0]
    downside_std = downside.std(ddof=1) if len(downside) > 1 else 0.0

    ann_factor = np.sqrt(periods_per_year)
    m.sharpe = float(mean_ret / std_ret * ann_factor) if std_ret > 0 else float("nan")
    m.sortino = float(mean_ret / downside_std * ann_factor) if downside_std > 0 else float("nan")

    # Equity curve + drawdown from the trade sequence itself.
    equity = starting_balance + np.cumsum(profits)
    running_peak = np.maximum.accumulate(np.concatenate(([starting_balance], equity)))[1:]
    drawdown_pct = np.where(running_peak > 0, 100.0 * (running_peak - equity) / running_peak, 0.0)
    m.max_drawdown_pct = float(drawdown_pct.max()) if len(drawdown_pct) else 0.0

    annualized_return_pct = 100.0 * mean_ret * periods_per_year
    m.calmar = (annualized_return_pct / m.max_drawdown_pct) if m.max_drawdown_pct > 0 else float("nan")

    m.tail_loss_5pct = float(np.percentile(profits, 5))
    m.vol_adjusted_return = float(m.net_profit / (profits.std(ddof=1))) if len(profits) > 1 and profits.std(ddof=1) > 0 else float("nan")

    daily = trades.set_index("close_time")["profit"].resample("1D").sum()
    weekly = trades.set_index("close_time")["profit"].resample("1W").sum()
    m.worst_day = float(daily.min()) if len(daily) else float("nan")
    m.worst_week = float(weekly.min()) if len(weekly) else float("nan")

    if trades["open_time"].notna().any():
        durations = (trades["close_time"] - trades["open_time"]).dt.total_seconds() / 86400.0
        span_days = (trades["close_time"].max() - trades["close_time"].min()).total_seconds() / 86400.0
        m.time_in_market_days = float(durations.sum())
        if span_days > 0:
            m.extra["time_in_market_pct_of_span"] = 100.0 * m.time_in_market_days / span_days

    return m


def format_metrics(m: Metrics) -> str:
    lines = [f"### {m.label}", ""]
    lines.append(f"- Trades: {m.n_trades}")
    if m.n_trades == 0:
        lines.append("- (no trades in this bucket)")
        return "\n".join(lines)
    lines += [
        f"- Net profit: {m.net_profit:,.2f}",
        f"- Win rate: {m.win_rate:.1f}%",
        f"- Average trade: {m.avg_trade:,.2f}",
        f"- Profit factor: {m.profit_factor:.2f}",
        f"- Sharpe (annualized): {m.sharpe:.2f}",
        f"- Sortino (annualized): {m.sortino:.2f}",
        f"- Calmar: {m.calmar:.2f}",
        f"- Max drawdown: {m.max_drawdown_pct:.2f}%",
        f"- Tail loss (5th pct trade): {m.tail_loss_5pct:,.2f}",
        f"- Worst day: {m.worst_day:,.2f}",
        f"- Worst week: {m.worst_week:,.2f}",
        f"- Volatility-adjusted return: {m.vol_adjusted_return:.3f}",
    ]
    if not np.isnan(m.time_in_market_days):
        pct = m.extra.get("time_in_market_pct_of_span")
        pct_str = f" ({pct:.1f}% of span)" if pct is not None else ""
        lines.append(f"- Time in market: {m.time_in_market_days:.1f} days{pct_str}")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--decision-log", required=True, help="AutopsyX_Log.csv from AutopsyLogger.mqh")
    ap.add_argument("--trades", required=True, help="MT5 trade-history export, converted to CSV")
    ap.add_argument("--balance", type=float, required=True, help="Starting account balance for this run")
    ap.add_argument("--periods-per-year", type=int, default=252, help="Annualization factor for Sharpe/Sortino/Calmar (default 252, i.e. daily-style trade cadence)")
    ap.add_argument("--out", default=None, help="Write the report to this Markdown file (also prints to stdout)")
    args = ap.parse_args()

    trades = load_trades(args.trades)
    decisions = load_decision_log(args.decision_log)
    trades = attach_regime(trades, decisions)

    report = []
    report.append("# AUTOPSY X — Backtest / Out-of-Sample Report\n")
    report.append(f"Trades file: `{args.trades}`  \nDecision log: `{args.decision_log}`  \nStarting balance: {args.balance:,.2f}\n")

    report.append("## Overall\n")
    report.append(format_metrics(compute_metrics(trades, args.balance, args.periods_per_year, "All trades")))
    report.append("")

    report.append("## Long vs short\n")
    for side, group in trades.groupby("side"):
        report.append(format_metrics(compute_metrics(group, args.balance, args.periods_per_year, f"Side = {side}")))
        report.append("")

    report.append("## Regime-specific performance\n")
    for regime, group in trades.groupby("regime"):
        report.append(format_metrics(compute_metrics(group, args.balance, args.periods_per_year, f"Regime = {regime}")))
        report.append("")

    report.append("## Volatility-shock performance\n")
    shock_trades = trades[trades["shock_mode"] == True]  # noqa: E712
    non_shock_trades = trades[trades["shock_mode"] != True]  # noqa: E712
    report.append(format_metrics(compute_metrics(shock_trades, args.balance, args.periods_per_year, "SHOCK_MODE = TRUE")))
    report.append("")
    report.append(format_metrics(compute_metrics(non_shock_trades, args.balance, args.periods_per_year, "SHOCK_MODE = FALSE")))
    report.append("")

    report.append(
        "\n---\n"
        "Reminder from spec section 24: this is one run. The engine isn't considered "
        "validated on in-sample results alone — repeat this with out-of-sample and "
        "walk-forward windows, and vary the regime/risk thresholds to check they aren't "
        "curve-fit to one slice of history before trusting any of the numbers above.\n"
    )

    text = "\n".join(report)
    print(text)
    if args.out:
        with open(args.out, "w") as f:
            f.write(text)
        print(f"\nWrote report to {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
