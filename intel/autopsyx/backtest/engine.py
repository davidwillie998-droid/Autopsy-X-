"""Event-driven, point-in-time backtest.

Rules that prevent the usual lies:
  * Decisions at step t see only ``store.view(t)``.
  * Orders fill no earlier than ``latency_bars`` later, at the price and
    liquidity visible *then*; slippage comes from that liquidity.
  * If liquidity or slippage at fill time breaks the risk limits, the entry
    fails and is counted, not silently skipped.
  * Exits pay a stressed slippage multiple; an exit that would consume an
    implausible share of the pool is marked a failed exit.
  * The universe is whatever tokens existed at t, including ones that later
    died, so there is no survivorship filter.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from ..core.config import Config
from ..features.liquidity import cpmm_slippage
from ..pipeline import ScanResult, scan
from ..providers.store import EventStore, PointInTimeView
from ..risk import engine as risk
from ..signals import exit as exit_mod
from ..signals.entry import SignalType
from .metrics import Trade, summarize


@dataclass
class _Open:
    pos: exit_mod.Position
    notional: float
    entry_fee: float
    entry_slip_usd: float
    regime: str
    chain: str


@dataclass
class BacktestResult:
    trades: list[Trade]
    metrics: dict
    config_fingerprint: str
    decisions: list[dict] = field(default_factory=list)


def _price_liq(view: PointInTimeView, key: str) -> tuple[float | None, float | None]:
    sw = view.swaps(key)
    snaps = view.pool_snapshots(key)
    price = sw[-1].price_usd if sw else (snaps[-1].price_usd if snaps else None)
    latest = {}
    for s in snaps:
        latest[s.pool] = s.liquidity_usd
    return price, (sum(latest.values()) if latest else None)


def run(store: EventStore, cfg: Config, start_ts: int, end_ts: int, step_ms: int,
        social_available: bool = True) -> BacktestResult:
    bt, rcfg, xcfg = cfg.section("backtest"), cfg.section("risk"), cfg.section("exit")
    interval = cfg.section("bars")["interval_ms"]
    latency = bt["latency_bars"] * interval
    fee = bt["fee_bps"] / 1e4
    pf = risk.PortfolioState(equity_usd=rcfg["account_equity_usd"])
    open_: dict[str, _Open] = {}
    trades: list[Trade] = []
    decisions: list[dict] = []
    attempts = failed = 0
    prior: ScanResult | None = None
    day = None

    t = start_ts
    while t <= end_ts:
        if day != t // 86_400_000:
            day, pf.realized_pnl_today_usd = t // 86_400_000, 0.0
        view = store.view(t)
        res = scan(view, cfg, prior, social_available)
        fill_view = store.view(t + latency)

        for key, o in list(open_.items()):
            a = res.assessments.get(key)
            if a is None:
                continue
            d = exit_mod.decide(o.pos, a, xcfg)
            final = t + step_ms > end_ts
            if d.action in (exit_mod.ExitAction.EXIT, exit_mod.ExitAction.EMERGENCY_EXIT) or final:
                px, liq = _price_liq(fill_view, key)
                if px is None:
                    continue
                slip = cpmm_slippage(o.notional, liq, 0) * rcfg["exit_slippage_multiplier"] if liq else 0.5
                failed_exit = liq is None or o.notional > 0.1 * liq
                tr = Trade(key, o.pos.entry_ts, t + latency, o.pos.entry_price, px, o.notional,
                           o.entry_fee + fee * o.notional, o.entry_slip_usd + slip * o.notional,
                           "END_OF_TEST" if final and d.action not in (exit_mod.ExitAction.EXIT,
                                                                       exit_mod.ExitAction.EMERGENCY_EXIT)
                           else d.action.value + ": " + "; ".join(d.reasons[:2]), o.regime, failed_exit)
                trades.append(tr)
                pf.realized_pnl_today_usd += tr.pnl_usd
                pf.equity_usd += tr.pnl_usd
                pf.consecutive_losses = pf.consecutive_losses + 1 if tr.pnl_usd <= 0 else 0
                pf.open_positions = [p for p in pf.open_positions if p.token != key]
                del open_[key]
                decisions.append({"ts": t, "token": key, "action": d.action.value, "reasons": d.reasons})

        for key, sig in res.signals.items():
            if sig.type != SignalType.HIGH_CONVICTION_CONTINUATION or key in open_:
                continue
            a = res.assessments[key]
            attempts += 1
            px, liq = _price_liq(fill_view, key)
            inv = sig.invalidation.get("price_below")
            pools = view.pools(key)
            prop = risk.TradeProposal(key, a.token.ref.chain, a.narratives, px or 0.0, inv, liq,
                                      pools[0].fee_bps if pools else 30.0, a.liquidity.amm_model,
                                      execution_available=px is not None)
            dec = risk.evaluate(prop, pf, rcfg)
            decisions.append({"ts": t, "token": key, "signal": sig.type.value, "risk": dec.to_dict()})
            if not dec.approved:
                failed += 1
                continue
            slip = cpmm_slippage(dec.notional_usd, liq, 0)
            open_[key] = _Open(exit_mod.Position(key, t + latency, px, liq, dec.notional_usd / px, inv, a.narratives),
                               dec.notional_usd, fee * dec.notional_usd + bt["priority_fee_usd"],
                               slip * dec.notional_usd, a.regime.regime.value, a.token.ref.chain)
            pf.open_positions.append(risk.OpenPosition(key, a.token.ref.chain, a.narratives, dec.notional_usd))
        prior = res
        t += step_ms

    days = (end_ts - start_ts) / 86_400_000
    return BacktestResult(trades, summarize(trades, rcfg["account_equity_usd"], days, attempts, failed),
                          cfg.fingerprint(), decisions)
