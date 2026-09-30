"""Raw response archive.

Every HTTP exchange an acquisition run makes, successful or not, becomes one
manifest line. Successful bodies are stored byte-for-byte (gzip with a fixed
mtime, so the archive itself is deterministic) under their sha256, which is
the ``raw_id`` every normalized record carries.

Layout of a run directory::

    manifest.jsonl        one line per exchange, in request order
    raw/<sha256>.json.gz  response bodies, content-addressed
    selection.json        how the token universe was chosen (seed, strata)
    run.json              run metadata (start, end, code version, parameters)
"""
from __future__ import annotations

import gzip
import hashlib
import json
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Iterator


@dataclass(frozen=True)
class ManifestEntry:
    seq: int
    provider: str
    endpoint: str  # logical endpoint name, e.g. "gt.trades"
    url: str
    request_ts: int
    response_ts: int | None
    status: int | None
    raw_id: str | None  # sha256 of body; None when no body was received
    bytes: int | None
    attempts: int | None
    error: str | None
    context: dict = field(default_factory=dict)  # chain, pool, token, stratum...

    def to_json(self) -> str:
        return json.dumps(asdict(self), sort_keys=True)


def sha256(body: bytes) -> str:
    return hashlib.sha256(body).hexdigest()


class RawStore:
    def __init__(self, run_dir: str | Path):
        self.dir = Path(run_dir)
        (self.dir / "raw").mkdir(parents=True, exist_ok=True)
        self._seq = sum(1 for _ in self._lines()) if (self.dir / "manifest.jsonl").exists() else 0

    def _lines(self) -> Iterator[str]:
        with open(self.dir / "manifest.jsonl") as fh:
            for line in fh:
                if line.strip():
                    yield line

    def record(self, *, provider: str, endpoint: str, url: str, request_ts: int, response_ts: int | None,
               status: int | None, body: bytes | None, attempts: int | None, error: str | None,
               context: dict | None = None) -> ManifestEntry:
        raw_id = None
        if body is not None:
            raw_id = sha256(body)
            path = self.dir / "raw" / f"{raw_id}.json.gz"
            if not path.exists():
                path.write_bytes(gzip.compress(body, mtime=0))
        self._seq += 1
        e = ManifestEntry(self._seq, provider, endpoint, url, request_ts, response_ts, status, raw_id,
                          len(body) if body is not None else None, attempts, error, context or {})
        with open(self.dir / "manifest.jsonl", "a") as fh:
            fh.write(e.to_json() + "\n")
        return e

    def body(self, raw_id: str) -> bytes:
        data = gzip.decompress((self.dir / "raw" / f"{raw_id}.json.gz").read_bytes())
        if sha256(data) != raw_id:
            raise ValueError(f"raw body {raw_id} fails its own hash: archive corrupted")
        return data

    def entries(self) -> list[ManifestEntry]:
        if not (self.dir / "manifest.jsonl").exists():
            return []
        return [ManifestEntry(**json.loads(l)) for l in self._lines()]

    def write_json(self, name: str, obj) -> None:
        (self.dir / name).write_text(json.dumps(obj, indent=2, sort_keys=True) + "\n")

    def read_json(self, name: str):
        p = self.dir / name
        return json.loads(p.read_text()) if p.exists() else None
