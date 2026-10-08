"""Phase 3D independent acquisition coordinator."""
from __future__ import annotations
import argparse, json, time
from pathlib import Path
from .data import acquire
from .phase3c_acquire import run as protected_run

ROOT = Path(__file__).resolve().parents[2]
EXCLUDED_RUNS = ("gt-sol-20260930a","gt-sol-20260930b","gt-sol-20260930c","p3a-sol-20261001d2","p3c-sol-20261004e","p3c-sol-20261004f")

def _tokens(path):
    if not path.exists(): return set()
    return set(json.loads(path.read_text()).get("tokens", []))

def forbidden_tokens(window, out_root):
    out=set()
    for run_id in EXCLUDED_RUNS:
        out |= _tokens(ROOT/"intel"/"datasets"/"phase3c"/"runs"/run_id/"universe.json")
    if window == "B":
        out |= _tokens(Path(out_root)/"p3d-sol-20261008a"/"universe.json")
    return out

def _select(plan, forbidden, max_attempts=50):
    now=lambda: int(time.time()*1000)
    for attempt in range(max_attempts):
        trial=acquire.Plan(**{**plan.__dict__, "seed": plan.seed+attempt})
        raw=acquire.RawStore(Path("/tmp")/"phase3d-universe")
        f=acquire.Fetcher(raw, acquire.default_clients(trial, now), now, time.sleep, trial.circuit_waits,
                          display={"solana_rpc":"https://api.mainnet-beta.solana.com"})
        sel=acquire.select_universe(f, trial)
        picked=[p for p in sel["picked"] if p["token"] not in forbidden]
        tokens={p["token"] for p in picked}
        if len(tokens) >= 85:
            picked=sorted(picked,key=lambda p:(p["stratum"],p["pool"]))
            u={"frozen_at_ms":sel["selected_at_ms"],
               "mechanism":{"procedure":"Phase 3D fresh seeded stratified selection using frozen Phase 3C provider machinery",
                            "seed":trial.seed,"attempt":attempt,"strata_targets":trial.strata,
                            "network":trial.network,"forbidden_token_count":len(forbidden)},
               "tokens":sorted(tokens),
               "pools":[{k:p[k] for k in ("pool","token","dex","stratum","created_ts")} for p in picked],
               "metadata":{p["token"]:{"total_supply_at_selection":p["total_supply"],
                                      "liquidity_usd_at_selection":p["liquidity_usd"],
                                      "h1_txns_at_selection":p["h1_txns"]} for p in picked},
               "exclusions":[{"pool":p["pool"],"token":p["token"],"reason":"Phase 3D forbidden token"}
                             for p in sel["picked"] if p["token"] in forbidden]}
            u["fingerprint"]=acquire._universe_fingerprint(u)
            return u
    raise RuntimeError("unable to obtain >=85 fresh distinct tokens after 50 seed attempts")

def run(request_path, window, out_root):
    req=json.loads(Path(request_path).read_text())
    cfg=req["windows"][window]
    out=Path(out_root)/cfg["run_id"]; out.mkdir(parents=True,exist_ok=True)
    forbidden=forbidden_tokens(window,out_root)
    plan=acquire.Plan(**{**req["plan"],"seed":int(cfg["seed"])})
    u=_select(plan,forbidden)
    if len(u["tokens"])<req["min_distinct_tokens"] or forbidden & set(u["tokens"]):
        raise RuntimeError("Phase 3D universe gate failed")
    (out/"universe.json").write_text(json.dumps(u,indent=2,sort_keys=True)+"\n")
    plan.universe_file=str(out/"universe.json")
    meta=protected_run(str(out),plan,
                       replay_reserve_s=int(req["plan"]["phase3c1_replay_reserve_s"]),
                       enrichment_guard_s=int(req["plan"]["phase3c1_enrichment_guard_s"]))
    meta["phase3d"]={"window":window,"run_id":cfg["run_id"],
                     "distinct_selected_tokens":len(u["tokens"]),
                     "sample_gate":len(u["tokens"])>=req["min_distinct_tokens"],
                     "contamination_check":not bool(forbidden & set(u["tokens"]))}
    acquire.RawStore(out).write_json("run.json",meta)
    return meta

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--request",required=True); ap.add_argument("--window",choices=("A","B"),required=True)
    ap.add_argument("--out-root",required=True)
    a=ap.parse_args(); m=run(a.request,a.window,a.out_root)
    print(json.dumps(m["phase3d"],sort_keys=True))
    return 0 if m.get("status")=="COMPLETE" else 1

if __name__=="__main__":
    raise SystemExit(main())
