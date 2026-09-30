"""Normalized records and replay output -> SQL INSERT statements (migrations 0001 + 0002).

Used to verify the database contract by loading real archives into a
disposable PostgreSQL instance. Literals are quoted here rather than
parameterized because the target is a psql script; every value passes through
``lit()``, which escapes quotes and rejects non-finite numbers.
"""
from __future__ import annotations

import json
import math
from datetime import datetime, timezone
from typing import Iterable

from ..core.models import Coverage, HolderSnapshot, PoolInfo, PoolSnapshot, ProviderBar, Swap, TokenMeta
from .raw import ManifestEntry


def lit(v) -> str:
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "TRUE" if v else "FALSE"
    if isinstance(v, (int, float)):
        if isinstance(v, float) and not math.isfinite(v):
            raise ValueError(f"non-finite number {v}")
        return repr(v)
    if isinstance(v, (dict, list)):
        return lit(json.dumps(v, sort_keys=True, default=str)) + "::jsonb"
    return "'" + str(v).replace("'", "''") + "'"


def ts(ms: int | None) -> str:
    if ms is None:
        return "NULL"
    return lit(datetime.fromtimestamp(ms / 1000, tz=timezone.utc).isoformat()) + "::timestamptz"


def arr(xs: list[str]) -> str:
    return "ARRAY[" + ",".join(lit(x) for x in xs) + "]::text[]" if xs else "ARRAY[]::text[]"


# Parents before children (pools reference tokens).
LOAD_ORDER = {"TokenMeta": 0, "PoolInfo": 1}


def records_sql(records) -> list[str]:
    ordered = sorted(records, key=lambda r: LOAD_ORDER.get(type(r).__name__, 2))  # stable sort keeps input order
    return [s for s in (record_sql(r) for r in ordered) if s]


def record_sql(r) -> str | None:
    if isinstance(r, TokenMeta):
        return (f"INSERT INTO tokens (chain,address,symbol,name,launch_ts,creator,total_supply,first_seen_ts,source,raw_id) "
                f"VALUES ({lit(r.ref.chain)},{lit(r.ref.address)},{lit(r.symbol)},{lit(r.name)},{ts(r.launch_ts)},"
                f"{lit(r.creator)},{lit(r.total_supply)},{ts(r.seen_ts)},{lit(r.source)},{lit(r.raw_id)}) "
                f"ON CONFLICT (chain,address) DO NOTHING;")
    if isinstance(r, PoolInfo):
        return (f"INSERT INTO pools (chain,pool,token,venue,amm_model,fee_bps,created_ts,seen_ts,source,raw_id) VALUES "
                f"({lit(r.chain)},{lit(r.pool)},{lit(r.token)},{lit(r.venue)},{lit(r.amm_model)},{lit(r.fee_bps)},"
                f"{ts(r.created_ts)},{ts(r.seen_ts)},{lit(r.source)},{lit(r.raw_id)}) ON CONFLICT (chain,pool) DO NOTHING;")
    if isinstance(r, Swap):
        return (f"INSERT INTO swaps (chain,tx_hash,log_index,ts,seen_ts,block,pool,token,wallet,side,token_amount,quote_usd,"
                f"price_usd,source,raw_id) VALUES ({lit(r.chain)},{lit(r.tx_hash)},{r.log_index},{ts(r.ts)},{ts(r.seen_ts)},"
                f"{r.block},{lit(r.pool)},{lit(r.token)},{lit(r.wallet)},{lit(r.side.value)},{lit(r.token_amount)},"
                f"{lit(r.quote_usd)},{lit(r.price_usd)},{lit(r.source)},{lit(r.raw_id)}) "
                f"ON CONFLICT (chain,tx_hash,log_index,ts) DO NOTHING;")
    if isinstance(r, PoolSnapshot):
        return (f"INSERT INTO pool_snapshots (chain,pool,token,ts,seen_ts,liquidity_usd,price_usd,source,raw_id) VALUES "
                f"({lit(r.chain)},{lit(r.pool)},{lit(r.token)},{ts(r.ts)},{ts(r.seen_ts)},{lit(r.liquidity_usd)},"
                f"{lit(r.price_usd)},{lit(r.source)},{lit(r.raw_id)}) ON CONFLICT DO NOTHING;")
    if isinstance(r, HolderSnapshot):
        return (f"INSERT INTO holder_snapshots (chain,token,ts,seen_ts,holders,top10_pct,creator_pct,source,raw_id) VALUES "
                f"({lit(r.chain)},{lit(r.token)},{ts(r.ts)},{ts(r.seen_ts)},{r.holders},{lit(r.top10_pct)},"
                f"{lit(r.creator_pct)},{lit(r.source)},{lit(r.raw_id)}) ON CONFLICT DO NOTHING;")
    if isinstance(r, ProviderBar):
        return (f"INSERT INTO provider_bars (chain,pool,token,ts,interval_ms,seen_ts,open,high,low,close,volume_usd,source,"
                f"raw_id) VALUES ({lit(r.chain)},{lit(r.pool)},{lit(r.token)},{ts(r.ts)},{r.interval_ms},{ts(r.seen_ts)},"
                f"{lit(r.open)},{lit(r.high)},{lit(r.low)},{lit(r.close)},{lit(r.volume_usd)},{lit(r.source)},"
                f"{lit(r.raw_id)}) ON CONFLICT DO NOTHING;")
    if isinstance(r, Coverage):
        return (f"INSERT INTO coverage (chain,token,pool,kind,start_ts,end_ts,seen_ts,source,raw_id) VALUES "
                f"({lit(r.chain)},{lit(r.token)},{lit(r.pool)},{lit(r.kind)},{ts(r.start_ts)},{ts(r.end_ts)},"
                f"{ts(r.seen_ts)},{lit(r.source)},{lit(r.raw_id)}) ON CONFLICT DO NOTHING;")
    return None


