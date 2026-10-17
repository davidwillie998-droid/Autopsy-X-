"""Research-only replication harness for Zarattini & Aziz (SSRN 4631351).

This module never connects to a broker and never places orders. It deliberately
keeps the paper-style close-fill assumption separate from a next-bar-open model.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
from dataclasses import asdict, dataclass
from datetime import datetime, time
from pathlib import Path
from typing import Iterable
from zoneinfo import ZoneInfo

NY = ZoneInfo("America/New_York")


@dataclass(frozen=True)
class Bar:
    timestamp: datetime
    open: float
    high: float
    low: float
    close: float
    volume: float


@dataclass(frozen=True)
class Config:
    initial_capital: float = 25_000.0
    position_fraction: float = 1.0
    commission_per_share_per_side: float = 0.0005
    fill_model: str = "paper_close"  # paper assumption; choose next_open for a stricter sensitivity run
    timezone: str = "America/New_York"
    allow_short: bool = True
    flatten_at_session_end: bool = True

    def validate(self) -> None:
        if not math.isfinite(self.initial_capital) or self.initial_capital <= 0:
            raise ValueError("initial_capital must be finite and > 0")
        if not math.isfinite(self.position_fraction) or not 0 < self.position_fraction <= 1:
            raise ValueError("position_fraction must be in (0, 1]; leverage is not allowed")
        if not math.isfinite(self.commission_per_share_per_side) or self.commission_per_share_per_side < 0:
            raise ValueError("commission must be finite and >= 0")
        if self.fill_model not in {"paper_close", "next_open"}:
            raise ValueError("fill_model must be 'paper_close' or 'next_open'")
        ZoneInfo(self.timezone)


@dataclass
class Trade:
    session_date: str
    direction: str
    entry_time: str
    entry_price: float
    exit_time: str
    exit_price: float
    shares: float
    gross_pnl: float
    entry_commission: float
    exit_commission: float
    net_pnl: float
    exit_reason: str


def parse_timestamp(value: str) -> datetime:
    value = value.strip()
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError(f"timestamp must include UTC offset or Z suffix: {value!r}")
    return parsed


def load_csv(path: str | Path) -> list[Bar]:
    bars: list[Bar] = []
    with open(path, newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        required = {"timestamp", "open", "high", "low", "close", "volume"}
        if not reader.fieldnames or not required.issubset(set(reader.fieldnames)):
            raise ValueError("CSV must contain timestamp,open,high,low,close,volume columns")
        for line, row in enumerate(reader, start=2):
            try:
                bar = Bar(parse_timestamp(row["timestamp"]),
                          float(row["open"]), float(row["high"]), float(row["low"]),
                          float(row["close"]), float(row["volume"]))
            except (TypeError, ValueError) as exc:
                raise ValueError(f"invalid CSV row {line}: {exc}") from exc
            bars.append(bar)
    validate_bars(bars)
    return bars


def validate_bars(bars: Iterable[Bar]) -> None:
    previous: datetime | None = None
    count = 0
    for bar in bars:
        count += 1
        values = (bar.open, bar.high, bar.low, bar.close, bar.volume)
        if not all(math.isfinite(value) for value in values):
            raise ValueError("OHLCV values must all be finite")
        if min(bar.open, bar.high, bar.low, bar.close) <= 0 or bar.volume < 0:
            raise ValueError("prices must be > 0 and volume must be >= 0")
        if bar.high < max(bar.open, bar.close, bar.low) or bar.low > min(bar.open, bar.close, bar.high):
            raise ValueError("invalid OHLC envelope")
        if previous is not None and bar.timestamp <= previous:
            raise ValueError("timestamps must be strictly increasing; duplicates/out-of-order bars are rejected")
        previous = bar.timestamp
    if count == 0:
        raise ValueError("input contains no bars")


def _session_bars(bars: list[Bar], timezone: str) -> dict[str, list[tuple[Bar, float]]]:
    tz = ZoneInfo(timezone)
    grouped: dict[str, list[Bar]] = {}
    for bar in bars:
        local = bar.timestamp.astimezone(tz)
        if time(9, 30) <= local.time().replace(tzinfo=None) < time(16, 0):
            grouped.setdefault(local.date().isoformat(), []).append(bar)

    result: dict[str, list[tuple[Bar, float]]] = {}
    for day, day_bars in grouped.items():
        cumulative_pv = 0.0
        cumulative_volume = 0.0
        values: list[tuple[Bar, float]] = []
        for bar in day_bars:
            cumulative_pv += ((bar.high + bar.low + bar.close) / 3.0) * bar.volume
            cumulative_volume += bar.volume
            # Zero-volume bars are allowed in raw data, but cannot create a VWAP.
            vwap = cumulative_pv / cumulative_volume if cumulative_volume > 0 else float("nan")
            values.append((bar, vwap))
        result[day] = values
    return result


def backtest(bars: list[Bar], config: Config = Config()) -> dict:
    """Run a single-instrument, RTH-only VWAP trend backtest."""
    config.validate()
    validate_bars(bars)
    sessions = _session_bars(bars, config.timezone)
    if not sessions:
        raise ValueError("no bars fall inside the configured regular session (09:30-16:00 local time)")

    cash = config.initial_capital
    direction = 0
    shares = 0.0
    entry_price = 0.0
    entry_time = ""
    entry_commission = 0.0
    entry_session = ""
    trades: list[Trade] = []
    equity_curve: list[dict] = []
    incomplete_sessions: list[str] = []
    tz = ZoneInfo(config.timezone)

    def close_position(price: float, timestamp: datetime, reason: str) -> None:
        nonlocal cash, direction, shares, entry_price, entry_time, entry_commission, entry_session
        if direction == 0:
            return
        exit_commission = shares * config.commission_per_share_per_side
        gross = direction * shares * (price - entry_price)
        cash += gross - exit_commission
        net = gross - entry_commission - exit_commission
        trades.append(Trade(entry_session, "LONG" if direction > 0 else "SHORT",
                            entry_time, entry_price, timestamp.isoformat(), price, shares,
                            gross, entry_commission, exit_commission, net, reason))
        direction, shares, entry_price = 0, 0.0, 0.0
        entry_time, entry_commission, entry_session = "", 0.0, ""

    def open_position(new_direction: int, price: float, timestamp: datetime, session: str) -> None:
        nonlocal cash, direction, shares, entry_price, entry_time, entry_commission, entry_session
        if new_direction < 0 and not config.allow_short:
            return
        if cash <= 0:
            return
        direction = new_direction
        shares = (cash * config.position_fraction) / price
        entry_price = price
        entry_time = timestamp.isoformat()
        entry_session = session
        entry_commission = shares * config.commission_per_share_per_side
        cash -= entry_commission

    for day, items in sessions.items():
        first_local = items[0][0].timestamp.astimezone(tz).time().replace(tzinfo=None)
        last_local = items[-1][0].timestamp.astimezone(tz).time().replace(tzinfo=None)
        if first_local != time(9, 30) or last_local != time(15, 59):
            incomplete_sessions.append(day)
        pending_direction: int | None = None

        for index, (bar, vwap) in enumerate(items):
            is_last = index == len(items) - 1
            if config.fill_model == "next_open" and pending_direction is not None:
                if direction != pending_direction:
                    close_position(bar.open, bar.timestamp, "VWAP_CROSS")
                    if pending_direction:
                        open_position(pending_direction, bar.open, bar.timestamp, day)
                pending_direction = None

            signal = 0
            if math.isfinite(vwap):
                if bar.close > vwap:
                    signal = 1
                elif bar.close < vwap:
                    signal = -1
            if signal < 0 and not config.allow_short:
                signal = 0

            if config.fill_model == "paper_close":
                # Same-bar close fill mirrors the paper-style no-slippage assumption.
                # Equality to VWAP leaves the existing position unchanged.
                if signal and signal != direction:
                    close_position(bar.close, bar.timestamp, "VWAP_CROSS")
                    open_position(signal, bar.close, bar.timestamp, day)
            else:
                # Signal is only known after this candle closes; fill on the next candle open.
                if signal and signal != direction:
                    pending_direction = signal

            # Mark-to-market equity at each bar close; entry commission was deducted from cash.
            marked = cash + (direction * shares * (bar.close - entry_price) if direction else 0.0)
            equity_curve.append({"timestamp": bar.timestamp.isoformat(), "session": day,
                                 "close": bar.close, "vwap": vwap if math.isfinite(vwap) else None,
                                 "direction": direction, "equity": marked})

            if is_last and config.flatten_at_session_end:
                close_position(bar.close, bar.timestamp, "SESSION_CLOSE")
                pending_direction = None
                equity_curve[-1]["equity"] = cash
                equity_curve[-1]["direction"] = 0

    final_equity = cash
    peak = config.initial_capital
    max_drawdown = 0.0
    for point in equity_curve:
        peak = max(peak, point["equity"])
        if peak > 0:
            max_drawdown = max(max_drawdown, (peak - point["equity"]) / peak)

    wins = sum(1 for trade in trades if trade.net_pnl > 0)
    losses = sum(1 for trade in trades if trade.net_pnl < 0)
    return {
        "config": asdict(config),
        "initial_capital": config.initial_capital,
        "final_equity": final_equity,
        "net_profit": final_equity - config.initial_capital,
        "total_return_pct": (final_equity / config.initial_capital - 1.0) * 100.0,
        "max_drawdown_pct": max_drawdown * 100.0,
        "closed_trades": len(trades),
        "wins": wins,
        "losses": losses,
        "win_rate_pct": (wins / len(trades) * 100.0) if trades else 0.0,
        "commission_paid": sum(t.entry_commission + t.exit_commission for t in trades),
        "incomplete_sessions": incomplete_sessions,
        "session_count": len(sessions),
        "trades": [asdict(t) for t in trades],
        "equity_curve": equity_curve,
        "limitations": [
            "Research/backtest only; no broker connection or order execution.",
            "The paper's headline results use QQQ/TQQQ 1-minute data, not XAUUSD or FX.",
            "paper_close is a paper-style same-close/no-slippage sensitivity, not a guaranteed executable fill.",
            "next_open avoids same-bar signal/fill lookahead but is a different execution assumption.",
            "Reported metrics are only as valid as the supplied data, corporate-action handling, and chosen costs.",
        ],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv", help="CSV with timestamp,open,high,low,close,volume; timestamp must be ISO-8601 with offset or Z")
    parser.add_argument("--fill-model", choices=("paper_close", "next_open"), default="paper_close")
    parser.add_argument("--capital", type=float, default=25_000.0)
    parser.add_argument("--position-fraction", type=float, default=1.0)
    parser.add_argument("--commission-per-share", type=float, default=0.0005)
    parser.add_argument("--timezone", default="America/New_York")
    parser.add_argument("--long-only", action="store_true")
    parser.add_argument("--output", help="Optional JSON output path")
    args = parser.parse_args()
    config = Config(args.capital, args.position_fraction, args.commission_per_share,
                    args.fill_model, args.timezone, not args.long_only, True)
    report = backtest(load_csv(args.csv), config)
    encoded = json.dumps(report, indent=2, allow_nan=False)
    if args.output:
        Path(args.output).write_text(encoded + "\n", encoding="utf-8")
    print(encoded)


if __name__ == "__main__":
    main()
