"""Phase 3A observation contract.

One record type for every new evidence class (funding transfers, liquidity
events, creator state, news, social). The contract's purpose is that
"not seen" can never be read as "seen, and it was zero / false / none":

* ``state`` says whether the fact was observed at all. Only OBSERVED records
  carry a value; every other state carries an empty value.
* ``source_ts`` (what the provider says the event time is) has its own
  state, so a missing block time or publication time is NOT_OBSERVED rather
  than silently replaced by the ingestion time.
* ``ingestion_ts`` is the local receive time; point-in-time reads filter on
  it (it is exposed as ``seen_ts`` for the store).
"""
from __future__ import annotations

from dataclasses import asdict, dataclass, field
from enum import Enum

SCHEMA_VERSION = "3a.1"


class Availability(str, Enum):
    OBSERVED = "OBSERVED"              # the provider returned the fact
    NOT_OBSERVED = "NOT_OBSERVED"      # asked, provider answered, the fact was not in the answer
    UNAVAILABLE = "UNAVAILABLE"        # the provider does not offer this fact (or needs auth we do not have)
    STALE = "STALE"                    # observed, but older than the frozen freshness policy allows
    ERROR = "ERROR"                    # the request failed (transport, HTTP or RPC error)
    UNKNOWN = "UNKNOWN"                # the fact exists in principle but cannot be established (e.g. beneficiary)
    NOT_APPLICABLE = "NOT_APPLICABLE"  # the question does not apply (e.g. mint of a native SOL transfer)


KINDS = ("funding_transfer", "liquidity_event", "creator_state", "news", "social")

# Fields every OBSERVED value of a kind must carry (values may themselves be None only
# where the kind documents a paired *_state field).
REQUIRED_VALUE_FIELDS: dict[str, tuple[str, ...]] = {
    "funding_transfer": ("program", "source", "destination", "amount", "amount_raw", "mint", "mint_state",
                         "tx_status", "signers", "fee_payer", "beneficiary", "beneficiary_status"),
    "liquidity_event": ("event_type", "pool", "vault_deltas", "classification_method", "tx_status"),
    "creator_state": ("creator", "creator_state", "creator_pct", "creator_pct_state"),
    "news": ("title", "url", "domain", "content_sha256", "publication_time_state", "event_type"),
    "social": ("platform", "author", "url", "content_sha256", "publication_time_state", "event_type"),
}


@dataclass(frozen=True)
class Observation:
    kind: str
    entity: str  # token mint, wallet or pool the observation is about
    chain: str
    venue: str | None
    state: Availability
    observation_ts: int  # when the fact holds in the world, as best known (event time or response time)
    source_ts: int | None  # provider's own timestamp (block time, publication time)
    source_ts_state: Availability
    ingestion_ts: int  # local receive time; point-in-time reads filter on this
    provider: str
    response_status: int | None
    raw_id: str | None
    slot: int | None = None
    signature: str | None = None
    value: dict = field(default_factory=dict)
    reason: str = ""
    schema_version: str = SCHEMA_VERSION

    @property
    def seen_ts(self) -> int:
        return self.ingestion_ts

    @property
    def uid(self) -> tuple:
        """Identity used for deduplication across overlapping responses."""
        return (self.kind, self.chain, self.entity, self.signature, self.value.get("url"),
                self.value.get("source"), self.value.get("destination"), self.value.get("amount_raw"),
                self.observation_ts if self.signature is None and not self.value.get("url") else None)

    def to_dict(self) -> dict:
        d = asdict(self)
        d["state"] = self.state.value
        d["source_ts_state"] = self.source_ts_state.value
        return d

    @classmethod
    def from_dict(cls, d: dict) -> "Observation":
        d = dict(d)
        d["state"] = Availability(d["state"])
        d["source_ts_state"] = Availability(d["source_ts_state"])
        return cls(**d)


class ContractViolation(ValueError):
    pass


def validate(o: Observation) -> Observation:
    """Raise ContractViolation unless the record keeps every state explicit."""
    if o.kind not in KINDS:
        raise ContractViolation(f"unknown kind {o.kind!r}")
    if not isinstance(o.state, Availability) or not isinstance(o.source_ts_state, Availability):
        raise ContractViolation("states must be Availability members")
    if not isinstance(o.ingestion_ts, int) or not isinstance(o.observation_ts, int):
        raise ContractViolation("ingestion_ts and observation_ts must be integer milliseconds")
    if (o.source_ts is None) != (o.source_ts_state != Availability.OBSERVED):
        raise ContractViolation(f"source_ts={o.source_ts!r} inconsistent with source_ts_state={o.source_ts_state.value}")
    if o.source_ts is not None and o.source_ts > o.ingestion_ts + 5_000:
        raise ContractViolation("source_ts after ingestion_ts: a provider cannot report the future")
    if o.state == Availability.OBSERVED:
        missing = [f for f in REQUIRED_VALUE_FIELDS[o.kind] if f not in o.value]
        if missing:
            raise ContractViolation(f"OBSERVED {o.kind} lacks fields {missing}")
        if o.raw_id is None:
            raise ContractViolation("OBSERVED record without raw provenance")
    else:
        if o.value:
            raise ContractViolation(f"{o.state.value} record carries a value; only OBSERVED records may")
        if not o.reason:
            raise ContractViolation(f"{o.state.value} record without a reason")
    for k, v in o.value.items():
        if k.endswith("_state") and v not in {a.value for a in Availability}:
            raise ContractViolation(f"{k}={v!r} is not an Availability state")
        base = k[: -len("_state")] if k.endswith("_state") else None
        if base and base in o.value and (o.value[base] is None) == (v == Availability.OBSERVED.value):
            raise ContractViolation(f"{base}={o.value[base]!r} inconsistent with {k}={v}")
    return o
