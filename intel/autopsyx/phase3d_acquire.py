"""Phase 3D independent acquisition coordinator."""
from __future__ import annotations
import argparse, json, time, random
from pathlib import Path
from .data import acquire
from .data.providers import geckoterminal as gt
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

def _select(plan, forbidden, trending_pages=3, established_pages=3):
    """Phase 3D-only discovery. Fetch each candidate page once; never mutate Phase 3C acquisition code."""
    now=lambda: int(time.time()*1000)
    raw=acquire.RawStore(Path("/tmp")/f"phase3d-universe-{plan.seed}")
    f=acquire.Fetcher(raw, acquire.default_clients(plan, now), now, time.sleep, plan.circuit_waits,
                      display={"solana_rpc":"https://api.mainnet-beta.solana.com"})
    candidates={"young": [], "trending": [], "established": []}
    for page in range(1, plan.new_pool_pages + 1):
        e,b=f.get(gt.NAME, "gt.new_pools", gt.path_new_pools(plan.network,page),
                  {"chain":plan.network,"stratum":"young","page":page})
        candidates["young"] += acquire._pools_from(e,b)
    for page in range(1, trending_pages + 1):
        e,b=f.get(gt.NAME, "gt.trending", gt.path_trending(plan.network,page),
                  {"chain":plan.network,"stratum":"trending","page":page})
        candidates["trending"] += acquire._pools_from(e,b)
    for page in range(1, established_pages + 1):
        e,b=f.get(gt.NAME, "gt.top_pools", gt.path_top_pools(plan.network,page),
                  {"chain":plan.network,"stratum":"established","page":page})
        candidates["established"] += acquire._pools_from(e,b)

    rng=random.Random(plan.seed)
    picked=[]; tokens=set(); excluded=[]
    def take(stratum, pool_list, quota):
        pool_list=sorted(pool_list,key=lambda p:p.get("pool") or "")
        rng.shuffle(pool_list)
        count=sum(1 for item in picked if item["stratum"]==stratum)
        for p in pool_list:
            if count >= quota: return
            token=p.get("token"); pool=p.get("pool")
            if not token or not pool: continue
            if token in acquire.EXCLUDED_BASES:
                excluded.append({**p,"reason":"non-meme base asset"}); continue
            if token in forbidden:
                excluded.append({**p,"reason":"Phase 3D forbidden token"}); continue
            if token in tokens: continue
            picked.append({**p,"stratum":stratum}); tokens.add(token); count += 1

    quiet=[p for p in candidates["young"] if p.get("h1_txns") is not None and p["h1_txns"]<5]
    take("quiet_young",quiet,plan.strata["quiet_young"])
    take("young",candidates["young"],plan.strata["young"])
    take("trending",candidates["trending"],plan.strata["trending"])
    take("established",candidates["established"],plan.strata["established"])
    counts={k:len(v) for k,v in candidates.items()} | {"quiet_young":len(quiet)}
    if len(tokens) < 85:
        raise RuntimeError(f"unable to obtain >=85 fresh distinct tokens in one discovery pass; selected={len(tokens)}; candidate_counts={counts}; selected_by_stratum={{s:sum(1 for p in picked if p['stratum']==s) for s in plan.strata}}")
    picked=sorted(picked,key=lambda p:(p["stratum"],p["pool"]))
    u={"frozen_at_ms":now(),
       "mechanism":{"procedure":"Phase 3D fresh seeded stratified selection using paginated GeckoTerminal discovery",
                    "seed":plan.seed,"strata_targets":plan.strata,"network":plan.network,
                    "forbidden_token_count":len(forbidden),"pages":{"young":plan.new_pool_pages,
                    "trending":trending_pages,"established":established_pages},
                    "candidate_counts":counts,"selected_by_stratum":{s:sum(1 for p in picked if p["stratum"]==s) for s in plan.strata}},
       "tokens":sorted(tokens),
       "pools":[{k:p[k] for k in ("pool","token","dex","stratum","created_ts")} for p in picked],
       "metadata":{p["token"]:{"total_supply_at_selection":p["total_supply"],
                               "liquidity_usd_at_selection":p["liquidity_usd"],
                               "h1_txns_at_selection":p["h1_txns"]} for p in picked},
       "exclusions":[{"pool":p["pool"],"token":p["token"],"reason":"Phase 3D forbidden token"}
                     for p in excluded if p.get("reason")=="Phase 3D forbidden token"]}
    u["fingerprint"]=acquire._universe_fingerprint(u)
    return u

def run(request_path, window, out_root):
    req=json.loads(Path(request_path).read_text())
    cfg=req["windows"][window]
    out=Path(out_root)/cfg["run_id"]; out.mkdir(parents=True,exist_ok=True)
    forbidden=forbidden_tokens(window,out_root)
    plan=acquire.Plan(**{k:v for k,v in req["plan"].items() if k in acquire.Plan.__dataclass_fields__}, seed=int(cfg["seed"]))
    u=_select(plan,forbidden,
              trending_pages=int(req["plan"].get("trending_pages",3)),
              established_pages=int(req["plan"].get("established_pages",3)))
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
