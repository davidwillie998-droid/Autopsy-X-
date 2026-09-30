"""Configuration loading. Secrets come from environment variables only."""
from __future__ import annotations

import hashlib
import json
import os
import tomllib
from pathlib import Path
from typing import Any

DEFAULT_PATH = Path(__file__).resolve().parents[2] / "config" / "default.toml"


class Config:
    def __init__(self, data: dict[str, Any]):
        self._data = data

    @classmethod
    def load(cls, path: str | Path | None = None, overrides: dict[str, Any] | None = None) -> "Config":
        with open(path or DEFAULT_PATH, "rb") as fh:
            data = tomllib.load(fh)
        if overrides:
            data = _deep_merge(data, overrides)
        return cls(data)

    def section(self, name: str) -> dict[str, Any]:
        if name not in self._data:
            raise KeyError(f"config section [{name}] missing")
        return self._data[name]

    @property
    def raw(self) -> dict[str, Any]:
        return self._data

    def fingerprint(self) -> str:
        """Stable hash recorded with every backtest and journal entry."""
        blob = json.dumps(self._data, sort_keys=True, default=str).encode()
        return hashlib.sha256(blob).hexdigest()[:16]


def secret(name: str) -> str | None:
    """Read a provider credential. Never logged, never written to disk."""
    return os.environ.get(name) or None


def _deep_merge(a: dict, b: dict) -> dict:
    out = dict(a)
    for k, v in b.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = _deep_merge(out[k], v)
        else:
            out[k] = v
    return out