def manifest_sql(run_id: str, e: ManifestEntry) -> str:
    return (f"INSERT INTO raw_manifest (run_id,seq,provider,endpoint,url,request_ts,response_ts,status,raw_id,bytes,"
            f"attempts,error,context) VALUES ({lit(run_id)},{e.seq},{lit(e.provider)},{lit(e.endpoint)},{lit(e.url)},"
            f"{ts(e.request_ts)},{ts(e.response_ts)},{lit(e.status)},{lit(e.raw_id)},{lit(e.bytes)},{lit(e.attempts)},"
            f"{lit(e.error)},{lit(e.context)});")


def replay_sql(summary: dict, records: Iterable[dict]) -> list[str]:
    rid = f"{summary['dataset_id']}|{summary['configuration_hash']}|{summary['code_version']}"
    out = [f"INSERT INTO replay_runs (replay_id,dataset_id,config_hash,code_version,start_ts,end_ts,step_ms,capabilities,"
           f"records_sha256,summary) VALUES ({lit(rid)},{lit(summary['dataset_id'])},{lit(summary['configuration_hash'])},"
           f"{lit(summary['code_version'])},{ts(summary['start_ts'])},{ts(summary['end_ts'])},{summary['step_ms']},"
           f"{lit(summary['capabilities'])},{lit(summary['records_sha256'])},{lit(summary)});"]
    for r in records:
        out.append(f"INSERT INTO replay_records (replay_id,token,chain,as_of,configuration_hash,code_version,dataset_id,"
                   f"signal,move_class,data_quality,risk,entry,exit,reason,outcome,payload) VALUES ({lit(rid)},"
                   f"{lit(r['token'])},{lit(r['chain'])},{ts(r['as_of'])},{lit(r['configuration_hash'])},"
                   f"{lit(r['code_version'])},{lit(r['dataset_id'])},{lit(r['signal'])},{lit(r['move_class'])},"
                   f"{arr(r['data_quality'])},{lit(r['risk'])},{lit(r['entry'])},{lit(r['exit'])},{lit(r['reason'])},"
                   f"{lit(r['outcome'])},{lit(r)});")
    return out


# Integrity queries run after loading an archive. Each returns a single integer that must be 0.
VALIDATION_QUERIES = {
    "swaps_without_raw_id": "select count(*) from swaps where raw_id is null",
    "bars_without_raw_id": "select count(*) from provider_bars where raw_id is null",
    "snapshots_without_raw_id": "select count(*) from pool_snapshots where raw_id is null",
    "raw_ids_not_in_manifest": ("select count(*) from (select raw_id from swaps union select raw_id from provider_bars "
                                "union select raw_id from pool_snapshots union select raw_id from coverage "
                                "union select raw_id from holder_snapshots) r where r.raw_id is not null and not exists "
                                "(select 1 from raw_manifest m where m.raw_id = r.raw_id)"),
    "orphan_pools": "select count(*) from pools p where not exists (select 1 from tokens t where t.chain=p.chain and t.address=p.token)",
    "orphan_swaps": "select count(*) from swaps s where not exists (select 1 from tokens t where t.chain=s.chain and t.address=s.token)",
    "orphan_replay_records": "select count(*) from replay_records r where not exists (select 1 from replay_runs u where u.replay_id=r.replay_id)",
    "replay_config_hash_mismatch": ("select count(*) from replay_records r join replay_runs u using (replay_id) "
                                    "where r.configuration_hash <> u.config_hash"),
    "duplicate_replay_steps": "select count(*) - count(distinct (replay_id, token, as_of)) from replay_records",
    "seen_before_event_swaps": "select count(*) from swaps where seen_ts < ts - interval '5 seconds'",
    "unclosed_bars": "select count(*) from provider_bars where seen_ts < ts + make_interval(secs => interval_ms/1000.0)",
    "coverage_beyond_seen": "select count(*) from coverage where end_ts > seen_ts",
}


def journal_sql(lines: list[str]) -> list[str]:
    out = []
    for l in lines:
        r = json.loads(l)
        out.append(f"INSERT INTO journal (kind,config_hash,label_rules,prev_hash,hash,payload) VALUES ({lit(r['kind'])},"
                   f"{lit(r['config'])},{lit(r['label_rules'])},{lit(r['prev'])},{lit(r['hash'])},{lit(r['payload'])});")
    return out
