"""Deterministic Phase 3A readiness gate: READY or NOT_READY, with reasons.

Two kinds of condition:
  integrity   must hold whatever the thresholds: replay determinism,
              point-in-time validity, traceability, evidence integrity,
              frozen freshness policy, clean scope, no blank matrix cells
  thresholds  read from config/phase3a_readiness.toml; while the file is
              unapproved or any value is UNSET the gate is NOT_READY. The
              gate never supplies a value of its own.
"""
from __future__ import annotations

import hashlib
import json
import tomllib
from pathlib import Path

CONFIG = Path(__file__).resolve().parents[2] / "config" / "phase3a_readiness.toml"
INTEGRITY = ("replay_determinism", "point_in_time_validity", "traceability", "evidence_integrity",
             "freshness_policy_frozen", "scope_clean", "no_blank_cells", "contract_valid")
# metric name -> (threshold key, comparison)
METRICS = {
    "funding_transfer_share": ("funding_transfer_min_share", ">="),
    "liquidity_vault_delta_share": ("liquidity_vault_delta_min_share", ">="),
    "creator_state_share": ("creator_state_min_share", ">="),
    "holder_state_share": ("holder_state_min_share", ">="),
    "news_share": ("news_min_share", ">="),
    "social_share": ("social_min_share", ">="),
    "freshness_compliance": ("freshness_min_compliance", ">="),
    "provider_error_rate": ("provider_max_error_rate", "<="),
    "multi_day_days": ("multi_day_min_days", ">="),
    "universe_tokens": ("universe_min_tokens", ">="),
}
RULE = ("READY only if every integrity condition holds, the readiness config is approved by a named human, every "
        "threshold is set, and every metric meets its threshold; otherwise NOT_READY with one reason per failure")


def load_config(path: Path = CONFIG) -> dict:
    with open(path, "rb") as fh:
        return tomllib.load(fh)


def config_fingerprint(cfg: dict) -> str:
    return hashlib.sha256(json.dumps(cfg, sort_keys=True).encode()).hexdigest()


def gate(integrity: dict[str, bool], metrics: dict[str, float | None], cfg: dict) -> dict:
    reasons = []
    for k in INTEGRITY:
        if integrity.get(k) is not True:
            reasons.append(f"integrity: {k} not verified")
    approved = cfg.get("approved") is True and bool(cfg.get("approved_by")) and bool(cfg.get("approved_at"))
    if not approved:
        reasons.append("thresholds not approved by a human (config/phase3a_readiness.toml: approved = false)")
    th = cfg.get("thresholds", {})
    for m, (key, op) in METRICS.items():
        t = th.get(key, "UNSET")
        v = metrics.get(m)
        if not isinstance(t, (int, float)) or isinstance(t, bool):
            reasons.append(f"threshold {key} is UNSET (metric {m} = {v})")
            continue
        if v is None:
            reasons.append(f"metric {m} not observed")
        elif not (v >= t if op == ">=" else v <= t):
            reasons.append(f"metric {m} = {v} fails {op} {t}")
    return {"result": "NOT_READY" if reasons else "READY", "reasons": reasons, "rule": RULE,
            "integrity": {k: integrity.get(k) is True for k in INTEGRITY}, "metrics": metrics,
            "config": cfg, "config_fingerprint": config_fingerprint(cfg)}
