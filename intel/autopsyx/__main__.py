"""Command line entry point.

  python -m autopsyx demo            scan the synthetic scenarios and print the radar
  python -m autopsyx demo --json     full structured output
  python -m autopsyx replay FILE.jsonl --as-of MS
  python -m autopsyx features        print the feature dictionary as markdown
"""
from __future__ import annotations

import argparse
import json
import sys

from .alerts import engine as alerts
from .core.config import Config
from .features import registry
from .pipeline import ScanResult, scan
from .providers.store import EventStore
from .ranking import all_rankings
from .sim import generator


def _fmt(x, pct=False, d=2):
    if x is None:
        return "  n/a"
    return f"{x * 100:+.1f}%" if pct else f"{x:.{d}f}"


def radar(res: ScanResult) -> str:
    cols = ["TOKEN", "CHAIN", "PRICE", "1M", "5M", "15M", "1H", "VOL-VEL", "LIQ", "NEWW", "NEWS", "SOCIAL",
            "NARR", "MANIP", "MQ", "REGIME", "SIGNAL"]
    rows = [cols]
    for k, a in sorted(res.assessments.items(), key=lambda kv: -(kv[1].move.abnormality or 0)):
        w = a.market.windows
        r = lambda n: _fmt(__import__("math").expm1(w[n].ret.value), pct=True) if n in w and w[n].ret.ok else "n/a"
        rows.append([
            a.token.symbol, a.token.ref.chain, f"{a.market.price.value:.6g}" if a.market.price.ok else "n/a",
            r(1), r(5), r(15), r(60),
            _fmt(w[15].volume_ratio.or_none(), d=1) + "x" if 15 in w else "n/a",
            f"${a.liquidity.liquidity_usd.value / 1000:,.0f}k" if a.liquidity.liquidity_usd.ok else "n/a",
            str(int(a.participation.new_wallets.value)) if a.participation.new_wallets.ok else "n/a",
            a.catalyst.timing.value.split("_")[0], _fmt(a.social.mention_velocity.or_none(), d=1),
            ",".join(p.split("_")[-1][:4] for p in a.narrative_phases.values()) or "-",
            _fmt(a.manipulation.score), _fmt(a.move_quality.score if a.move_quality else None),
            a.regime.regime.value, res.signals[k].type.value,
        ])
    widths = [max(len(str(r[i])) for r in rows) for i in range(len(cols))]
    return "\n".join("  ".join(str(c).ljust(wd) for c, wd in zip(r, widths)) for r in rows)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="autopsyx")
    sub = ap.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("demo")
    d.add_argument("--json", action="store_true")
    d.add_argument("--config")
    rp = sub.add_parser("replay")
    rp.add_argument("file")
    rp.add_argument("--as-of", type=int, required=True)
    rp.add_argument("--config")
    rp.add_argument("--json", action="store_true")
    sub.add_parser("features")
    ap.add_argument("--log", action="store_true", help="emit structured JSON logs to stderr")
    args = ap.parse_args(argv)
    if args.log:
        from .core import logs
        logs.configure()

    if args.cmd == "features":
        print(registry.markdown())
        return 0
    cfg = Config.load(args.config)
    if args.cmd == "demo":
        store, as_of = generator.build_store(), generator.end_ts()
    else:
        store, as_of = EventStore.load_jsonl(args.file), args.as_of
    view = store.view(as_of)
    res = scan(view, cfg)
    if args.json:
        json.dump({
            "as_of": as_of, "config": cfg.fingerprint(),
            "assessments": {k: a.to_dict() for k, a in res.assessments.items()},
            "signals": {k: s.to_dict() for k, s in res.signals.items()},
            "narratives": {k: n.to_dict() for k, n in res.narratives.items()},
            "rankings": all_rankings(res.assessments),
            "symbol_collisions": res.symbol_collisions,
        }, sys.stdout, indent=2, default=str)
        return 0
    print(f"LIVE MARKET RADAR  as_of={as_of}  config={cfg.fingerprint()}  [synthetic data]" if args.cmd == "demo"
          else f"RADAR as_of={as_of}")
    print(radar(res))
    print("\nALERTS")
    for a in res.assessments.values():
        for al in alerts.token_alerts(a, cfg.section("alerts")["min_flag_confidence"]):
            print(f"  [{al.kind.value}] {al.text}")
    for al in alerts.narrative_alerts(list(res.narratives.values()), as_of):
        print(f"  [{al.kind.value}] {al.text}")
    print("\nSIGNALS")
    for k, s in res.signals.items():
        if s.type.value != "NO_SIGNAL" or s.blocked_by:
            passed = [c.name for c in s.conditions if c.passed]
            print(f"  {s.symbol:6} {s.type.value:30} conf={s.confidence} passed={len(passed)}/{len(s.conditions)}"
                  + (f" blocked_by={s.blocked_by}" if s.blocked_by else ""))
    top = max(res.assessments.values(), key=lambda a: a.move.abnormality or 0)
    print(f"\nTIMELINE  {top.token.symbol}")
    for ts, text in alerts.raw_timeline(view, top, cfg.section("alerts")["large_trade_usd"])[:25]:
        print(f"  {alerts.fmt_ts(ts)}  {text}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
