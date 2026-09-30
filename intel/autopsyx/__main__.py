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


def _git_version() -> str:
    import subprocess
    try:
        sha = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
        dirty = subprocess.run(["git", "status", "--porcelain", "--", "."], capture_output=True, text=True).stdout.strip()
        return sha + ("-dirty" if dirty else "")
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


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
    aq = sub.add_parser("acquire", help="LIVE: fetch real data from public APIs into a raw archive (no trading)")
    aq.add_argument("--live", action="store_true", help="required: confirms network access to vendor APIs is intended")
    aq.add_argument("--request", required=True, help="JSON file with run_id and plan overrides")
    aq.add_argument("--out", required=True)
    rr = sub.add_parser("replay-run", help="deterministic point-in-time replay of an acquired raw archive")
    rr.add_argument("run_dir")
    rr.add_argument("--step-min", type=int, default=5)
    rr.add_argument("--out")
    rr.add_argument("--config")
    rr.add_argument("--expect-config", help="refuse to run unless the config hash equals this")
    rr.add_argument("--code-version", help="defaults to the git commit of the working tree")
    rr.add_argument("--universe", choices=["selection", "all"], default="selection",
                    help="replay only the selected, polled tokens (default) or every token seen in discovery")
    pr = sub.add_parser("phase2-report", help="descriptive statistics for the Phase 2 replay report")
    pr.add_argument("run_dir")
    pr.add_argument("replay_dir")
    pr.add_argument("--config")
    dv = sub.add_parser("db-validate", help="load archive + replay into a disposable PostgreSQL db and check integrity")
    dv.add_argument("run_dir")
    dv.add_argument("replay_dir")
    dv.add_argument("--pg", default="host=/tmp port=55432 user=postgres", help="libpq-style key=value pairs")
    dv.add_argument("--db", default="autopsyx_phase2_validate")
    la = sub.add_parser("lookahead-audit", help="adversarial look-ahead tests A-F against a real archive")
    la.add_argument("run_dir")
    la.add_argument("--samples", type=int, default=4)
    la.add_argument("--config")
    pv = sub.add_parser("phase2-verify", help="run every Phase 2 gate on every archive; write evidence and report")
    pv.add_argument("--pg", default="host=/tmp port=55432 user=postgres")
    pv.add_argument("--work", default="/tmp/autopsyx_phase2_verify")
    pv.add_argument("--evidence", default="../artifacts/phase2/PHASE2_EVIDENCE.json")
    pv.add_argument("--report", default="../docs/PHASE2_REPORT.md")
    pv.add_argument("--status", default="../docs/SYSTEM_STATUS.md")
    nm = sub.add_parser("normalize", help="raw archive -> normalized.jsonl + normalization_report.json")
    nm.add_argument("run_dir")
    ap.add_argument("--log", action="store_true", help="emit structured JSON logs to stderr")
    args = ap.parse_args(argv)
    if args.log:
        from .core import logs
        logs.configure()

    if args.cmd == "features":
        print(registry.markdown())
        return 0
    if args.cmd == "acquire":
        if not args.live:
            print("refusing: acquisition contacts external APIs; pass --live to confirm", file=sys.stderr)
            return 2
        from .data import acquire
        req = json.load(open(args.request))
        plan = acquire.Plan(**{k: v for k, v in req.items() if k in acquire.Plan.__dataclass_fields__})
        meta = acquire.run(args.out, plan)
        print(json.dumps({k: meta.get(k) for k in ("status", "cycles", "exchanges", "errors")}))
        return 0 if meta.get("status") == "COMPLETE" else 1
    if args.cmd == "replay-run":
        from . import replay
        from .data.normalize import PHASE2_CAPABILITIES, normalize, replay_window, restrict_to_selection, to_store
        from .data.raw import RawStore
        cfg = Config.load(args.config)
        records, rep = normalize(args.run_dir)
        win = replay_window(RawStore(args.run_dir))
        if win is None:
            print("no live polls in archive; nothing to replay", file=sys.stderr)
            return 1
        spec = replay.ReplaySpec(start_ts=win[0], end_ts=win[1], step_ms=args.step_min * 60_000,
                                 dataset_id=f"{args.run_dir.rstrip('/').split('/')[-1]}:{rep.dataset_sha256[:16]}",
                                 code_version=args.code_version or _git_version(),
                                 caps=PHASE2_CAPABILITIES, expected_config_hash=args.expect_config)
        out = args.out or f"{args.run_dir}/replay_{cfg.fingerprint()}"
        if args.universe == "selection":
            records = restrict_to_selection(records, RawStore(args.run_dir).read_json("selection.json"))
        res = replay.run(to_store(records), cfg, spec, out)
        print(json.dumps(res.summary, indent=2, sort_keys=True))
        return 0
    if args.cmd == "db-validate":
        from pathlib import Path
        from .research import db_validate
        conn = [f"--{'username' if k == 'user' else k}={v}" for k, v in (kv.split("=", 1) for kv in args.pg.split())]
        out = db_validate.run(args.run_dir, args.replay_dir, conn, args.db, Path(__file__).resolve().parents[1] / "migrations",
                              Path(args.replay_dir) / "db_load")
        print(json.dumps(out, indent=2, sort_keys=True))
        return 0 if out.get("all_checks_zero") else 1
    if args.cmd == "lookahead-audit":
        from .data.normalize import PHASE2_CAPABILITIES, normalize, replay_window, restrict_to_selection
        from .data.raw import RawStore
        from .research import lookahead_audit
        cfg = Config.load(args.config)
        raw = RawStore(args.run_dir)
        records = restrict_to_selection(normalize(args.run_dir)[0], raw.read_json("selection.json"))
        lo, hi = replay_window(raw)
        step = (hi - lo) // (args.samples + 1)
        times = [lo + step * (i + 1) for i in range(args.samples)]
        out = lookahead_audit.run(records, cfg, PHASE2_CAPABILITIES, times)
        print(json.dumps(out, indent=2, sort_keys=True))
        return 0 if out["all_passed"] else 1
    if args.cmd == "phase2-verify":
        from pathlib import Path
        from .research import phase2_verify
        conn = [f"--{'username' if k == 'user' else k}={v}" for k, v in (kv.split("=", 1) for kv in args.pg.split())]
        ev = phase2_verify.collect(Path("datasets/phase2/runs"), Path(args.work), conn)
        Path(args.evidence).parent.mkdir(parents=True, exist_ok=True)
        Path(args.evidence).write_text(json.dumps(ev, indent=1, sort_keys=True, default=str) + "\n")
        # Renderers read the file just written, never the in-memory dict, so the documents
        # provably derive from the artifact alone.
        frozen = json.loads(Path(args.evidence).read_text())
        Path(args.report).write_text(phase2_verify.render(frozen))
        Path(args.status).write_text(phase2_verify.render_status(frozen))
        print(json.dumps({"classification": ev["classification"]["result"], "why": ev["classification"]["reasons"],
                          "tests": ev["tests"]["summary_line"]}, indent=2))
        return 0
    if args.cmd == "phase2-report":
        from .research import phase2_report
        cfg = Config.load(args.config)
        out = phase2_report.build(args.run_dir, args.replay_dir, cfg.section("signal")["min_coverage"])
        print(json.dumps(out, indent=2, sort_keys=True, default=str))
        return 0
    if args.cmd == "normalize":
        from .data.normalize import normalize
        records, rep = normalize(args.run_dir)
        EventStore.dump_jsonl(f"{args.run_dir}/normalized.jsonl", records)
        with open(f"{args.run_dir}/normalization_report.json", "w") as fh:
            json.dump(rep.to_dict(), fh, indent=2, sort_keys=True, default=str)
        print(json.dumps({"records": rep.records, "issues": rep.issues, "dataset_sha256": rep.dataset_sha256}))
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
