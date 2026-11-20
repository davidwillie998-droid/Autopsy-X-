"""Integrity checks for MT5 market-snapshot CSV exports.

This module validates replay input only. It does not execute MQL5 strategy logic
and deliberately computes no trading-performance statistics.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

REQUIRED_COLUMNS = {
    "record_type",
    "sequence",
    "symbol",
    "magic",
    "time_msc",
    "bid",
    "ask",
    "spread_points",
    "dropped_before",
}


@dataclass(frozen=True)
class SnapshotAudit:
    path: str
    symbol: str | None
    magic: int | None
    rows: int
    invalid_rows: int
    invalid_quotes: int
    timestamp_regressions: int
    duplicate_timestamps: int
    sequence_gaps: int
    reported_dropped_rows: int
    first_time_msc: int | None
    last_time_msc: int | None

    @property
    def valid_for_replay_import(self) -> bool:
        return (
            self.rows > 0
            and self.invalid_rows == 0
            and self.invalid_quotes == 0
            and self.timestamp_regressions == 0
            and self.sequence_gaps == 0
            and self.reported_dropped_rows == 0
        )

    def to_dict(self) -> dict[str, Any]:
        result = asdict(self)
        result["valid_for_replay_import"] = self.valid_for_replay_import
        return result


def audit_snapshot(path: str | Path) -> SnapshotAudit:
    source = Path(path)
    with source.open("r", newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        columns = set(reader.fieldnames or ())
        missing = REQUIRED_COLUMNS - columns
        if missing:
            raise ValueError(f"snapshot is missing required columns: {sorted(missing)}")

        rows = invalid_rows = invalid_quotes = 0
        timestamp_regressions = duplicate_timestamps = sequence_gaps = 0
        reported_dropped_rows = 0
        first_time = last_time = previous_time = previous_sequence = None
        symbol: str | None = None
        magic: int | None = None

        for raw in reader:
            if raw.get("record_type") == "SUMMARY":
                try:
                    reported_dropped_rows = max(reported_dropped_rows, int(raw["sequence"]))
                except (TypeError, ValueError):
                    invalid_rows += 1
                continue
            if raw.get("record_type") != "TICK":
                invalid_rows += 1
                continue
            rows += 1
            try:
                sequence = int(raw["sequence"])
                row_symbol = raw["symbol"]
                row_magic = int(raw["magic"])
                timestamp = int(raw["time_msc"])
                bid = float(raw["bid"])
                ask = float(raw["ask"])
                spread = float(raw["spread_points"])
                dropped = int(raw["dropped_before"])
                if not all(math.isfinite(value) for value in (bid, ask, spread)):
                    raise ValueError("non-finite numeric field")
            except (TypeError, ValueError, KeyError):
                invalid_rows += 1
                continue

            if symbol is None:
                symbol, magic = row_symbol, row_magic
            elif row_symbol != symbol or row_magic != magic:
                invalid_rows += 1

            if bid <= 0 or ask <= bid or spread < 0:
                invalid_quotes += 1

            if previous_sequence is not None and sequence != previous_sequence + 1:
                sequence_gaps += max(1, sequence - previous_sequence - 1)
            if previous_time is not None:
                if timestamp < previous_time:
                    timestamp_regressions += 1
                elif timestamp == previous_time:
                    duplicate_timestamps += 1

            if first_time is None:
                first_time = timestamp
            last_time = timestamp
            previous_time = timestamp
            previous_sequence = sequence
            reported_dropped_rows = max(reported_dropped_rows, dropped)

    return SnapshotAudit(
        path=str(source),
        symbol=symbol,
        magic=magic,
        rows=rows,
        invalid_rows=invalid_rows,
        invalid_quotes=invalid_quotes,
        timestamp_regressions=timestamp_regressions,
        duplicate_timestamps=duplicate_timestamps,
        sequence_gaps=sequence_gaps,
        reported_dropped_rows=reported_dropped_rows,
        first_time_msc=first_time,
        last_time_msc=last_time,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate an AUTOPSY X MT5 snapshot CSV.")
    parser.add_argument("snapshot", type=Path)
    args = parser.parse_args()
    try:
        result = audit_snapshot(args.snapshot)
    except (OSError, ValueError) as exc:
        parser.error(str(exc))
    print(json.dumps(result.to_dict(), indent=2, sort_keys=True))
    return 0 if result.valid_for_replay_import else 2


if __name__ == "__main__":
    raise SystemExit(main())
